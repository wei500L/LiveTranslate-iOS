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
    /// its outbox operations from these notifications). The getter may
    /// return a forwarding fanout that also reaches the auxiliary
    /// observers below — notification call sites are oblivious.
    var mutationObserver: (any TranscriptMutationObserving)? { get set }
    /// Additional mutation observers (system surfaces: Spotlight indexing
    /// + widget snapshot refresh). Additive; the sync observer's
    /// exclusive set/nil contract on `mutationObserver` is unchanged and
    /// survives sync shutdown.
    var auxiliaryMutationObservers: [any TranscriptMutationObserving] { get set }
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

    // MARK: Learning entities (review center)
    // Glossary terms, study cards and study tasks. Learning material
    // SURVIVES its sources: deleting a session/attachment never deletes
    // these rows (dangling source refs are shown as 来源已不存在), and
    // deleting a course clears their `courseID` reference (matching the
    // server's detach semantics). AI task candidates are created with
    // status `pendingConfirm` and never notify the sync observer until
    // the user confirms them.

    // Glossary terms

    /// All terms (nil courseID = every course), newest first.
    func terms(courseID: UUID?) throws -> [GlossaryTerm]
    /// Terms whose russian/chinese/explanation/note contains the query.
    func terms(matching query: String) throws -> [GlossaryTerm]
    /// Dedup lookup within a course: same normalized russian word.
    func findTerm(courseID: UUID?, russian: String) throws -> GlossaryTerm?
    func addTerm(_ draft: TermDraft) throws -> GlossaryTerm
    /// Applies every draft field (edit sheet save). Notifies sync.
    func updateTerm(_ term: GlossaryTerm, with draft: TermDraft) throws
    /// Records an extra classroom source on an existing term (duplicate
    /// merge — "合并新的来源"). Unions the session list, never overwrites
    /// the user's edited text. Notifies sync.
    func mergeTermSources(
        _ term: GlossaryTerm, sessionID: UUID?,
        entryID: UUID?, attachmentID: UUID?
    ) throws
    func updateTermFavorite(_ term: GlossaryTerm, isFavorite: Bool) throws
    func updateTermStatus(_ term: GlossaryTerm, status: GlossaryTermStatus) throws
    func deleteTerm(_ term: GlossaryTerm) throws
    /// Cloud-sync apply for a term record.
    func applyRemoteTerm(record: SyncServerRecordDTO, serverVersion: Int) throws
    func deleteTermByID(_ id: UUID) throws

    // Study cards

    /// All cards (nil courseID = every course), newest first.
    func cards(courseID: UUID?) throws -> [StudyCard]
    /// Cards due at `date` (scheduled stage + dueAt <= date), oldest due
    /// first. New cards are excluded until enrolled by their first
    /// review-session queue build.
    func dueCards(before date: Date, limit: Int) throws -> [StudyCard]
    /// Cards whose front/back/note contains the query.
    func cards(matching query: String) throws -> [StudyCard]
    /// Cards derived from a term (term detail's card list).
    func cards(forTermID id: UUID) throws -> [StudyCard]
    func addCard(_ draft: CardDraft) throws -> StudyCard
    /// Applies every draft field; leaves the schedule untouched (the
    /// caller offers an explicit reset separately). Notifies sync.
    func updateCard(_ card: StudyCard, with draft: CardDraft) throws
    /// Applies one review grade via the scheduler. Notifies sync.
    func reviewCard(_ card: StudyCard, grade: StudyCardGrade, at date: Date) throws
    /// Persists scheduling fields the caller restored on the model (the
    /// review session's 撤销 path mutates the card then calls this).
    func restoreCardSchedule(_ card: StudyCard) throws
    /// Explicit, user-confirmed schedule reset after editing content.
    func resetCardSchedule(_ card: StudyCard) throws
    /// Puts new cards into the review queue (due now, stage learning).
    func enrollCard(_ card: StudyCard) throws
    func deleteCard(_ card: StudyCard) throws
    /// Cloud-sync apply for a card record.
    func applyRemoteStudyCard(record: SyncServerRecordDTO, serverVersion: Int) throws
    func deleteCardByID(_ id: UUID) throws

    // Study tasks

    /// Confirmed tasks (pending/done/ignored — pendingConfirm candidates
    /// are only in `pendingConfirmTasks`). Sorted: unfinished first, by
    /// due date then created.
    func tasks(courseID: UUID?, includeDone: Bool) throws -> [StudyTask]
    /// AI candidates awaiting the user's confirmation.
    func pendingConfirmTasks() throws -> [StudyTask]
    /// Tasks whose title/detail/note contains the query (confirmed only).
    func tasks(matching query: String) throws -> [StudyTask]
    func addTask(_ draft: TaskDraft) throws -> StudyTask
    /// Applies every draft field. Notifies sync only for confirmed tasks.
    func updateTask(_ task: StudyTask, with draft: TaskDraft) throws
    /// Promotes a pendingConfirm candidate to `pending` — its FIRST sync
    /// push (the row existed only locally until now).
    func confirmTask(_ task: StudyTask) throws
    func setTaskStatus(_ task: StudyTask, status: StudyTaskStatus) throws
    /// Deletes the row. A pendingConfirm candidate was never pushed, so
    /// its delete is local-only (no tombstone); confirmed tasks notify
    /// sync.
    func deleteTask(_ task: StudyTask) throws
    /// Cloud-sync apply for a task record.
    func applyRemoteStudyTask(record: SyncServerRecordDTO, serverVersion: Int) throws
    func deleteTaskByID(_ id: UUID) throws

    // MARK: Session recordings (device-local)
    // The audio FILE lives under SessionRecordings; these rows are the
    // only sanctioned way to reach it (views never build raw.wav paths).
    // Recordings never sync — only their row exists locally.

    /// The session's recording metadata (nil = never recorded / no row).
    func recording(sessionID: UUID) throws -> SessionRecording?
    /// All recordings across sessions (storage management statistics).
    func allRecordings() throws -> [SessionRecording]
    /// Registers a recording started by the live coordinator (file is
    /// already open on disk). Local-only — no sync notification.
    func beginRecording(sessionID: UUID) throws -> SessionRecording
    /// Marks duration/size and completion after a clean stop. Local-only.
    func finishRecording(_ recording: SessionRecording, duration: TimeInterval, fileSize: Int64) throws
    /// Persists a waveform-status change WITHOUT touching
    /// duration/completion semantics (the waveform precompute uses this;
    /// `finishRecording` is reserved for the clean-stop path).
    /// Local-only.
    func updateRecordingWaveformStatus(_ recording: SessionRecording, status: SessionRecording.WaveformStatus) throws
    /// Deletes the audio FILE but keeps the row (isDeleted) so transcript
    /// time metadata survives. Local-only. Returns the reclaimed bytes.
    @discardableResult
    func deleteRecordingFile(_ recording: SessionRecording) throws -> Int64
    /// Reconciles rows against disk at launch: creates rows for legacy
    /// recordings (raw.wav exists, no row — recorded by an older version),
    /// flips isComplete on rows whose session ended, and marks isDeleted
    /// when the file was removed behind our back. Local-only.
    func reconcileRecordingState() throws

    // MARK: Transcript corrections (user edit layer)
    // The model's original ASR/translation text is immutable; corrections
    // are a separate overlay synced as their own entity (id == entry id).

    /// All corrections of a session, keyed by entry id.
    func corrections(forSessionID id: UUID) throws -> [TranscriptCorrection]
    /// All corrections across sessions (search, storage statistics).
    func allCorrections() throws -> [TranscriptCorrection]
    /// Saves (creates or updates) the correction for one entry. Bumps the
    /// session's updatedAt (study-review staleness). Notifies sync.
    func saveCorrection(
        sessionID: UUID, entryID: UUID,
        russian: String, chinese: String?, needsRetranslation: Bool
    ) throws -> TranscriptCorrection
    /// Removes the correction (revert to the model's original). Notifies
    /// sync (delete → tombstone).
    func deleteCorrection(entryID: UUID) throws
    /// Cloud-sync apply for a correction record (newer modifiedAt wins;
    /// a lost-but-substantive race preserves the loser in conflictJSON).
    func applyRemoteCorrection(record: SyncServerRecordDTO, serverVersion: Int) throws
    /// Cloud-sync delete for a correction (revert to model original; never
    /// resurrects locally).
    func deleteCorrectionByID(_ id: UUID) throws

    // MARK: Course schedules (pre-class layer)
    // Recurring rules + dated exceptions; occurrences are computed by
    // ScheduleCalculator, never materialized. Deleting a course deletes
    // its schedules and their exceptions (a rule without its course is
    // meaningless); sessions keep their scheduleID/occurrenceKey (the
    // references dangle — the UI shows 来源已不存在).

    /// All schedules (nil courseID = every course), newest first.
    func schedules(courseID: UUID?) throws -> [CourseSchedule]
    /// Creates a schedule. Notifies sync.
    func addSchedule(_ draft: ScheduleDraft) throws -> CourseSchedule
    /// Applies every draft field. Notifies sync.
    func updateSchedule(_ schedule: CourseSchedule, with draft: ScheduleDraft) throws
    /// Flips the enabled flag (pause/resume). Notifies sync.
    func setScheduleEnabled(_ schedule: CourseSchedule, isEnabled: Bool) throws
    /// Deletes the schedule. Its exceptions are deleted too (matching the
    /// server's cascade). Notifies sync.
    func deleteSchedule(_ schedule: CourseSchedule) throws
    /// Cloud-sync apply for a schedule record.
    func applyRemoteSchedule(record: SyncServerRecordDTO, serverVersion: Int) throws
    /// Cloud-sync delete for a schedule (also removes its exceptions —
    /// the server cascade arrives as separate delete changes, but the
    /// local rows go together).
    func deleteScheduleByID(_ id: UUID) throws

    /// All exceptions of one schedule (any order — the calculator groups).
    func exceptions(scheduleID: UUID) throws -> [ScheduleException]
    /// All exceptions across schedules (calculator input).
    func allExceptions() throws -> [ScheduleException]
    /// Creates an exception. Notifies sync.
    func addException(_ draft: ScheduleExceptionDraft) throws -> ScheduleException
    /// Applies every draft field. Notifies sync.
    func updateException(_ exception: ScheduleException, with draft: ScheduleExceptionDraft) throws
    /// Deletes the exception. Notifies sync.
    func deleteException(_ exception: ScheduleException) throws
    /// Cloud-sync apply for an exception record.
    func applyRemoteException(record: SyncServerRecordDTO, serverVersion: Int) throws
    /// Cloud-sync delete for an exception.
    func deleteExceptionByID(_ id: UUID) throws

    // MARK: Schedule-attributed session queries

    /// Sessions whose occurrenceKey matches (duplicate-start protection
    /// and attendance grouping). Includes finished sessions.
    func sessions(occurrenceKey: String) throws -> [ClassroomSession]
    /// The user's ongoing session (nil when none is running).
    func ongoingSession() throws -> ClassroomSession?

    // MARK: Course materials (资料库)
    // Files live under MaterialFileStore; the repository persists
    // metadata and page rows only. Extraction/digest/OCR in-progress
    // states (extracting/analyzing/running) are device-local and never
    // notify the sync observer; terminal states and user edits do.
    // Materials SURVIVE their sources: deleting a course clears the
    // material's courseID (资料转入未归类); deleting a session clears the
    // sessionID (资料仍属于课程). Deleting a MATERIAL cascades to its
    // pages and annotations and reaps its files.

    // Materials

    /// All materials (nil courseID = every course incl. 未归类), newest
    /// first.
    func materials(courseID: UUID?) throws -> [CourseMaterial]
    /// One material by id.
    func material(id: UUID) throws -> CourseMaterial?
    /// Materials whose title/file name/digest text contains the query.
    func materials(matching query: String) throws -> [CourseMaterial]
    /// Materials with this original-file hash (duplicate-import prompt;
    /// never auto-deletes).
    func materials(contentHash: String) throws -> [CourseMaterial]
    /// Materials linked to one schedule occurrence (课前资料).
    func materials(occurrenceKey: String) throws -> [CourseMaterial]
    /// Persists a fully-imported material (files already on disk — the
    /// row is written LAST by contract). Notifies sync.
    func addMaterial(_ draft: MaterialDraft) throws -> CourseMaterial
    /// Applies every metadata field of the draft (edit sheet save).
    /// Notifies sync.
    func updateMaterial(_ material: CourseMaterial, with draft: MaterialDraft) throws
    /// Reading-progress touch (lastReadPage/lastOpenedAt). Notifies sync.
    func touchMaterialRead(_ material: CourseMaterial, page: Int) throws
    /// Deletes the material and its pages/annotations (server cascades
    /// the children). Notifies sync; files are reaped by the store.
    func deleteMaterial(_ material: CourseMaterial) throws

    // Material digest (导读) lifecycle. The old digest survives until a
    // new one succeeds (never blanked at regeneration start); generation
    // progress (analyzing / chunk state) is device-local.

    /// Starts/restarts a digest run: writes the chunk plan and the local
    /// analyzing state. The previous digest content stays until
    /// completion. Local-only.
    func beginMaterialDigestGeneration(
        _ material: CourseMaterial, chunkStateJSON: String
    ) throws
    /// Persists chunk progress; `terminal` optionally updates the status.
    /// Local-only.
    func updateMaterialDigestProgress(
        _ material: CourseMaterial, chunkStateJSON: String,
        terminal: MaterialDigestStatus?
    ) throws
    /// A finished run: replaces the digest, stamps model and source hash,
    /// sets completed. Notifies sync.
    func completeMaterialDigestGeneration(
        _ material: CourseMaterial, digest: MaterialDigestResult,
        model: String, sourceHash: String
    ) throws
    /// Marks a run failed (previous digest, if any, stays). Notifies sync
    /// only when a digest worth keeping exists.
    func failMaterialDigestGeneration(_ material: CourseMaterial) throws
    /// An orphaned `analyzing` row (app was killed): becomes partial when
    /// chunks finished, else failed. Local-only.
    func markMaterialDigestInterrupted(_ material: CourseMaterial) throws

    /// Cloud-sync apply for a material record.
    func applyRemoteMaterial(record: SyncServerRecordDTO, serverVersion: Int) throws
    func deleteMaterialByID(_ id: UUID) throws

    // Material pages (extraction + OCR)

    /// All pages of a material, page order.
    func materialPages(materialID: UUID) throws -> [MaterialPage]
    /// Pages whose extracted/OCR text contains the query, joined with
    /// their material for display.
    func materialPages(matching query: String) throws -> [(page: MaterialPage, material: CourseMaterial)]
    /// Begins an extraction run: clears stale page rows when re-extracting
    /// (keep OCR/annotations — the pages are the same), sets the local
    /// extracting state. Local-only.
    func beginMaterialExtraction(_ material: CourseMaterial, pageCount: Int) throws
    /// Upserts one page's extracted text (deterministic row id). Notifies
    /// sync — each completed page is final content.
    func upsertMaterialPageText(
        _ material: CourseMaterial, pageNumber: Int, extractedText: String
    ) throws -> MaterialPage
    /// Ends an extraction run with a terminal status. Notifies sync.
    func finishMaterialExtraction(
        _ material: CourseMaterial, status: MaterialExtractionStatus
    ) throws
    /// Saves page OCR text with its terminal status. Notifies sync.
    func updateMaterialPageOCR(
        _ page: MaterialPage, text: String, status: MaterialOCRStatus
    ) throws
    /// An orphaned `extracting` row (app was killed): becomes partial when
    /// any page landed, else failed. Local-only.
    func markMaterialExtractionInterrupted(_ material: CourseMaterial) throws
    /// Cloud-sync apply for a page record.
    func applyRemoteMaterialPage(record: SyncServerRecordDTO, serverVersion: Int) throws
    func deleteMaterialPageByID(_ id: UUID) throws

    // Material annotations (user note/bookmark layer)

    /// All annotations of a material, page then created order.
    func materialAnnotations(materialID: UUID) throws -> [MaterialAnnotation]
    func addMaterialAnnotation(_ draft: MaterialAnnotationDraft) throws -> MaterialAnnotation
    func updateMaterialAnnotationText(_ annotation: MaterialAnnotation, text: String) throws
    func deleteMaterialAnnotation(_ annotation: MaterialAnnotation) throws
    /// Cloud-sync apply for an annotation record.
    func applyRemoteMaterialAnnotation(record: SyncServerRecordDTO, serverVersion: Int) throws
    func deleteMaterialAnnotationByID(_ id: UUID) throws

    // Course assistant (问这门课)

    /// All threads of a course (nil = every course incl. 未归类), newest
    /// activity first.
    func assistantThreads(courseID: UUID?) throws -> [CourseAssistantThread]
    func addAssistantThread(courseID: UUID?, title: String) throws -> CourseAssistantThread
    func renameAssistantThread(_ thread: CourseAssistantThread, title: String) throws
    /// Deletes the thread and its messages (server cascades). Notifies
    /// sync.
    func deleteAssistantThread(_ thread: CourseAssistantThread) throws
    /// Cloud-sync apply for a thread record.
    func applyRemoteAssistantThread(record: SyncServerRecordDTO, serverVersion: Int) throws
    func deleteAssistantThreadByID(_ id: UUID) throws

    // Assistant messages

    /// All messages of a thread, oldest first.
    func assistantMessages(threadID: UUID) throws -> [CourseAssistantMessage]
    /// Appends one message (user question or completed answer with its
    /// citations). Notifies sync.
    func addAssistantMessage(_ draft: AssistantMessageDraft) throws -> CourseAssistantMessage
    /// Messages whose text contains the query (search).
    func assistantMessages(matching query: String) throws -> [(message: CourseAssistantMessage, thread: CourseAssistantThread)]
    /// Cloud-sync apply for a message record.
    func applyRemoteAssistantMessage(record: SyncServerRecordDTO, serverVersion: Int) throws
    func deleteAssistantMessageByID(_ id: UUID) throws

    // MARK: Exams (考试中心)
    // AI candidates (origin == .aiCandidate rows with status .pending)
    // are device-local like pendingConfirm tasks: they never notify the
    // sync observer, never register notifications and never generate
    // plans, until the user confirms them. Deleting an EXAM cascades its
    // topics + plans + plan items (server mirrors) and DETACHES its study
    // activities (the learning history survives). Deleting a COURSE
    // clears the exam's courseID (转入未归类).

    // Exams

    /// All exams (nil courseID = every course incl. 未归类), soonest date
    /// first. AI candidates included only when `includeCandidates`.
    func exams(courseID: UUID?, includeCandidates: Bool) throws -> [Exam]
    func exam(id: UUID) throws -> Exam?
    /// Exams whose title/scope/note contains the query (search).
    func exams(matching query: String) throws -> [Exam]
    /// AI candidates awaiting confirmation (device-local rows).
    func pendingExamCandidates() throws -> [Exam]
    /// Persists a new exam (or an AI candidate when the draft carries
    /// `.pending`). Notifies sync for real exams only.
    func addExam(_ draft: ExamDraft) throws -> Exam
    /// Applies every field of the draft (edit sheet save). Notifies sync
    /// unless the row is still a device-local candidate.
    func updateExam(_ exam: Exam, with draft: ExamDraft) throws
    /// Confirms an AI candidate into a real exam (status pending →
    /// scheduled): first sync push of a previously device-local row.
    func confirmExam(_ exam: Exam) throws
    /// Status change (done/cancelled/re-scheduled). Notifies sync unless
    /// the row is still a candidate.
    func setExamStatus(_ exam: Exam, status: ExamStatus) throws
    /// Deletes the exam: cascades topics + plans + items (server
    /// mirrors), detaches activities. Notifies sync.
    func deleteExam(_ exam: Exam) throws
    func applyRemoteExam(record: SyncServerRecordDTO, serverVersion: Int) throws
    func deleteExamByID(_ id: UUID) throws

    // Exam topics

    /// All topics of one exam, focus/important first then title order.
    func examTopics(examID: UUID) throws -> [ExamTopic]
    func addExamTopic(_ draft: ExamTopicDraft) throws -> ExamTopic
    /// Full-field update (edit sheet). Notifies sync.
    func updateExamTopic(_ topic: ExamTopic, with draft: ExamTopicDraft) throws
    /// Status + self-rating setters. Notifies sync. `mastered` is only
    /// reachable through the UI's explicit user action.
    func setExamTopicStatus(_ topic: ExamTopic, status: ExamTopicStatus) throws
    func setExamTopicSelfRating(_ topic: ExamTopic, rating: ExamTopicSelfRating) throws
    func deleteExamTopic(_ topic: ExamTopic) throws
    func applyRemoteExamTopic(record: SyncServerRecordDTO, serverVersion: Int) throws
    func deleteExamTopicByID(_ id: UUID) throws

    // Study plans

    /// All plans (nil examID = every exam).
    func studyPlans(examID: UUID?) throws -> [StudyPlan]
    func addStudyPlan(_ draft: StudyPlanDraft) throws -> StudyPlan
    func updateStudyPlan(_ plan: StudyPlan, with draft: StudyPlanDraft) throws
    /// Status change (pause/resume/archive). Notifies sync.
    func setStudyPlanStatus(_ plan: StudyPlan, status: StudyPlanStatus) throws
    /// Deletes the plan: cascades its items (server mirrors). Notifies
    /// sync.
    func deleteStudyPlan(_ plan: StudyPlan) throws
    func applyRemoteStudyPlan(record: SyncServerRecordDTO, serverVersion: Int) throws
    func deleteStudyPlanByID(_ id: UUID) throws

    // Plan items

    /// All items of one plan, date then order.
    func studyPlanItems(planID: UUID) throws -> [StudyPlanItem]
    /// One plan item by id (the timer card's title resolution).
    func studyPlanItem(id: UUID) throws -> StudyPlanItem?
    /// Items across every plan scheduled on one date key.
    func studyPlanItems(dateKey: String) throws -> [StudyPlanItem]
    /// Items whose title/note contains the query (search).
    func studyPlanItems(matching query: String) throws -> [StudyPlanItem]
    /// Persists generated or manually-created items. Notifies sync.
    func addStudyPlanItems(_ drafts: [StudyPlanItemDraft]) throws -> [StudyPlanItem]
    /// Single-field updates (title/estimated/delay/skip status). Notify
    /// sync; every status change stamps statusChangedAt (the merge
    /// order).
    func updateStudyPlanItem(_ item: StudyPlanItem, title: String?, estimatedMinutes: Int?, userNote: String?) throws
    func setStudyPlanItemStatus(_ item: StudyPlanItem, status: StudyPlanItemStatus) throws
    func setStudyPlanItemDate(_ item: StudyPlanItem, dateKey: String) throws
    /// Writes the activity's measured minutes back onto the item
    /// (monotonic — never decreases). Notifies sync.
    func recordStudyPlanItemActualMinutes(_ item: StudyPlanItem, minutes: Int) throws
    func deleteStudyPlanItem(_ item: StudyPlanItem) throws
    func applyRemoteStudyPlanItem(record: SyncServerRecordDTO, serverVersion: Int) throws
    func deleteStudyPlanItemByID(_ id: UUID) throws

    // Study activities (真实学习计时)

    /// All activities (nil examID = every exam), newest first.
    func studyActivities(examID: UUID?) throws -> [StudyActivity]
    /// The single in-progress activity, if any (exactly-one invariant).
    func currentStudyActivity() throws -> StudyActivity?
    /// Starts a new activity — refuses while another is in progress.
    /// Notifies sync.
    func startStudyActivity(_ draft: StudyActivityDraft) throws -> StudyActivity?
    /// Terminal transition (completed/abandoned): folds active time into
    /// duration, writes the minutes back onto the plan item. Notifies
    /// sync.
    func finishStudyActivity(_ activity: StudyActivity, status: StudyActivityStatus, note: String) throws
    /// Device-local pause/resume (folds time; no sync notification —
    /// the folded duration syncs at the next terminal or background
    /// checkpoint).
    func pauseStudyActivity(_ activity: StudyActivity) throws
    func resumeStudyActivity(_ activity: StudyActivity) throws
    /// Background checkpoint: folds elapsed active time into
    /// durationSeconds WITHOUT ending the activity. Notifies sync so
    /// another device sees honest progress.
    func checkpointStudyActivity(_ activity: StudyActivity) throws
    /// Total ACTIVE minutes on one calendar day (今日学习统计 — classroom
    /// recording time never counts, only these rows).
    func studyActivityMinutes(on date: Date) throws -> Int
    /// Activities whose note contains the query (search).
    func studyActivities(matching query: String) throws -> [StudyActivity]
    func applyRemoteStudyActivity(record: SyncServerRecordDTO, serverVersion: Int) throws
    func deleteStudyActivityByID(_ id: UUID) throws

    // MARK: Interpreter (随身翻译)

    /// The active draft (at most one per account; nil = none).
    var interpreterDraft: InterpreterConversation? { get }
    /// Creates a fresh draft (refuses while one is active). Draft rows
    /// NEVER notify sync (device-local until saved).
    func startInterpreterDraft(scene: InterpreterScene, contextNote: String) throws -> InterpreterConversation
    /// The draft's turns in sequence order.
    func interpreterTurns(conversationID: UUID) throws -> [InterpreterTurn]
    /// Appends a counterpart (ru2zh) turn from local ASR. The Russian
    /// source lands immediately (translation pending); draft rows never
    /// notify sync.
    func addInterpreterCounterpartTurn(
        conversationID: UUID, russian: String, inputMethod: InterpreterInputMethod
    ) throws -> InterpreterTurn
    /// Appends a user (zh2ru) turn — the Chinese lands first, translation
    /// pending. Draft rows never notify sync.
    func addInterpreterUserTurn(
        conversationID: UUID, chinese: String, inputMethod: InterpreterInputMethod
    ) throws -> InterpreterTurn
    /// Writes a completed structured translation onto a turn. Draft rows
    /// never notify sync. localSources (文件上下文回合的设备本地来源)
    /// 只落本地 —— wire 上没有它的位置。
    func completeInterpreterTurnTranslation(
        _ turn: InterpreterTurn,
        chinese: String?, russian: String?, stressedRussian: String?,
        backTranslation: String?, details: InterpreterTurnDetails?,
        localSources: [InterpreterLocalSource]?
    ) throws
    /// Marks a turn's translation failed (the source text stays).
    func failInterpreterTurnTranslation(_ turn: InterpreterTurn) throws
    /// User edit of a turn's source text (stamps modifiedAt — the merge
    /// tiebreak). Notifies sync only for saved conversations.
    func updateInterpreterTurnSource(_ turn: InterpreterTurn, text: String) throws
    /// Deletes one turn (draft delete; also delete-wins for saved rows).
    /// Notifies sync only for saved conversations.
    func deleteInterpreterTurn(_ turn: InterpreterTurn) throws
    /// Persists the draft as a saved record: stamps endedAt, flips
    /// status, notifies sync for the conversation AND its turns. Empty
    /// conversations are deleted instead (no history garbage).
    func saveInterpreterDraft(title: String?) throws
    /// Discards the draft and its turns outright (no wire traffic).
    func discardInterpreterDraft() throws
    /// A pending-draft recovery prompt: the draft's turn count, or nil
    /// when no draft exists.
    func interpreterDraftTurnCount() throws -> Int?
    /// Saved conversations, newest first (历史记录 inside 随身翻译 —
    /// never the classroom record list).
    func savedInterpreterConversations() throws -> [InterpreterConversation]
    /// All saved conversations whose title/scene/turn texts match the
    /// query (global search).
    func interpreterConversations(matching query: String) throws -> [InterpreterConversation]
    /// One conversation by id.
    func interpreterConversation(id: UUID) -> InterpreterConversation?
    /// Renames a saved conversation. Notifies sync.
    func renameInterpreterConversation(_ conversation: InterpreterConversation, to title: String) throws
    /// Updates scene + context note of a saved conversation. Notifies
    /// sync (used by 继续作为新对话的上下文副本).
    func updateInterpreterConversationMeta(
        _ conversation: InterpreterConversation, contextNote: String
    ) throws
    /// Deletes a saved conversation and its turns. Notifies sync.
    func deleteInterpreterConversation(_ conversation: InterpreterConversation) throws
    func applyRemoteInterpreterConversation(record: SyncServerRecordDTO, serverVersion: Int) throws
    func applyRemoteInterpreterTurn(record: SyncServerRecordDTO, serverVersion: Int) throws
    func deleteInterpreterConversationByID(_ id: UUID) throws
    func deleteInterpreterTurnByID(_ id: UUID) throws
    /// One-time migration (round 17): moves file-source labels from the
    /// syncable detailsJSON into the device-local localSourcesJSON and
    /// re-notifies sync for the rewritten turns. Idempotent.
    @discardableResult
    func migrateInterpreterCitationDetails() throws -> Int
    /// Round 17 retention: deletes SAVED conversations' interpreter
    /// documents older than `days` (0 = keep everything). Row + file
    /// reconciled; active drafts never touched.
    @discardableResult
    func applyInterpreterDocumentRetention(
        days: Int, store: InterpreterDocumentStore?, asOf now: Date
    ) throws -> Int

    // MARK: Interpreter document context (现场文件 · device-local)

    /// All documents of one conversation, creation order. NEVER notifies
    /// sync — interpreter documents are device-local.
    func interpreterDocuments(conversationID: UUID) throws -> [InterpreterDocument]
    /// One document by id.
    func interpreterDocument(id: UUID) -> InterpreterDocument?
    /// Documents with the same content hash in ONE conversation (the
    /// duplicate-import prompt; never crosses accounts).
    func interpreterDocuments(conversationID: UUID, contentHash: String) throws -> [InterpreterDocument]
    /// All document rows (storage management / launch reconcile).
    func allInterpreterDocuments() throws -> [InterpreterDocument]
    /// Inserts a fully-imported document row (file already landed via
    /// the store). Local-only — never notifies sync.
    func addInterpreterDocument(_ draft: InterpreterDocumentDraft) throws -> InterpreterDocument
    /// Status transition of the local state machine. Local-only.
    func setInterpreterDocumentStatus(
        _ document: InterpreterDocument, status: InterpreterDocumentStatus, errorSummary: String?
    ) throws
    /// Records a landed extraction sidecar. Local-only.
    func setInterpreterDocumentExtraction(
        _ document: InterpreterDocument,
        extractionRelativePath: String,
        pageCount: Int,
        status: InterpreterDocumentStatus
    ) throws
    /// Privacy gate / keep-originals preference. Local-only.
    func updateInterpreterDocumentPreferences(
        _ document: InterpreterDocument, allowsModelUse: Bool?, keepOriginalFile: Bool?
    ) throws
    /// Stores the latest AI analysis (the field assistant's data source).
    /// Local-only.
    func setInterpreterDocumentAnalysis(
        _ document: InterpreterDocument, analysis: InterpreterDocumentAnalysis
    ) throws
    /// Interrupt recovery: importing → retryable failed, extracting →
    /// imported; a row whose file vanished flips to failed. Local-only.
    func reconcileInterpreterDocuments(store: InterpreterDocumentStore)
    /// Deletes one document row + its files. Local-only (no wire traffic).
    func deleteInterpreterDocument(
        _ document: InterpreterDocument, store: InterpreterDocumentStore?
    ) throws
    /// Deletes every document of one conversation (+ files). Local-only.
    func deleteInterpreterDocuments(
        conversationID: UUID, store: InterpreterDocumentStore?
    ) throws
    /// Drops ORIGINAL files keeping extraction sidecars (the
    /// end-of-conversation choice). Local-only.
    func dropInterpreterDocumentOriginals(
        conversationID: UUID, store: InterpreterDocumentStore?
    ) throws
    /// Row counts for the storage-management UI.
    func interpreterDocumentCounts() throws -> (documents: Int, withOriginals: Int)
}

