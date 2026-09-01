import Foundation
import CoreML
import OSLog

/// Compiles `.mlpackage` sources into a versioned on-disk cache and hands
/// out the compiled `.mlmodelc` URLs.
///
/// Rules:
/// - Compilation output goes to `Compiled/v{cacheVersion}/{name}.mlmodelc`.
/// - Compilation happens in a temporary directory first and is moved into
///   place atomically — a failed compile never destroys a working old cache.
/// - Bumping `cacheVersion` in the manifest invalidates every older version
///   directory (`pruneOldVersions` removes them once the new one is built).
enum CompiledCoreMLCache {
    static let logger = Logger(subsystem: "com.livetranslate.ios", category: "coreml-cache")

    enum CacheError: LocalizedError {
        case sourceMissing(String)
        case compileFailed(String)

        var errorDescription: String? {
            switch self {
            case .sourceMissing(let path):
                return "Core ML source package not found: \(path)"
            case .compileFailed(let reason):
                return "Core ML compilation failed: \(reason)"
            }
        }
    }

    /// The three GigaAM sub-models of the Core ML backend.
    static let packageNames = [
        "GigaAMv3Encoder",
        "GigaAMv3DecoderStep",
        "GigaAMv3JointStep",
    ]

    static func compiledURL(packageName: String, cacheVersion: Int) throws -> URL {
        try ModelPaths.coreMLCompiledRoot(cacheVersion: cacheVersion)
            .appendingPathComponent("\(packageName).mlmodelc", isDirectory: true)
    }

    static func sourceURL(packageName: String) throws -> URL {
        try ModelPaths.coreMLSourceRoot()
            .appendingPathComponent("\(packageName).mlpackage", isDirectory: true)
    }

    /// A compiled model counts as present only when its directory exists
    /// and contains the manifest plist Core ML writes on successful builds.
    static func isCompiled(packageName: String, cacheVersion: Int) -> Bool {
        guard let url = try? compiledURL(packageName: packageName, cacheVersion: cacheVersion) else {
            return false
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        // A partially moved directory must not count as a valid cache entry.
        return FileManager.default.fileExists(
            atPath: url.appendingPathComponent("model.mil").path
        ) || FileManager.default.fileExists(
            atPath: url.appendingPathComponent("com.apple.CoreML/model.mil").path
        )
    }

    static func allCompiled(cacheVersion: Int) -> Bool {
        packageNames.allSatisfy { isCompiled(packageName: $0, cacheVersion: cacheVersion) }
    }

    /// Compile `packageName` from Source/ into the versioned cache and
    /// return the compiled URL. Uses an existing cache entry when valid.
    /// `progress` reports 0–1 across all three packages when installing.
    @discardableResult
    static func compile(
        packageName: String,
        cacheVersion: Int
    ) async throws -> URL {
        let source = try sourceURL(packageName: packageName)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue else {
            throw CacheError.sourceMissing(source.lastPathComponent)
        }

        if isCompiled(packageName: packageName, cacheVersion: cacheVersion) {
            logger.debug("Cache hit for \(packageName, privacy: .public) v\(cacheVersion)")
            return try compiledURL(packageName: packageName, cacheVersion: cacheVersion)
        }

        let destination = try compiledURL(packageName: packageName, cacheVersion: cacheVersion)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Compile into a sibling temp dir, then atomically move into place
        // so a failure leaves any previous working cache untouched.
        let tempRoot = destination.deletingLastPathComponent()
            .appendingPathComponent(".tmp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let compiled: URL
        let started = Date()
        do {
            compiled = try await Task.detached(priority: .userInitiated) {
                try MLModel.compileModel(at: source)
            }.value
        } catch {
            logger.error("Compile failed for \(packageName, privacy: .public): \(String(describing: error), privacy: .public)")
            throw CacheError.compileFailed("\(packageName): \(error.localizedDescription)")
        }
        let duration = Date().timeIntervalSince(started)
        logger.info("Compiled \(packageName, privacy: .public) in \(duration, privacy: .public)s")

        let finalPath = destination
        do {
            // Remove a leftover (never-valid) destination before the move.
            try? FileManager.default.removeItem(at: finalPath)
            try FileManager.default.moveItem(at: compiled, to: finalPath)
        } catch {
            throw CacheError.compileFailed("\(packageName): could not move compiled model into cache — \(error.localizedDescription)")
        }
        return finalPath
    }

    /// Compile all three packages for the given cache version.
    static func compileAll(cacheVersion: Int) async throws {
        for name in packageNames {
            _ = try await compile(packageName: name, cacheVersion: cacheVersion)
        }
        pruneOldVersions(keeping: cacheVersion)
    }

    /// Remove version directories older than the current one. Called only
    /// after the new version compiled successfully, so we never invalidate
    /// a working cache without a replacement.
    static func pruneOldVersions(keeping currentVersion: Int) {
        guard let root = try? ModelPaths.coreMLCompiledRoot() else { return }
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return }
        for child in children {
            let name = child.lastPathComponent
            guard name.hasPrefix("v") else { continue }
            let version = Int(name.dropFirst())
            if let version, version < currentVersion {
                logger.info("Pruning old Core ML cache \(name, privacy: .public)")
                try? FileManager.default.removeItem(at: child)
            }
        }
    }

    /// Delete the entire compiled cache (used when the Core ML backend is
    /// removed). Source files are deleted separately by the installer.
    static func removeAll() {
        guard let root = try? ModelPaths.coreMLCompiledRoot() else { return }
        try? FileManager.default.removeItem(at: root)
    }
}
