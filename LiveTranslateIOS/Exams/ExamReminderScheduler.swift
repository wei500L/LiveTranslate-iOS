import Foundation
import UserNotifications

/// Local-notification reminders for the exam center — the 考试提醒 /
/// 今日学习提醒 layer. Fully local like TaskReminderScheduler and
/// ClassReminderScheduler (notification state NEVER syncs).
///
/// Scheduling model:
/// - EXAM reminders: one per user-armed exam, lead chosen by the user
///   (-1 = off). Rescheduled/cancelled on date change, completion and
///   cancellation. Candidates (status pending) are NEVER armed.
/// - STUDY reminders: at most ONE daily summary notification (今日学习),
///   never one notification per plan item; fire time chosen by the user
///   (default 19:00); the body counts today's real plan items — computed
///   when the user arms it (a static count would go stale; the honest
///   message is "查看今天的安排" plus the count at arm time).
/// - Authorization is requested ONLY on the user's explicit toggle.
/// - Account switch: `cancelAll()` (AppSession calls it next to the
///   other schedulers).
@MainActor
final class ExamReminderScheduler {
    /// Lead choices offered in the UI (raw = minutes; -1 = off).
    enum Lead: Int, CaseIterable, Identifiable {
        case off = -1
        case atStart = 0
        case thirty = 30
        case hour = 60
        case threeHours = 180
        case oneDay = 1440
        case threeDays = 4320
        case oneWeek = 10080

        var id: Int { rawValue }

        var displayName: String {
            switch self {
            case .off: return "不提醒"
            case .atStart: return "考试当天"
            case .thirty: return "提前 30 分钟"
            case .hour: return "提前 1 小时"
            case .threeHours: return "提前 3 小时"
            case .oneDay: return "提前 1 天"
            case .threeDays: return "提前 3 天"
            case .oneWeek: return "提前 1 周"
            }
        }
    }

