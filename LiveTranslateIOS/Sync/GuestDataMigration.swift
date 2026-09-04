import Foundation
import OSLog
import SwiftData

/// Resumable migration of GUEST (local-only) classroom data into a signed-in
/// account's store. Runs after the first sign-in, on explicit user consent —
/// history is NEVER auto-uploaded.
///
/// Concurrency & memory contract:
///   - everything runs on the main actor (SwiftData is main-actor here);
///   - the guest store is read ONLY through `GuestLibraryReader` — a type
///     whose entire API surface is fetch/count (no insert, no delete, no
///     save: writes are structurally impossible through it). The reader
///     additionally opens the store with allowsSave=false; the API boundary
///     is the primary guard, the flag the second;
///   - models never cross contexts or actors: each batch of sessions (plus
///     its entries) is converted to a Sendable value snapshot on the main
///     actor and ONLY the values move on. Batches are bounded
///     (`sessionBatchSize`), so the snapshot working set is bounded.
///
/// State machine (persisted in the ACCOUNT's defaults suite so it survives
/// restarts and stays per-account):
///
///     waiting → preparing → moving → queuedForUpload → completed
///                                     ↘ partiallyFailed
///
///   - `moving` records `copiedSessionIDs` after every confirmed batch, so
///     an interrupted run RESUMES from the last confirmed batch (skipping
///     those sessions) instead of restarting or double-copying;
///   - `partiallyFailed` records `failedSessionIDs` (the retryable scope);
///     a retry re-copies exactly those;
///   - UUID conflicts are COMPARED, never silently skipped or overwritten:
///     an existing account row with the same id must match in ownership
///     (session's own entries) and content, else it is recorded as a
///     conflict in `conflictedSessionIDs` and surfaced.
///
/// The guest store is only ever READ here; deleting the guest copy is a
/// separate, explicitly confirmed action and is only offered after the
/// copy AND the upload hand-off completed.
@MainActor
@Observable
final class GuestDataMigration {
    private static let logger = Logger(
        subsystem: "com.livetranslate.ios", category: "guest-migration"
    )

    enum Phase: String, Codable {
        case waiting
        case preparing
        case moving
        case queuedForUpload
        case completed
        case partiallyFailed
        /// The user chose to keep the data local-only; nothing was copied.
        case declined
    }

    /// Persisted record (per account). `copiedSessionIDs`/`failedSessionIDs`
    /// are the resume/conflict bookkeeping; they are cleared on completion.
    struct Record: Codable {
        var phase: Phase = .waiting
        var totalSessions: Int = 0
        var copiedSessionIDs: [UUID] = []
        var failedSessionIDs: [UUID] = []
        var conflictedSessionIDs: [UUID] = []
        var movedEntries: Int = 0
        var startedAt: Date?
        var finishedAt: Date?

        var copiedCount: Int { copiedSessionIDs.count }
    }

    private(set) var record: Record {
        didSet { persist() }
    }

    /// True while a migration pass is executing (blocks profile switches).
    var isRunning: Bool {
        record.phase == .preparing || record.phase == .moving
    }

    /// Sessions copied per batch (bounded working set: a session snapshot
    /// plus its entries is a few KB; the batch cap keeps the main-thread
    /// snapshot work short between persists).
    private let sessionBatchSize = 10

    private let accountID: UUID
    private let defaults: UserDefaults
    private let repository: any ClassroomRepositoryProtocol
    private let bookmarks: BookmarkStore
    private let sync: CloudSyncService?
    private let reader = GuestLibraryReader()

    private static let recordKey = "guestMigration.record"

