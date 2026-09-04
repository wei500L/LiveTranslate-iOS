import Foundation
import UserNotifications

/// Local-notification reminders for course schedules — the 上课提醒
/// layer. Fully local like TaskReminderScheduler: the reminder lead is
/// part of the schedule row (synced), but WHICH occurrences are armed is
/// a per-device rolling window — iOS caps pending notifications, so the
/// whole semester is never pre-scheduled.
///
/// Scheduling model:
/// - A rolling window (next 14 days) is (re)computed on app launch, on
///   foreground entry and after schedule/exception mutations.
/// - Armed occurrence keys are recorded in account-scoped defaults; a
///   re-run cancels stale ids and arms missing ones — idempotent.
/// - Cancelled/adjusted occurrences are handled by the same recompute:
///   the old notification id goes away when its occurrence disappears
///   from the window's armed set.
/// - The notification id embeds the occurrence key, so tapping routes to
///   the exact class (NotificationRouter).
/// - No authorization: the timetable still works, reminders just don't.
@MainActor
final class ClassReminderScheduler {
    /// Lead choices offered in the UI (raw = minutes; -1 = off).
    enum Lead: Int, CaseIterable, Identifiable {
        case off = -1
        case atStart = 0
        case ten = 10
        case fifteen = 15
        case thirty = 30
        case hour = 60

        var id: Int { rawValue }

        var displayName: String {
            switch self {
            case .off: return "不提醒"
            case .atStart: return "上课时"
            case .ten: return "提前 10 分钟"
            case .fifteen: return "提前 15 分钟"
            case .thirty: return "提前 30 分钟"
            case .hour: return "提前 1 小时"
            }
        }
    }

    static let defaultLead: Lead = .fifteen

    /// Days of occurrences kept armed ahead of now (rolling).
    static let windowDays = 14

    private let defaults: UserDefaults
    /// Occurrence keys currently armed on this device (the record of
    /// what was scheduled — NOT a fake "reminder state").
    private var armedKeys: Set<String>

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let stored = try? JSONDecoder().decode([String].self, from: data) {
            armedKeys = Set(stored)
        } else {
            armedKeys = []
        }
    }

    var center: UNUserNotificationCenter { .current() }

    /// Whether the user has granted (or provisionally granted)
    /// notifications. False when denied — the timetable keeps working.
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

    /// Asks for permission on the user's explicit toggle only.
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

    /// Recomputes the rolling window: cancels armed notifications whose
    /// occurrences are gone (schedule deleted/paused, class cancelled,
    /// window moved on) and arms the missing ones. Called on launch,
    /// foreground entry and after schedule mutations. A denied
    /// authorization simply cancels everything and records an empty set.
    func refresh(
        schedules: [CourseSchedule], exceptions: [ScheduleException],
        courseName: (UUID) -> String?
    ) async {
        guard await isAuthorized else {
            if !armedKeys.isEmpty {
                cancelAll()
            }
            return
        }

        // Compute the window's occurrences across every live schedule.
        let windowStart = Date()
        let windowEnd = windowStart.addingTimeInterval(
            TimeInterval(Self.windowDays) * 86_400
        )
        var desired: [String: (occurrence: ScheduleCalculator.Occurrence, schedule: CourseSchedule)] = [:]
        for schedule in schedules where schedule.isEnabled && schedule.reminderLeadMins >= 0 {
            let occurrences = ScheduleCalculator.occurrences(
                of: schedule,
                from: windowStart,
                to: windowEnd,
                exceptions: exceptions
            )
            for occurrence in occurrences where !occurrence.isCancelled {
                desired[occurrence.occurrenceKey] = (occurrence, schedule)
            }
        }

        // Cancel stale ids: armed keys no longer desired.
        let stale = armedKeys.subtracting(desired.keys)
        if !stale.isEmpty {
            let ids = stale.map { Self.notificationID($0) }
            center.removePendingNotificationRequests(withIdentifiers: ids)
            armedKeys.subtract(stale)
        }

        // Arm missing occurrences whose fire time is still ahead.
        var toPersist = false
        for (key, entry) in desired where !armedKeys.contains(key) {
            let lead = entry.schedule.reminderLeadMins
            let fireDate = entry.occurrence.start
                .addingTimeInterval(-TimeInterval(lead) * 60)
            guard fireDate > windowStart else { continue }
            if scheduleNotification(
                key: key, occurrence: entry.occurrence,
                schedule: entry.schedule, fireDate: fireDate,
                courseName: courseName(entry.occurrence.courseID ?? UUID())
                    ?? courseName(entry.schedule.courseID ?? UUID())
            ) {
                armedKeys.insert(key)
                toPersist = true
            }
        }
        if toPersist || !stale.isEmpty {
            persist()
        }
    }

    /// Cancels every armed reminder (schedule deleted/paused or account
    /// switch — the caller rebuilds the new account's window right after).
    func cancelAll() {
        let ids = armedKeys.map { Self.notificationID($0) }
        if !ids.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
        armedKeys = []
        persist()
    }

    private func scheduleNotification(
        key: String,
        occurrence: ScheduleCalculator.Occurrence,
        schedule: CourseSchedule,
        fireDate: Date,
        courseName: String
    ) -> Bool {
        let content = UNMutableNotificationContent()
        content.title = "上课提醒"
        var body = courseName
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = ScheduleCalculator.zone(schedule)
        formatter.dateFormat = "HH:mm"
        body += " · " + formatter.string(from: occurrence.start)
        if let location = occurrence.location, !location.isEmpty {
            body += " · " + location
        }
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.categoryID
        // Route target: the occurrence key + fire context.
        content.userInfo = [
            Self.occurrenceKeyUserInfo: key,
            Self.scheduleIDUserInfo: schedule.id.uuidString
        ]

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(
            identifier: Self.notificationID(key), content: content, trigger: trigger
        )
        center.add(request)
        return true
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(Array(armedKeys)) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    // MARK: - Wire constants (shared with NotificationRouter)

    nonisolated static let categoryID = "COURSE_REMINDER"
    nonisolated static let startActionID = "START_CLASS"
    nonisolated static let occurrenceKeyUserInfo = "occurrenceKey"
    static let scheduleIDUserInfo = "scheduleID"

    private static func notificationID(_ occurrenceKey: String) -> String {
        "class.reminder.\(occurrenceKey)"
    }

    private static let storageKey = "schedule.armedReminders"
}

// MARK: - iOS pending-notification cap awareness

extension ClassReminderScheduler {
    /// Rough cap check: the system's soft limit on pending notifications
    /// per app. The rolling window (14 days × a handful of schedules)
    /// stays far below it; a schedule-heavy user is bounded by the window,
    /// never by the semester.
    static let pendingNotificationSoftCap = 64
}
