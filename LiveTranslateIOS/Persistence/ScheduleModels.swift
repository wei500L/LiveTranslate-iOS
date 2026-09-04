import Foundation
import SwiftData

/// How a recurring course schedule repeats. Odd/even weeks are resolved
/// against the schedule's own `weekParityAnchor` (the Monday that starts
/// week 1 of the term) and `firstWeekIsOdd` — never against the natural
/// calendar week number (semester weeks do not start in January).
enum ScheduleRecurrence: String, Codable, Sendable, CaseIterable {
    /// Every week within the semester range.
    case weekly
    /// Every second week, counting from the parity anchor's week 1.
    case biweekly
    /// Odd semester weeks only.
    case oddWeeks = "odd_weeks"
    /// Even semester weeks only.
    case evenWeeks = "even_weeks"
    /// A single dated class (recurrence carries no rule; `onceDate` is
    /// the one date it runs).
    case once

    var displayName: String {
        switch self {
        case .weekly: return "每周"
        case .biweekly: return "每两周"
        case .oddWeeks: return "仅单周"
        case .evenWeeks: return "仅双周"
        case .once: return "单次"
        }
    }
}

/// One dated deviation of a schedule: a cancelled class, a moved/resized
/// one, a relocated one, or an ad-hoc extra class (no original date).
enum ScheduleExceptionKind: String, Codable, Sendable, CaseIterable {
    case cancelled
    case timeChanged = "time_changed"
    case adHoc = "ad_hoc"

    var displayName: String {
        switch self {
        case .cancelled: return "停课"
        case .timeChanged: return "调课"
        case .adHoc: return "临时加课"
        }
    }
}

/// A recurring course schedule rule ("Monday 10:30–12:05, odd weeks, this
/// semester"). Occurrences are COMPUTED (ScheduleCalculator) — no per-week
/// rows are ever materialized. Schedules sync as their own entity; the
/// course reference is a plain id (a schedule row may arrive before its
/// course).
@Model
final class CourseSchedule: Identifiable {
    @Attribute(.unique) var id: UUID
    /// The course this schedule belongs to (nil = orphaned; the UI shows
    /// 来源已不存在). Plain id — same convention as ClassroomSession.
    var courseID: UUID?
    /// 0=Sunday … 6=Saturday, interpreted in `timezoneID`.
    var weekday: Int
    /// Wall-clock seconds since midnight in `timezoneID` (10:30 = 37800).
    var startSecs: Int
    /// Wall-clock seconds since midnight in `timezoneID`.
    var endSecs: Int
    /// Raw value of `ScheduleRecurrence`.
    var recurrenceRaw: String
    /// The Monday starting week 1 of the term (stored as a day-level date;
    /// nil when the recurrence needs no parity: weekly/once).
    var weekParityAnchor: Date?
    /// True when the anchor's week 1 is an "odd" semester week.
    var firstWeekIsOdd: Bool
    /// First day of the term (inclusive, day-level).
    var semesterStart: Date
    /// Last day of the term (inclusive, day-level).
    var semesterEnd: Date
    /// IANA timezone id (never a fixed UTC offset — DST follows the zone).
    var timezoneID: String
    /// Optional per-schedule teacher override; empty = use the course's.
    var teacherOverride: String
    /// Optional per-schedule location override; empty = use the course's.
    var locationOverride: String
    /// Optional free-text note.
    var note: String
    /// -1 = no reminder (local device concern), 0 = at start, >0 minutes
    /// before start.
    var reminderLeadMins: Int
    /// Paused schedules generate no occurrences and schedule no
    /// notifications, but keep their rules.
    var isEnabled: Bool
    /// The one date a `once` recurrence runs (day-level; nil otherwise).
    var onceDate: Date?
    var createdAt: Date
    var updatedAt: Date
    /// Cloud-sync metadata (0 = never synced).
    var serverVersion: Int

    init(
        id: UUID = UUID(),
        courseID: UUID?,
        weekday: Int,
        startSecs: Int,
        endSecs: Int,
        recurrence: ScheduleRecurrence,
        weekParityAnchor: Date? = nil,
        firstWeekIsOdd: Bool = true,
        semesterStart: Date,
        semesterEnd: Date,
        timezoneID: String = TimeZone.current.identifier,
        teacherOverride: String = "",
        locationOverride: String = "",
        note: String = "",
        reminderLeadMins: Int = -1,
        isEnabled: Bool = true,
        onceDate: Date? = nil,
        serverVersion: Int = 0
    ) {
        self.id = id
        self.courseID = courseID
        self.weekday = weekday
        self.startSecs = startSecs
        self.endSecs = endSecs
        self.recurrenceRaw = recurrence.rawValue
        self.weekParityAnchor = weekParityAnchor
        self.firstWeekIsOdd = firstWeekIsOdd
        self.semesterStart = semesterStart
        self.semesterEnd = semesterEnd
        self.timezoneID = timezoneID
        self.teacherOverride = teacherOverride
        self.locationOverride = locationOverride
        self.note = note
        self.reminderLeadMins = reminderLeadMins
        self.isEnabled = isEnabled
        self.onceDate = onceDate
        self.createdAt = .now
        self.updatedAt = .now
        self.serverVersion = serverVersion
    }