    init(
        accountID: UUID,
        repository: any ClassroomRepositoryProtocol,
        bookmarks: BookmarkStore,
        sync: CloudSyncService?
    ) {
        self.accountID = accountID
        self.defaults = AccountStore.defaultsSuite(accountID: accountID)
        self.repository = repository
        self.bookmarks = bookmarks
        self.sync = sync
        if let data = defaults.data(forKey: Self.recordKey),
           let decoded = try? JSONDecoder().decode(Record.self, from: data) {
            self.record = decoded
        } else {
            self.record = Record()
        }
        // A crash mid-move resumes from the last confirmed batch on the
        // next construction (copiedSessionIDs carries the boundary).
        if record.phase == .preparing || record.phase == .moving {
            record.phase = .moving
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(record) {
            defaults.set(data, forKey: Self.recordKey)
        }
    }

    /// Whether the "本机记录待归属" prompt should be shown for this account:
    /// a not-yet-decided migration AND guest data exists.
    var needsPrompt: Bool {
        record.phase == .waiting && reader.sessionCount() > 0
    }

    /// True when some guest data is still un-migrated (banner in settings).
    var hasUnclaimedData: Bool {
        (record.phase == .waiting || record.phase == .partiallyFailed)
            && reader.sessionCount() > 0
    }

    /// Session count in the guest store (for the settings banner).
    func guestSessionCount() -> Int {
        reader.sessionCount()
    }

    // MARK: - Actions

    /// User chose 继续仅保存在本机 — nothing is copied, ever (unless they
    /// reopen the flow from the settings banner).
    func decline() {
        record.phase = .declined
        record.finishedAt = .now
    }

    /// User chose 上传并加入当前账号 (or retried a partially-failed run).
    /// Copies guest rows into the ACCOUNT store under their original UUIDs
    /// in bounded batches, then hands off to the normal initial-upload
    /// pipeline. The guest store is untouched.
    func beginMigration() {
        guard !isRunning else { return }
        record.phase = .preparing
        record.startedAt = .now
        record.failedSessionIDs = []
        record.conflictedSessionIDs = []
        Task { await run() }
    }

    /// Re-open a declined/partially-failed migration.
    func reopen() {
        record.phase = .waiting
    }

    private func run() async {
        // Bounded batch loop: read one batch of session snapshots from the
        // guest store (Sendable values only), copy it, persist the batch
        // boundary, then continue. Nothing loads the whole library.
        do {
            // Courses first (add-only union, like bookmarks: an account row
            // with the same id always wins) so session course references
            // resolve during the copy.
            mergeGuestCourses()
            // Notes and reviews are session-scoped; collect them for the
            // copy after the sessions exist.
            let guestNotes = reader.noteSnapshots()
            let guestReviews = reader.reviewSnapshots()
            let sessionIDs = try reader.sessionIDs(excluding: Set(record.copiedSessionIDs))
            record.totalSessions = record.copiedCount + sessionIDs.count
            record.phase = .moving

            var index = 0
            while index < sessionIDs.count {
                let batchIDs = Array(sessionIDs[index..<min(index + sessionBatchSize, sessionIDs.count)])
                let snapshots = try reader.snapshots(forIDs: batchIDs)
                for snapshot in snapshots {
                    do {
                        switch try copySessionCheckingConflicts(snapshot) {
                        case .copied:
                            record.copiedSessionIDs.append(snapshot.id)
                            record.movedEntries += snapshot.entries.count
                        case .alreadyPresentIdentical:
                            // Our own previous copy (or a re-run): counted,
                            // never duplicated.
                            record.copiedSessionIDs.append(snapshot.id)
                        case .conflict:
                            record.conflictedSessionIDs.append(snapshot.id)
                        }
                    } catch {
                        record.failedSessionIDs.append(snapshot.id)
                        Self.logger.error(
                            "guest session copy failed: \(String(describing: error), privacy: .public)"
                        )
                    }
                }
                // Batch boundary persisted: an interruption resumes here.
                persist()
                index += batchIDs.count
            }
            copyGuestNotes(guestNotes)
            copyGuestReviews(guestReviews)
            copyGuestAttachments()
            copyGuestLearningData()
            copyGuestSchedules()
            copyGuestMaterials()
            copyGuestExams()
            mergeGuestBookmarks()

            if record.copiedCount == 0 && (!record.failedSessionIDs.isEmpty || !record.conflictedSessionIDs.isEmpty) {
                // Nothing moved — either failures or conflicts consumed the
                // whole run; the retry scope is explicit either way.
                record.phase = .partiallyFailed
                record.finishedAt = .now
                return
            }
            // Hand the copied rows to the sync pipeline: reset the
            // account's first-upload flag so the initial upload snapshots
            // them (server-side idempotency + outbox per-entity merge make
            // the re-run of this trigger non-duplicating).
            record.phase = .queuedForUpload
            sync?.prepareForGuestMigrationUpload()
            if !record.failedSessionIDs.isEmpty || !record.conflictedSessionIDs.isEmpty {
                record.phase = .partiallyFailed
            } else {
                record.phase = .completed
                // Bookkeeping has served its purpose; drop the id lists.
                record.copiedSessionIDs = []
                record.failedSessionIDs = []
                record.conflictedSessionIDs = []
            }
            record.finishedAt = .now
        } catch {
            Self.logger.error(
                "guest migration failed: \(String(describing: error), privacy: .public)"
            )
            record.phase = .partiallyFailed
            record.finishedAt = .now
        }
    }

    enum CopyOutcome {
        case copied
        case alreadyPresentIdentical
        case conflict
    }

    /// Copies one session (+entries) into the account store under its
    /// ORIGINAL id, comparing any pre-existing row instead of skipping it
    /// silently: identical content (a previous copy of this very session)
    /// is treated as done; different content is a conflict, recorded and
    /// never overwritten.
    private func copySessionCheckingConflicts(_ session: GuestLibraryReader.SessionSnapshot) throws -> CopyOutcome {
        if let existing = repository.sessionSummary(id: session.id) {
            // Ownership + content comparison: same title, start time and
            // entry count ⇒ treat as our own prior copy.
            if existing.title == session.title,
               existing.startTime == session.startTime,
               existing.entryCount == session.entries.count {
                return .alreadyPresentIdentical
            }
            return .conflict
        }
        try copySession(session)
        return .copied
    }

    /// Copies the session and its entries through the repository's
    /// remote-apply path (it preserves ids) with serverVersion 0, so the
    /// sync layer treats them as fresh local data. The course reference is
    /// carried verbatim.
    private func copySession(_ session: GuestLibraryReader.SessionSnapshot) throws {
        let sessionRecord = SyncServerRecordDTO(
            id: session.id,
            title: session.title,
            startedAt: session.startTime,
            endedAt: session.endTime,
            duration: session.duration,
            sessionStatus: session.endTime == nil ? "active" : "finished",
            abnormalTermination: session.abnormalTermination,
            courseId: session.courseID,
            serverVersion: 0
        )
        try repository.applyRemoteSession(record: sessionRecord, serverVersion: 0)

        for entry in session.entries {
            if repository.entryExists(id: entry.id) { continue }
            let entryRecord = SyncServerRecordDTO(
                id: entry.id,
                sessionId: session.id,
                sequenceId: entry.sequenceID,
                startOffset: entry.startOffset,
                endOffset: entry.endOffset,
                russianText: entry.originalText,
                chineseText: entry.translatedText,
                translationStatus: entry.translationStatus,
                serverVersion: 0
            )
            try repository.applyRemoteEntry(record: entryRecord, serverVersion: 0)
        }
    }

    /// Copies guest courses into the account store (add-only union — an
    /// existing account row with the same id always wins, mirroring the
    /// bookmark merge; locally generated UUIDs make a real collision
    /// practically impossible).
    private func mergeGuestCourses() {
        for course in reader.courseSnapshots() {
            guard (try? repository.course(id: course.id)) ?? nil == nil else { continue }
            let record = SyncServerRecordDTO(
                id: course.id,
                title: course.name,
                teacher: course.teacherName,
                location: course.location,
                colorIndex: course.colorIndex,
                isArchived: course.isArchived,
                serverVersion: 0
            )
            try? repository.applyRemoteCourse(record: record, serverVersion: 0)
        }
    }

    /// Copies the guest pre-class layer (schedules + exceptions) into the
    /// account store, add-only union: an account row with the same id
    /// always wins, so a re-run never duplicates. Rows keep their guest
    /// UUIDs and arrive with serverVersion 0 — the initial upload picks
    /// them up like every other copied row. Schedules are course-scoped
    /// (mergeGuestCourses ran first) and exceptions follow their schedules.
    private func copyGuestSchedules() {
        for schedule in reader.scheduleSnapshots() {
            guard (try? repository.schedules(courseID: nil))?.contains { $0.id == schedule.id } != true else {
                continue
            }
            let record = SyncServerRecordDTO(
                id: schedule.id,
                courseId: schedule.courseID,
                scheduleWeekday: schedule.weekday,
                scheduleStartSecs: schedule.startSecs,
                scheduleEndSecs: schedule.endSecs,
                scheduleRecurrence: schedule.recurrenceRaw,
                scheduleParityAnchor: schedule.weekParityAnchor.map {
                    ScheduleCalculator.formatDay($0)
                },
                scheduleFirstWeekIsOdd: schedule.firstWeekIsOdd,
                scheduleSemesterStart: ScheduleCalculator.formatDay(schedule.semesterStart),
                scheduleSemesterEnd: ScheduleCalculator.formatDay(schedule.semesterEnd),
                scheduleTimezone: schedule.timezoneID,
                scheduleTeacher: schedule.teacherOverride.isEmpty ? nil : schedule.teacherOverride,
                scheduleLocation: schedule.locationOverride.isEmpty ? nil : schedule.locationOverride,
                scheduleNote: schedule.note.isEmpty ? nil : schedule.note,
                scheduleReminderMins: schedule.reminderLeadMins,
                scheduleEnabled: schedule.isEnabled,
                scheduleOnceDate: schedule.onceDate.map { ScheduleCalculator.formatDay($0) },
                serverVersion: 0
            )
            try? repository.applyRemoteSchedule(record: record, serverVersion: 0)
        }
        for exception in reader.exceptionSnapshots() {
            guard let scheduleID = exception.scheduleID else { continue }
            let record = SyncServerRecordDTO(
                id: exception.id,
                scheduleId: scheduleID,
                courseId: exception.courseID,
                scheduleOriginalDate: exception.originalDate.map {
                    ScheduleCalculator.formatDay($0)
                },
                scheduleExceptionKind: exception.kindRaw,
                scheduleChangedStart: exception.changedStart,
                scheduleChangedEnd: exception.changedEnd,
                scheduleMovedToDate: exception.movedToDate.map {
                    ScheduleCalculator.formatDay($0)
                },
                scheduleTeacher: exception.teacherOverride.isEmpty ? nil : exception.teacherOverride,
                scheduleLocation: exception.locationOverride.isEmpty ? nil : exception.locationOverride,
                scheduleNote: exception.note.isEmpty ? nil : exception.note,
                serverVersion: 0
            )
            try? repository.applyRemoteException(record: record, serverVersion: 0)
        }
    }

    /// Copies the guest course-material library (materials, pages,
    /// annotations, assistant threads/messages) into the account store,
    /// add-only union like every other course-scoped family, AND copies
    /// each material's ORIGINAL FILE from the guest material store into
    /// the account's (page thumbnails are regenerable caches and stay
    /// behind). Materials borrowing a classroom attachment's files are
    /// copied after copyGuestAttachments has run — they carry no file of
    /// their own.
    private func copyGuestMaterials() {
        let guestFileStore = MaterialFileStore(accountID: nil)
        let accountFileStore = MaterialFileStoreShared.store
        for material in reader.materialSnapshots() {
            guard (try? repository.material(id: material.id)) ?? nil == nil else { continue }
            let record = SyncServerRecordDTO(
                id: material.id,
                title: material.title,
                courseId: material.courseID,
                sessionId: material.sessionID,
                scheduleOccurrenceKey: material.occurrenceKey ?? "",
                sourceAttachmentId: material.sourceAttachmentID,
                materialKind: material.kindRaw,
                materialMime: material.mimeType.isEmpty ? nil : material.mimeType,
                materialFileName: material.originalFileName.isEmpty ? nil : material.originalFileName,
                materialFormat: material.formatRaw,
                materialFileSize: material.fileSize,
                materialHash: material.contentHash.isEmpty ? nil : material.contentHash,
                materialPageCount: material.pageCount,
                materialExtraction: material.extractionStatusRaw,
                materialDigestStatus: material.digestStatusRaw,
                materialDigest: material.digestJSON.isEmpty ? nil : material.digestJSON,
                materialDigestModel: material.digestModel.isEmpty ? nil : material.digestModel,
                materialDigestAt: material.digestGeneratedAt,
                materialDigestSourceHash: material.digestSourceHash.isEmpty ? nil : material.digestSourceHash,
                materialLastReadPage: material.lastReadPage,
                materialLastOpenedAt: material.lastOpenedAt,
                serverVersion: 0
            )
            try? repository.applyRemoteMaterial(record: record, serverVersion: 0)
            // The original file follows its metadata (thumbnails are
            // regenerable — they stay guest-local and die with the copy).
            if material.ownsFile, let accountFileStore {
                let ext = MaterialFileStore.fileExtension(
                    fileName: material.originalFileName, mime: material.mimeType
                )
                if let original = guestFileStore.originalData(
                    materialID: material.id, fileExtension: ext
                ) {
                    try? accountFileStore.writeSyncedOriginal(
                        original, materialID: material.id, fileExtension: ext
                    )
                }
            }
        }
        for page in reader.materialPageSnapshots() {
            let record = SyncServerRecordDTO(
                id: page.id,
                materialId: page.materialID,
                materialPageNumber: page.pageNumber,
                materialPageText: page.extractedText.isEmpty ? nil : page.extractedText,
                materialPageOCR: page.ocrText.isEmpty ? nil : page.ocrText,
                materialPageOCRStatus: page.ocrStatusRaw,
                serverVersion: 0
            )
            try? repository.applyRemoteMaterialPage(record: record, serverVersion: 0)
        }
        for annotation in reader.materialAnnotationSnapshots() {
            let record = SyncServerRecordDTO(
                id: annotation.id,
                materialId: annotation.materialID,
                materialPageNumber: annotation.pageNumber,
                materialAnnotationKind: annotation.kindRaw,
                noteText: annotation.text.isEmpty ? nil : annotation.text,
                serverVersion: 0
            )
            try? repository.applyRemoteMaterialAnnotation(record: record, serverVersion: 0)
        }
        for thread in reader.assistantThreadSnapshots() {
            guard (try? repository.assistantThreads(courseID: nil))?.contains {
                $0.id == thread.id
            } != true else { continue }
            let record = SyncServerRecordDTO(
                id: thread.id,
                title: thread.title,
                courseId: thread.courseID,
                serverVersion: 0
            )
            try? repository.applyRemoteAssistantThread(record: record, serverVersion: 0)
        }
        for message in reader.assistantMessageSnapshots() {
            let record = SyncServerRecordDTO(
                id: message.id,
                threadId: message.threadID,
                assistantRole: message.roleRaw,
                assistantText: message.text.isEmpty ? nil : message.text,
                assistantCitations: message.citationsJSON.isEmpty ? nil : message.citationsJSON,
                assistantMode: message.modeRaw.isEmpty ? nil : message.modeRaw,
                assistantEvidence: message.visualEvidenceJSON.isEmpty ? nil : message.visualEvidenceJSON,
                assistantAnswer: message.answerJSON.isEmpty ? nil : message.answerJSON,
                assistantModel: message.answerModel.isEmpty ? nil : message.answerModel,
                materialId: message.scopeMaterialID,
                sessionId: message.scopeSessionID,
                serverVersion: 0
            )
            try? repository.applyRemoteAssistantMessage(record: record, serverVersion: 0)
        }
    }

    /// Copies the guest exam center (exams, topics, plans, items,
    /// activities) into the account store, add-only union like every
    /// other family. Device-local AI candidates transfer as candidates
    /// (status pending rows stay local until confirmed on the account).
    private func copyGuestExams() {
        for exam in reader.examSnapshots() {
            guard (try? repository.exam(id: exam.id)) ?? nil == nil else { continue }
            let record = SyncServerRecordDTO(
                id: exam.id,
                title: exam.title,
                courseId: exam.courseID,
                examKind: exam.kindRaw,
                examDate: exam.examDateKey,
                examStartSecs: exam.startSecs,
                examEndSecs: exam.endSecs,
                examLocation: exam.location,
                examScope: exam.scopeText.isEmpty ? nil : exam.scopeText,
                examNote: exam.note.isEmpty ? nil : exam.note,
                examTargetScore: exam.targetScore.isEmpty ? nil : exam.targetScore,
                examStatus: exam.statusRaw,
                examOrigin: exam.originRaw,
                examSource: exam.sourceJSON.isEmpty ? nil : exam.sourceJSON,
                serverVersion: 0
            )
            try? repository.applyRemoteExam(record: record, serverVersion: 0)
        }
        for topic in reader.examTopicSnapshots() {
            let record = SyncServerRecordDTO(
                id: topic.id,
                examId: topic.examID,
                title: topic.title,
                topicDetail: topic.detail.isEmpty ? nil : topic.detail,
                topicImportance: topic.importanceRaw,
                topicSelfRating: topic.selfRatingRaw,
                topicStatus: topic.statusRaw,
                topicSource: topic.sourceJSON.isEmpty ? nil : topic.sourceJSON,
                topicUserEdited: topic.userEdited,
                serverVersion: 0
            )
            try? repository.applyRemoteExamTopic(record: record, serverVersion: 0)
        }
        for plan in reader.studyPlanSnapshots() {
            let record = SyncServerRecordDTO(
                id: plan.id,
                examId: plan.examID,
                title: plan.title,
                planStartDate: plan.startDateKey,
                planEndDate: plan.endDateKey,
                planWeekdayMinutes: plan.weekdayMinutes,
                planWeekendMinutes: plan.weekendMinutes,
                planRestDays: plan.restDaysJSON.isEmpty ? nil : plan.restDaysJSON,
                planFinishEarlyDays: plan.finishEarlyDays,
                planIncludeCards: plan.includeCards,
                planIncludeTasks: plan.includeTasks,
                planIncludeMaterials: plan.includeMaterials,
                planIncludeSessions: plan.includeSessions,
                planFocusTopics: plan.focusTopicsJSON.isEmpty ? nil : plan.focusTopicsJSON,
                planBlockedTimes: plan.blockedTimesJSON.isEmpty ? nil : plan.blockedTimesJSON,
                planStatus: plan.statusRaw,
                serverVersion: 0
            )
            try? repository.applyRemoteStudyPlan(record: record, serverVersion: 0)
        }
        for item in reader.studyPlanItemSnapshots() {
            let record = SyncServerRecordDTO(
                id: item.id,
                planId: item.planID,
                examId: item.examID,
                title: item.title,
                planItemDate: item.itemDateKey,
                planItemKind: item.kindRaw,
                planItemEstimatedMinutes: item.estimatedMinutes,
                planItemActualMinutes: item.actualMinutes,
                planItemStatus: item.statusRaw,
                planItemStatusChangedAt: item.statusChangedAt,
                planItemOrder: item.itemOrder,
                planItemSource: item.sourceJSON.isEmpty ? nil : item.sourceJSON,
                planItemUserNote: item.userNote.isEmpty ? nil : item.userNote,
                planItemUserEdited: item.userEdited,
                serverVersion: 0
            )
            try? repository.applyRemoteStudyPlanItem(record: record, serverVersion: 0)
        }
        for activity in reader.studyActivitySnapshots() {
            let record = SyncServerRecordDTO(
                id: activity.id,
                planItemId: activity.planItemID,
                examId: activity.examID,
                courseId: activity.courseID,
                topicId: activity.topicID,
                activityStartedAt: activity.startedAt,
                activityEndedAt: activity.endedAt,
                activityDurationSeconds: activity.durationSeconds,
                activityStatus: activity.statusRaw,
                activityNote: activity.note.isEmpty ? nil : activity.note,
                serverVersion: 0
            )
            try? repository.applyRemoteStudyActivity(record: record, serverVersion: 0)
        }
    }

    /// Copies guest notes whose session now exists in the account store.
    /// The remote-apply path preserves ids and serverVersion 0.
    private func copyGuestNotes(_ notes: [GuestLibraryReader.NoteSnapshot]) {
        for note in notes {
            let noteRecord = SyncServerRecordDTO(
                id: note.id,
                sessionId: note.sessionID,
                noteText: note.text,
                anchorEntryId: note.anchorEntryID,
                serverVersion: 0
            )
            try? repository.applyRemoteNote(record: noteRecord, serverVersion: 0)
        }
    }

    /// Copies guest study reviews whose session now exists in the account
    /// store (add-only union: an account row with the same id always wins).
    private func copyGuestReviews(_ reviews: [GuestLibraryReader.ReviewSnapshot]) {
        for review in reviews {
            guard (try? repository.studyReview(forSessionID: review.id)) ?? nil == nil else {
                continue
            }
            let record = SyncServerRecordDTO(
                id: review.id,
                reviewStatus: review.status,
                reviewContent: review.contentJSON,
                reviewGeneratedContent: review.generatedJSON,
                reviewModel: review.reviewModel,
                reviewGeneratedAt: review.generatedAt,
                reviewSourceUpdatedAt: review.sourceUpdatedAt,
                serverVersion: 0
            )
            try? repository.applyRemoteStudyReview(record: record, serverVersion: 0)
        }
    }

    /// Copies the guest review-center material (terms, cards, tasks) into
    /// the account store, add-only union: an account row with the same id
    /// always wins, so a re-run never duplicates. Rows keep their guest
    /// UUIDs and arrive with serverVersion 0 — the initial upload picks
    /// them up like every other copied row. Review progress rides with
    /// the cards; unconfirmed AI task candidates stay unconfirmed.
    private func copyGuestLearningData() {
        for term in reader.termSnapshots() {
            let record = SyncServerRecordDTO(
                id: term.id,
                termRussian: term.russian,
                termChinese: term.chinese,
                termExplanation: term.explanation.isEmpty ? nil : term.explanation,
                termPartOfSpeech: term.partOfSpeech.isEmpty ? nil : term.partOfSpeech,
                termUserNote: term.userNote.isEmpty ? nil : term.userNote,
                termSourceSessions: term.sourceSessionIDsJSON.isEmpty ? nil : term.sourceSessionIDsJSON,
                termFavorite: term.isFavorite,
                termStatus: term.statusRaw,
                courseId: term.courseID,
                sessionId: term.sessionID,
                entryId: term.sourceEntryID,
                sourceAttachmentId: term.sourceAttachmentID,
                sourceReviewId: term.sourceReviewID,
                materialId: term.sourceMaterialID,
                materialPageNumber: term.sourceMaterialID == nil ? nil : term.sourceMaterialPage,
                serverVersion: 0
            )
            try? repository.applyRemoteTerm(record: record, serverVersion: 0)
        }
        for card in reader.cardSnapshots() {
            let record = SyncServerRecordDTO(
                id: card.id,
                cardFront: card.front,
                cardBack: card.back,
                cardType: card.typeRaw,
                cardUserNote: card.userNote.isEmpty ? nil : card.userNote,
                cardOrigin: card.originRaw,
                cardStage: card.stageRaw,
                cardReviewCount: card.reviewCount,
                cardIntervalHours: card.intervalHours,
                cardDueAt: card.dueAt,
                cardLastReviewedAt: card.lastReviewedAt,
                cardLastGrade: card.lastGradeRaw.isEmpty ? nil : card.lastGradeRaw,
                courseId: card.courseID,
                sessionId: card.sessionID,
                entryId: card.sourceEntryID,
                sourceAttachmentId: card.sourceAttachmentID,
                sourceTermId: card.sourceTermID,
                materialId: card.sourceMaterialID,
                materialPageNumber: card.sourceMaterialID == nil ? nil : card.sourceMaterialPage,
                serverVersion: 0
            )
            try? repository.applyRemoteStudyCard(record: record, serverVersion: 0)
        }
        for task in reader.taskSnapshots() {
            let record = SyncServerRecordDTO(
                id: task.id,
                title: task.title,
                taskDetail: task.detail.isEmpty ? nil : task.detail,
                taskDueAt: task.dueAt,
                taskPriority: task.priorityRaw,
                taskStatus: task.statusRaw,
                taskOrigin: task.originRaw,
                taskUncertainty: task.uncertainty.isEmpty ? nil : task.uncertainty,
                taskUserNote: task.userNote.isEmpty ? nil : task.userNote,
                taskCompletedAt: task.completedAt,
                courseId: task.courseID,
                sessionId: task.sessionID,
                entryId: task.sourceEntryID,
                sourceAttachmentId: task.sourceAttachmentID,
                sourceReviewId: task.sourceReviewID,
                materialId: task.sourceMaterialID,
                materialPageNumber: task.sourceMaterialID == nil ? nil : task.sourceMaterialPage,
                serverVersion: 0
            )
            try? repository.applyRemoteStudyTask(record: record, serverVersion: 0)
        }
    }

    /// Copies guest attachments whose session now exists in the account
    /// store: the metadata row via the remote-apply path AND the image
    /// files from the guest store into the account's file store. A missing
    /// local file (should not happen — the guest store is intact) is
    /// logged and skipped, never fatal.
    private func copyGuestAttachments() {
        let guestFileStore = AttachmentFileStore(accountID: nil)
        let accountFileStore = AttachmentFileStoreShared.store
        for snapshot in reader.attachmentSnapshots() {
            guard (try? repository.attachment(id: snapshot.id)) ?? nil == nil else { continue }
            let record = SyncServerRecordDTO(
                id: snapshot.id,
                title: snapshot.title,
                sessionId: snapshot.sessionID,
                courseId: snapshot.courseID,
                anchorEntryId: snapshot.anchorEntryID,
                attachmentKind: snapshot.kindRaw,
                attachmentMime: snapshot.mimeType,
                attachmentWidth: snapshot.pixelWidth,
                attachmentHeight: snapshot.pixelHeight,
                attachmentFileSize: snapshot.fileSize,
                attachmentHash: snapshot.contentHash,
                attachmentCapturedAt: snapshot.capturedAt,
                attachmentCaption: snapshot.caption,
                attachmentSortIndex: snapshot.sortIndex,
                attachmentTransform: snapshot.transformJSON.isEmpty ? nil : snapshot.transformJSON,
                attachmentAnalysisStatus: snapshot.analysisStatusRaw,
                attachmentAnalysis: snapshot.analysisJSON.isEmpty ? nil : snapshot.analysisJSON,
                attachmentOcrText: snapshot.ocrText.isEmpty ? nil : snapshot.ocrText,
                serverVersion: 0
            )
            try? repository.applyRemoteAttachment(record: record, serverVersion: 0)
            // Files: original (extension from mime) + preview + analysis.
            guard let accountFileStore else { continue }
            let ext = AttachmentFileStore.fileExtension(forMIME: snapshot.mimeType)
            if let original = guestFileStore.originalData(
                for: snapshot.id, sessionID: snapshot.sessionID
            ) {
                try? accountFileStore.writeSynced(
                    original, variant: .original,
                    attachmentID: snapshot.id, sessionID: snapshot.sessionID,
                    fileExtension: ext
                )
            }
            if let preview = guestFileStore.previewOrOriginalData(
                for: snapshot.id, sessionID: snapshot.sessionID
            ) {
                try? accountFileStore.writeSynced(
                    preview, variant: .preview,
                    attachmentID: snapshot.id, sessionID: snapshot.sessionID
                )
            }
            if let analysis = guestFileStore.analysisData(
                for: snapshot.id, sessionID: snapshot.sessionID
            ) {
                try? accountFileStore.writeSynced(
                    analysis, variant: .analysis,
                    attachmentID: snapshot.id, sessionID: snapshot.sessionID
                )
            }
        }
    }

    /// Merges the guest bookmark ids into the account's store (union —
    /// existing account bookmarks win). Runs on the account's BookmarkStore.
    private func mergeGuestBookmarks() {
        let guestDefaults = UserDefaults.standard
        let guestKey = AccountScope.bookmarkKey(accountID: nil)
        guard let data = guestDefaults.data(forKey: guestKey) else { return }
        struct GuestRecord: Decodable {
            var entryBookmarks: [GuestBookmark]?
            var favoriteSessionIDs: [UUID]?
            struct GuestBookmark: Decodable {
                var entryID: UUID?
                var sessionID: UUID?
            }
        }
        guard let record = try? JSONDecoder().decode(GuestRecord.self, from: data) else { return }
        for favorite in record.favoriteSessionIDs ?? [] {
            bookmarks.addFavoriteIfMissing(sessionID: favorite)
        }
        for bookmark in record.entryBookmarks ?? [] {
            guard let entryID = bookmark.entryID, let sessionID = bookmark.sessionID else { continue }
            bookmarks.addBookmarkIfMissing(sessionID: sessionID, entryID: entryID)
        }
    }

    /// User explicitly confirmed deleting the guest copy AFTER a completed
    /// migration. Destructive to the GUEST store only; the account store
    /// (and the cloud copy) is untouched.
    func deleteGuestCopy() {
        guard record.phase == .completed else { return }
        let url = AccountScope.guestDatabaseURL
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            try? fm.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
        // The guest attachment AND material files follow the guest copy.
        AttachmentFileStore(accountID: nil).removeAll()
        MaterialFileStore(accountID: nil).removeAll()
        // Clear the guest bookmark record too (its sessions are gone).
        UserDefaults.standard.removeObject(forKey: AccountScope.bookmarkKey(accountID: nil))
        Self.logger.info("guest copy deleted after migration")
    }

    /// Readable status for the settings UI.
    var statusText: String {
        switch record.phase {
        case .waiting: return String(localized: "待处理")
        case .preparing: return String(localized: "准备中…")
        case .moving:
            return String(localized: "正在迁移 \(record.copiedCount)/\(record.totalSessions)")
        case .queuedForUpload: return String(localized: "已加入上传队列")
        case .completed: return String(localized: "已并入当前账号，云端上传进度见「同步状态」")
        case .partiallyFailed: return String(localized: "部分失败")
        case .declined: return String(localized: "仅保存在本机")
        }
    }
}

// MARK: - Guest library reader (the ONLY guest-store access path)

/// Read-only accessor for the guest (pre-sign-in) SwiftData store.
///
/// The write boundary is structural: this type exposes ONLY count / id /
/// snapshot queries. It performs no inserts, no deletes and no saves — and
/// it opens the store with `allowsSave: false` as a second layer, plus
/// `shouldAutosave = false` on its private context. All returned values
/// are Sendable snapshots; `@Model` objects never leave this type.
@MainActor
struct GuestLibraryReader {
    /// Sendable value snapshot of one guest session (bounded: a session
    /// plus its entries).
    struct SessionSnapshot: Sendable {
        struct Entry: Sendable {
            var id: UUID
            var sequenceID: Int
            var startOffset: TimeInterval
            var endOffset: TimeInterval
            var originalText: String
            var translatedText: String?
            var translationStatus: String
        }

