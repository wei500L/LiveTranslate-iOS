import Foundation
import OSLog

/// Single coordinator that owns the (at most one) resident ASR engine.
///
/// Invariants enforced here — these are the product's core backend rules:
/// - At most one backend is loaded at any time. Loading a new backend
///   requires unloading the previous one first.
/// - No silent backend switching: a failed load leaves an error state; the
///   user decides what to do next.
/// - A live session pins its backend: `requestBackendSwitch` is rejected
///   while a session is running.
@MainActor
@Observable
final class ASREngineManager {
    private static let logger = Logger(subsystem: "com.livetranslate.ios", category: "engine-manager")

    struct LoadedEngine: Identifiable {
        let id = UUID()
        let kind: ASRBackendKind
        let engine: any ASREngine
        let loadedAt: Date
        let loadDuration: TimeInterval
        var lastInferenceRTF: Double?
        var lastUsedAt: Date?
    }

    enum ManagerError: LocalizedError, Equatable {
        case sessionActive(ASRBackendKind)
        case alreadyLoading
        case backendNotInstalled(ASRBackendKind)

        var errorDescription: String? {
            switch self {
            case .sessionActive(let kind):
                return String(format: String(localized: "Cannot switch backends while a session is running on %@. Stop the session first."), kind.shortLabel)
            case .alreadyLoading:
                return String(localized: "A backend is already loading.")
            case .backendNotInstalled(let kind):
                return String(format: String(localized: "%@ is not installed."), kind.displayName)
            }
        }
    }

    private(set) var loaded: LoadedEngine?
    private(set) var isLoading = false
    private(set) var lastError: String?
    /// True while a live classroom session is running on the loaded engine.
    private(set) var sessionActive = false
    /// Concurrency gate for load/unload operations.
    private var loadGate = AsyncSemaphore()

    private let settings: SettingsStore
    private let coreMLFactory: @Sendable (CoreMLComputePreference) -> any ASREngine
    private let sherpaFactory: @Sendable (Int) -> any ASREngine

    var residentBackendKind: ASRBackendKind? { loaded?.kind }

    init(
        settings: SettingsStore,
        coreMLFactory: @escaping @Sendable (CoreMLComputePreference) -> any ASREngine = { GigaAMCoreMLEngine(computePreference: $0) },
        sherpaFactory: @escaping @Sendable (Int) -> any ASREngine = { GigaAMSherpaEngine(threadCount: $0) }
    ) {
        self.settings = settings
        self.coreMLFactory = coreMLFactory
        self.sherpaFactory = sherpaFactory
    }

    // MARK: - Session pinning

    func beginSession() throws {
        guard loaded != nil else {
            throw ManagerError.backendNotInstalled(settings.preferredBackend)
        }
        sessionActive = true
    }

    func endSession() {
        sessionActive = false
    }

    // MARK: - Load / unload

    /// Ensure `kind` is the resident engine, unloading anything else first.
    /// Throws without changing state if a session is active or the model is
    /// not installed.
    func ensureLoaded(_ kind: ASRBackendKind) async throws {
        if loaded?.kind == kind, lastError == nil { return }
        guard !sessionActive else { throw ManagerError.sessionActive(kind) }
        guard !isLoading else { throw ManagerError.alreadyLoading }
        guard await isInstalled(kind) else { throw ManagerError.backendNotInstalled(kind) }

        isLoading = true
        lastError = nil
        await loadGate.wait()
        defer { loadGate.signal(); isLoading = false }

        // Rule: never two resident backends. Unload the old one fully.
        if let current = loaded {
            Self.logger.info("Unloading \(current.kind.rawValue, privacy: .public) before loading \(kind.rawValue, privacy: .public)")
            await unloadCurrent()
        }

        let engine: any ASREngine
        switch kind {
        case .coreMLFP16:
            engine = coreMLFactory(settings.coreMLCompute)
        case .sherpaONNXInt8:
            engine = sherpaFactory(settings.onnxThreads)
        }

        let started = Date()
        do {
            try await engine.prepare()
            try await engine.warmup()
        } catch {
            // Failed load never falls back to the other backend.
            lastError = error.localizedDescription
            Self.logger.error("Load failed for \(kind.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            await engine.unload()
            throw error
        }
        loaded = LoadedEngine(
            kind: kind, engine: engine,
            loadedAt: .now,
            loadDuration: Date().timeIntervalSince(started)
        )
        Self.logger.info("Loaded \(kind.rawValue, privacy: .public) in \(self.loaded?.loadDuration ?? 0, privacy: .public)s")
    }

    func unloadCurrent() async {
        if let current = loaded {
            await current.engine.unload()
        }
        loaded = nil
    }

    // MARK: - Inference

    /// Serialized transcription through the resident engine.
    func transcribe(_ segment: SpeechSegment) async throws -> ASRResult {
        guard let engine = loaded?.engine else {
            throw ASREngineError.engineNotLoaded
        }
        let result = try await engine.transcribe(
            samples: segment.samples,
            sampleRate: segment.sampleRate,
            segmentStart: segment.startOffset,
            segmentEnd: segment.endOffset
        )
        loaded?.lastInferenceRTF = result.realTimeFactor
        loaded?.lastUsedAt = .now
        return result
    }

    func recordRTF(_ rtf: Double) {
        loaded?.lastInferenceRTF = rtf
    }

    // MARK: - Install state

    nonisolated func isInstalled(_ kind: ASRBackendKind) async -> Bool {
        switch kind {
        case .sherpaONNXInt8:
            return SherpaModelConfiguration.isInstalled()
        case .coreMLFP16:
            return await CoreMLModelLoader.hasCompiledModel()
        }
    }
}

/// Minimal async semaphore for the load gate (counting not needed; used as
/// a mutual-exclusion marker so repeated calls queue politely).
actor AsyncSemaphore {
    private var locked = false

    func wait() async {
        while locked {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        locked = true
    }

    func signal() {
        locked = false
    }
}