extension ClassroomRepositoryProtocol {
    /// Default-argument shim for protocol-existential call sites (the
    /// implementation signature carries its own default, but dynamic
    /// dispatch through `any ClassroomRepositoryProtocol` cannot see it).
    func setInterpreterDocumentStatus(
        _ document: InterpreterDocument, status: InterpreterDocumentStatus
    ) throws {
        try setInterpreterDocumentStatus(document, status: status, errorSummary: nil)
    }
}

/// A new exam (title + date required). AI candidates pass
/// `status: .pending, origin: .ai` — the row stays local until confirmed.
struct ExamDraft: Sendable, Equatable {
    var title: String
    var courseID: UUID? = nil
    var kind: ExamKind = .custom
    var examDateKey: String
    var startSecs: Int = -1
    var endSecs: Int = -1
    var location: String = ""
    var scopeText: String = ""
    var note: String = ""
    var targetScore: String = ""
    var status: ExamStatus = .scheduled
    var origin: ExamOrigin = .manual
    var source: ExamSource? = nil
}

/// A new exam topic.
struct ExamTopicDraft: Sendable, Equatable {
    var examID: UUID
    var title: String
    var detail: String = ""
    var importance: ExamTopicImportance = .normal
    var selfRating: ExamTopicSelfRating = .none
    var status: ExamTopicStatus = .notStarted
    var source: TopicSource? = nil
    var userEdited: Bool = false
}