        var id: UUID
        var title: String
        var startTime: Date
        var endTime: Date?
        var duration: TimeInterval
        var abnormalTermination: Bool
        var courseID: UUID?
        var entries: [Entry]
    }

    /// Sendable snapshot of one guest course.
    struct CourseSnapshot: Sendable {
        var id: UUID
        var name: String
        var teacherName: String
        var location: String
        var colorIndex: Int
        var isArchived: Bool
    }

    /// Sendable snapshot of one guest note.
    struct NoteSnapshot: Sendable {
        var id: UUID
        var sessionID: UUID
        var anchorEntryID: UUID?
        var text: String
    }

    /// Sendable snapshot of one guest study review (terminal content only —
    /// generation progress is device-local and never migrates).
    struct ReviewSnapshot: Sendable {
        var id: UUID
        var status: String
        var contentJSON: String
        var generatedJSON: String
        var reviewModel: String
        var generatedAt: Date?
        var sourceUpdatedAt: Date?
    }

    /// Sendable snapshot of one guest attachment (metadata; the FILES are
    /// copied separately by the migration through the file stores).
    struct AttachmentSnapshot: Sendable {
        var id: UUID
        var sessionID: UUID
        var courseID: UUID?
        var anchorEntryID: UUID?
        var capturedAt: Date
        var title: String
        var caption: String
        var kindRaw: String
        var mimeType: String
        var pixelWidth: Int
        var pixelHeight: Int
        var fileSize: Int64
        var contentHash: String
        var sortIndex: Int
        var transformJSON: String
        var analysisStatusRaw: String
        var analysisJSON: String
        var ocrText: String
    }

