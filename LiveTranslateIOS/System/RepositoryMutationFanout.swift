import Foundation
import OSLog

// Repository-mutation fanout + the system-surface observer bridge.
//
// The repository's single `mutationObserver` slot belongs to the sync
// service (exclusive set/nil contract). System surfaces (Spotlight
// indexing, widget snapshot refresh) need the SAME complete mutation
// coverage — including cloud-sync applies and inbox-driven imports — so
// they register as AUXILIARY observers; the repository hands mutation
// sites a small forwarding fanout (primary + auxiliaries) whenever
// auxiliaries exist. Call sites and the sync service stay untouched.

// MARK: - Fanout

/// Forwards every mutation notification to the primary observer and each
/// auxiliary. One instance per notification (cheap; mutations are
/// user-paced) — no identity semantics needed.
@MainActor
final class RepositoryMutationFanout: TranscriptMutationObserving {
    private let primary: (any TranscriptMutationObserving)?
    private let auxiliaries: [any TranscriptMutationObserving]

    init(
        primary: (any TranscriptMutationObserving)?,
        auxiliaries: [any TranscriptMutationObserving]
    ) {
        self.primary = primary
        self.auxiliaries = auxiliaries
    }

    func sessionCreated(_ session: ClassroomSession) {
        primary?.sessionCreated(session)
        auxiliaries.forEach { $0.sessionCreated(session) }
    }
    func sessionUpdated(_ session: ClassroomSession) {
        primary?.sessionUpdated(session)
        auxiliaries.forEach { $0.sessionUpdated(session) }
    }
    func sessionDeleted(id: UUID) {
        primary?.sessionDeleted(id: id)
        auxiliaries.forEach { $0.sessionDeleted(id: id) }
    }
    func entryCreated(_ entry: TranscriptEntry) {
        primary?.entryCreated(entry)
        auxiliaries.forEach { $0.entryCreated(entry) }
    }
    func entryUpdated(_ entry: TranscriptEntry) {
        primary?.entryUpdated(entry)
        auxiliaries.forEach { $0.entryUpdated(entry) }
    }
    func courseCreated(_ course: Course) {
        primary?.courseCreated(course)
        auxiliaries.forEach { $0.courseCreated(course) }
    }
    func courseUpdated(_ course: Course) {
        primary?.courseUpdated(course)
        auxiliaries.forEach { $0.courseUpdated(course) }
    }
    func courseDeleted(id: UUID) {
        primary?.courseDeleted(id: id)
        auxiliaries.forEach { $0.courseDeleted(id: id) }
    }
    func noteCreated(_ note: SessionNote) {
        primary?.noteCreated(note)
        auxiliaries.forEach { $0.noteCreated(note) }
    }
    func noteUpdated(_ note: SessionNote) {
        primary?.noteUpdated(note)
        auxiliaries.forEach { $0.noteUpdated(note) }
    }
    func noteDeleted(id: UUID) {
        primary?.noteDeleted(id: id)
        auxiliaries.forEach { $0.noteDeleted(id: id) }
    }
    func studyReviewUpdated(_ review: StudyReview) {
        primary?.studyReviewUpdated(review)
        auxiliaries.forEach { $0.studyReviewUpdated(review) }
    }
    func studyReviewDeleted(id: UUID) {
        primary?.studyReviewDeleted(id: id)
        auxiliaries.forEach { $0.studyReviewDeleted(id: id) }
    }
    func attachmentCreated(_ attachment: SessionAttachment) {
        primary?.attachmentCreated(attachment)
        auxiliaries.forEach { $0.attachmentCreated(attachment) }
    }
    func attachmentUpdated(_ attachment: SessionAttachment) {
        primary?.attachmentUpdated(attachment)
        auxiliaries.forEach { $0.attachmentUpdated(attachment) }
    }
    func attachmentDeleted(id: UUID) {
        primary?.attachmentDeleted(id: id)
        auxiliaries.forEach { $0.attachmentDeleted(id: id) }
    }
    func termCreated(_ term: GlossaryTerm) {
        primary?.termCreated(term)
        auxiliaries.forEach { $0.termCreated(term) }
    }
    func termUpdated(_ term: GlossaryTerm) {
        primary?.termUpdated(term)
        auxiliaries.forEach { $0.termUpdated(term) }
    }
    func termDeleted(id: UUID) {
        primary?.termDeleted(id: id)
        auxiliaries.forEach { $0.termDeleted(id: id) }
    }
    func cardCreated(_ card: StudyCard) {
        primary?.cardCreated(card)
        auxiliaries.forEach { $0.cardCreated(card) }
    }
    func cardUpdated(_ card: StudyCard) {
        primary?.cardUpdated(card)
        auxiliaries.forEach { $0.cardUpdated(card) }
    }
    func cardDeleted(id: UUID) {
        primary?.cardDeleted(id: id)
        auxiliaries.forEach { $0.cardDeleted(id: id) }
    }
    func taskCreated(_ task: StudyTask) {
        primary?.taskCreated(task)
        auxiliaries.forEach { $0.taskCreated(task) }
    }
    func taskUpdated(_ task: StudyTask) {
        primary?.taskUpdated(task)
        auxiliaries.forEach { $0.taskUpdated(task) }
    }
    func taskDeleted(id: UUID) {
        primary?.taskDeleted(id: id)
        auxiliaries.forEach { $0.taskDeleted(id: id) }
    }
    func correctionUpserted(_ correction: TranscriptCorrection) {
        primary?.correctionUpserted(correction)
        auxiliaries.forEach { $0.correctionUpserted(correction) }
    }
    func correctionDeleted(id: UUID) {
        primary?.correctionDeleted(id: id)
        auxiliaries.forEach { $0.correctionDeleted(id: id) }
    }
    func scheduleCreated(_ schedule: CourseSchedule) {
        primary?.scheduleCreated(schedule)
        auxiliaries.forEach { $0.scheduleCreated(schedule) }
    }
    func scheduleUpdated(_ schedule: CourseSchedule) {
        primary?.scheduleUpdated(schedule)
        auxiliaries.forEach { $0.scheduleUpdated(schedule) }
    }
    func scheduleDeleted(id: UUID) {
        primary?.scheduleDeleted(id: id)
        auxiliaries.forEach { $0.scheduleDeleted(id: id) }
    }
    func exceptionCreated(_ exception: ScheduleException) {
        primary?.exceptionCreated(exception)
        auxiliaries.forEach { $0.exceptionCreated(exception) }
    }
    func exceptionUpdated(_ exception: ScheduleException) {
        primary?.exceptionUpdated(exception)
        auxiliaries.forEach { $0.exceptionUpdated(exception) }
    }
    func exceptionDeleted(id: UUID) {
        primary?.exceptionDeleted(id: id)
        auxiliaries.forEach { $0.exceptionDeleted(id: id) }
    }
    func materialCreated(_ material: CourseMaterial) {
        primary?.materialCreated(material)
        auxiliaries.forEach { $0.materialCreated(material) }
    }
    func materialUpdated(_ material: CourseMaterial) {
        primary?.materialUpdated(material)
        auxiliaries.forEach { $0.materialUpdated(material) }
    }
    func materialDeleted(id: UUID) {
        primary?.materialDeleted(id: id)
        auxiliaries.forEach { $0.materialDeleted(id: id) }
    }
    func materialPageUpserted(_ page: MaterialPage) {
        primary?.materialPageUpserted(page)
        auxiliaries.forEach { $0.materialPageUpserted(page) }
    }
    func materialAnnotationCreated(_ annotation: MaterialAnnotation) {
        primary?.materialAnnotationCreated(annotation)
        auxiliaries.forEach { $0.materialAnnotationCreated(annotation) }
    }
    func materialAnnotationUpdated(_ annotation: MaterialAnnotation) {
        primary?.materialAnnotationUpdated(annotation)
        auxiliaries.forEach { $0.materialAnnotationUpdated(annotation) }
    }
    func materialAnnotationDeleted(id: UUID) {
        primary?.materialAnnotationDeleted(id: id)
        auxiliaries.forEach { $0.materialAnnotationDeleted(id: id) }
    }
    func assistantThreadCreated(_ thread: CourseAssistantThread) {
        primary?.assistantThreadCreated(thread)
        auxiliaries.forEach { $0.assistantThreadCreated(thread) }
    }
    func assistantThreadUpdated(_ thread: CourseAssistantThread) {
        primary?.assistantThreadUpdated(thread)
        auxiliaries.forEach { $0.assistantThreadUpdated(thread) }
    }
    func assistantThreadDeleted(id: UUID) {
        primary?.assistantThreadDeleted(id: id)
        auxiliaries.forEach { $0.assistantThreadDeleted(id: id) }
    }
    func assistantMessageCreated(_ message: CourseAssistantMessage) {
        primary?.assistantMessageCreated(message)
        auxiliaries.forEach { $0.assistantMessageCreated(message) }
    }
    func examCreated(_ exam: Exam) {
        primary?.examCreated(exam)
        auxiliaries.forEach { $0.examCreated(exam) }
    }
    func examUpdated(_ exam: Exam) {
        primary?.examUpdated(exam)
        auxiliaries.forEach { $0.examUpdated(exam) }
    }
    func examDeleted(id: UUID) {
        primary?.examDeleted(id: id)
        auxiliaries.forEach { $0.examDeleted(id: id) }
    }
    func examTopicCreated(_ topic: ExamTopic) {
        primary?.examTopicCreated(topic)
        auxiliaries.forEach { $0.examTopicCreated(topic) }
    }
    func examTopicUpdated(_ topic: ExamTopic) {
        primary?.examTopicUpdated(topic)
        auxiliaries.forEach { $0.examTopicUpdated(topic) }
    }
    func examTopicDeleted(id: UUID) {
        primary?.examTopicDeleted(id: id)
        auxiliaries.forEach { $0.examTopicDeleted(id: id) }
    }
    func studyPlanCreated(_ plan: StudyPlan) {
        primary?.studyPlanCreated(plan)
        auxiliaries.forEach { $0.studyPlanCreated(plan) }
    }
    func studyPlanUpdated(_ plan: StudyPlan) {
        primary?.studyPlanUpdated(plan)
        auxiliaries.forEach { $0.studyPlanUpdated(plan) }
    }
    func studyPlanDeleted(id: UUID) {
        primary?.studyPlanDeleted(id: id)
        auxiliaries.forEach { $0.studyPlanDeleted(id: id) }
    }
    func studyPlanItemCreated(_ item: StudyPlanItem) {
        primary?.studyPlanItemCreated(item)
        auxiliaries.forEach { $0.studyPlanItemCreated(item) }
    }
    func studyPlanItemUpdated(_ item: StudyPlanItem) {
        primary?.studyPlanItemUpdated(item)
        auxiliaries.forEach { $0.studyPlanItemUpdated(item) }
    }
    func studyPlanItemDeleted(id: UUID) {
        primary?.studyPlanItemDeleted(id: id)
        auxiliaries.forEach { $0.studyPlanItemDeleted(id: id) }
    }
    func studyActivityCreated(_ activity: StudyActivity) {
        primary?.studyActivityCreated(activity)
        auxiliaries.forEach { $0.studyActivityCreated(activity) }
    }
    func studyActivityUpdated(_ activity: StudyActivity) {
        primary?.studyActivityUpdated(activity)
        auxiliaries.forEach { $0.studyActivityUpdated(activity) }
    }
    func studyActivityDeleted(id: UUID) {
        primary?.studyActivityDeleted(id: id)
        auxiliaries.forEach { $0.studyActivityDeleted(id: id) }
    }
    func interpreterConversationSaved(_ conversation: InterpreterConversation) {
        primary?.interpreterConversationSaved(conversation)
        auxiliaries.forEach { $0.interpreterConversationSaved(conversation) }
    }
    func interpreterConversationUpdated(_ conversation: InterpreterConversation) {
        primary?.interpreterConversationUpdated(conversation)
        auxiliaries.forEach { $0.interpreterConversationUpdated(conversation) }
    }
    func interpreterConversationDeleted(id: UUID) {
        primary?.interpreterConversationDeleted(id: id)
        auxiliaries.forEach { $0.interpreterConversationDeleted(id: id) }
    }
    func interpreterTurnCreated(_ turn: InterpreterTurn) {
        primary?.interpreterTurnCreated(turn)
        auxiliaries.forEach { $0.interpreterTurnCreated(turn) }
    }
    func interpreterTurnUpdated(_ turn: InterpreterTurn) {
        primary?.interpreterTurnUpdated(turn)
        auxiliaries.forEach { $0.interpreterTurnUpdated(turn) }
    }
    func interpreterTurnDeleted(id: UUID) {
        primary?.interpreterTurnDeleted(id: id)
        auxiliaries.forEach { $0.interpreterTurnDeleted(id: id) }
    }
    func errandCaseSaved(_ errandCase: ErrandCase) {
        primary?.errandCaseSaved(errandCase)
        auxiliaries.forEach { $0.errandCaseSaved(errandCase) }
    }
    func errandCaseUpdated(_ errandCase: ErrandCase) {
        primary?.errandCaseUpdated(errandCase)
        auxiliaries.forEach { $0.errandCaseUpdated(errandCase) }
    }
    func errandCaseDeleted(id: UUID) {
        primary?.errandCaseDeleted(id: id)
        auxiliaries.forEach { $0.errandCaseDeleted(id: id) }
    }
    func errandCaseItemCreated(_ item: ErrandCaseItem) {
        primary?.errandCaseItemCreated(item)
        auxiliaries.forEach { $0.errandCaseItemCreated(item) }
    }
    func errandCaseItemUpdated(_ item: ErrandCaseItem) {
        primary?.errandCaseItemUpdated(item)
        auxiliaries.forEach { $0.errandCaseItemUpdated(item) }
    }
    func errandCaseItemDeleted(id: UUID) {
        primary?.errandCaseItemDeleted(id: id)
        auxiliaries.forEach { $0.errandCaseItemDeleted(id: id) }
    }
}

