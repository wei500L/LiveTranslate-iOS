import Foundation
import Observation
import AVFAudio

/// Shared engine for the pre-class layer: computes today's/this week's
/// occurrences, the next class, and runs the CONTROLLED schedule start
/// (the single start chain — mic + resource checks, duplicate guard,
/// occurrence attribution). HomeScreen's next-class card, the timetable
/// pages and CourseDetailView all drive through this; no page builds its
/// own occurrence math (ScheduleCalculator is the only algorithm).
@MainActor
@Observable
final class ScheduleViewModel {
    private weak var environment: AppEnvironment?

    // MARK: - State

    /// Schedules + exceptions as of the last reload.
    private(set) var schedules: [CourseSchedule] = []
    private(set) var exceptions: [ScheduleException] = []
    private(set) var courses: [Course] = []
    private var courseByID: [UUID: Course] = [:]

    /// The window of computed occurrences [today, today+8d), ascending by
    /// start. Cancelled occurrences included (the timetable shows them).
    private(set) var occurrences: [ScheduleCalculator.Occurrence] = []

    var isLoaded = false
    /// Presentation minute tick (minute-level UI refresh only — no
    /// per-second countdown battery drain).
    var now = Date()

    // MARK: - Lifecycle

    func attach(_ environment: AppEnvironment) {
        self.environment = environment
    }

    /// Reloads rules, exceptions, courses and the occurrence window, and
    /// snaps `now` to the current minute.
    func reload() async {
        guard let environment else { return }
        schedules = (try? environment.repository.schedules(courseID: nil)) ?? []
        exceptions = (try? environment.repository.allExceptions()) ?? []
        courses = (try? environment.repository.courses()) ?? []
        courseByID = Dictionary(uniqueKeysWithValues: courses.map { ($0.id, $0) })

        let windowStart = now
        let windowEnd = windowStart.addingTimeInterval(8 * 86_400)
        var computed: [ScheduleCalculator.Occurrence] = []
        for schedule in schedules {
            computed.append(contentsOf: ScheduleCalculator.occurrences(
                of: schedule, from: windowStart, to: windowEnd, exceptions: exceptions
            ))
        }
        computed.sort { $0.start < $1.start }
        occurrences = computed
        now = Date()
        isLoaded = true
    }

    /// Minute-level tick for relative-time labels.
    func tick() {
        now = Date()
    }

    // MARK: - Course resolution

    func course(for occurrence: ScheduleCalculator.Occurrence) -> Course? {
        occurrence.courseID.flatMap { courseByID[$0] }
    }

    /// Effective teacher: exception override → schedule override → course.
    func teacher(for occurrence: ScheduleCalculator.Occurrence) -> String {
        let courseTeacher = course(for: occurrence)?.teacherName ?? ""
        return ScheduleCalculator.effectiveTeacher(occurrence: occurrence, courseTeacher: courseTeacher)
    }

    /// Effective location: exception override → schedule override → course.
    func location(for occurrence: ScheduleCalculator.Occurrence) -> String {
        let courseLocation = course(for: occurrence)?.location ?? ""
        return ScheduleCalculator.effectiveLocation(occurrence: occurrence, courseLocation: courseLocation)
    }

    var courseColorIndex: (ScheduleCalculator.Occurrence) -> Int {
        { [weak self] occurrence in self?.course(for: occurrence)?.colorIndex ?? 0 }
    }

    /// Whether the schedule row backing an occurrence still exists (a
    /// deleted rule leaves history dangling — the UI shows 来源已不存在).
    func scheduleExists(for occurrence: ScheduleCalculator.Occurrence) -> Bool {
        schedules.contains { $0.id == occurrence.scheduleID }
    }

    // MARK: - Day slicing