    /// Sendable snapshot of one guest glossary term.
    struct TermSnapshot: Sendable {
        var id: UUID
        var russian: String
        var chinese: String
        var explanation: String
        var partOfSpeech: String
        var userNote: String
        var courseID: UUID?
        var sessionID: UUID?
        var sourceEntryID: UUID?
        var sourceAttachmentID: UUID?
        var sourceReviewID: UUID?
        var sourceMaterialID: UUID?
        var sourceMaterialPage: Int
        var sourceSessionIDsJSON: String
        var isFavorite: Bool
        var statusRaw: String
    }

    /// Sendable snapshot of one guest study card.
    struct CardSnapshot: Sendable {
        var id: UUID
        var front: String
        var back: String
        var typeRaw: String
        var originRaw: String
        var userNote: String
        var courseID: UUID?
        var sessionID: UUID?
        var sourceEntryID: UUID?
        var sourceAttachmentID: UUID?
        var sourceTermID: UUID?
        var sourceMaterialID: UUID?
        var sourceMaterialPage: Int
        var stageRaw: String
        var reviewCount: Int
        var intervalHours: Int
        var dueAt: Date?
        var lastReviewedAt: Date?
        var lastGradeRaw: String
    }

    /// Sendable snapshot of one guest study task.
    struct TaskSnapshot: Sendable {
        var id: UUID
        var title: String
        var detail: String
        var priorityRaw: String
        var statusRaw: String
        var originRaw: String
        var uncertainty: String
        var userNote: String
        var dueAt: Date?
        var completedAt: Date?
        var courseID: UUID?
        var sessionID: UUID?
        var sourceEntryID: UUID?
        var sourceAttachmentID: UUID?
        var sourceReviewID: UUID?
        var sourceMaterialID: UUID?
        var sourceMaterialPage: Int
    }