// MARK: - System-surface bridge

/// Auxiliary repository observer: keeps the Spotlight index in step with
/// real mutations (local edits, cloud-sync applies, inbox imports — the
/// repository is the single choke point) and nudges the widget snapshot
/// refresh. Indexing failures are logged and swallowed (they must never
/// block a repository save).
@MainActor
final class SystemMutationBridge: TranscriptMutationObserving {
    private weak var coordinator: SystemIntegrationCoordinator?
    /// Errand system surfaces (reminders + calendar mirrors + Spotlight)
    /// — weak: the environment owns them; the bridge must never keep a
    /// dead profile alive.
    private weak var errandReminders: ErrandReminderScheduler?
    private weak var errandCalendar: ErrandCalendarMirror?
    /// sessionUpdated fires on EVERY transcript entry (the session's
    /// entryCount moves) — re-indexing per line would be absurd. At most
    /// one session re-index per minute; creates and deletes are always
    /// immediate.
    private var lastSessionReindex = Date.distantPast

    init(
        coordinator: SystemIntegrationCoordinator,
        errandReminders: ErrandReminderScheduler? = nil,
        errandCalendar: ErrandCalendarMirror? = nil
    ) {
        self.coordinator = coordinator
        self.errandReminders = errandReminders
        self.errandCalendar = errandCalendar
    }

