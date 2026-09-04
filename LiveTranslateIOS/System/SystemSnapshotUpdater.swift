import Foundation
import OSLog
import Observation

/// Assembles the App Group system snapshot from REAL state (the
/// coordinator, the study tracker, the repository, the inbox) and writes
/// it atomically. Owned by the AppEnvironment; rebuilt per profile (its
/// output is scope-filtered by construction).
///
/// The snapshot is the single source of widget data — the extension never
/// assembles business data itself. Regeneration is event-driven (phase /
/// pause / translation changes, foreground entry, data mutations) and
/// throttled: never on audio levels, never per transcript entry beyond
/// the latest-Chinese line's bounded update cadence.
@MainActor
final class SystemSnapshotUpdater {
    private static let logger = Logger(
        subsystem: "com.livetranslate.ios", category: "system-snapshot"
    )

    private let repository: any ClassroomRepositoryProtocol
    private let scopeKey: String
    /// Live translation-service configuration probe (read at snapshot
    /// time so a settings change applies on the next update).
    /// MainActor-isolated: it reads the environment's live service.
    private let isTranslationConfigured: @MainActor () -> Bool
    private let store: SystemSnapshotStore
    /// Whether the App Group is available at all (nil container = system
    /// integration honestly off).
    private(set) var isAvailable: Bool

    init(
        repository: any ClassroomRepositoryProtocol,
        scopeKey: String,
        isTranslationConfigured: @escaping @MainActor () -> Bool
    ) {
        self.repository = repository
        self.scopeKey = scopeKey
        self.isTranslationConfigured = isTranslationConfigured
        self.store = SystemSnapshotStore()
        self.isAvailable = SystemSnapshotStore.containerURL != nil
    }

    // MARK: - Writes

    /// Full regeneration + persist. Callers pass the live classroom /
    /// study state; everything else is re-derived from the repository.
    @discardableResult
    func update(
        coordinator: (any LiveTranslationCoordinating)? = nil,
        studyTracker: StudyActivityTracker? = nil,
        inboxPendingCount: Int = 0,
        privacy: LockScreenPrivacy = .statusAndTitle
    ) -> WidgetSnapshot {
        let snapshot = build(
            coordinator: coordinator,
            studyTracker: studyTracker,
            inboxPendingCount: inboxPendingCount,
            privacy: privacy
        )
        store.save(snapshot)
        return snapshot
    }

    /// Account switch / profile teardown: the old profile's data leaves
    /// the App Group before the new profile's snapshot ever lands.
    func clear() {
        store.clear()
    }

    // MARK: - Assembly

    private func build(
        coordinator: (any LiveTranslationCoordinating)?,
        studyTracker: StudyActivityTracker?,
        inboxPendingCount: Int,
        privacy: LockScreenPrivacy
    ) -> WidgetSnapshot {
        var classroom: WidgetClassroom?
        if let coordinator, coordinator.isRunning,
           let sessionID = coordinator.activeSessionID {
            // Effective seconds: the coordinator's elapsed is already
            // wall-clock-minus-pauses; the live stretch anchor lets the
            // system-driven timer continue from the last push.
            let accumulated = Int(coordinator.state.elapsed)
            let latestChinese: String
            if privacy == .statusTitleAndLatestText {
                latestChinese = Self.latestCompletedChinese(coordinator)
            } else {
                latestChinese = ""
            }
            classroom = WidgetClassroom(
                sessionID: sessionID,
                title: coordinator.activeSessionTitle ?? "课堂",
                startedAt: Date().addingTimeInterval(-TimeInterval(accumulated)),
                accumulatedSeconds: accumulated,
                isPaused: coordinator.isPaused,
                activeSince: coordinator.isPaused ? nil : .now,
                isRecording: coordinator.isRunning && !coordinator.isPaused,
                isTranscribing: coordinator.isRunning,
                translationState: translationState(coordinator).rawValue,
                latestChinese: String(latestChinese.prefix(160))
            )
        }

        var study: WidgetStudyActivity?
        if let studyTracker, let activity = studyTracker.currentActivity,
           activity.status == .inProgress {
            study = WidgetStudyActivity(
                activityID: activity.id,
                planItemID: activity.planItemID,
                title: studyTitle(activity),
                courseName: studyCourseName(activity),
                startedAt: activity.startedAt,
                accumulatedSeconds: activity.durationSeconds,
                activeSince: studyTracker.isPaused ? nil : .now,
                isPaused: studyTracker.isPaused,
                estimatedMinutes: studyEstimatedMinutes(activity)
            )
        }

        return WidgetSnapshot(
            schemaVersion: WidgetSnapshot.schemaVersion,
            scopeKey: scopeKey,
            generatedAt: .now,
            classroom: classroom,
            study: study,
            nextClass: nextClassOccurrence(),
            nextExam: nextScheduledExam(),
            today: todayPlanAggregate(),
            inboxPendingCount: inboxPendingCount,
            privacy: privacy
        )
    }

    // MARK: - Derived data (real repository queries)