    private static let schema = Schema([
        ClassroomSession.self, TranscriptEntry.self,
        Course.self, SessionNote.self, StudyReview.self,
        SessionAttachment.self,
        GlossaryTerm.self, StudyCard.self, StudyTask.self,
        SessionRecording.self, TranscriptCorrection.self,
        CourseSchedule.self, ScheduleException.self,
        CourseMaterial.self, MaterialPage.self, MaterialAnnotation.self,
        CourseAssistantThread.self, CourseAssistantMessage.self,
        Exam.self, ExamTopic.self, StudyPlan.self, StudyPlanItem.self,
        StudyActivity.self
    ])

    /// Sendable snapshot of one guest course schedule (the pre-class
    /// layer — rules migrate so the timetable survives sign-in).
    struct ScheduleSnapshot: Sendable {
        var id: UUID
        var courseID: UUID?
        var weekday: Int
        var startSecs: Int
        var endSecs: Int
        var recurrenceRaw: String
        var weekParityAnchor: Date?
        var firstWeekIsOdd: Bool
        var semesterStart: Date
        var semesterEnd: Date
        var timezoneID: String
        var teacherOverride: String
        var locationOverride: String
        var note: String
        var reminderLeadMins: Int
        var isEnabled: Bool
        var onceDate: Date?
    }