    /// Occurrences on one calendar day (in the device zone for display).
    func occurrences(on day: Date) -> [ScheduleCalculator.Occurrence] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        return occurrences.filter { $0.start >= dayStart && $0.start < nextDay }
    }

    /// Today's occurrences, ascending.
    var todayOccurrences: [ScheduleCalculator.Occurrence] {
        occurrences(on: now)
    }

    /// This week (Mon–Sun of the current device week), grouped per day.
    var weekDays: [(day: Date, items: [ScheduleCalculator.Occurrence])] {
        let calendar = Calendar.current
        var comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        comps.weekday = 2 // Monday
        guard let monday = calendar.date(from: comps) else { return [] }
        return (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: monday) else { return nil }
            return (day, occurrences(on: day))
        }
    }

    // MARK: - Next class

    /// The next class worth surfacing: the first non-cancelled occurrence
    /// whose end is still ahead (an in-progress class counts — the user
    /// may be late), today or later. Nil when nothing is upcoming.
    var nextOccurrence: ScheduleCalculator.Occurrence? {
        occurrences.first { !$0.isCancelled && $0.end > now }
    }

    /// Relative label for the next class card. Minute-level only.
    func relativeLabel(for occurrence: ScheduleCalculator.Occurrence) -> String {
        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: occurrence.start)
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: today, to: startDay).day ?? 0
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated

        if occurrence.isCancelled { return "已停课" }
        if occurrence.isTimeChanged { /* the time label itself shows 调课 */ }
        if now < occurrence.start {
            if days == 0 {
                if let text = formatter.string(from: now.distance(to: occurrence.start)) {
                    return "\(text)后上课"
                }
                return "即将开始"
            }
            if days == 1 { return "明天" }
            return "\(days) 天后"
        }
        if now < occurrence.end {
            let late = now.timeIntervalSince(occurrence.start)
            if late > 600 {
                return "已迟到 · 正在上课"
            }
            return "正在上课"
        }
        return "已结束"
    }

    /// Unfinished task count of the occurrence's course (今日课程联动).
    func openTaskCount(for occurrence: ScheduleCalculator.Occurrence) -> Int {
        guard let environment, let courseID = occurrence.courseID else { return 0 }
        let tasks = (try? environment.repository.tasks(courseID: courseID, includeDone: false)) ?? []
        return tasks.filter { $0.status == .pending }.count
    }

    // MARK: - Session matching (duplicate guard + 返回课堂)

    /// Sessions attached to an occurrence (schedule-launched only).
    func sessions(for occurrence: ScheduleCalculator.Occurrence) -> [ClassroomSession] {
        guard let environment else { return [] }
        return (try? environment.repository.sessions(occurrenceKey: occurrence.occurrenceKey)) ?? []
    }

    enum OccurrenceStartState {
        /// Nothing recorded for this class — 开始记录 available.
        case canStart
        /// A session is in progress — return to it (never a second one).
        case returnToSession(ClassroomSession)
        /// A session already finished — offer, but ask before another.
        case finishedSession(ClassroomSession)
    }

    /// The start state for an occurrence: duplicate-start protection and
    /// 返回课堂 routing.
    func startState(for occurrence: ScheduleCalculator.Occurrence) -> OccurrenceStartState {
        let sessions = sessions(for: occurrence)
        if let ongoing = sessions.first(where: { $0.endTime == nil }) {
            return .returnToSession(ongoing)
        }
        if let last = sessions.last(where: { $0.endTime != nil }) {
            return .finishedSession(last)
        }
        return .canStart
    }

    /// The coordinator's ongoing session (a manual start unrelated to the
    /// occurrence still blocks starting a second one).
    var hasOngoingCoordinatorSession: Bool {
        environment?.coordinator.isRunning ?? false
    }

    // MARK: - Controlled start (the single chain)

    /// Suggested course title for a schedule-launched session: course
    /// name + date (user-editable afterwards in the live screen's rename).
    static func sessionTitle(
        for occurrence: ScheduleCalculator.Occurrence, courseName: String
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return "\(courseName) · \(formatter.string(from: occurrence.start))"
    }

    /// Starts the class through the FULL existing chain: mic permission,
    /// resource check, duplicate guard, then the coordinator's
    /// `start(title:courseID:schedule:)`. Returns the course to preselect
    /// in NewSessionSheet when the caller should fall back to the form
    /// (permissions missing / resources missing / start failed) — the form
    /// re-runs the complete validation; no second start logic exists here.
    ///
    /// `force` bypasses the finished-session prompt only when the user
    /// explicitly confirmed an additional session.
    @discardableResult
    func startOccurrence(
        _ occurrence: ScheduleCalculator.Occurrence, force: Bool = false
    ) async -> Course? {
        guard let environment else { return nil }

        // Duplicate guard.
        switch startState(for: occurrence) {
        case .returnToSession:
            // Never a second classroom for one occurrence — return to it.
            environment.presentLive()
            return nil
        case .finishedSession:
            guard force else { return nil }
        case .canStart:
            break
        }
        if hasOngoingCoordinatorSession { return nil }

        // Learning-timer guard: a running study activity is paused
        // honestly before the classroom recording starts (课堂录音时间
        // 不计入学习时长). The pause is checkpointed so its minutes stay.
        if environment.studyActivityTracker.hasActiveActivity {
            environment.studyActivityTracker.pause()
            LTHaptics.warning()
        }

        // Permission + resource checks (same gates as quickStart).
        if !environment.capabilities.assumesMicrophoneAuthorized {
            let permission = AVAudioApplication.shared.recordPermission
            if permission != .granted { return course(for: occurrence) }
        }
        let backend = environment.settings.preferredBackend
        let installed = await environment.engineManager.isInstalled(backend)
        guard installed else { return course(for: occurrence) }

        let courseName = course(for: occurrence)?.name ?? "课堂"
        let context = ScheduleSessionContext(
            scheduleID: occurrence.scheduleID,
            occurrenceKey: occurrence.occurrenceKey,
            plannedStart: occurrence.start
        )
        await environment.coordinator.start(
            title: Self.sessionTitle(for: occurrence, courseName: courseName),
            courseID: occurrence.courseID,
            schedule: context
        )
        if environment.coordinator.isRunning {
            environment.presentLive()
            // The occurrence now has a session — refresh the attribution.
            await reload()
            await environment.refreshClassReminders()
            return nil
        }
        // The start failed (engine load etc.) — the form explains why.
        return course(for: occurrence)
    }

    // MARK: - NewSessionSheet auto-suggest

    /// Suggests occurrences near `now` for the manual new-classroom flow:
    /// starting within 30 minutes, in progress, or started less than
    /// 15 minutes ago. Suggestions only — the user picks, nothing
    /// auto-starts. Overlapping candidates all surface (the user chooses).
    func suggestOccurrencesForNewSession() -> [ScheduleCalculator.Occurrence] {
        let window: TimeInterval = 30 * 60
        let grace: TimeInterval = 15 * 60
        return occurrences.filter { occurrence in
            guard !occurrence.isCancelled else { return false }
            let status = ScheduleCalculator.status(of: occurrence, at: now)
            switch status {
            case .upcoming:
                return occurrence.start.timeIntervalSince(now) <= window
            case .inProgress:
                return now.timeIntervalSince(occurrence.start) <= 90 * 60
            case .ended:
                return now.timeIntervalSince(occurrence.end) <= grace
            }
        }
    }

    // MARK: - Scheduling mutations (timetable edit flows)

    func addSchedule(_ draft: ScheduleDraft) {
        guard let environment else { return }
        _ = try? environment.repository.addSchedule(draft)
        Task { await reloadAndRefreshReminders() }
    }

    func updateSchedule(_ schedule: CourseSchedule, with draft: ScheduleDraft) {
        guard let environment else { return }
        try? environment.repository.updateSchedule(schedule, with: draft)
        Task { await reloadAndRefreshReminders() }
    }

    func setScheduleEnabled(_ schedule: CourseSchedule, isEnabled: Bool) {
        guard let environment else { return }
        try? environment.repository.setScheduleEnabled(schedule, isEnabled: isEnabled)
        Task { await reloadAndRefreshReminders() }
    }

    func deleteSchedule(_ schedule: CourseSchedule) {
        guard let environment else { return }
        try? environment.repository.deleteSchedule(schedule)
        Task { await reloadAndRefreshReminders() }
    }

    func addException(_ draft: ScheduleExceptionDraft) {
        guard let environment else { return }
        _ = try? environment.repository.addException(draft)
        Task { await reloadAndRefreshReminders() }
    }

    func updateException(_ exception: ScheduleException, with draft: ScheduleExceptionDraft) {
        guard let environment else { return }
        try? environment.repository.updateException(exception, with: draft)
        Task { await reloadAndRefreshReminders() }
    }

    func deleteException(_ exception: ScheduleException) {
        guard let environment else { return }
        try? environment.repository.deleteException(exception)
        Task { await reloadAndRefreshReminders() }
    }

    /// Reload + reminder re-arm after any rule mutation (the rolling
    /// window must drop cancelled/adjusted notifications).
    private func reloadAndRefreshReminders() async {
        await reload()
        await environment?.refreshClassReminders()
    }
}