    // Spotlight-backed entities (index on create/update, delete on
    // delete). Entry/note/correction/OCR mutations are deliberately NOT
    // indexed (transcripts and notes never reach Spotlight).

    func sessionCreated(_ session: ClassroomSession) {
        coordinator?.indexEntity(session.id, kind: .session)
    }
    func sessionUpdated(_ session: ClassroomSession) {
        // Throttled (see lastSessionReindex): the description's entry
        // count / duration catch up on the next mutation or foreground.
        guard Date().timeIntervalSince(lastSessionReindex) > 60 else { return }
        lastSessionReindex = Date()
        coordinator?.indexEntity(session.id, kind: .session)
    }
    func sessionDeleted(id: UUID) {
        coordinator?.removeEntity(id: id, kind: .session)
        coordinator?.refreshSnapshotAndWidgets()
    }
    func courseCreated(_ course: Course) {
        coordinator?.indexEntity(course.id, kind: .course)
        coordinator?.refreshSnapshotAndWidgets()
    }
    func courseUpdated(_ course: Course) {
        coordinator?.indexEntity(course.id, kind: .course)
        coordinator?.refreshSnapshotAndWidgets()
    }
    func courseDeleted(id: UUID) {
        coordinator?.removeEntity(id: id, kind: .course)
        coordinator?.refreshSnapshotAndWidgets()
    }
    func materialCreated(_ material: CourseMaterial) {
        coordinator?.indexEntity(material.id, kind: .material)
        coordinator?.refreshSnapshotAndWidgets()
    }
    func materialUpdated(_ material: CourseMaterial) {
        coordinator?.indexEntity(material.id, kind: .material)
    }
    func materialDeleted(id: UUID) {
        coordinator?.removeEntity(id: id, kind: .material)
        coordinator?.refreshSnapshotAndWidgets()
    }
    func examCreated(_ exam: Exam) {
        coordinator?.indexEntity(exam.id, kind: .exam)
        coordinator?.refreshSnapshotAndWidgets()
    }
    func examUpdated(_ exam: Exam) {
        coordinator?.indexEntity(exam.id, kind: .exam)
        coordinator?.refreshSnapshotAndWidgets()
    }
    func examDeleted(id: UUID) {
        coordinator?.removeEntity(id: id, kind: .exam)
        coordinator?.refreshSnapshotAndWidgets()
    }
    func taskCreated(_ task: StudyTask) {
        // Only confirmed tasks are indexable (pendingConfirm AI
        // candidates never reach Spotlight).
        if task.status != .pendingConfirm {
            coordinator?.indexEntity(task.id, kind: .task)
        }
        coordinator?.refreshSnapshotAndWidgets()
    }
    func taskUpdated(_ task: StudyTask) {
        if task.status != .pendingConfirm {
            coordinator?.indexEntity(task.id, kind: .task)
        }
        coordinator?.refreshSnapshotAndWidgets()
    }
    func taskDeleted(id: UUID) {
        coordinator?.removeEntity(id: id, kind: .task)
        coordinator?.refreshSnapshotAndWidgets()
    }

