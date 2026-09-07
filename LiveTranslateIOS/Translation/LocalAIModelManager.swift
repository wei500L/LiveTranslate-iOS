import Foundation
import OSLog

/// Engine-side manager for the on-device AI models: OWNS the single
/// `LlamaContext` (the one-resident-model invariant for text translation),
/// loads/unloads on demand, and provides install/download/verify/delete
/// state for ALL three AI models (both GGUFs and Gemma) exactly the way
/// `ModelManager` does for the ASR backends.
///
/// Invariants (mirroring ASREngineManager):
/// - At most ONE GGUF translation model is resident at any time; switching
///   fully unloads the previous model before loading the next.
/// - No silent fallback: a failed load surfaces as an error, never an
///   automatic switch to another model or to cloud translation.
/// - A classroom session PINS the selected translation model: requests
///   mid-session keep using the model the session started with, so an
///   in-flight model switch cannot corrupt a running session's results.
///   Switching takes effect at the next session (or, when no session is
///   active, immediately).
/// - Gemma (image model) is loaded only while an image request is in
///   flight and released right after — it never coexists with a resident
///   GGUF translation model beyond the duration of one request, and never
///   loads while a translation model is loading.
///
/// This class is the ENGINE half (thread-safe via an internal lock +
/// `LlamaContext` actor); the UI-facing state lives in
/// `AIModelInstallStates` (@MainActor @Observable) updated through the
/// injected callback.
@MainActor
@Observable
final class LocalAIModelManager {
    static let logger = Logger(subsystem: "com.livetranslate.ios", category: "ai-model-manager")

    enum ManagerError: LocalizedError {
        case modelNotInstalled(LocalAIModelKind)
        case sessionPinned
        case loadFailed(LocalAIModelKind, underlying: String)

        var errorDescription: String? {
            switch self {
            case .modelNotInstalled(let kind):
                return String(localized: "模型未下载：\(kind.userTitle)")
            case .sessionPinned:
                return String(localized: "课堂进行中，模型已锁定。")
            case .loadFailed(let kind, let underlying):
                return String(localized: "\(kind.userTitle) 加载失败：\(underlying)")
            }
        }
    }

    // MARK: - Install state (UI mirror)

    struct InstallState: Identifiable, Equatable {
        var kind: LocalAIModelKind
        var isInstalled = false
        var installedBytes = 0
        var version = ""
        var integrityVerified = false
        var downloadProgress: Double?
        var isVerifying = false
        var isPaused = false
        var error: String?
        var lastLoadedAt: Date?

        var id: LocalAIModelKind { kind }
    }

    private(set) var states: [LocalAIModelKind: InstallState] = [
        .hyMT2: InstallState(kind: .hyMT2),
        .milmmt46: InstallState(kind: .milmmt46),
        .gemmaE2B: InstallState(kind: .gemmaE2B),
    ]

    /// Injected so the UI can refuse model deletion while a live
    /// classroom session is running (same contract as
    /// `ModelManager.isBackendInUse`).
    var isModelInUse: @MainActor (_ kind: LocalAIModelKind) -> Bool = { _ in false }

    private let installer = AIModelInstaller()
    private let defaults: UserDefaults
    private let manifest: ModelManifest?
    private var installTask: Task<Void, Never>?
    private var pendingInstall: LocalAIModelKind?

    // MARK: - Engine state

