import Foundation
import SwiftData

/// Exam-center repository methods — the exam/topic/plan/item/activity
/// family of `ClassroomRepositoryProtocol`. Implemented as an extension
/// on the concrete class so it shares the model context and the
/// mutationObserver chain; kept in its own file the way the domain
/// families deserve.
///
/// Candidate semantics (the pendingConfirm task convention):
/// `Exam` rows with `status == .pending` are AI-extracted candidates —
/// device-local, never notified to the sync observer, until
/// `confirmExam` promotes them.
extension TranscriptRepository {

    // MARK: - Exams

    func exams(courseID: UUID?, includeCandidates: Bool) throws -> [Exam] {
        let descriptor = FetchDescriptor<Exam>()
        var rows = try context.fetch(descriptor)
        if !includeCandidates {
            rows = rows.filter { $0.status != .pending }
        }
        if let courseID {
            rows = rows.filter { $0.courseID == courseID }
        }
        return rows.sorted { lhs, rhs in
            // Live exams by date; candidates (no firm date) sink to the
            // end awaiting confirmation.
            switch (lhs.examDate, rhs.examDate) {
            case (nil, .some): return false
            case (.some, nil): return true
            case let (.some(l), .some(r)): return l < r
            default: return lhs.createdAt < rhs.createdAt
            }
        }
    }

    func exam(id: UUID) throws -> Exam? {
        let descriptor = FetchDescriptor<Exam>(predicate: #Predicate { $0.id == id })
        return try context.fetch(descriptor).first
    }

    func exams(matching query: String) throws -> [Exam] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let lowered = trimmed.lowercased()
        return ((try? exams(courseID: nil, includeCandidates: false)) ?? [])
            .filter { exam in
                exam.title.lowercased().contains(lowered)
                    || exam.scopeText.lowercased().contains(lowered)
                    || exam.note.lowercased().contains(lowered)
            }
    }