    // Errand cases (办事事项): formal cases are Spotlight-indexable
    // (drafts and unconfirmed candidates never reach Spotlight — the
    // StudyTask pendingConfirm convention); deletes cancel the case's
    // reminders. All under the system-surface privacy policy
    // (hideSensitiveContent keeps Spotlight off entirely).

    func errandCaseSaved(_ errandCase: ErrandCase) {
        indexErrandCase(errandCase)
        coordinator?.refreshSnapshotAndWidgets()
    }
    func errandCaseUpdated(_ errandCase: ErrandCase) {
        indexErrandCase(errandCase)
    }
    func errandCaseDeleted(id: UUID) {
        coordinator?.removeEntity(id: id, kind: .errandCase)
        errandReminders?.cancelCase(caseID: id)
        coordinator?.refreshSnapshotAndWidgets()
    }
    func errandCaseItemCreated(_ item: ErrandCaseItem) {
        // Items are not individually indexed (the case is the unit); a
        // dated item may matter to the today aggregate → refresh.
        coordinator?.refreshSnapshotAndWidgets()
    }
    func errandCaseItemUpdated(_ item: ErrandCaseItem) {
        coordinator?.refreshSnapshotAndWidgets()
    }
    func errandCaseItemDeleted(id: UUID) {
        errandReminders?.disable(itemID: id)
        errandCalendar?.removeMirroredAppointment(itemID: id)
    }