/// A new study plan (created after the user confirms a PREVIEW — the
/// repository never persists a generated preview directly).
struct StudyPlanDraft: Sendable, Equatable {
    var examID: UUID
    var title: String
    var startDateKey: String
    var endDateKey: String
    var weekdayMinutes: Int = 60
    var weekendMinutes: Int = 90
    var restDays: [Int] = []
    var finishEarlyDays: Int = 1
    var includeCards: Bool = true
    var includeTasks: Bool = true
    var includeMaterials: Bool = true
    var includeSessions: Bool = true
    var focusTopics: [UUID] = []
    var blockedTimes: [StudyBlockedTime] = []
    var status: StudyPlanStatus = .active
}

/// A daily time range the user does not want study scheduled in.
struct StudyBlockedTime: Codable, Sendable, Equatable, Identifiable {
    var id = UUID()
    /// Weekday numbers the range applies to (empty = every day).
    var weekdays: [Int] = []
    /// Seconds since midnight.
    var startSecs: Int
    var endSecs: Int
}

/// A new plan item (generated by the planner or created manually).
struct StudyPlanItemDraft: Sendable {
    var planID: UUID
    var examID: UUID?
    var itemDateKey: String
    var title: String
    var kind: StudyPlanItemKind = .custom
    var estimatedMinutes: Int = 30
    var itemOrder: Int = 0
    var source: PlanItemSource? = nil
}