    func pendingExamCandidates() throws -> [Exam] {
        let descriptor = FetchDescriptor<Exam>()
        return try context.fetch(descriptor)
            .filter { $0.status == .pending }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func addExam(_ draft: ExamDraft) throws -> Exam {
        let exam = Exam(
            courseID: draft.courseID,
            title: draft.title,
            kind: draft.kind,
            examDateKey: draft.examDateKey,
            startSecs: draft.startSecs,
            endSecs: draft.endSecs,
            location: draft.location,
            scopeText: draft.scopeText,
            note: draft.note,
            targetScore: draft.targetScore,
            status: draft.status,
            origin: draft.origin,
            sourceJSON: draft.source.map { $0.encode() } ?? ""
        )
        context.insert(exam)
        try context.save()
        // pendingConfirm candidates are device-local until confirmed.
        if exam.status != .pending {
            mutationObserver?.examCreated(exam)
        }
        return exam
    }

    func updateExam(_ exam: Exam, with draft: ExamDraft) throws {
        exam.courseID = draft.courseID
        exam.title = draft.title
        exam.kind = draft.kind
        exam.examDateKey = draft.examDateKey
        exam.startSecs = draft.startSecs
        exam.endSecs = draft.endSecs
        exam.location = draft.location
        exam.scopeText = draft.scopeText
        exam.note = draft.note
        exam.targetScore = draft.targetScore
        if let source = draft.source {
            exam.sourceJSON = source.encode()
        }
        exam.updatedAt = .now
        try context.save()
        if exam.status != .pending {
            mutationObserver?.examUpdated(exam)
        }
    }

    func confirmExam(_ exam: Exam) throws {
        guard exam.status == .pending else { return }
        exam.status = .scheduled
        exam.updatedAt = .now
        try context.save()
        // First push of a previously device-local candidate.
        mutationObserver?.examCreated(exam)
    }

    func setExamStatus(_ exam: Exam, status: ExamStatus) throws {
        guard exam.status != status else { return }
        exam.status = status
        exam.updatedAt = .now
        try context.save()
        if exam.status != .pending {
            mutationObserver?.examUpdated(exam)
        }
    }

    func deleteExam(_ exam: Exam) throws {
        let examID = exam.id
        let wasConfirmed = exam.status != .pending
        // Local cascade mirrors the server's: topics + plans + items die,
        // activities detach (their history survives).
        let topics = try context.fetch(FetchDescriptor<ExamTopic>(
            predicate: #Predicate { $0.examID == examID }
        ))
        for topic in topics {
            context.delete(topic)
        }
        let plans = try context.fetch(FetchDescriptor<StudyPlan>(
            predicate: #Predicate { $0.examID == examID }
        ))
        for plan in plans {
            // Hoisted: a captured value's property inside #Predicate
            // becomes an unbuildable key path (the same rule as the other
            // four predicate fixes).
            let planID = plan.id
            let items = try context.fetch(FetchDescriptor<StudyPlanItem>(
                predicate: #Predicate { $0.planID == planID }
            ))
            for item in items {
                context.delete(item)
            }
            context.delete(plan)
        }
        let activities = try context.fetch(FetchDescriptor<StudyActivity>(
            predicate: #Predicate { $0.examID == examID }
        ))
        for activity in activities {
            activity.examID = nil
            activity.updatedAt = .now
        }
        context.delete(exam)
        try context.save()
        if wasConfirmed {
            mutationObserver?.examDeleted(id: examID)
        }
    }

    func applyRemoteExam(record: SyncServerRecordDTO, serverVersion: Int) throws {
        guard let recordID = record.id,
              let title = record.title, !title.isEmpty,
              let dateKey = record.examDate else { return }
        let descriptor = FetchDescriptor<Exam>(predicate: #Predicate { $0.id == recordID })
        let existing = try context.fetch(descriptor).first
        if let existing, existing.serverVersion >= serverVersion { return }

        let exam: Exam
        if let existing {
            exam = existing
        } else {
            exam = Exam(id: recordID, title: title, examDateKey: dateKey)
            context.insert(exam)
        }
        exam.title = title
        exam.examDateKey = dateKey
        if let kindRaw = record.examKind { exam.kindRaw = kindRaw }
        if let startSecs = record.examStartSecs { exam.startSecs = startSecs }
        if let endSecs = record.examEndSecs { exam.endSecs = endSecs }
        if let location = record.examLocation { exam.location = location }
        if let scope = record.examScope { exam.scopeText = scope }
        if let note = record.examNote { exam.note = note }
        if let target = record.examTargetScore { exam.targetScore = target }
        if let statusRaw = record.examStatus { exam.statusRaw = statusRaw }
        if let originRaw = record.examOrigin { exam.originRaw = originRaw }
        if let sourceJSON = record.examSource { exam.sourceJSON = sourceJSON }
        exam.courseID = record.courseId
        exam.serverVersion = serverVersion
        try context.save()
    }

    func deleteExamByID(_ id: UUID) throws {
        guard let exam = try exam(id: id) else { return }
        // Remote deletions ride the same cascade path.
        exam.status = exam.status == .pending ? .pending : .cancelled
        try deleteExam(exam)
    }

    // MARK: - Exam topics

    func examTopics(examID: UUID) throws -> [ExamTopic] {
        let descriptor = FetchDescriptor<ExamTopic>(
            predicate: #Predicate { $0.examID == examID }
        )
        return try context.fetch(descriptor).sorted { lhs, rhs in
            if lhs.importance != rhs.importance {
                return lhs.importance == .high
            }
            return lhs.createdAt < rhs.createdAt
        }
    }

    func addExamTopic(_ draft: ExamTopicDraft) throws -> ExamTopic {
        let topic = ExamTopic(
            examID: draft.examID,
            title: draft.title,
            detail: draft.detail,
            importance: draft.importance,
            selfRating: draft.selfRating,
            status: draft.status,
            sourceJSON: draft.source.map { $0.encode() } ?? "",
            userEdited: draft.userEdited
        )
        context.insert(topic)
        try context.save()
        mutationObserver?.examTopicCreated(topic)
        return topic
    }

    func updateExamTopic(_ topic: ExamTopic, with draft: ExamTopicDraft) throws {
        topic.title = draft.title
        topic.detail = draft.detail
        topic.importance = draft.importance
        topic.selfRating = draft.selfRating
        if let source = draft.source {
            topic.sourceJSON = source.encode()
        }
        topic.userEdited = true
        topic.updatedAt = .now
        try context.save()
        mutationObserver?.examTopicUpdated(topic)
    }

    func setExamTopicStatus(_ topic: ExamTopic, status: ExamTopicStatus) throws {
        guard topic.status != status else { return }
        topic.status = status
        topic.updatedAt = .now
        try context.save()
        mutationObserver?.examTopicUpdated(topic)
    }

    func setExamTopicSelfRating(_ topic: ExamTopic, rating: ExamTopicSelfRating) throws {
        guard topic.selfRating != rating else { return }
        topic.selfRating = rating
        topic.updatedAt = .now
        try context.save()
        mutationObserver?.examTopicUpdated(topic)
    }

    func deleteExamTopic(_ topic: ExamTopic) throws {
        let topicID = topic.id
        // The topic's activities detach (history survives).
        let activities = try context.fetch(FetchDescriptor<StudyActivity>(
            predicate: #Predicate { $0.topicID == topicID }
        ))
        for activity in activities {
            activity.topicID = nil
            activity.updatedAt = .now
        }
        context.delete(topic)
        try context.save()
        mutationObserver?.examTopicDeleted(id: topicID)
    }

    func applyRemoteExamTopic(record: SyncServerRecordDTO, serverVersion: Int) throws {
        guard let recordID = record.id,
              let title = record.title, !title.isEmpty,
              let examID = record.examId else { return }
        let descriptor = FetchDescriptor<ExamTopic>(predicate: #Predicate { $0.id == recordID })
        let existing = try context.fetch(descriptor).first
        if let existing, existing.serverVersion >= serverVersion { return }

        let topic: ExamTopic
        if let existing {
            topic = existing
        } else {
            topic = ExamTopic(id: recordID, examID: examID, title: title)
            context.insert(topic)
        }
        topic.title = title
        topic.examID = examID
        if let detail = record.topicDetail { topic.detail = detail }
        if let importanceRaw = record.topicImportance { topic.importanceRaw = importanceRaw }
        if let ratingRaw = record.topicSelfRating { topic.selfRatingRaw = ratingRaw }
        if let statusRaw = record.topicStatus { topic.statusRaw = statusRaw }
        if let sourceJSON = record.topicSource { topic.sourceJSON = sourceJSON }
        if let userEdited = record.topicUserEdited { topic.userEdited = userEdited }
        topic.serverVersion = serverVersion
        try context.save()
    }

    func deleteExamTopicByID(_ id: UUID) throws {
        let descriptor = FetchDescriptor<ExamTopic>(predicate: #Predicate { $0.id == id })
        guard let topic = try context.fetch(descriptor).first else { return }
        try deleteExamTopic(topic)
    }

    // MARK: - Study plans

    func studyPlans(examID: UUID?) throws -> [StudyPlan] {
        let descriptor = FetchDescriptor<StudyPlan>()
        var rows = try context.fetch(descriptor)
        if let examID {
            rows = rows.filter { $0.examID == examID }
        }
        return rows.sorted { $0.createdAt > $1.createdAt }
    }

    func addStudyPlan(_ draft: StudyPlanDraft) throws -> StudyPlan {
        let plan = StudyPlan(
            examID: draft.examID,
            title: draft.title,
            startDateKey: draft.startDateKey,
            endDateKey: draft.endDateKey,
            weekdayMinutes: draft.weekdayMinutes,
            weekendMinutes: draft.weekendMinutes,
            restDaysJSON: Self.encodeRestDays(draft.restDays),
            finishEarlyDays: draft.finishEarlyDays,
            includeCards: draft.includeCards,
            includeTasks: draft.includeTasks,
            includeMaterials: draft.includeMaterials,
            includeSessions: draft.includeSessions,
            focusTopicsJSON: Self.encodeUUIDs(draft.focusTopics),
            blockedTimesJSON: Self.encodeBlockedTimes(draft.blockedTimes),
            status: draft.status
        )
        context.insert(plan)
        try context.save()
        mutationObserver?.studyPlanCreated(plan)
        return plan
    }

    func updateStudyPlan(_ plan: StudyPlan, with draft: StudyPlanDraft) throws {
        plan.title = draft.title
        plan.startDateKey = draft.startDateKey
        plan.endDateKey = draft.endDateKey
        plan.weekdayMinutes = draft.weekdayMinutes
        plan.weekendMinutes = draft.weekendMinutes
        plan.restDaysJSON = Self.encodeRestDays(draft.restDays)
        plan.finishEarlyDays = draft.finishEarlyDays
        plan.includeCards = draft.includeCards
        plan.includeTasks = draft.includeTasks
        plan.includeMaterials = draft.includeMaterials
        plan.includeSessions = draft.includeSessions
        plan.focusTopicsJSON = Self.encodeUUIDs(draft.focusTopics)
        plan.blockedTimesJSON = Self.encodeBlockedTimes(draft.blockedTimes)
        plan.updatedAt = .now
        try context.save()
        mutationObserver?.studyPlanUpdated(plan)
    }

    func setStudyPlanStatus(_ plan: StudyPlan, status: StudyPlanStatus) throws {
        guard plan.status != status else { return }
        plan.status = status
        plan.updatedAt = .now
        try context.save()
        mutationObserver?.studyPlanUpdated(plan)
    }

    func deleteStudyPlan(_ plan: StudyPlan) throws {
        let planID = plan.id
        let items = try context.fetch(FetchDescriptor<StudyPlanItem>(
            predicate: #Predicate { $0.planID == planID }
        ))
        for item in items {
            try detachActivities(ofItem: item.id)
            context.delete(item)
        }
        context.delete(plan)
        try context.save()
        mutationObserver?.studyPlanDeleted(id: planID)
    }

    func applyRemoteStudyPlan(record: SyncServerRecordDTO, serverVersion: Int) throws {
        guard let recordID = record.id,
              let title = record.title, !title.isEmpty,
              let examID = record.examId,
              let startKey = record.planStartDate,
              let endKey = record.planEndDate else { return }
        let descriptor = FetchDescriptor<StudyPlan>(predicate: #Predicate { $0.id == recordID })
        let existing = try context.fetch(descriptor).first
        if let existing, existing.serverVersion >= serverVersion { return }

        let plan: StudyPlan
        if let existing {
            plan = existing
        } else {
            plan = StudyPlan(
                id: recordID, examID: examID, title: title,
                startDateKey: startKey, endDateKey: endKey
            )
            context.insert(plan)
        }
        plan.title = title
        plan.examID = examID
        plan.startDateKey = startKey
        plan.endDateKey = endKey
        if let minutes = record.planWeekdayMinutes { plan.weekdayMinutes = minutes }
        if let minutes = record.planWeekendMinutes { plan.weekendMinutes = minutes }
        if let restJSON = record.planRestDays { plan.restDaysJSON = restJSON }
        if let days = record.planFinishEarlyDays { plan.finishEarlyDays = days }
        if let include = record.planIncludeCards { plan.includeCards = include }
        if let include = record.planIncludeTasks { plan.includeTasks = include }
        if let include = record.planIncludeMaterials { plan.includeMaterials = include }
        if let include = record.planIncludeSessions { plan.includeSessions = include }
        if let focusJSON = record.planFocusTopics { plan.focusTopicsJSON = focusJSON }
        if let blockedJSON = record.planBlockedTimes { plan.blockedTimesJSON = blockedJSON }
        if let statusRaw = record.planStatus { plan.statusRaw = statusRaw }
        plan.serverVersion = serverVersion
        try context.save()
    }

    func deleteStudyPlanByID(_ id: UUID) throws {
        let descriptor = FetchDescriptor<StudyPlan>(predicate: #Predicate { $0.id == id })
        guard let plan = try context.fetch(descriptor).first else { return }
        try deleteStudyPlan(plan)
    }

    // MARK: - Plan items

    func studyPlanItems(planID: UUID) throws -> [StudyPlanItem] {
        let descriptor = FetchDescriptor<StudyPlanItem>(
            predicate: #Predicate { $0.planID == planID }
        )
        return try context.fetch(descriptor).sorted {
            if $0.itemDateKey != $1.itemDateKey {
                return $0.itemDateKey < $1.itemDateKey
            }
            return $0.itemOrder < $1.itemOrder
        }
    }

    func studyPlanItem(id: UUID) throws -> StudyPlanItem? {
        let descriptor = FetchDescriptor<StudyPlanItem>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first
    }

    func studyPlanItems(dateKey: String) throws -> [StudyPlanItem] {
        let descriptor = FetchDescriptor<StudyPlanItem>(
            predicate: #Predicate { $0.itemDateKey == dateKey }
        )
        return try context.fetch(descriptor).sorted { $0.itemOrder < $1.itemOrder }
    }

    func studyPlanItems(matching query: String) throws -> [StudyPlanItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let lowered = trimmed.lowercased()
        let descriptor = FetchDescriptor<StudyPlanItem>()
        return try context.fetch(descriptor)
            .filter {
                $0.title.lowercased().contains(lowered)
                    || $0.userNote.lowercased().contains(lowered)
            }
            .sorted { $0.itemDateKey < $1.itemDateKey }
    }

    func addStudyPlanItems(_ drafts: [StudyPlanItemDraft]) throws -> [StudyPlanItem] {
        var items: [StudyPlanItem] = []
        for draft in drafts {
            let item = StudyPlanItem(
                planID: draft.planID,
                examID: draft.examID,
                itemDateKey: draft.itemDateKey,
                title: draft.title,
                kind: draft.kind,
                estimatedMinutes: draft.estimatedMinutes,
                itemOrder: draft.itemOrder,
                sourceJSON: draft.source.map { $0.encode() } ?? ""
            )
            context.insert(item)
            items.append(item)
        }
        try context.save()
        for item in items {
            mutationObserver?.studyPlanItemCreated(item)
        }
        return items
    }

    func updateStudyPlanItem(
        _ item: StudyPlanItem,
        title: String?, estimatedMinutes: Int?, userNote: String?
    ) throws {
        if let title, !title.isEmpty { item.title = title }
        if let estimatedMinutes, estimatedMinutes > 0 {
            item.estimatedMinutes = estimatedMinutes
        }
        if let userNote { item.userNote = userNote }
        item.userEdited = true
        item.updatedAt = .now
        try context.save()
        mutationObserver?.studyPlanItemUpdated(item)
    }

    func setStudyPlanItemStatus(_ item: StudyPlanItem, status: StudyPlanItemStatus) throws {
        guard item.status != status else { return }
        item.status = status
        // The merge order: every status change stamps the time (a newer
        // deliberate reopen propagates cross-device; a stale pending
        // push never blanks progress).
        item.statusChangedAt = .now
        item.updatedAt = .now
        try context.save()
        mutationObserver?.studyPlanItemUpdated(item)
    }

    func setStudyPlanItemDate(_ item: StudyPlanItem, dateKey: String) throws {
        guard item.itemDateKey != dateKey else { return }
        item.itemDateKey = dateKey
        item.statusChangedAt = item.status == .deferred ? .now : item.statusChangedAt
        item.userEdited = true
        item.updatedAt = .now
        try context.save()
        mutationObserver?.studyPlanItemUpdated(item)
    }

    func recordStudyPlanItemActualMinutes(_ item: StudyPlanItem, minutes: Int) throws {
        guard minutes > item.actualMinutes else { return }
        item.actualMinutes = minutes
        item.updatedAt = .now
        try context.save()
        mutationObserver?.studyPlanItemUpdated(item)
    }

    func deleteStudyPlanItem(_ item: StudyPlanItem) throws {
        let itemID = item.id
        try detachActivities(ofItem: itemID)
        context.delete(item)
        try context.save()
        mutationObserver?.studyPlanItemDeleted(id: itemID)
    }

    func applyRemoteStudyPlanItem(record: SyncServerRecordDTO, serverVersion: Int) throws {
        guard let recordID = record.id,
              let title = record.title, !title.isEmpty,
              let planID = record.planId,
              let dateKey = record.planItemDate else { return }
        let descriptor = FetchDescriptor<StudyPlanItem>(
            predicate: #Predicate { $0.id == recordID }
        )
        let existing = try context.fetch(descriptor).first
        if let existing, existing.serverVersion >= serverVersion { return }

        let item: StudyPlanItem
        if let existing {
            item = existing
        } else {
            item = StudyPlanItem(
                id: recordID, planID: planID, examID: record.examId,
                itemDateKey: dateKey, title: title
            )
            context.insert(item)
        }
        item.title = title
        item.planID = planID
        item.examID = record.examId
        item.itemDateKey = dateKey
        if let kindRaw = record.planItemKind { item.kindRaw = kindRaw }
        if let estimated = record.planItemEstimatedMinutes { item.estimatedMinutes = estimated }
        // Status merge: a remote status newer by statusChangedAt wins —
        // mirrors the server rule (a stale pending record never blanks a
        // done item).
        if let statusRaw = record.planItemStatus,
           let status = StudyPlanItemStatus(rawValue: statusRaw),
           status != item.status {
            let remoteChanged = record.planItemStatusChangedAt
            let localChanged = item.statusChangedAt
            let remoteWins: Bool
            switch (remoteChanged, localChanged) {
            case (nil, nil): remoteWins = true
            case (nil, .some): remoteWins = false
            case (.some, nil): remoteWins = true
            case let (.some(remote), .some(local)):
                remoteWins = remote >= local || status == .done || status == .skipped
            }
            if remoteWins {
                item.status = status
                item.statusChangedAt = remoteChanged
            }
        }
        // Actual minutes are monotonic.
        if let actual = record.planItemActualMinutes, actual > item.actualMinutes {
            item.actualMinutes = actual
        }
        if let order = record.planItemOrder { item.itemOrder = order }
        if let sourceJSON = record.planItemSource { item.sourceJSON = sourceJSON }
        if let note = record.planItemUserNote { item.userNote = note }
        if let userEdited = record.planItemUserEdited { item.userEdited = userEdited }
        item.serverVersion = serverVersion
        try context.save()
    }

    func deleteStudyPlanItemByID(_ id: UUID) throws {
        let descriptor = FetchDescriptor<StudyPlanItem>(
            predicate: #Predicate { $0.id == id }
        )
        guard let item = try context.fetch(descriptor).first else { return }
        try deleteStudyPlanItem(item)
    }

    // MARK: - Study activities

    func studyActivities(examID: UUID?) throws -> [StudyActivity] {
        let descriptor = FetchDescriptor<StudyActivity>()
        var rows = try context.fetch(descriptor)
        if let examID {
            rows = rows.filter { $0.examID == examID }
        }
        return rows.sorted { $0.startedAt > $1.startedAt }
    }

    func currentStudyActivity() throws -> StudyActivity? {
        let descriptor = FetchDescriptor<StudyActivity>()
        return try context.fetch(descriptor)
            .first { $0.status == .inProgress }
    }

    func startStudyActivity(_ draft: StudyActivityDraft) throws -> StudyActivity? {
        // The exactly-one invariant: an in-progress activity blocks a
        // new one (the UI offers to resume/finish it instead).
        if try currentStudyActivity() != nil { return nil }
        let activity = StudyActivity(
            planItemID: draft.planItemID,
            examID: draft.examID,
            courseID: draft.courseID,
            topicID: draft.topicID,
            note: draft.note
        )
        context.insert(activity)
        try context.save()
        mutationObserver?.studyActivityCreated(activity)
        return activity
    }

    func finishStudyActivity(
        _ activity: StudyActivity, status: StudyActivityStatus, note: String
    ) throws {
        guard !activity.isTerminal else { return }
        activity.finish(status: status)
        if !note.isEmpty { activity.note = note }
        activity.updatedAt = .now
        // Measured minutes flow back onto the plan item (monotonic).
        if let itemID = activity.planItemID {
            let descriptor = FetchDescriptor<StudyPlanItem>(
                predicate: #Predicate { $0.id == itemID }
            )
            if let item = try context.fetch(descriptor).first {
                try recordStudyPlanItemActualMinutes(
                    item, minutes: activity.durationSeconds / 60
                )
                if status == .completed {
                    try setStudyPlanItemStatus(item, status: .done)
                }
            }
        }
        try context.save()
        mutationObserver?.studyActivityUpdated(activity)
    }

    func pauseStudyActivity(_ activity: StudyActivity) throws {
        guard activity.status == .inProgress else { return }
        activity.pause()
        try context.save()
        // Device-local: the folded duration rides the next checkpoint.
    }

    func resumeStudyActivity(_ activity: StudyActivity) throws {
        guard activity.status == .inProgress else { return }
        activity.resume()
        try context.save()
        // Device-local, same as pause.
    }

    func checkpointStudyActivity(_ activity: StudyActivity) throws {
        guard activity.status == .inProgress else { return }
        // Fold the active stretch so far without ending the run.
        if activity.pausedAt == nil {
            activity.pause()
            activity.resume()
        }
        activity.updatedAt = .now
        try context.save()
        mutationObserver?.studyActivityUpdated(activity)
    }

    func studyActivityMinutes(on date: Date) throws -> Int {
        let dayStart = Calendar.current.startOfDay(for: date)
        let dayEnd = Calendar.current.date(
            byAdding: .day, value: 1, to: dayStart
        ) ?? dayStart
        let descriptor = FetchDescriptor<StudyActivity>()
        let rows = try context.fetch(descriptor)
        // Minutes credited to the day the activity STARTED on (a session
        // crossing midnight is one activity; honest per-day accounting
        // without splitting rows).
        var seconds = 0
        for activity in rows where activity.startedAt >= dayStart && activity.startedAt < dayEnd {
            if activity.isTerminal {
                seconds += activity.durationSeconds
            } else {
                seconds += activity.liveElapsedSeconds
            }
        }
        return seconds / 60
    }

    func studyActivities(matching query: String) throws -> [StudyActivity] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let lowered = trimmed.lowercased()
        let descriptor = FetchDescriptor<StudyActivity>()
        return try context.fetch(descriptor)
            .filter { $0.note.lowercased().contains(lowered) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    func applyRemoteStudyActivity(record: SyncServerRecordDTO, serverVersion: Int) throws {
        guard let recordID = record.id, let startedAt = record.activityStartedAt else { return }
        let descriptor = FetchDescriptor<StudyActivity>(
            predicate: #Predicate { $0.id == recordID }
        )
        let existing = try context.fetch(descriptor).first
        if let existing, existing.serverVersion >= serverVersion { return }

        let activity: StudyActivity
        if let existing {
            activity = existing
        } else {
            activity = StudyActivity(
                id: recordID,
                planItemID: record.planItemId,
                examID: record.examId,
                courseID: record.courseId,
                topicID: record.topicId,
                startedAt: startedAt
            )
            context.insert(activity)
        }
        activity.startedAt = startedAt
        activity.planItemID = record.planItemId
        activity.examID = record.examId
        activity.courseID = record.courseId
        activity.topicID = record.topicId
        if let endedAt = record.activityEndedAt { activity.endedAt = endedAt }
        // Duration merges by MAX; terminal status is sticky (never
        // resurrected by a stale in_progress record).
        if let duration = record.activityDurationSeconds, duration > activity.durationSeconds {
            activity.durationSeconds = duration
        }
        if let statusRaw = record.activityStatus,
           let status = StudyActivityStatus(rawValue: statusRaw) {
            if !activity.isTerminal {
                activity.statusRaw = status.rawValue
                if status == .inProgress {
                    activity.endedAt = nil
                }
            }
        }
        if let note = record.activityNote, !note.isEmpty { activity.note = note }
        activity.serverVersion = serverVersion
        try context.save()
    }

    func deleteStudyActivityByID(_ id: UUID) throws {
        let descriptor = FetchDescriptor<StudyActivity>(
            predicate: #Predicate { $0.id == id }
        )
        guard let activity = try context.fetch(descriptor).first else { return }
        context.delete(activity)
        try context.save()
        mutationObserver?.studyActivityDeleted(id: id)
    }

    // MARK: - Helpers

    /// Clears planItemID on an item's activities before the item dies.
    private func detachActivities(ofItem itemID: UUID) throws {
        let activities = try context.fetch(FetchDescriptor<StudyActivity>(
            predicate: #Predicate { $0.planItemID == itemID }
        ))
        for activity in activities {
            activity.planItemID = nil
            activity.updatedAt = .now
            mutationObserver?.studyActivityUpdated(activity)
        }
    }

    private static func encodeRestDays(_ days: [Int]) -> String {
        guard let data = try? JSONEncoder().encode(days),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    private static func encodeUUIDs(_ ids: [UUID]) -> String {
        guard let data = try? JSONEncoder().encode(ids),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    private static func encodeBlockedTimes(_ times: [StudyBlockedTime]) -> String {
        guard let data = try? JSONEncoder().encode(times),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }
}