    private func indexErrandCase(_ errandCase: ErrandCase) {
        guard errandCase.status.isFormal else { return }
        coordinator?.indexEntity(errandCase.id, kind: .errandCase)
    }

    // Snapshot-relevant mutations without Spotlight indexing.

    func scheduleCreated(_ schedule: CourseSchedule) { refresh() }
    func scheduleUpdated(_ schedule: CourseSchedule) { refresh() }
    func scheduleDeleted(id: UUID) { refresh() }
    func exceptionCreated(_ exception: ScheduleException) { refresh() }
    func exceptionUpdated(_ exception: ScheduleException) { refresh() }
    func exceptionDeleted(id: UUID) { refresh() }
    func studyPlanItemCreated(_ item: StudyPlanItem) { refresh() }
    func studyPlanItemUpdated(_ item: StudyPlanItem) { refresh() }
    func studyPlanItemDeleted(id: UUID) { refresh() }
    func studyPlanCreated(_ plan: StudyPlan) { refresh() }
    func studyPlanUpdated(_ plan: StudyPlan) { refresh() }
    func studyPlanDeleted(id: UUID) { refresh() }

    private func refresh() {
        coordinator?.refreshSnapshotAndWidgets()
    }
}

// MARK: - Optional-method defaults

/// Default (no-op) implementations so auxiliary observers implement only
/// what they need. The sync service implements everything explicitly —
/// these defaults never apply to it.
extension TranscriptMutationObserving {
    func sessionCreated(_ session: ClassroomSession) {}
    func sessionUpdated(_ session: ClassroomSession) {}
    func sessionDeleted(id: UUID) {}
    func entryCreated(_ entry: TranscriptEntry) {}
    func entryUpdated(_ entry: TranscriptEntry) {}
    func courseCreated(_ course: Course) {}
    func courseUpdated(_ course: Course) {}
    func courseDeleted(id: UUID) {}
    func noteCreated(_ note: SessionNote) {}
    func noteUpdated(_ note: SessionNote) {}
    func noteDeleted(id: UUID) {}
    func studyReviewUpdated(_ review: StudyReview) {}
    func studyReviewDeleted(id: UUID) {}
    func attachmentCreated(_ attachment: SessionAttachment) {}
    func attachmentUpdated(_ attachment: SessionAttachment) {}
    func attachmentDeleted(id: UUID) {}
    func termCreated(_ term: GlossaryTerm) {}
    func termUpdated(_ term: GlossaryTerm) {}
    func termDeleted(id: UUID) {}
    func cardCreated(_ card: StudyCard) {}
    func cardUpdated(_ card: StudyCard) {}
    func cardDeleted(id: UUID) {}
    func taskCreated(_ task: StudyTask) {}
    func taskUpdated(_ task: StudyTask) {}
    func taskDeleted(id: UUID) {}
    func correctionUpserted(_ correction: TranscriptCorrection) {}
    func correctionDeleted(id: UUID) {}
    func scheduleCreated(_ schedule: CourseSchedule) {}
    func scheduleUpdated(_ schedule: CourseSchedule) {}
    func scheduleDeleted(id: UUID) {}
    func exceptionCreated(_ exception: ScheduleException) {}
    func exceptionUpdated(_ exception: ScheduleException) {}
    func exceptionDeleted(id: UUID) {}
    func materialCreated(_ material: CourseMaterial) {}
    func materialUpdated(_ material: CourseMaterial) {}
    func materialDeleted(id: UUID) {}
    func materialPageUpserted(_ page: MaterialPage) {}
    func materialAnnotationCreated(_ annotation: MaterialAnnotation) {}
    func materialAnnotationUpdated(_ annotation: MaterialAnnotation) {}
    func materialAnnotationDeleted(id: UUID) {}
    func assistantThreadCreated(_ thread: CourseAssistantThread) {}
    func assistantThreadUpdated(_ thread: CourseAssistantThread) {}
    func assistantThreadDeleted(id: UUID) {}
    func assistantMessageCreated(_ message: CourseAssistantMessage) {}
    func examCreated(_ exam: Exam) {}
    func examUpdated(_ exam: Exam) {}
    func examDeleted(id: UUID) {}
    func examTopicCreated(_ topic: ExamTopic) {}
    func examTopicUpdated(_ topic: ExamTopic) {}
    func examTopicDeleted(id: UUID) {}
    func studyPlanCreated(_ plan: StudyPlan) {}
    func studyPlanUpdated(_ plan: StudyPlan) {}
    func studyPlanDeleted(id: UUID) {}
    func studyPlanItemCreated(_ item: StudyPlanItem) {}
    func studyPlanItemUpdated(_ item: StudyPlanItem) {}
    func studyPlanItemDeleted(id: UUID) {}
    func studyActivityCreated(_ activity: StudyActivity) {}
    func studyActivityUpdated(_ activity: StudyActivity) {}
    func studyActivityDeleted(id: UUID) {}
    func interpreterConversationSaved(_ conversation: InterpreterConversation) {}
    func interpreterConversationUpdated(_ conversation: InterpreterConversation) {}
    func interpreterConversationDeleted(id: UUID) {}
    func interpreterTurnCreated(_ turn: InterpreterTurn) {}
    func interpreterTurnUpdated(_ turn: InterpreterTurn) {}
    func interpreterTurnDeleted(id: UUID) {}
    func errandCaseSaved(_ errandCase: ErrandCase) {}
    func errandCaseUpdated(_ errandCase: ErrandCase) {}
    func errandCaseDeleted(id: UUID) {}
    func errandCaseItemCreated(_ item: ErrandCaseItem) {}
    func errandCaseItemUpdated(_ item: ErrandCaseItem) {}
    func errandCaseItemDeleted(id: UUID) {}
}
