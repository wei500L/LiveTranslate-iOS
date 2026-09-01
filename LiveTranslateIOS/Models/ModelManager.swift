import Foundation
import OSLog

/// User-facing facade over model install state for both backends.
///
/// Owns one `ModelInstaller` (installs are strictly serialized) and answers
/// the questions the Model Management page asks: installed? verified?
/// compiled? how big? what version? when last loaded? Download / pause /
/// resume / delete / re-verify / metrics all route through here.
@MainActor
@Observable
final class ModelManager {
    static let logger = Logger(subsystem: "com.livetranslate.ios", category: "model-manager")

    struct BackendInstallState: Identifiable, Equatable {
        var kind: ASRBackendKind
        var isInstalled = false
        var installedBytes = 0
        /// Pinned HF commit SHA from the manifest.
        var version = ""
        var integrityVerified = false
        var coreMLCompiled = false
        var lastLoadedAt: Date?
        var lastRTF: Double?
        var downloadProgress: Double?
        var isVerifying = false
        var isCompiling = false
        /// True after an explicit user pause (download stopped, partial
        /// progress kept); cleared on resume / new install / completion.
        var isPaused = false
        var error: String?

        var id: ASRBackendKind { kind }
    }

    private(set) var states: [ASRBackendKind: BackendInstallState] = [
        .coreMLFP16: BackendInstallState(kind: .coreMLFP16),
        .sherpaONNXInt8: BackendInstallState(kind: .sherpaONNXInt8),
    ]

    /// Injected so the UI can refuse model deletion while a live classroom
    /// session is running on the engine.
    var isBackendInUse: @MainActor (_ kind: ASRBackendKind) -> Bool = { _ in false }