/// A new study activity (start of a real learning-timer run).
struct StudyActivityDraft: Sendable {
    var planItemID: UUID? = nil
    var examID: UUID? = nil
    var courseID: UUID? = nil
    var topicID: UUID? = nil
    var note: String = ""
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
    /// Schedule attribution (schedule-launched sessions only): nil on
    /// manual starts. Written once at creation, never edited after.
    var scheduleID: UUID? = nil
    var occurrenceKey: String? = nil
    var plannedStart: Date? = nil
}

struct EntryDraft: Sendable {
    var sequenceID: Int
    var startOffset: TimeInterval
    var endOffset: TimeInterval
    var originalText: String
    var asrBackend: ASRBackendKind
    var asrLatency: TimeInterval
    var asrRTF: Double
    /// Provenance of the offsets: live classes write `.audio` (sample
    /// timeline); remote/cloud rows apply as `.legacy` at pull time.
    var timeSource: TranscriptTimeSource = .audio
}

/// Course fields the create/edit form produces.
struct CourseDraft: Sendable, Equatable {
    var name: String
    var teacherName: String = ""
    var location: String = ""
    var colorIndex: Int = 0
    var isArchived: Bool = false
}

/// A new note (text required; anchor optional). `timeOffset` is the
/// classroom-relative moment (live time or playback position); nil on
/// legacy/unknown.
struct NoteDraft: Sendable {
    var text: String
    var anchorEntryID: UUID? = nil
    var timeOffset: TimeInterval? = nil
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

/// A new glossary term (russian required; sources optional).
struct TermDraft: Sendable, Equatable {
    var russian: String
    var chinese: String = ""
    var explanation: String = ""
    var partOfSpeech: String = ""
    var userNote: String = ""
    var courseID: UUID? = nil
    var sessionID: UUID? = nil
    var sourceEntryID: UUID? = nil
    var sourceAttachmentID: UUID? = nil
    var sourceReviewID: UUID? = nil
    var sourceMaterialID: UUID? = nil
    var sourceMaterialPage: Int = 0
    var isFavorite: Bool = false
    var status: GlossaryTermStatus = .new
}

/// A new study card (front + back required; sources optional).
struct CardDraft: Sendable, Equatable {
    var front: String
    var back: String
    var type: StudyCardType = .qa
    var userNote: String = ""
    var courseID: UUID? = nil
    var sessionID: UUID? = nil
    var sourceEntryID: UUID? = nil
    var sourceAttachmentID: UUID? = nil
    var sourceTermID: UUID? = nil
    var sourceMaterialID: UUID? = nil
    var sourceMaterialPage: Int = 0
    var origin: StudyCardOrigin = .manual
}

/// A new study task (title required). AI candidates pass
/// `status: .pendingConfirm` — the row stays local until confirmed.
struct TaskDraft: Sendable, Equatable {
    var title: String
    var detail: String = ""
    var priority: StudyTaskPriority = .normal
    var status: StudyTaskStatus = .pending
    var origin: StudyTaskOrigin = .manual
    var uncertainty: String = ""
    var userNote: String = ""
    var dueAt: Date? = nil
    var courseID: UUID? = nil
    var sessionID: UUID? = nil
    var sourceEntryID: UUID? = nil
    var sourceAttachmentID: UUID? = nil
    var sourceReviewID: UUID? = nil
    var sourceMaterialID: UUID? = nil
    var sourceMaterialPage: Int = 0
}

/// A fully-imported new material. The FILE is already on disk (or the
/// material borrows a classroom attachment's files when
/// `sourceAttachmentID` is set — then no file copy exists; or the
/// material is a saved LINK — `format == .link`, no file, the URL rides
/// `sourceURL` and any shared text rides `sharedText`); the draft
/// carries only metadata derived during import.
struct MaterialDraft: Sendable, Equatable {
    var title: String
    var originalFileName: String
    var mimeType: String = ""
    var kind: MaterialKind = .other
    var format: MaterialFormat = .other
    var fileSize: Int64 = 0
    var contentHash: String = ""
    var pageCount: Int = 0
    var courseID: UUID? = nil
    var sessionID: UUID? = nil
    var occurrenceKey: String? = nil
    var sourceAttachmentID: UUID? = nil
    /// Saved web URL (format .link only).
    var sourceURL: String = ""
    /// Text shared alongside the URL (format .link only).
    var sharedText: String = ""
    /// Terminal extraction state at import time (text materials arrive
    /// parsed; office documents arrive `unsupported`).
    var extractionStatus: MaterialExtractionStatus = .pending
}

/// A new page-level note or bookmark on a material.
struct MaterialAnnotationDraft: Sendable, Equatable {
    var materialID: UUID
    var pageNumber: Int
    var kind: MaterialAnnotationKind
    var text: String = ""
}

/// One assistant message (question or completed answer).
struct AssistantMessageDraft: Sendable {
    var threadID: UUID
    var role: AssistantMessageRole
    var text: String
    var scopeMaterialID: UUID? = nil
    var scopeSessionID: UUID? = nil
    var citations: [AssistantMessageCitation] = []
    /// Text vs visual turn (visual = the message carried evidence images).
    var mode: AssistantMessageMode = .text
    /// Evidence snapshot for visual turns (stable ids + normalized crop
    /// rects only — never image bytes).
    var evidence: [VisualEvidence] = []
    /// Structured answer payload (visual answers).
    var answer: VisualAnswer? = nil
    /// Model that produced the answer (provenance).
    var answerModel: String? = nil
}

extension GlossaryTerm {
    /// Case-insensitive, whitespace/ё-normalized russian used for dedup
    /// ("дифференциал" == "Дифференциал " == "диференциал"-lite).
    var normalizedRussian: String {
        russian
            .lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension UUID {
    /// Wire sentinel for "clear this reference" in sync payloads. A nil
    /// optional payload field means "not specified — keep the server
    /// value"; this all-zero UUID means "remove it". Mirrors Go's uuid.Nil.
    static let nilSentinel = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
}
