import Foundation
import SwiftData

/// Repository over the SwiftData store. All UI reads/writes classroom
/// data through this so persistence stays testable and the UI stays thin.
@MainActor
protocol ClassroomRepositoryProtocol: AnyObject {
    func createSession(_ draft: SessionDraft) throws -> ClassroomSession
    func finishSession(_ session: ClassroomSession, abnormal: Bool) throws
    func addEntry(_ draft: EntryDraft, to session: ClassroomSession) throws -> TranscriptEntry
    func updateTranslation(entryID: UUID, text: String, latency: TimeInterval?, status: TranslationStatus) throws
    func sessions(matching query: String) throws -> [ClassroomSession]
    func entries(for session: ClassroomSession) throws -> [TranscriptEntry]
    func entriesNeedingRetry(for session: ClassroomSession) throws -> [TranscriptEntry]
    func deleteSession(_ session: ClassroomSession) throws
    func deleteAllSessions() throws
    func storageBytes() -> Int
    func markAbnormalTerminations() throws

    // MARK: Cloud-sync support
    /// Hook receiving every persisted mutation (the sync service builds
    /// its outbox operations from these notifications).
    var mutationObserver: (any TranscriptMutationObserving)? { get set }
    func renameSession(_ session: ClassroomSession, to title: String) throws
    func recordServerVersion(entityType: SyncEntityType, entityID: UUID, version: Int) throws
    func applyRemoteSession(record: SyncServerRecordDTO, serverVersion: Int) throws
    func applyRemoteEntry(record: SyncServerRecordDTO, serverVersion: Int) throws
    func deleteSessionByID(_ id: UUID) throws
    func deleteEntryByID(_ id: UUID) throws
    /// Snapshot of every locally-stored entity as outbox operations, in
    /// batches (used by the first-upload flow).
    func syncSnapshots(batchSize: Int, progress: ((Int, Int) -> Void)?) -> [SyncOutboxItem]

    // MARK: Guest-data migration support

    /// Lightweight summary of one locally-stored session (migration
    /// conflict comparison — no entries loaded).
    func sessionSummary(id: UUID) -> SessionSummary?
    /// Whether an entry with the given UUID exists locally.
    func entryExists(id: UUID) -> Bool
}

/// Minimal comparable projection of a classroom session (Sendable).
struct SessionSummary: Sendable, Equatable {
    var id: UUID
    var title: String
    var startTime: Date
    var entryCount: Int
}

struct SessionDraft: Sendable {
    var title: String
    var backend: ASRBackendKind
    var modelVersion: String
    var computePreference: String
    var translationModel: String
    var sourceLanguage: String = "ru"
    var targetLanguage: String = "zh-CN"
}

struct EntryDraft: Sendable {
    var sequenceID: Int
    var startOffset: TimeInterval
    var endOffset: TimeInterval
    var originalText: String
    var asrBackend: ASRBackendKind
    var asrLatency: TimeInterval
    var asrRTF: Double
}
