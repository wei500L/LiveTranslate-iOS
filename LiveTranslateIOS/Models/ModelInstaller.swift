import Foundation
import OSLog

/// Downloads and installs one backend's model files per the manifest.
///
/// Install flow per file: stream `URLSession.bytes` into a hidden
/// `.{uuid}.partial` file (so nothing half-written is ever mistaken for a
/// model), verify size + SHA256, then atomically rename into the install
/// tree. Core ML `.mlpackage` directory structure is rebuilt file-by-file
/// from the manifest paths. After every file of the Core ML backend is
/// verified, the three packages are compiled into the versioned cache.
///
/// Failure semantics: a hash mismatch deletes the partial file and throws;
/// the user can retry (the whole file re-downloads). Pause cancels the
/// in-flight file and keeps its partial; resume continues it with an HTTP
/// Range request when the server supports it, otherwise the file restarts.
@MainActor
@Observable
final class ModelInstaller {
    static let logger = Logger(subsystem: "com.livetranslate.ios", category: "model-installer")

    enum InstallerError: LocalizedError, Equatable {
        case diskSpaceLow(neededBytes: Int, availableBytes: Int)
        case unsafePath(String)

        var errorDescription: String? {
            switch self {
            case .diskSpaceLow(let needed, let available):
                return String(format: String(localized: "Not enough free disk space. About %.1f GB is required (source files, compiled copy and temporary files); %.1f GB is available."),
                              Double(needed) / 1_000_000_000, Double(available) / 1_000_000_000)
            case .unsafePath(let path):
                return "Refusing to install a file with an unsafe path: \(path)"
            }
        }
    }

    struct Progress: Equatable, Sendable {
        var completedBytes: Int = 0
        var totalBytes: Int = 0
        /// 0–1 across the whole backend install.
        var fraction: Double {
            totalBytes > 0 ? Double(completedBytes) / Double(totalBytes) : 0
        }
    }

    private(set) var isInstalling = false
    private(set) var isPaused = false
    private(set) var progress = Progress()
    private(set) var currentFile: String?
    private(set) var isCompiling = false

    private var activeTask: Task<Void, any Error>?
    private let session: URLSession

    /// Download bytes accumulated per disk write.
    nonisolated private static let writeChunkBytes = 262_144

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Public entry points

    /// Install one backend end-to-end. Throws on any failure; safe to call
    /// again to retry. `onProgress` fires on the main actor as bytes land.
    func install(
        _ backend: ModelManifest.BackendInfo,
        onProgress: @escaping @MainActor (Progress) -> Void = { _ in }
    ) async throws {
        precondition(!isInstalling, "installer is not reentrant")
        isInstalling = true
        isPaused = false
        isCompiling = false
        progress = Progress(completedBytes: 0, totalBytes: backend.totalDownloadBytes)
        defer { isInstalling = false; currentFile = nil; isCompiling = false }

        // Disk-space preflight: the Core ML backend needs source + compiled
        // copy + temp files simultaneously — not just the download size.
        try preflightDiskSpace(backend)

        let root = try ModelPaths.backendRoot(backend.kind)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        for file in backend.files {
            guard ModelIntegrityVerifier.isSafePath(file.path) else {
                throw InstallerError.unsafePath(file.path)
            }
            let destination = root.appendingPathComponent(file.path)

            // Already-installed and verified: count it and move on.
            if await ModelIntegrityVerifier.verify(file: file, at: destination) == nil {
                progress.completedBytes += file.bytes
                onProgress(progress)
                continue
            }

            currentFile = (file.path as NSString).lastPathComponent
            try await downloadFile(file, to: destination, backend: backend, onProgress: onProgress)
        }

        if backend.kind == .coreMLFP16 {
            guard let cacheVersion = backend.coreMLCompiledCacheVersion else {
                throw InstallerError.unsafePath("manifest is missing coreMLCompiledCacheVersion")
            }
            isCompiling = true
            try await CompiledCoreMLCache.compileAll(cacheVersion: cacheVersion)
        }
        Self.logger.info("Install complete for \(backend.kind.rawValue, privacy: .public)")
    }

    /// Pause the in-flight install. Partial files stay on disk for resume.
    func pause() {
        guard isInstalling, !isPaused else { return }
        isPaused = true
        activeTask?.cancel()
        Self.logger.info("Install paused at \(self.progress.fraction, privacy: .public)")
    }

    // MARK: - Internals

    private func preflightDiskSpace(_ backend: ModelManifest.BackendInfo) throws {
        let root = try ModelPaths.modelsRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let values = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let available = values.volumeAvailableCapacityForImportantUsage ?? 0
        guard available >= backend.minimumFreeDiskBytes else {
            throw InstallerError.diskSpaceLow(
                neededBytes: backend.minimumFreeDiskBytes, availableBytes: Int(available)
            )
        }
    }