    /// Next class: the same first non-cancelled occurrence with a future
    /// end the app's schedule layer computes. 8-day window, ascending.
    private func nextClassOccurrence() -> WidgetNextClass? {
        guard let schedules = try? repository.schedules(courseID: nil),
              let exceptions = try? repository.allExceptions() else { return nil }
        let courses = (try? repository.courses()) ?? []
        var names: [UUID: String] = [:]
        for course in courses { names[course.id] = course.name }
        let now = Date()
        let windowEnd = now.addingTimeInterval(8 * 86_400)
        var best: WidgetNextClass?
        for schedule in schedules {
            let occurrences = ScheduleCalculator.occurrences(
                of: schedule, from: now, to: windowEnd, exceptions: exceptions
            )
            for occurrence in occurrences where !occurrence.isCancelled && occurrence.end > now {
                let courseName = occurrence.courseID.flatMap { names[$0] } ?? "课程"
                let candidate = WidgetNextClass(
                    occurrenceKey: occurrence.occurrenceKey,
                    courseName: courseName,
                    start: occurrence.start,
                    end: occurrence.end,
                    location: occurrence.location ?? "",
                    isCancelled: occurrence.isCancelled,
                    isTimeChanged: occurrence.isTimeChanged
                )
                if best == nil || candidate.start < best!.start {
                    best = candidate
                }
            }
        }
        return best
    }

    /// Next scheduled exam within 14 days (same semantics as home).
    private func nextScheduledExam() -> WidgetNextExam? {
        guard let exams = try? repository.exams(courseID: nil, includeCandidates: false) else {
            return nil
        }
        let candidates = exams.filter { exam in
            guard exam.status == .scheduled, let days = exam.daysUntilExam else { return false }
            return days >= 0 && days <= 14
        }
        guard let exam = candidates.min(by: {
            ($0.examDate ?? .distantFuture) < ($1.examDate ?? .distantFuture)
        }) else { return nil }
        let courseName = exam.courseID.flatMap { courseID in
            (try? repository.course(id: courseID)).flatMap { $0 }?.name
        } ?? ""
        return WidgetNextExam(
            examID: exam.id,
            title: exam.title,
            courseName: courseName,
            examDate: exam.examDate ?? .now,
            daysUntil: exam.daysUntilExam ?? 0
        )
    }

    /// Today's plan aggregate (same shape the review center computes).
    private func todayPlanAggregate() -> WidgetTodayStudy {
        let todayKey = Exam.dateKey(.now)
        guard let plans = try? repository.studyPlans(examID: nil) else {
            return WidgetTodayStudy(
                planTotal: 0, planDone: 0, nextItemTitle: "", nextItemEstimatedMinutes: 0
            )
        }
        var items: [StudyPlanItem] = []
        for plan in plans where plan.status == .active {
            items += (try? repository.studyPlanItems(planID: plan.id)) ?? []
        }
        let todayItems = items
            .filter { $0.itemDateKey == todayKey && $0.status != .skipped }
            .sorted { $0.itemOrder < $1.itemOrder }
        let done = todayItems.filter { $0.status == .done }.count
        let next = todayItems.first { $0.status != .done }
        return WidgetTodayStudy(
            planTotal: todayItems.count,
            planDone: done,
            nextItemTitle: next?.title ?? "",
            nextItemEstimatedMinutes: next?.estimatedMinutes ?? 0
        )
    }

    // MARK: - Helpers

    /// The latest completed Chinese translation (privacy-filtered later).
    private static func latestCompletedChinese(
        _ coordinator: any LiveTranslationCoordinating
    ) -> String {
        coordinator.entries
            .last { $0.translationStatus == .completed }
            .flatMap { $0.translatedText } ?? ""
    }

    private func translationState(
        _ coordinator: any LiveTranslationCoordinating
    ) -> LiveTranslationHealth {
        switch coordinator.state.phase {
        case .networkOffline:
            return .waitingForNetwork
        default:
            return isTranslationConfigured() ? .available : .notConfigured
        }
    }

    private func studyTitle(_ activity: StudyActivity) -> String {
        if let itemID = activity.planItemID,
           let item = try? repository.studyPlanItem(id: itemID) {
            return item.title
        }
        if let examID = activity.examID,
           let exam = try? repository.exam(id: examID) {
            return exam.title
        }
        return "自主学习"
    }

    private func studyCourseName(_ activity: StudyActivity) -> String {
        let courseID = activity.courseID
            ?? activity.planItemID.flatMap { itemID in
                (try? repository.studyPlanItem(id: itemID)).flatMap { $0 }?
                    .examID.flatMap { (try? repository.exam(id: $0)).flatMap { $0 }?.courseID }
            }
        guard let courseID,
              let course = try? repository.course(id: courseID) else { return "" }
        return course.name
    }

    private func studyEstimatedMinutes(_ activity: StudyActivity) -> Int {
        activity.planItemID.flatMap { itemID in
            (try? repository.studyPlanItem(id: itemID)).flatMap { $0 }?.estimatedMinutes
        } ?? 0
    }
}
