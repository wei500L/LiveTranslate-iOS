import Foundation
import CoreML
import CryptoKit
import OSLog

/// Compiles, verifies and locates the three Core ML sub-models.
///
/// Layout (see `ModelPaths`):
/// ```
/// coreml-fp16/
///   Source/{GigaAMv3Encoder,GigaAMv3DecoderStep,GigaAMv3JointStep}.mlpackage
///   Metadata/{tokens.json, tokenizer.model, ...}
///   Compiled/v{cacheVersion}/{...}.mlmodelc
/// ```
///
/// Install rules:
/// - Source files are SHA256-verified against the manifest before any
///   compilation starts.
/// - Compilation happens into a staging directory that is atomically
///   renamed into `Compiled/v{N}` only after all three models compiled.
/// - A failed compile never deletes the previously valid version.
/// - Old version directories are pruned only after the new version loads.
struct CoreMLModelLoader {
    static let packageNames = [
        "GigaAMv3Encoder", "GigaAMv3DecoderStep", "GigaAMv3JointStep",
    ]
    static let encoderName = "GigaAMv3Encoder"
    static let decoderName = "GigaAMv3DecoderStep"
    static let jointName = "GigaAMv3JointStep"

    /// Default used when the bundled manifest is unreadable — the manifest
    /// itself is the source of truth and D-module tests cover it.
    static let fallbackCacheVersion = 1

    private static let logger = Logger(
        subsystem: "com.livetranslate.ios", category: "coreml-loader"
    )

    struct LoadedModels {
        let encoder: MLModel
        let decoder: MLModel
        let joint: MLModel
        let computeUnits: MLComputeUnits
        let compiledDuringLoad: Bool
    }

    enum LoaderError: LocalizedError {
        case manifestUnavailable(String)
        case sourceMissing(String)
        case compileFailed(String)

        var errorDescription: String? {
            switch self {
            case .manifestUnavailable(let reason):
                return "Core ML model manifest unavailable: \(reason)"
            case .sourceMissing(let path):
                return "Core ML source model missing: \(path). Re-download the model from Model Management."
            case .compileFailed(let reason):
                return "Core ML compilation failed: \(reason)"
            }
        }
    }

    // MARK: - Public entry points

