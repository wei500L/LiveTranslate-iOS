import Foundation
import OSLog
import SwiftUI

/// Installer for the downloadable AI models — the same streamed,
/// SHA256-gated, pause/resumable flow as `ModelInstaller`, generalized to
/// any install root (AI models do not need the Core ML compile step).
///
/// Reuses `ModelInstaller`'s download machinery by delegating to a fresh
/// instance per install (the installer is @MainActor and holds per-install
/// progress; a shared instance would fight the ASR manager's installs).
@MainActor
@Observable
final class AIModelInstaller {
    static let logger = Logger(subsystem: "com.livetranslate.ios", category: "ai-model-installer")

    struct Progress: Equatable, Sendable {
        var completedBytes: Int = 0
        var totalBytes: Int = 0
        var fraction: Double {
            totalBytes > 0 ? Double(completedBytes) / Double(totalBytes) : 0
        }
    }

    private(set) var isInstalling = false
    private(set) var isPaused = false
    private(set) var progress = Progress()

    private let delegate: ModelInstaller

    init() {
        self.delegate = ModelInstaller()
    }

    /// Install one AI model end-to-end: download every manifest file with
    /// streaming SHA256 verification (pause/resume with HTTP Range),
    /// atomic rename into the install tree. Throws on failure; safe to
    /// retry. `onProgress` fires on the main actor as bytes land.
    ///
    /// `context` selects the download source: `.huggingFace` (manifest
    /// URLs, no auth) or `.server` (the user's own server + Bearer). The
    /// SHA256 gate is identical either way — the source only decides
    /// where bytes come from.
    func install(
        _ model: ModelManifest.BackendInfo,
        context: AIModelDownloadContext?,
        onProgress: @escaping @MainActor (Progress) -> Void = { _ in }
    ) async throws {
        isInstalling = true
        isPaused = false
        progress = Progress(completedBytes: 0, totalBytes: model.totalDownloadBytes)
        defer { isInstalling = false }

        // Resolve the per-file URLs once, before any byte moves (a nil
        // resolution under the server source is an immediate, honest
        // failure — never a silent fallback to another source).
        var overrides: [String: URL] = [:]
        if let context {
            for file in model.files {
                if let url = context.source.resolvedURL(
                    manifestURL: file.url,
                    modelID: model.id,
                    filePath: file.path,
                    serverBaseURL: context.serverBaseURL
                ) {
                    if url.absoluteString != file.url {
                        overrides[file.path] = url
                    }
                } else {
                    throw TranslationError.fatal(String(localized: "云端服务器下载源不可用：请确认已在设置中配置并登录服务器，或改用平台直连。"))
                }
            }
        }
        delegate.downloadURLOverrides = overrides
        delegate.downloadAuthToken = context?.source == .server ? context?.authToken : nil

        // Disk-space preflight with AI-model phrasing (the delegate's
        // text mentions the Core ML compiled copy, which does not apply).
        let root = try ModelPaths.aiModelRootKind(model)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let values = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let available = values.volumeAvailableCapacityForImportantUsage ?? 0
        guard available >= model.minimumFreeDiskBytes else {
            throw ModelInstaller.InstallerError.diskSpaceLow(
                neededBytes: model.minimumFreeDiskBytes, availableBytes: Int(available)
            )
        }
        try await delegate.install(model, intoRoot: root) { delegateProgress in
            self.progress.completedBytes = delegateProgress.completedBytes
            self.progress.totalBytes = delegateProgress.totalBytes
            onProgress(self.progress)
        }
    }

    /// Pause the in-flight install. Partial files stay for resume.
    func pause() {
        delegate.pause()
        isPaused = true
    }
}

extension ModelInstaller {
    /// AI-model install entry: same per-file flow as `install(_:)` but
    /// with a caller-chosen root (the ASR `install` hardcodes the ASR
    /// backend root via `ModelPaths.backendRoot`).
    func install(
        _ model: ModelManifest.BackendInfo,
        intoRoot root: URL,
        onProgress: @escaping @MainActor (ModelInstaller.Progress) -> Void
    ) async throws {
        precondition(!isInstalling, "installer is not reentrant")
        isInstalling = true
        isPaused = false
        progress = Progress(completedBytes: 0, totalBytes: model.totalDownloadBytes)
        defer { isInstalling = false; currentFile = nil }

        try preflightDiskSpace(model)

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        FileProtection.apply(.modelFile, to: root)

        for file in model.files {
            guard ModelIntegrityVerifier.isSafePath(file.path) else {
                throw ModelInstaller.InstallerError.unsafePath(file.path)
            }
            let destination = root.appendingPathComponent(file.path)
            if await ModelIntegrityVerifier.verify(file: file, at: destination) == nil {
                progress.completedBytes += file.bytes
                onProgress(progress)
                continue
            }
            currentFile = (file.path as NSString).lastPathComponent
            try await downloadFile(file, to: destination, onProgress: onProgress)
        }
        Self.logger.info("AI model install complete (\(model.id, privacy: .public))")
    }
}

extension ModelPaths {
    /// Resolve an AI model's install root from its manifest id.
    static func aiModelRootKind(_ model: ModelManifest.BackendInfo) throws -> URL {
        guard let kind = LocalAIModelKind.allCases.first(where: { $0.manifestKey == model.id })
        else {
            throw ModelInstaller.InstallerError.unsafePath("unknown AI model id \(model.id)")
        }
        return try aiModelRoot(kind)
    }
}