    private func downloadFile(
        _ file: ModelManifest.BackendInfo.FileInfo,
        to destination: URL,
        backend: ModelManifest.BackendInfo,
        onProgress: @escaping @MainActor (Progress) -> Void
    ) async throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Hidden sibling temp file — a half-written file must never be
        // mistaken for an installed model.
        let partialURL = destination.deletingLastPathComponent()
            .appendingPathComponent(".partial-\(destination.lastPathComponent)-\(UUID().uuidString)")
        // Bytes already on disk from a paused attempt of the same file, if
        // the previous partial is still next to the destination.
        var resumeOffset = 0
        if let stale = try findStalePartial(nextTo: destination) {
            resumeOffset = (try? FileManager.default.attributesOfItem(atPath: stale.path)[.size] as? Int) ?? 0
            if resumeOffset > 0, resumeOffset < file.bytes {
                try? FileManager.default.moveItem(at: stale, to: partialURL)
            } else {
                try? FileManager.default.removeItem(at: stale)
                resumeOffset = 0
            }
        }

        var request = URLRequest(url: URL(string: file.url)!)
        request.timeoutInterval = 60
        if resumeOffset > 0 {
            request.setValue("bytes=\(resumeOffset)-", forHTTPHeaderField: "Range")
        }

        // Snapshot of bytes already banked by earlier files in this install.
        let baseCompleted = progress.completedBytes

        // Detached: file writes must stay off the main actor; progress hops
        // back through `reportProgress`.
        let downloadTask = Task.detached(priority: .userInitiated) {
            let (bytes, response) = try await self.session.bytes(for: request)
            var offset = resumeOffset
            // A server that ignores Range answers 200 with the full body.
            if let http = response as? HTTPURLResponse, resumeOffset > 0, http.statusCode == 200 {
                offset = 0
                try? FileManager.default.removeItem(at: partialURL)
            }

            if !FileManager.default.fileExists(atPath: partialURL.path) {
                FileManager.default.createFile(atPath: partialURL.path, contents: nil)
            }
            let fileHandle = try FileHandle(forWritingTo: partialURL)
            defer { try? fileHandle.close() }
            if offset > 0 { try fileHandle.seek(toOffset: UInt64(offset)) }

            // AsyncBytes yields one byte at a time; batch into 256 KiB
            // writes so disk I/O and the progress hop stay reasonable.
            var iterator = bytes.makeAsyncIterator()
            var buffer = [UInt8]()
            buffer.reserveCapacity(Self.writeChunkBytes)
            while true {
                if Task.isCancelled { throw CancellationError() }
                guard let byte = try await iterator.next() else { break }
                buffer.append(byte)
                if buffer.count >= Self.writeChunkBytes {
                    try fileHandle.write(contentsOf: buffer)
                    offset += buffer.count
                    await self.reportProgress(base: baseCompleted, fileBytes: offset, onProgress: onProgress)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            if !buffer.isEmpty {
                try fileHandle.write(contentsOf: buffer)
                offset += buffer.count
                await self.reportProgress(base: baseCompleted, fileBytes: offset, onProgress: onProgress)
            }
        }
        activeTask = downloadTask
        defer { activeTask = nil }

        do {
            try await downloadTask.value
        } catch let urlError as URLError where urlError.code == .cancelled {
            // URLSession reports task cancellation as URLError.cancelled.
            throw CancellationError()
        } catch is CancellationError {
            // A pause (or task cancellation) — propagate as CancellationError
            // so the manager records the paused state, not an error.
            throw CancellationError()
        }

        // Size + hash gate before the file is allowed into the tree.
        if let failure = await ModelIntegrityVerifier.verify(file: file, at: partialURL) {
            try? FileManager.default.removeItem(at: partialURL)
            throw failure
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partialURL, to: destination)
    }

    /// MainActor progress hop from the download task.
    private func reportProgress(
        base: Int,
        fileBytes: Int,
        onProgress: @escaping @MainActor (Progress) -> Void
    ) {
        progress.completedBytes = base + fileBytes
        onProgress(progress)
    }

    /// Find a leftover `.partial-*` file sitting next to `destination`
    /// from a previous paused/failed attempt.
    private func findStalePartial(nextTo destination: URL) throws -> URL? {
        let dir = destination.deletingLastPathComponent()
        let name = destination.lastPathComponent
        let children = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        return children.first { $0.lastPathComponent.hasPrefix(".partial-") && $0.lastPathComponent.contains(name) }
    }
}