    /// Sendable snapshot of one guest schedule exception.
    struct ExceptionSnapshot: Sendable {
        var id: UUID
        var scheduleID: UUID?
        var courseID: UUID?
        var originalDate: Date?
        var kindRaw: String
        var changedStart: Int?
        var changedEnd: Int?
        var movedToDate: Date?
        var locationOverride: String
        var teacherOverride: String
        var note: String
    }

    private var guestURL: URL { AccountScope.guestDatabaseURL }

    /// Opens the guest store read-only. Returns nil when the guest store
    /// does not exist (never signed in / already deleted).
    ///
    /// Upgrade path: a store written by an older app version lacks newer
    /// tables (courses / notes). A read-only open of such a store fails
    /// (lightweight migration cannot run without save), so on that — and
    /// only that — failure the store is brought forward ONCE through a
    /// normal container: the migration adds the missing tables and columns
    /// without touching any row content, after which the read-only open
    /// is retried.
    private func containerIfPresent() throws -> ModelContainer? {
        guard FileManager.default.fileExists(atPath: guestURL.path) else { return nil }
        if let container = try? Self.readOnlyContainer(url: guestURL) {
            return container
        }
        _ = try ModelContainer(
            for: Self.schema,
            configurations: [
                ModelConfiguration("LiveTranslate", schema: Self.schema, url: guestURL)
            ]
        )
        return try Self.readOnlyContainer(url: guestURL)
    }

    private static func readOnlyContainer(url: URL) throws -> ModelContainer {
        try ModelContainer(
            for: Self.schema,
            configurations: [
                ModelConfiguration(
                    "LiveTranslate", schema: Self.schema, url: url, allowsSave: false
                )
            ]
        )
    }

    /// Session count in the guest store (cheap; used for prompts/banners).
    func sessionCount() -> Int {
        guard let container = try? containerIfPresent() else { return 0 }
        let context = ModelContext(container)
        context.shouldAutosave = false
        return (try? context.fetchCount(FetchDescriptor<ClassroomSession>())) ?? 0
    }

    /// All guest session ids, optionally excluding already-copied ones.
    /// (Ids only — bounded memory regardless of library size.)
    func sessionIDs(excluding done: Set<UUID> = []) throws -> [UUID] {
        guard let container = try containerIfPresent() else { return [] }
        let context = ModelContext(container)
        context.shouldAutosave = false
        let sessions = try context.fetch(FetchDescriptor<ClassroomSession>())
        return sessions.map(\.id).filter { !done.contains($0) }
    }

    /// Snapshots of the GIVEN sessions (one bounded batch), values only.
    func snapshots(forIDs ids: [UUID]) throws -> [SessionSnapshot] {
        guard !ids.isEmpty else { return [] }
        guard let container = try containerIfPresent() else { return [] }
        let context = ModelContext(container)
        context.shouldAutosave = false
        let idSet = Set(ids)
        let sessions = try context.fetch(FetchDescriptor<ClassroomSession>())
        var out: [SessionSnapshot] = []
        out.reserveCapacity(ids.count)
        for s in sessions where idSet.contains(s.id) {
            let entries = s.entries.sorted { $0.sequenceID < $1.sequenceID }.map { e in
                SessionSnapshot.Entry(
                    id: e.id,
                    sequenceID: e.sequenceID,
                    startOffset: e.startOffset,
                    endOffset: e.endOffset,
                    originalText: e.originalText,
                    translatedText: e.translatedText,
                    translationStatus: e.translationStatus
                )
            }
            out.append(SessionSnapshot(
                id: s.id, title: s.title, startTime: s.startTime, endTime: s.endTime,
                duration: s.duration, abnormalTermination: s.abnormalTermination,
                courseID: s.courseID, entries: entries
            ))
        }
        return out
    }

    /// All guest courses, values only.
    func courseSnapshots() -> [CourseSnapshot] {
        guard let container = try? containerIfPresent() else { return [] }
        let context = ModelContext(container)
        context.shouldAutosave = false
        let courses = (try? context.fetch(FetchDescriptor<Course>())) ?? []
        return courses.map { c in
            CourseSnapshot(
                id: c.id, name: c.name, teacherName: c.teacherName,
                location: c.location, colorIndex: c.colorIndex, isArchived: c.isArchived
            )
        }
    }

    /// All guest notes, values only (copied after the sessions exist).
    func noteSnapshots() -> [NoteSnapshot] {
        guard let container = try? containerIfPresent() else { return [] }
        let context = ModelContext(container)
        context.shouldAutosave = false
        let notes = (try? context.fetch(FetchDescriptor<SessionNote>())) ?? []
        return notes.map { n in
            NoteSnapshot(
                id: n.id, sessionID: n.sessionID,
                anchorEntryID: n.anchorEntryID, text: n.text
            )
        }
    }

    /// All guest study reviews with content, values only.
    func reviewSnapshots() -> [ReviewSnapshot] {
        guard let container = try? containerIfPresent() else { return [] }
        let context = ModelContext(container)
        context.shouldAutosave = false
        let reviews = (try? context.fetch(FetchDescriptor<StudyReview>())) ?? []
        return reviews.compactMap { r in
            guard !r.contentJSON.isEmpty else { return nil }
            return ReviewSnapshot(
                id: r.id, status: r.status, contentJSON: r.contentJSON,
                generatedJSON: r.generatedJSON, reviewModel: r.reviewModel,
                generatedAt: r.generatedAt, sourceUpdatedAt: r.sourceUpdatedAt
            )
        }
    }

    /// All guest attachments (values only). Files live in the GUEST
    /// attachment store; the migration copies both.
    func attachmentSnapshots() -> [AttachmentSnapshot] {
        guard let container = try? containerIfPresent() else { return [] }
        let context = ModelContext(container)
        context.shouldAutosave = false
        let rows = (try? context.fetch(FetchDescriptor<SessionAttachment>())) ?? []
        return rows.map { row in
            AttachmentSnapshot(
                id: row.id,
                sessionID: row.sessionID,
                courseID: row.courseID,
                anchorEntryID: row.anchorEntryID,
                capturedAt: row.capturedAt,
                title: row.title,
                caption: row.caption,
                kindRaw: row.kindRaw,
                mimeType: row.mimeType,
                pixelWidth: row.pixelWidth,
                pixelHeight: row.pixelHeight,
                fileSize: row.fileSize,
                contentHash: row.contentHash,
                sortIndex: row.sortIndex,
                transformJSON: row.transformJSON,
                analysisStatusRaw: row.analysisStatusRaw,
                analysisJSON: row.analysisJSON,
                ocrText: row.ocrText
            )
        }
    }

    /// All guest glossary terms, values only.
    func termSnapshots() -> [TermSnapshot] {
        guard let container = try? containerIfPresent() else { return [] }
        let context = ModelContext(container)
        context.shouldAutosave = false
        let rows = (try? context.fetch(FetchDescriptor<GlossaryTerm>())) ?? []
        return rows.map { row in
            TermSnapshot(
                id: row.id,
                russian: row.russian,
                chinese: row.chinese,
                explanation: row.explanation,
                partOfSpeech: row.partOfSpeech,
                userNote: row.userNote,
                courseID: row.courseID,
                sessionID: row.sessionID,
                sourceEntryID: row.sourceEntryID,
                sourceAttachmentID: row.sourceAttachmentID,
                sourceReviewID: row.sourceReviewID,
                sourceMaterialID: row.sourceMaterialID,
                sourceMaterialPage: row.sourceMaterialPage,
                sourceSessionIDsJSON: row.sourceSessionIDsJSON,
                isFavorite: row.isFavorite,
                statusRaw: row.statusRaw
            )
        }
    }