    private let installer = ModelInstaller()
    private let defaults: UserDefaults
    private let manifest: ModelManifest?
    /// Serializes installs; also the resume hook after a pause.
    private var installTask: Task<Void, Never>?
    private var pendingInstall: ASRBackendKind?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.manifest = try? ModelManifest.load()
        if let manifest {
            for backend in manifest.backends.values {
                states[backend.kind]?.version = backend.revision
            }
        }
        // Silero VAD is shared by both backends and installed on demand by
        // the VAD layer; ModelManager only tracks the two ASR backends.
        restoreLastLoadedMetrics()
    }

    // MARK: - Queries

    func state(_ kind: ASRBackendKind) -> BackendInstallState {
        states[kind] ?? BackendInstallState(kind: kind)
    }

    func backendInfo(_ kind: ASRBackendKind) -> ModelManifest.BackendInfo? {
        manifest?.backend(kind)
    }

    var manifestAvailable: Bool { manifest != nil }

    func refreshStates() {
        guard let manifest else {
            for kind in ASRBackendKind.allCases {
                states[kind]?.error = "ModelManifest.json is missing from the app bundle."
            }
            return
        }
        for kind in ASRBackendKind.allCases {
            guard let info = manifest.backend(kind) else { continue }
            let root = try? ModelPaths.backendRoot(kind)
            let installed = root.map { isBackendPresent(info, at: $0) } ?? false
            states[kind]?.isInstalled = installed
            states[kind]?.installedBytes = installed ? installedBytes(info, at: root!) : 0
            states[kind]?.integrityVerified = false // a fresh scan proves nothing
            if kind == .coreMLFP16, let cacheVersion = info.coreMLCompiledCacheVersion {
                states[kind]?.coreMLCompiled = CompiledCoreMLCache.allCompiled(cacheVersion: cacheVersion)
            }
        }
    }

    // MARK: - Install / pause / resume

    func install(_ kind: ASRBackendKind) {
        guard installTask == nil else { return } // serialized, non-reentrant
        guard let info = backendInfo(kind) else {
            states[kind]?.error = "No manifest entry for \(kind.displayName)."
            return
        }
        pendingInstall = nil
        states[kind]?.error = nil
        states[kind]?.isPaused = false
        states[kind]?.downloadProgress = state(kind).isInstalled ? 1.0 : 0.0
        installTask = Task { [weak self] in
            guard let self else { return }
            defer { self.installTask = nil; self.pendingInstall = nil }
            do {
                try await self.installer.install(info) { progress in
                    self.states[kind]?.downloadProgress = progress.fraction
                    self.states[kind]?.isCompiling = self.installer.isCompiling
                }
                self.states[kind]?.downloadProgress = nil
                self.states[kind]?.isCompiling = false
                self.states[kind]?.isPaused = false
                self.refreshStates()
                // Post-install full verification.
                await self.reverify(kind)
            } catch is CancellationError {
                // Paused — keep the partial progress visible.
                self.states[kind]?.downloadProgress = self.installer.progress.fraction
            } catch {
                self.states[kind]?.downloadProgress = nil
                self.states[kind]?.isCompiling = false
                self.states[kind]?.isPaused = false
                self.states[kind]?.error = error.localizedDescription
                Self.logger.error("Install \(kind.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func pause(_ kind: ASRBackendKind) {
        installer.pause()
        states[kind]?.isPaused = true
        states[kind]?.downloadProgress = installer.progress.fraction
    }

    /// Resume after a pause (or retry after a failure).
    func resume(_ kind: ASRBackendKind) {
        guard installTask == nil else { return }
        install(kind)
    }

    var isInstalling: Bool { installTask != nil || installer.isInstalling }

    // MARK: - Verify / delete

    /// Full SHA256 re-verification of every file of one backend.
    func reverify(_ kind: ASRBackendKind) async {
        guard let info = backendInfo(kind) else { return }
        states[kind]?.isVerifying = true
        states[kind]?.error = nil
        defer { states[kind]?.isVerifying = false }
        guard let root = try? ModelPaths.backendRoot(kind) else {
            states[kind]?.integrityVerified = false
            return
        }
        if let failure = await ModelIntegrityVerifier.verifyBackend(info, root: root) {
            states[kind]?.integrityVerified = false
            states[kind]?.error = failure.localizedDescription
        } else {
            states[kind]?.integrityVerified = true
        }
    }

    /// Delete one backend's files (and, for Core ML, its compiled cache).
    /// The other backend is never touched. Refused while in use.
    func delete(_ kind: ASRBackendKind) throws {
        if isBackendInUse(kind) {
            throw NSError(
                domain: "ModelManager", code: 1,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "This backend is in use by a running session. Stop the session first.")]
            )
        }
        if kind == .coreMLFP16 {
            CompiledCoreMLCache.removeAll()
        }
        let root = try ModelPaths.backendRoot(kind)
        // Deleting a backend that is not installed is a no-op, not an error.
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        states[kind] = BackendInstallState(kind: kind, version: state(kind).version)
        refreshStates()
    }

    // MARK: - Metrics recording (called by the engine manager / UI)

    func recordLoad(_ kind: ASRBackendKind) {
        defaults.set(Date.now.timeIntervalSince1970, forKey: Self.lastLoadedKey(kind))
        states[kind]?.lastLoadedAt = .now
    }

    func recordRTF(_ kind: ASRBackendKind, rtf: Double) {
        defaults.set(rtf, forKey: Self.lastRTFKey(kind))
        states[kind]?.lastRTF = rtf
    }

    // MARK: - Internals

    private static func lastLoadedKey(_ kind: ASRBackendKind) -> String {
        "model.lastLoadedAt.\(kind.rawValue)"
    }

    private static func lastRTFKey(_ kind: ASRBackendKind) -> String {
        "model.lastRTF.\(kind.rawValue)"
    }

    private func restoreLastLoadedMetrics() {
        for kind in ASRBackendKind.allCases {
            let loaded = defaults.double(forKey: Self.lastLoadedKey(kind))
            if loaded > 0 { states[kind]?.lastLoadedAt = Date(timeIntervalSince1970: loaded) }
            let rtf = defaults.double(forKey: Self.lastRTFKey(kind))
            if rtf > 0 { states[kind]?.lastRTF = rtf }
        }
    }

    private func isBackendPresent(_ info: ModelManifest.BackendInfo, at root: URL) -> Bool {
        info.files.allSatisfy { file in
            FileManager.default.fileExists(atPath: root.appendingPathComponent(file.path).path)
        }
    }

    private func installedBytes(_ info: ModelManifest.BackendInfo, at root: URL) -> Int {
        info.files.reduce(0) { sum, file in
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: root.appendingPathComponent(file.path).path
            )
            let size = (attributes?[.size] as? Int) ?? 0
            return sum + size
        }
    }
}
