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
    /// batches (used by the first-upload flow). Courses are emitted before
    /// sessions so a session's course reference exists server-side first.
    func syncSnapshots(batchSize: Int, progress: ((Int, Int) -> Void)?) -> [SyncOutboxItem]

    // MARK: Guest-data migration support

    /// Lightweight summary of one locally-stored session (migration
    /// conflict comparison — no entries loaded).
    func sessionSummary(id: UUID) -> SessionSummary?
    /// Whether an entry with the given UUID exists locally.
    func entryExists(id: UUID) -> Bool

    // MARK: Courses

    func createCourse(_ draft: CourseDraft) throws -> Course
    /// Applies every field of the draft to an existing course.
    func updateCourse(_ course: Course, with draft: CourseDraft) throws
    /// All courses; archived last (each group by most recent use).
    func courses() throws -> [Course]
    func course(id: UUID) throws -> Course?
    /// Deletes a course. Its sessions stay and become standalone
    /// (their `courseID` is cleared — the change syncs as session upserts).
    func deleteCourse(_ course: Course) throws
    /// Assigns a session to a course (nil = standalone). Sync semantics:
    /// nil keeps the server value, `UUID.nilSentinel` explicitly clears.
    func assignCourse(_ courseID: UUID?, to session: ClassroomSession) throws
    /// Cloud-sync apply for a course record.
    func applyRemoteCourse(record: SyncServerRecordDTO, serverVersion: Int) throws
    func deleteCourseByID(_ id: UUID) throws

    // MARK: Session notes

    /// All notes of a session, oldest first. ID-based (not model-based) so
    /// the live classroom — which only holds the session id — can use it.
    func notes(forSessionID id: UUID) throws -> [SessionNote]
    func addNote(_ draft: NoteDraft, toSessionID id: UUID) throws -> SessionNote
    func updateNote(_ note: SessionNote, text: String) throws
    /// Clears or replaces a note's anchor (the note text stays). A nil
    /// anchor pushes the explicit-clear sentinel so the change syncs.
    func updateNoteAnchor(_ note: SessionNote, anchorEntryID: UUID?) throws
    func deleteNote(_ note: SessionNote) throws
    /// Cloud-sync apply for a note record.
    func applyRemoteNote(record: SyncServerRecordDTO, serverVersion: Int) throws
    func deleteNoteByID(_ id: UUID) throws
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
    var courseID: UUID? = nil
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

/// Course fields the create/edit form produces.
struct CourseDraft: Sendable, Equatable {
    var name: String
    var teacherName: String = ""
    var location: String = ""
    var colorIndex: Int = 0
    var isArchived: Bool = false
}

/// A new note (text required; anchor optional).
struct NoteDraft: Sendable {
    var text: String
    var anchorEntryID: UUID? = nil
}

extension UUID {
    /// Wire sentinel for "clear this reference" in sync payloads. A nil
    /// optional payload field means "not specified — keep the server
    /// value"; this all-zero UUID means "remove it". Mirrors Go's uuid.Nil.
    static let nilSentinel = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
}