    /// All guest study cards, values only (scheduling state included —
    /// review progress migrates with the card).
    func cardSnapshots() -> [CardSnapshot] {
        guard let container = try? containerIfPresent() else { return [] }
        let context = ModelContext(container)
        context.shouldAutosave = false
        let rows = (try? context.fetch(FetchDescriptor<StudyCard>())) ?? []
        return rows.map { row in
            CardSnapshot(
                id: row.id,
                front: row.front,
                back: row.back,
                typeRaw: row.typeRaw,
                originRaw: row.originRaw,
                userNote: row.userNote,
                courseID: row.courseID,
                sessionID: row.sessionID,
                sourceEntryID: row.sourceEntryID,
                sourceAttachmentID: row.sourceAttachmentID,
                sourceTermID: row.sourceTermID,
                sourceMaterialID: row.sourceMaterialID,
                sourceMaterialPage: row.sourceMaterialPage,
                stageRaw: row.stageRaw,
                reviewCount: row.reviewCount,
                intervalHours: row.intervalHours,
                dueAt: row.dueAt,
                lastReviewedAt: row.lastReviewedAt,
                lastGradeRaw: row.lastGradeRaw
            )
        }
    }

    /// All guest study tasks, values only. Unconfirmed AI candidates
    /// (pendingConfirm) migrate too — they stay unconfirmed in the
    /// account store until the user acts on them.
    func taskSnapshots() -> [TaskSnapshot] {
        guard let container = try? containerIfPresent() else { return [] }
        let context = ModelContext(container)
        context.shouldAutosave = false
        let rows = (try? context.fetch(FetchDescriptor<StudyTask>())) ?? []
        return rows.map { row in
            TaskSnapshot(
                id: row.id,
                title: row.title,
                detail: row.detail,
                priorityRaw: row.priorityRaw,
                statusRaw: row.statusRaw,
                originRaw: row.originRaw,
                uncertainty: row.uncertainty,
                userNote: row.userNote,
                dueAt: row.dueAt,
                completedAt: row.completedAt,
                courseID: row.courseID,
                sessionID: row.sessionID,
                sourceEntryID: row.sourceEntryID,
                sourceAttachmentID: row.sourceAttachmentID,
                sourceReviewID: row.sourceReviewID,
                sourceMaterialID: row.sourceMaterialID,
                sourceMaterialPage: row.sourceMaterialPage
            )
        }
    }

    /// All guest course schedules, values only.
    func scheduleSnapshots() -> [ScheduleSnapshot] {
        guard let container = try? containerIfPresent() else { return [] }
        let context = ModelContext(container)
        context.shouldAutosave = false
        let rows = (try? context.fetch(FetchDescriptor<CourseSchedule>())) ?? []
        return rows.map { row in
            ScheduleSnapshot(
                id: row.id,
                courseID: row.courseID,
                weekday: row.weekday,
                startSecs: row.startSecs,
                endSecs: row.endSecs,
                recurrenceRaw: row.recurrenceRaw,
                weekParityAnchor: row.weekParityAnchor,
                firstWeekIsOdd: row.firstWeekIsOdd,
                semesterStart: row.semesterStart,
                semesterEnd: row.semesterEnd,
                timezoneID: row.timezoneID,
                teacherOverride: row.teacherOverride,
                locationOverride: row.locationOverride,
                note: row.note,
                reminderLeadMins: row.reminderLeadMins,
                isEnabled: row.isEnabled,
                onceDate: row.onceDate
            )
        }
    }

    /// All guest schedule exceptions, values only.
    func exceptionSnapshots() -> [ExceptionSnapshot] {
        guard let container = try? containerIfPresent() else { return [] }
        let context = ModelContext(container)
        context.shouldAutosave = false
        let rows = (try? context.fetch(FetchDescriptor<ScheduleException>())) ?? []
        return rows.map { row in
            ExceptionSnapshot(
                id: row.id,
                scheduleID: row.scheduleID,
                courseID: row.courseID,
                originalDate: row.originalDate,
                kindRaw: row.kindRaw,
                changedStart: row.changedStart,
                changedEnd: row.changedEnd,
                movedToDate: row.movedToDate,
                locationOverride: row.locationOverride,
                teacherOverride: row.teacherOverride,
                note: row.note
            )
        }
    }

    /// All guest course materials, values only.
    func materialSnapshots() -> [MaterialSnapshot] {
        guard let container = try? containerIfPresent() else { return [] }
        let context = ModelContext(container)
        context.shouldAutosave = false
        let rows = (try? context.fetch(FetchDescriptor<CourseMaterial>())) ?? []
        return rows.map { row in
            MaterialSnapshot(
                id: row.id,
                courseID: row.courseID,
                sessionID: row.sessionID,
                occurrenceKey: row.occurrenceKey,
                title: row.title,
                originalFileName: row.originalFileName,
                mimeType: row.mimeType,
                kindRaw: row.kindRaw,
                formatRaw: row.formatRaw,
                fileSize: row.fileSize,
                contentHash: row.contentHash,
                pageCount: row.pageCount,
                sourceAttachmentID: row.sourceAttachmentID,
                extractionStatusRaw: row.extractionStatusRaw,
                digestStatusRaw: row.digestStatusRaw,
                digestJSON: row.digestJSON,
                digestModel: row.digestModel,
                digestGeneratedAt: row.digestGeneratedAt,
                digestSourceHash: row.digestSourceHash,
                lastReadPage: row.lastReadPage,
                lastOpenedAt: row.lastOpenedAt
            )
        }
    }

    /// All guest material pages, values only.
    func materialPageSnapshots() -> [MaterialPageSnapshot] {
        guard let container = try? containerIfPresent() else { return [] }
        let context = ModelContext(container)
        context.shouldAutosave = false
        let rows = (try? context.fetch(FetchDescriptor<MaterialPage>())) ?? []
        return rows.map { row in
            MaterialPageSnapshot(
                id: row.id,
                materialID: row.materialID,
                pageNumber: row.pageNumber,
                extractedText: row.extractedText,
                ocrText: row.ocrText,
                ocrStatusRaw: row.ocrStatusRaw
            )
        }
    }

    /// All guest material annotations, values only.
    func materialAnnotationSnapshots() -> [MaterialAnnotationSnapshot] {
        guard let container = try? containerIfPresent() else { return [] }
        let context = ModelContext(container)
        context.shouldAutosave = false
        let rows = (try? context.fetch(FetchDescriptor<MaterialAnnotation>())) ?? []
        return rows.map { row in
            MaterialAnnotationSnapshot(
                id: row.id,
                materialID: row.materialID,
                pageNumber: row.pageNumber,
                kindRaw: row.kindRaw,
                text: row.text
            )
        }
    }

    /// All guest assistant threads, values only.
    func assistantThreadSnapshots() -> [AssistantThreadSnapshot] {
        guard let container = try? containerIfPresent() else { return [] }
        let context = ModelContext(container)
        context.shouldAutosave = false
        let rows = (try? context.fetch(FetchDescriptor<CourseAssistantThread>())) ?? []
        return rows.map { row in
            AssistantThreadSnapshot(
                id: row.id,
                courseID: row.courseID,
                title: row.title
            )
        }
    }

    /// All guest assistant messages, values only.
    func assistantMessageSnapshots() -> [AssistantMessageSnapshot] {
        guard let container = try? containerIfPresent() else { return [] }
        let context = ModelContext(container)
        context.shouldAutosave = false
        let rows = (try? context.fetch(FetchDescriptor<CourseAssistantMessage>())) ?? []
        return rows.map { row in
            AssistantMessageSnapshot(
                id: row.id,
                threadID: row.threadID,
                roleRaw: row.roleRaw,
                text: row.text,
                scopeMaterialID: row.scopeMaterialID,
                scopeSessionID: row.scopeSessionID,
                citationsJSON: row.citationsJSON,
                modeRaw: row.modeRaw,
                visualEvidenceJSON: row.visualEvidenceJSON,
                answerJSON: row.answerJSON,
                answerModel: row.answerModel
            )
        }
    }

    /// All guest exams (device-local AI candidates included — they
    /// transfer as candidates and stay local until confirmed).
    func examSnapshots() -> [ExamSnapshot] {
        guard let container = try? containerIfPresent() else { return [] }
        let context = ModelContext(container)
        context.shouldAutosave = false
        let rows = (try? context.fetch(FetchDescriptor<Exam>())) ?? []
        return rows.map { row in
            ExamSnapshot(
                id: row.id,
                courseID: row.courseID,
                title: row.title,
                kindRaw: row.kindRaw,
                examDateKey: row.examDateKey,
                startSecs: row.startSecs,
                endSecs: row.endSecs,
                location: row.location,
                scopeText: row.scopeText,
                note: row.note,
                targetScore: row.targetScore,
                statusRaw: row.statusRaw,
                originRaw: row.originRaw,
                sourceJSON: row.sourceJSON
            )
        }
    }