    private let defaults: UserDefaults
    /// exam UUID string → lead minutes. Absent = no reminder.
    private var examLeads: [String: Int]
    /// Daily study-summary reminder (nil = off).
    private var studyReminderMinuteOfDay: Int?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let stored = try? JSONDecoder().decode(State.self, from: data) {
            examLeads = stored.examLeads
            studyReminderMinuteOfDay = stored.studyReminderMinuteOfDay
        } else {
            examLeads = [:]
            studyReminderMinuteOfDay = nil
        }
    }

    var center: UNUserNotificationCenter { .current() }

    private struct State: Codable {
        var examLeads: [String: Int]
        var studyReminderMinuteOfDay: Int?
    }

    private func persist() {
        let state = State(
            examLeads: examLeads,
            studyReminderMinuteOfDay: studyReminderMinuteOfDay
        )
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    // MARK: - Authorization (user-initiated only)

    var isAuthorized: Bool {
        get async {
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                return true
            default:
                return false
            }
        }
    }

    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default:
            return false
        }
    }

    // MARK: - Exam reminders

    func lead(examID: UUID) -> Lead {
        Lead(rawValue: examLeads[examID.uuidString] ?? -1) ?? .off
    }

    /// Arms (or re-arms) one exam's reminder. Returns false when the
    /// user denied notifications or the exam has no usable date/time.
    @discardableResult
    func enable(exam: Exam, lead: Lead) async -> Bool {
        guard exam.status != .pending else { return false }
        guard lead != .off else {
            disable(examID: exam.id)
            return true
        }
        // The fire anchor: the exam's start moment when the time is
        // known, otherwise the exam DAY's morning (09:00 — an honest
        // "today is the day" reminder, never a fake time).
        let fireAnchor: Date
        if let start = exam.startDateTime {
            fireAnchor = start
        } else if let day = exam.examDate {
            fireAnchor = Calendar.current.date(
                bySettingHour: 9, minute: 0, second: 0, of: day
            ) ?? day
        } else {
            return false
        }
        let fireDate = fireAnchor.addingTimeInterval(-TimeInterval(lead.rawValue) * 60)
        guard fireDate > .now else {
            // The lead already passed: remember the choice but schedule
            // nothing (a past fire date never fires).
            examLeads[exam.id.uuidString] = lead.rawValue
            persist()
            return true
        }
        guard await requestAuthorizationIfNeeded() else { return false }
        examLeads[exam.id.uuidString] = lead.rawValue
        persist()

        let content = UNMutableNotificationContent()
        content.title = "考试提醒"
        // Round 17: hideSensitiveContent strips exam title + room from
        // the body.
        if SettingsStore.shared.systemSurfacePrivacy.showsTitles {
            var body = exam.title
            if !exam.location.isEmpty { body += " · \(exam.location)" }
            content.body = body
        } else {
            content.body = "有一场考试临近"
        }
        content.sound = .default
        content.categoryIdentifier = Self.categoryID
        content.userInfo = [Self.examIDUserInfo: exam.id.uuidString]

        center.removePendingNotificationRequests(
            withIdentifiers: [Self.notificationID(exam.id)]
        )
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        try? await center.add(UNNotificationRequest(
            identifier: Self.notificationID(exam.id), content: content, trigger: trigger
        ))
        return true
    }

    /// Disables and cancels one exam's reminder.
    func disable(examID: UUID) {
        examLeads[examID.uuidString] = nil
        persist()
        center.removePendingNotificationRequests(
            withIdentifiers: [Self.notificationID(examID)]
        )
    }

    /// Cancels every exam + study reminder (exam deleted, account
    /// switch — the caller rebuilds the new account's state).
    func cancelAll() {
        let ids = examLeads.keys.map { "exam.reminder.\($0)" }
        if !ids.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
        center.removePendingNotificationRequests(
            withIdentifiers: [Self.studyNotificationID]
        )
        examLeads = [:]
        studyReminderMinuteOfDay = nil
        persist()
    }

    // MARK: - Daily study summary

    var studyReminderEnabled: Bool { studyReminderMinuteOfDay != nil }

    var studyReminderMinute: Int { studyReminderMinuteOfDay ?? 19 * 60 }

    /// Arms the single daily study summary (今日学习提醒). The body is
    /// intentionally generic — the real item list lives in the app.
    @discardableResult
    func enableStudyReminder(minuteOfDay: Int) async -> Bool {
        guard await requestAuthorizationIfNeeded() else { return false }
        studyReminderMinuteOfDay = minuteOfDay
        persist()
        await scheduleStudyReminder()
        return true
    }

    func disableStudyReminder() {
        studyReminderMinuteOfDay = nil
        persist()
        center.removePendingNotificationRequests(
            withIdentifiers: [Self.studyNotificationID]
        )
    }

    private func scheduleStudyReminder() async {
        center.removePendingNotificationRequests(
            withIdentifiers: [Self.studyNotificationID]
        )
        guard let minuteOfDay = studyReminderMinuteOfDay else { return }
        let content = UNMutableNotificationContent()
        content.title = "今日学习"
        content.body = "看看今天的复习安排"
        content.sound = .default
        content.categoryIdentifier = Self.studyCategoryID
        var components = DateComponents()
        components.hour = minuteOfDay / 60
        components.minute = minuteOfDay % 60
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        try? await center.add(UNNotificationRequest(
            identifier: Self.studyNotificationID, content: content, trigger: trigger
        ))
    }

    // MARK: - Wire constants (shared with NotificationRouter)

    nonisolated static let categoryID = "EXAM_REMINDER"
    nonisolated static let studyCategoryID = "STUDY_PLAN_REMINDER"
    nonisolated static let examIDUserInfo = "examID"

    private static func notificationID(_ examID: UUID) -> String {
        "exam.reminder.\(examID.uuidString)"
    }

    private static let studyNotificationID = "study.plan.daily"

    private static let storageKey = "exam.reminderState"
}
