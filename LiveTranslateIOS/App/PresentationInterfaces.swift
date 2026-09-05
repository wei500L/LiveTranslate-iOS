import Foundation

/// Presentation interfaces the UI depends on. The real pipeline, storage
/// and model-management types conform to them; the Debug-only UI Demo Mode
/// provides scripted stand-ins with the same interfaces. This is the
/// dependency-inversion boundary — views never check a global "is demo"
/// flag, they just receive whichever environment was assembled at launch.

/// Schedule attribution handed to `start(title:courseID:schedule:)` when a
/// session is launched from the timetable. A value type — safe to build
/// from a computed occurrence and pass across views.
struct ScheduleSessionContext: Sendable, Equatable {
    var scheduleID: UUID
    var occurrenceKey: String
    var plannedStart: Date
}

/// The surface of the live-classroom pipeline the UI reads and drives.
@MainActor
protocol LiveTranslationCoordinating: AnyObject {
    var state: PipelineState { get }
    var entries: [LiveTranscriptItem] { get }
    var audioLevels: [Float] { get }
    var isNetworkAvailable: Bool { get }
    var isPaused: Bool { get }
    var isRunning: Bool { get }
    /// Stable persisted session identity (bookmark target); nil while no
    /// classroom is active.
    var activeSessionID: UUID? { get }
    var activeSessionTitle: String? { get }
    /// The course the active session belongs to (nil = standalone). Kept
    /// across a restart of the same classroom.
    var activeSessionCourseID: UUID? { get }

    func start(title: String?, courseID: UUID?, schedule: ScheduleSessionContext?) async
    func pause()
    func resume()
    func stop() async
    func retryTranslation(sequenceID: Int)
    func retryFailedTranslations()
}

extension LiveTranslationCoordinator: LiveTranslationCoordinating {}

/// Status surface + pipeline control of the ASR engine manager. Sendable
/// because the (MainActor-isolated) manager may be handed to nonisolated
/// async install checks. The pipeline methods exist so the interpreter
/// view model can drive the SAME engine instance (never a second one)
/// through its own listening loop; `ASREngineManager` remains the only
/// implementation that actually loads GigaAM/sherpa.
@MainActor
protocol ASREngineManaging: AnyObject, Sendable {
    var loaded: ASREngineManager.LoadedEngine? { get }
    var sessionActive: Bool { get }
    /// Disk-backed install check (nonisolated so it can be awaited from
    /// any actor without hopping through the manager first).
    nonisolated func isInstalled(_ kind: ASRBackendKind) async -> Bool
    /// Load + pin the resident backend for a capture session (throws when
    /// another session holds the engine — the one-instance invariant).
    func ensureLoaded(_ kind: ASRBackendKind) async throws
    /// Session pinning: refuses to load a different backend mid-session.
    func beginSession() throws
    func endSession()
    /// Transcribe one speech segment through the resident engine.
    func transcribe(_ segment: SpeechSegment) async throws -> ASRResult
}

extension ASREngineManager: ASREngineManaging, Sendable {}

/// The surface of the model manager app UI uses (model management screen
/// and the root launch task).
@MainActor
protocol ModelManaging: AnyObject {
    var states: [ASRBackendKind: ModelManager.BackendInstallState] { get }
    var isInstalling: Bool { get }
    var manifestAvailable: Bool { get }

    func refreshStates()
    func install(_ kind: ASRBackendKind)
    func pause(_ kind: ASRBackendKind)
    func resume(_ kind: ASRBackendKind)
    func reverify(_ kind: ASRBackendKind) async
    func delete(_ kind: ASRBackendKind) throws
    func backendInfo(_ kind: ASRBackendKind) -> ModelManifest.BackendInfo?
}

extension ModelManager: ModelManaging {}

/// Keychain access the app UI needs (API key storage only).
protocol KeychainStoring: Sendable {
    func set(_ value: String, forKey key: String) throws
    func get(forKey key: String) throws -> String?
    func delete(forKey key: String) throws
}

extension KeychainStore: KeychainStoring {}