    /// All guest exam topics, values only.
    func examTopicSnapshots() -> [ExamTopicSnapshot] {
        guard let container = try? containerIfPresent() else { return [] }
        let context = ModelContext(container)
        context.shouldAutosave = false
        let rows = (try? context.fetch(FetchDescriptor<ExamTopic>())) ?? []
        return rows.map { row in
            ExamTopicSnapshot(
                id: row.id,
                examID: row.examID,
                title: row.title,
                detail: row.detail,
                importanceRaw: row.importanceRaw,
                selfRatingRaw: row.selfRatingRaw,
                statusRaw: row.statusRaw,
                sourceJSON: row.sourceJSON,
                userEdited: row.userEdited
            )
        }
    }

    /// All guest study plans, values only.
    func studyPlanSnapshots() -> [StudyPlanSnapshot] {
        guard let container = try? containerIfPresent() else { return [] }
        let context = ModelContext(container)
        context.shouldAutosave = false
        let rows = (try? context.fetch(FetchDescriptor<StudyPlan>())) ?? []
        return rows.map { row in
            StudyPlanSnapshot(
                id: row.id,
                examID: row.examID,
                title: row.title,
                startDateKey: row.startDateKey,
                endDateKey: row.endDateKey,
                weekdayMinutes: row.weekdayMinutes,
                weekendMinutes: row.weekendMinutes,
                restDaysJSON: row.restDaysJSON,
                finishEarlyDays: row.finishEarlyDays,
                includeCards: row.includeCards,
                includeTasks: row.includeTasks,
                includeMaterials: row.includeMaterials,
                includeSessions: row.includeSessions,
                focusTopicsJSON: row.focusTopicsJSON,
                blockedTimesJSON: row.blockedTimesJSON,
                statusRaw: row.statusRaw
            )
        }
    }

    /// All guest plan items, values only.
    func studyPlanItemSnapshots() -> [StudyPlanItemSnapshot] {
        guard let container = try? containerIfPresent() else { return [] }
        let context = ModelContext(container)
        context.shouldAutosave = false
        let rows = (try? context.fetch(FetchDescriptor<StudyPlanItem>())) ?? []
        return rows.map { row in
            StudyPlanItemSnapshot(
                id: row.id,
                planID: row.planID,
                examID: row.examID,
                itemDateKey: row.itemDateKey,
                title: row.title,
                kindRaw: row.kindRaw,
                estimatedMinutes: row.estimatedMinutes,
                actualMinutes: row.actualMinutes,
                statusRaw: row.statusRaw,
                statusChangedAt: row.statusChangedAt,
                itemOrder: row.itemOrder,
                sourceJSON: row.sourceJSON,
                userNote: row.userNote,
                userEdited: row.userEdited
            )
        }
    }

    /// All guest study activities, values only.
    func studyActivitySnapshots() -> [StudyActivitySnapshot] {
        guard let container = try? containerIfPresent() else { return [] }
        let context = ModelContext(container)
        context.shouldAutosave = false
        let rows = (try? context.fetch(FetchDescriptor<StudyActivity>())) ?? []
        return rows.map { row in
            StudyActivitySnapshot(
                id: row.id,
                planItemID: row.planItemID,
                examID: row.examID,
                courseID: row.courseID,
                topicID: row.topicID,
                startedAt: row.startedAt,
                endedAt: row.endedAt,
                durationSeconds: row.durationSeconds,
                statusRaw: row.statusRaw,
                note: row.note
            )
        }
    }
}

// MARK: - Material snapshots (guest library)

/// Sendable snapshot of one guest course material.
struct MaterialSnapshot: Sendable {
    var id: UUID
    var courseID: UUID?
    var sessionID: UUID?
    var occurrenceKey: String?
    var title: String
    var originalFileName: String
    var mimeType: String
    var kindRaw: String
    var formatRaw: String
    var fileSize: Int64
    var contentHash: String
    var pageCount: Int
    var sourceAttachmentID: UUID?
    var extractionStatusRaw: String
    var digestStatusRaw: String
    var digestJSON: String
    var digestModel: String
    var digestGeneratedAt: Date?
    var digestSourceHash: String
    var lastReadPage: Int
    var lastOpenedAt: Date?

    var ownsFile: Bool { sourceAttachmentID == nil }
}

/// Sendable snapshot of one guest material page.
struct MaterialPageSnapshot: Sendable {
    var id: UUID
    var materialID: UUID
    var pageNumber: Int
    var extractedText: String
    var ocrText: String
    var ocrStatusRaw: String
}

/// Sendable snapshot of one guest material annotation.
struct MaterialAnnotationSnapshot: Sendable {
    var id: UUID
    var materialID: UUID
    var pageNumber: Int
    var kindRaw: String
    var text: String
}

/// Sendable snapshot of one guest assistant thread.
struct AssistantThreadSnapshot: Sendable {
    var id: UUID
    var courseID: UUID?
    var title: String
}

/// Sendable snapshot of one guest assistant message.
struct AssistantMessageSnapshot: Sendable {
    var id: UUID
    var threadID: UUID
    var roleRaw: String
    var text: String
    var scopeMaterialID: UUID?
    var scopeSessionID: UUID?
    var citationsJSON: String
    /// Visual Q&A fields (00011 round): turn mode, evidence snapshot,
    /// structured answer and the producing model — they migrate with the
    /// message like every other field.
    var modeRaw: String
    var visualEvidenceJSON: String
    var answerJSON: String
    var answerModel: String
}

// MARK: - Exam-center snapshots (guest library)

/// Sendable snapshot of one guest exam.
struct ExamSnapshot: Sendable {
    var id: UUID
    var courseID: UUID?
    var title: String
    var kindRaw: String
    var examDateKey: String
    var startSecs: Int
    var endSecs: Int
    var location: String
    var scopeText: String
    var note: String
    var targetScore: String
    var statusRaw: String
    var originRaw: String
    var sourceJSON: String
}

/// Sendable snapshot of one guest exam topic.
struct ExamTopicSnapshot: Sendable {
    var id: UUID
    var examID: UUID
    var title: String
    var detail: String
    var importanceRaw: String
    var selfRatingRaw: String
    var statusRaw: String
    var sourceJSON: String
    var userEdited: Bool
}

/// Sendable snapshot of one guest study plan.
struct StudyPlanSnapshot: Sendable {
    var id: UUID
    var examID: UUID
    var title: String
    var startDateKey: String
    var endDateKey: String
    var weekdayMinutes: Int
    var weekendMinutes: Int
    var restDaysJSON: String
    var finishEarlyDays: Int
    var includeCards: Bool
    var includeTasks: Bool
    var includeMaterials: Bool
    var includeSessions: Bool
    var focusTopicsJSON: String
    var blockedTimesJSON: String
    var statusRaw: String
}

/// Sendable snapshot of one guest study plan item.
struct StudyPlanItemSnapshot: Sendable {
    var id: UUID
    var planID: UUID
    var examID: UUID?
    var itemDateKey: String
    var title: String
    var kindRaw: String
    var estimatedMinutes: Int
    var actualMinutes: Int
    var statusRaw: String
    var statusChangedAt: Date?
    var itemOrder: Int
    var sourceJSON: String
    var userNote: String
    var userEdited: Bool
}

/// Sendable snapshot of one guest study activity.
struct StudyActivitySnapshot: Sendable {
    var id: UUID
    var planItemID: UUID?
    var examID: UUID?
    var courseID: UUID?
    var topicID: UUID?
    var startedAt: Date
    var endedAt: Date?
    var durationSeconds: Int
    var statusRaw: String
    var note: String
}
