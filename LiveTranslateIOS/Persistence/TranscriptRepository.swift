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
    /// The course a session belongs to (attachment display bookkeeping;
    /// nil = standalone).
    func courseID(sessionID: UUID) throws -> UUID?

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

    // MARK: Study reviews
    // Generation progress (generating / chunk state) is device-local and
    // never notifies the sync observer; terminal states and user edits do.

    /// The session's review, if one exists.
    func studyReview(forSessionID id: UUID) throws -> StudyReview?
    /// All reviews (course aggregation, search, initial upload).
    func allStudyReviews() throws -> [StudyReview]
    /// Fetches or creates the review row (id == session id, status
    /// generating). Local-only — not synced.
    func ensureStudyReview(forSessionID id: UUID) throws -> StudyReview
    /// Starts/restarts a generation: writes the chunk plan and status.
    /// Local-only.
    func beginStudyReviewGeneration(_ review: StudyReview, chunkState: StudyChunkState) throws
    /// Persists chunk progress; `terminal` optionally updates the status.
    /// Local-only.
    func updateStudyReviewProgress(
        _ review: StudyReview, chunkStateJSON: String, terminal: StudyReviewStatus?
    ) throws
    /// A finished generation: replaces content + generated, stamps model
    /// and source snapshot, sets status completed. Notifies sync.
    func completeStudyReviewGeneration(
        _ review: StudyReview, content: StudyReviewContent,
        model: String, sourceUpdatedAt: Date
    ) throws
    /// Marks a run failed (previous content, if any, stays). Notifies sync
    /// only when there is content worth keeping in sync.
    func failStudyReviewGeneration(_ review: StudyReview) throws
    /// An orphaned `generating` row (app was killed): becomes partial when
    /// chunks finished, else failed. Local-only.
    func markStudyReviewInterrupted(_ review: StudyReview) throws
    /// Saves user-edited content. Notifies sync.
    func applyStudyReviewUserEdits(_ review: StudyReview, content: StudyReviewContent) throws
    func deleteStudyReview(_ review: StudyReview) throws
    /// Cloud-sync apply for a review record (protects local user edits).
    func applyRemoteStudyReview(record: SyncServerRecordDTO, serverVersion: Int) throws
    func deleteStudyReviewByID(_ id: UUID) throws

    // MARK: Session attachments (classroom images)
    // Files are managed by AttachmentFileStore; the repository persists
    // metadata only. Analysis progress (analyzing / chunk-less single
    // image states) is device-local and never notifies the sync observer;
    // terminal states and user edits do.

    /// All attachments of a session, timeline order (capturedAt, sortIndex).
    func attachments(forSessionID id: UUID) throws -> [SessionAttachment]
    /// One attachment by id (analysis runner).
    func attachment(id: UUID) throws -> SessionAttachment?
    /// All attachments across sessions (search, storage management).
    func allAttachments() throws -> [SessionAttachment]
    /// Whether an attachment with this hash exists in the session
    /// (duplicate-import prompt; never auto-deletes).
    func attachmentExists(sessionID: UUID, contentHash: String) throws -> Bool
    /// Persists a fully-written attachment (files already on disk — the
    /// row is written LAST by contract). Notifies sync.
    func addAttachment(_ draft: AttachmentDraft, toSessionID id: UUID) throws -> SessionAttachment
    func updateAttachmentTitle(_ attachment: SessionAttachment, title: String) throws
    func updateAttachmentCaption(_ attachment: SessionAttachment, caption: String) throws
    func updateAttachmentKind(_ attachment: SessionAttachment, kind: AttachmentKind) throws
    /// Clears or replaces the anchor (the image stays). A nil anchor
    /// pushes the explicit-clear sentinel so the change syncs.
    func updateAttachmentAnchor(_ attachment: SessionAttachment, anchorEntryID: UUID?) throws
    func updateAttachmentSortIndex(_ attachment: SessionAttachment, sortIndex: Int) throws
    /// Non-destructive display transform (rotation/crop). The original
    /// file is never rewritten. Notifies sync.
    func updateAttachmentTransform(_ attachment: SessionAttachment, transform: AttachmentTransform) throws
    /// Saves user-edited local OCR text (never mixed with model output).
    /// Notifies sync.
    func updateAttachmentOCRText(_ attachment: SessionAttachment, text: String) throws
    /// A finished analysis run: replaces the structured result, stamps the
    /// status. Notifies sync. Local-only state changes (analyzing) use
    /// `updateAttachmentAnalysisProgress`.
    func completeAttachmentAnalysis(
        _ attachment: SessionAttachment, result: AttachmentAnalysisResult, status: AttachmentAnalysisStatus
    ) throws
    /// Local-only analysis status change (analyzing start / interrupted /
    /// failed without result). Never notifies sync — terminal statuses are
    /// pushed only via completeAttachmentAnalysis / failAttachmentAnalysis.
    func updateAttachmentAnalysisProgress(
        _ attachment: SessionAttachment, status: AttachmentAnalysisStatus
    ) throws
    /// A failed analysis (previous result, if any, stays). Notifies sync
    /// only when a result worth keeping exists.
    func failAttachmentAnalysis(_ attachment: SessionAttachment) throws
    func deleteAttachment(_ attachment: SessionAttachment) throws
    /// Cloud-sync apply for an attachment record.
    func applyRemoteAttachment(record: SyncServerRecordDTO, serverVersion: Int) throws
    func deleteAttachmentByID(_ id: UUID) throws
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

/// A fully-processed new attachment. The FILES are already on disk (the
/// importer writes them first, the row last — an interrupted import never
/// leaves a row whose files are missing); the draft carries only metadata
/// derived during import.
struct AttachmentDraft: Sendable {
    var capturedAt: Date
    var title: String
    var caption: String
    var kind: AttachmentKind
    var mimeType: String
    var fileExtension: String
    var pixelWidth: Int
    var pixelHeight: Int
    var fileSize: Int64
    var contentHash: String
    var sortIndex: Int
    var anchorEntryID: UUID?
    var courseID: UUID?
}

extension UUID {
    /// Wire sentinel for "clear this reference" in sync payloads. A nil
    /// optional payload field means "not specified — keep the server
    /// value"; this all-zero UUID means "remove it". Mirrors Go's uuid.Nil.
    static let nilSentinel = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
}