    /// Whether the backend is installed: all three source `.mlpackage`
    /// bundles are present. "Installed" means the downloaded source —
    /// the compiled cache is produced on first load (`loadModels` compiles
    /// on demand and SHA256-verifies the sources), so requiring it here
    /// would report a freshly installed backend as missing.
    static func isInstalled() async -> Bool {
        let result = await Task.detached(priority: .utility) {
            let root = (try? ModelPaths.backendRoot(.coreMLFP16))?
                .appendingPathComponent("Source")
            guard let root else { return false }
            return packageNames.allSatisfy {
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("\($0).mlpackage").path)
            }
        }.value
        return result
    }

    /// Compile (if needed) and load all three models with one consistent
    /// compute policy. Synchronous and expensive — call from the engine
    /// actor's `prepare()` only.
    static func loadModels(computePreference: CoreMLComputePreference) throws -> LoadedModels {
        let manifest: ModelManifest
        do {
            manifest = try ModelManifest.load()
        } catch {
            throw LoaderError.manifestUnavailable(String(describing: error))
        }
        let cacheVersion = manifest.backend(.coreMLFP16)?.coreMLCompiledCacheVersion
            ?? fallbackCacheVersion

        var compiledDuringLoad = false
        let urls = compiledURLs(cacheVersion: cacheVersion)
        if urls.contains(where: { $0 == nil }) {
            // Either first install or a stale/corrupt cache — rebuild from
            // the verified source.
            let sourceRoot = try ModelPaths.coreMLSourceRoot()
            try verifySourceIntegrity(manifest: manifest, sourceRoot: sourceRoot)
            for name in packageNames where !sourcePackageExists(sourceRoot, name) {
                throw LoaderError.sourceMissing("\(name).mlpackage")
            }
            try compileAll(cacheVersion: cacheVersion, sourceRoot: sourceRoot)
            compiledDuringLoad = true
            guard compiledURLs(cacheVersion: cacheVersion).compactMap({ $0 }).count
                == packageNames.count
            else {
                throw LoaderError.compileFailed("compiled artifacts missing after build")
            }
        } else {
            // Cache hit still verifies the source is present and intact —
            // a tampered source with a valid cache must be caught.
            do {
                let sourceRoot = try ModelPaths.coreMLSourceRoot()
                try verifySourceIntegrity(manifest: manifest, sourceRoot: sourceRoot)
            } catch {
                logger.error("Source integrity check failed on cache hit: \(String(describing: error), privacy: .public)")
                throw error
            }
        }

        let configuration = MLModelConfiguration()
        #if targetEnvironment(simulator)
        // The iOS simulator cannot execute these models on the GPU: E5RT
        // fails MPSGraph backend validation ("incompatible OS") and every
        // inference returns garbage (an <unk> storm). Simulator builds run
        // the same verified weights on the CPU so tests exercise the real
        // math; device builds keep the documented compute policy below.
        // The engine records the *actual* units used, so simulator test
        // reports honestly show cpuOnly.
        configuration.computeUnits = .cpuOnly
        #else
        switch computePreference {
        case .accuracy:
            // Token-exact vs the PyTorch reference — the documented default.
            configuration.computeUnits = .cpuAndGPU
        case .neuralEngineExperimental:
            configuration.computeUnits = .cpuAndNeuralEngine
        }
        #endif

        let compiled = packageNames.map { name in
            compiledRoot(cacheVersion: cacheVersion)
                .appendingPathComponent("\(name).mlmodelc")
        }
        do {
            let encoder = try MLModel(contentsOf: compiled[0], configuration: configuration)
            let decoder = try MLModel(contentsOf: compiled[1], configuration: configuration)
            let joint = try MLModel(contentsOf: compiled[2], configuration: configuration)
            let loaded = LoadedModels(
                encoder: encoder, decoder: decoder, joint: joint,
                computeUnits: configuration.computeUnits,
                compiledDuringLoad: compiledDuringLoad
            )
            if compiledDuringLoad {
                pruneOtherVersions(keep: cacheVersion)
            }
            logger.info("Core ML models loaded (compute \(String(describing: configuration.computeUnits), privacy: .public), compiledDuringLoad=\(compiledDuringLoad, privacy: .public))")
            return loaded
        } catch {
            throw ASREngineError.loadFailed(
                .coreMLFP16, underlying: "MLModel init failed: \(error)"
            )
        }
    }

    // MARK: - Integrity

    /// Verify every manifest file under `Source/` against its SHA256.
    /// Throws `ASREngineError.integrityFailure` on any mismatch.
    static func verifySourceIntegrity(manifest: ModelManifest, sourceRoot: URL) throws {
        guard let backend = manifest.backend(.coreMLFP16) else {
            throw LoaderError.manifestUnavailable("manifest has no coreml-fp16 backend entry")
        }
        try verifySourceIntegrityThrows(backend: backend, sourceRoot: sourceRoot)
    }

    private static func verifySourceIntegrityThrows(
        backend: ModelManifest.BackendInfo, sourceRoot: URL
    ) throws {
        for file in backend.files where file.path.hasPrefix("Source/") {
            let relative = String(file.path.dropFirst("Source/".count))
            let url = sourceRoot.appendingPathComponent(relative)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ASREngineError.integrityFailure(
                    path: file.path, reason: "file missing"
                )
            }
            let digest = try sha256File(at: url)
            guard digest == file.sha256 else {
                throw ASREngineError.integrityFailure(
                    path: file.path,
                    reason: "SHA256 mismatch (expected \(file.sha256), got \(digest))"
                )
            }
        }
    }

    static func sha256File(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 4 << 20
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Compilation

    private static func sourcePackageExists(_ root: URL, _ name: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: root.appendingPathComponent("\(name).mlpackage").path, isDirectory: &isDir
        ) && isDir.boolValue
    }

    /// Compile all three packages into a staging directory, then atomically
    /// swap it in as `Compiled/v{N}`. On failure the staging dir is removed
    /// and any previously valid cache stays untouched.
    private static func compileAll(cacheVersion: Int, sourceRoot: URL) throws {
        let fileManager = FileManager.default
        let versionRoot = compiledRoot(cacheVersion: cacheVersion)
        let staging = versionRoot
            .deletingLastPathComponent()
            .appendingPathComponent("v\(cacheVersion).staging-\(UUID().uuidString)")

        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            for name in packageNames {
                let source = sourceRoot.appendingPathComponent("\(name).mlpackage")
                let compiledURL: URL
                do {
                    compiledURL = try MLModel.compileModel(at: source)
                } catch {
                    throw LoaderError.compileFailed("\(name): \(error)")
                }
                let destination = staging.appendingPathComponent("\(name).mlmodelc")
                // compileModel returns a temp URL; copy then remove, since
                // temp and Application Support may not share a volume.
                try fileManager.copyItem(at: compiledURL, to: destination)
                try? fileManager.removeItem(at: compiledURL)
            }
            // Atomic swap: only now does the new cache become visible.
            if fileManager.fileExists(atPath: versionRoot.path) {
                try fileManager.removeItem(at: versionRoot)
            }
            try fileManager.moveItem(at: staging, to: versionRoot)
            logger.info("Compiled Core ML cache v\(cacheVersion, privacy: .public)")
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    // MARK: - Paths

    static func currentCacheVersion() -> Int {
        guard let manifest = try? ModelManifest.load(),
              let version = manifest.backend(.coreMLFP16)?.coreMLCompiledCacheVersion
        else { return fallbackCacheVersion }
        return version
    }

    static func compiledRoot(cacheVersion: Int) -> URL {
        if let root = try? ModelPaths.coreMLCompiledRoot(cacheVersion: cacheVersion) {
            return root
        }
        // ModelPaths only fails if Application Support is unresolvable —
        // fall back to the same computation inline.
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("gigaam-v3-e2e-rnnt", isDirectory: true)
            .appendingPathComponent(ASRBackendKind.coreMLFP16.manifestKey, isDirectory: true)
            .appendingPathComponent("Compiled", isDirectory: true)
            .appendingPathComponent("v\(cacheVersion)", isDirectory: true)
    }

    /// Compiled artifact URLs in `packageNames` order; nil per missing model.
    static func compiledURLs(cacheVersion: Int) -> [URL?] {
        let root = compiledRoot(cacheVersion: cacheVersion)
        return packageNames.map { name in
            let url = root.appendingPathComponent("\(name).mlmodelc")
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    /// Remove `Compiled/v*` directories other than the current version.
    /// Only ever called after the current version loaded successfully.
    private static func pruneOtherVersions(keep: Int) {
        let fileManager = FileManager.default
        guard let compiledRoot = try? ModelPaths.coreMLCompiledRoot(),
              let children = try? fileManager.contentsOfDirectory(
                  at: compiledRoot, includingPropertiesForKeys: nil
              )
        else { return }
        for child in children {
            guard child.lastPathComponent != "v\(keep)" else { continue }
            try? fileManager.removeItem(at: child)
        }
    }
}