    var recurrence: ScheduleRecurrence {
        get { ScheduleRecurrence(rawValue: recurrenceRaw) ?? .weekly }
        set { recurrenceRaw = newValue.rawValue }
    }
}

/// One dated deviation of a schedule: cancel, move/resize, relocate, or
/// add an extra one-off class. Stored as its own synced entity so a
/// one-week cancellation never edits the recurring rule.
@Model
final class ScheduleException: Identifiable {
    @Attribute(.unique) var id: UUID
    /// The schedule this exception applies to (REQUIRED for created
    /// rows; nil only on pulled rows whose schedule was deleted — the UI
    /// shows 来源已不存在).
    var scheduleID: UUID?
    /// The course the parent schedule belongs to (denormalized for
    /// course-scoped queries; rides the wire with the sentinel rule).
    var courseID: UUID?
    /// The originally planned date (day-level) this exception replaces;
    /// nil for ad-hoc extras.
    var originalDate: Date?
    /// Raw value of `ScheduleExceptionKind`.
    var kindRaw: String
    /// Shifted wall-clock seconds since midnight in the parent schedule's
    /// timezone (nil = keep the schedule's times).
    var changedStart: Int?
    /// Shifted wall-clock seconds since midnight; nil = keep.
    var changedEnd: Int?
    /// Relocated date (day-level); nil = keep the original date.
    var movedToDate: Date?
    /// One-off location for this occurrence; empty = keep.
    var locationOverride: String
    /// One-off teacher for this occurrence; empty = keep.
    var teacherOverride: String
    /// Free-text explanation shown on the timetable.
    var note: String
    var createdAt: Date
    var updatedAt: Date
    /// Cloud-sync metadata (0 = never synced).
    var serverVersion: Int

    init(
        id: UUID = UUID(),
        scheduleID: UUID?,
        courseID: UUID? = nil,
        originalDate: Date? = nil,
        kind: ScheduleExceptionKind,
        changedStart: Int? = nil,
        changedEnd: Int? = nil,
        movedToDate: Date? = nil,
        locationOverride: String = "",
        teacherOverride: String = "",
        note: String = "",
        serverVersion: Int = 0
    ) {
        self.id = id
        self.scheduleID = scheduleID
        self.courseID = courseID
        self.originalDate = originalDate
        self.kindRaw = kind.rawValue
        self.changedStart = changedStart
        self.changedEnd = changedEnd
        self.movedToDate = movedToDate
        self.locationOverride = locationOverride
        self.teacherOverride = teacherOverride
        self.note = note
        self.createdAt = .now
        self.updatedAt = .now
        self.serverVersion = serverVersion
    }

    var kind: ScheduleExceptionKind {
        get { ScheduleExceptionKind(rawValue: kindRaw) ?? .cancelled }
        set { kindRaw = newValue.rawValue }
    }
}

/// Fields the schedule create/edit form produces. Times are wall-clock
/// seconds since midnight in the schedule's timezone.
struct ScheduleDraft: Sendable, Equatable {
    var courseID: UUID
    var weekday: Int
    var startSecs: Int
    var endSecs: Int
    var recurrence: ScheduleRecurrence
    /// Monday starting week 1 (nil = fall back to semesterStart's week).
    var weekParityAnchor: Date?
    var firstWeekIsOdd: Bool = true
    var semesterStart: Date
    var semesterEnd: Date
    var timezoneID: String = TimeZone.current.identifier
    var teacherOverride: String = ""
    var locationOverride: String = ""
    var note: String = ""
    var reminderLeadMins: Int = -1
    var isEnabled: Bool = true
    var onceDate: Date? = nil
}

/// Fields the exception create/edit form produces.
struct ScheduleExceptionDraft: Sendable, Equatable {
    var scheduleID: UUID
    var courseID: UUID?
    var originalDate: Date?
    var kind: ScheduleExceptionKind
    var changedStart: Int?
    var changedEnd: Int?
    var movedToDate: Date?
    var locationOverride: String = ""
    var teacherOverride: String = ""
    var note: String = ""
}