    /// The single llama.cpp context actor. Loading is serialized through
    /// the manager (MainActor); inference is serialized inside the actor.
    private let llama = LlamaContext()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.manifest = try? ModelManifest.load()
        if let manifest {
            for kind in LocalAIModelKind.allCases {
                if let info = manifest.aiModel(kind) {
                    states[kind]?.version = info.revision
                }
            }
        }
        restoreLastLoadedMetrics()
    }

    // MARK: - Install queries

    func state(_ kind: LocalAIModelKind) -> InstallState {
        states[kind] ?? InstallState(kind: kind)
    }

    func modelInfo(_ kind: LocalAIModelKind) -> ModelManifest.BackendInfo? {
        manifest?.aiModel(kind)
    }

    var manifestAvailable: Bool { manifest?.aiModels?.isEmpty == false }

    func refreshStates() {
        guard let manifest else {
            for kind in LocalAIModelKind.allCases {
                states[kind]?.error = "ModelManifest.json is missing from the app bundle."
            }
            return
        }
        for kind in LocalAIModelKind.allCases {
            guard let info = manifest.aiModel(kind) else { continue }
            let root = try? ModelPaths.aiModelRoot(kind)
            let installed = root.map { isModelPresent(info, at: $0) } ?? false
            states[kind]?.isInstalled = installed
            states[kind]?.installedBytes = installed ? installedBytes(info, at: root!) : 0
            states[kind]?.integrityVerified = false // a fresh scan proves nothing
        }
    }

    // MARK: - Install / pause / resume / delete

    func install(_ kind: LocalAIModelKind) {
        guard installTask == nil else { return } // serialized, non-reentrant
        guard let info = modelInfo(kind) else {
            states[kind]?.error = "No manifest entry for \(kind.userTitle)."
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
                }
                self.states[kind]?.downloadProgress = nil
                self.states[kind]?.isPaused = false
                self.refreshStates()
                await self.reverify(kind)
            } catch is CancellationError {
                // Paused — keep the partial progress visible.
                self.states[kind]?.downloadProgress = self.installer.progress.fraction
            } catch {
                self.states[kind]?.downloadProgress = nil
                self.states[kind]?.isPaused = false
                self.states[kind]?.error = error.localizedDescription
                Self.logger.error("AI model install \(kind.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func pause(_ kind: LocalAIModelKind) {
        installer.pause()
        states[kind]?.isPaused = true
        states[kind]?.downloadProgress = installer.progress.fraction
    }

    func resume(_ kind: LocalAIModelKind) {
        guard installTask == nil else { return }
        install(kind)
    }

    var isInstalling: Bool { installTask != nil || installer.isInstalling }

    func reverify(_ kind: LocalAIModelKind) async {
        guard let info = modelInfo(kind) else { return }
        states[kind]?.isVerifying = true
        states[kind]?.error = nil
        defer { states[kind]?.isVerifying = false }
        guard let root = try? ModelPaths.aiModelRoot(kind) else {
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

    func delete(_ kind: LocalAIModelKind) async throws {
        if isModelInUse(kind) {
            throw NSError(
                domain: "AIModelManager", code: 1,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "This model is in use by a running session. Stop the session first.")]
            )
        }
        // A resident engine must be released before its files disappear.
        // The actor hop is awaited so the model is fully freed before the
        // files are removed (never delete files under a live context).
        if residentModel == kind {
            await llama.unload()
            residentModel = nil
        }
        let root = try ModelPaths.aiModelRoot(kind)
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        states[kind] = InstallState(kind: kind, version: state(kind).version)
        refreshStates()
    }

    // MARK: - Engine: resident model lifecycle

    /// The model currently loaded in the llama context (nil = none).
    /// Manager-side mirror of the actor's `loadedModelID`; only mutated on
    /// the main actor (the class is @MainActor), so no lock is needed.
    private(set) var residentModel: LocalAIModelKind?

    /// Whether a classroom session has pinned the translation model
    /// (mid-session model switches are refused).
    private(set) var isSessionPinned = false

    /// Ensure a GGUF translation model is loaded. Safe to call repeatedly
    /// — an already-resident matching model is a no-op. A different model
    /// fully unloads the old one first (never two resident).
    func ensureTranslationModelLoaded(_ kind: LocalAIModelKind) async throws {
        guard kind.isTranslationModel else { return }
        if residentModel == kind { return }
        guard let info = modelInfo(kind) else {
            throw ManagerError.modelNotInstalled(kind)
        }
        let root = try ModelPaths.aiModelRoot(kind)
        let file = root.appendingPathComponent(info.files[0].path)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw ManagerError.modelNotInstalled(kind)
        }
        if isSessionPinned, let resident = residentModel, resident != kind {
            // Session pinning: mid-session requests keep the session's model.
            throw ManagerError.sessionPinned
        }
        do {
            try await llama.load(modelPath: file.path, modelID: kind.rawValue)
            residentModel = kind
            recordLoad(kind)
        } catch {
            Self.logger.error("Load \(kind.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            throw ManagerError.loadFailed(kind, underlying: error.localizedDescription)
        }
    }

    /// Release the resident GGUF model completely. Returns whether a
    /// model was actually resident (and is now released).
    @discardableResult
    func unloadResident() async -> Bool {
        guard residentModel != nil else { return false }
        await llama.unload()
        residentModel = nil
        return true
    }

    /// Pin/unpin the session model (called by the coordinator at session
    /// start/end). While pinned, `ensureTranslationModelLoaded` refuses to
    /// switch to a different model; the coordinator reads the resident
    /// model per request, so in-flight requests keep their model.
    func beginSessionPin() {
        isSessionPinned = true
    }

    func endSessionPin() {
        isSessionPinned = false
    }

    // MARK: - Engine: generation

    /// Translate one request through the resident model. The model must
    /// have been loaded (guard throws otherwise). Cancellation-aware: a
    /// request cancelled by its caller stops decoding and returns the
    /// partial text — better than hanging the coordinator's drain.
    func generate(prompt: String, modelID: LocalAIModelKind) async throws -> String {
        guard residentModel == modelID else {
            throw ManagerError.loadFailed(
                modelID,
                underlying: String(localized: "请求的模型与当前加载的模型不一致。")
            )
        }
        return try await llama.complete(prompt: prompt, isCancelled: { Task.isCancelled })
    }

    // MARK: - Metrics

    func recordLoad(_ kind: LocalAIModelKind) {
        defaults.set(Date.now.timeIntervalSince1970, forKey: Self.lastLoadedKey(kind))
        states[kind]?.lastLoadedAt = .now
    }

    private static func lastLoadedKey(_ kind: LocalAIModelKind) -> String {
        "aiModel.lastLoadedAt.\(kind.rawValue)"
    }

    private func restoreLastLoadedMetrics() {
        for kind in LocalAIModelKind.allCases {
            let loaded = defaults.double(forKey: Self.lastLoadedKey(kind))
            if loaded > 0 { states[kind]?.lastLoadedAt = Date(timeIntervalSince1970: loaded) }
        }
    }

    // MARK: - Internals

    private func isModelPresent(_ info: ModelManifest.BackendInfo, at root: URL) -> Bool {
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

