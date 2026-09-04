import Foundation

/// THE single authority for turning schedule rules + exceptions into
/// concrete occurrences. Every consumer (timetable UI, home next-class,
/// notification scheduler, quick-start matching) computes through this —
/// no page implements its own odd/even-week algorithm.
///
/// All week arithmetic is day-level in the SCHEDULE's timezone. Dates are
/// normalized to UTC midnight ("day anchors") before any math.
enum ScheduleCalculator {

    // MARK: - Day-anchor helpers

    /// A day-level date (UTC midnight). Two dates are the same day iff
    /// their anchors are equal, regardless of the calendar they came from.
    static func dayAnchor(_ date: Date, timeZone: TimeZone = .current) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return calendar.date(from: comps) ?? date
    }

    /// The Monday (or same weekday) starting `date`'s week in the zone.
    static func weekStart(of date: Date, timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2 // Monday
        var comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        comps.weekday = 2
        return calendar.date(from: comps) ?? date
    }

    /// Whole-day difference `later - earlier` in the zone (negative when
    /// earlier is after later).
    static func daysBetween(_ earlier: Date, _ later: Date, timeZone: TimeZone) -> Int {
        Int((later.timeIntervalSince(earlier) / 86_400).rounded())
    }

    /// Parses "YYYY-MM-DD" into a day anchor. Nil on malformed input.
    static func parseDay(_ string: String) -> Date? {
        let parts = string.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2])
        else { return nil }
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar.date(from: comps)
    }

    /// Renders a day anchor as "YYYY-MM-DD".
    static func formatDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // MARK: - Occurrence key

    /// Stable identity of ONE concrete class: "scheduleUUID:YYYY-MM-DD"
    /// (the date in the schedule's timezone). Survives time and room
    /// changes (they edit the same occurrence); a rule deletion orphans
    /// the key — history keeps it dangling.
    static func occurrenceKey(scheduleID: UUID, date: Date, timeZone: TimeZone) -> String {
        "\(scheduleID.uuidString):\(formatDay(dayAnchor(date, timeZone: timeZone)))"
    }

    /// Splits an occurrence key back into (scheduleID, day string); nil
    /// when malformed.
    static func parseOccurrenceKey(_ key: String) -> (scheduleID: UUID, day: String)? {
        guard let colon = key.firstIndex(of: ":") else { return nil }
        guard let id = UUID(uuidString: String(key[key.startIndex..<colon])) else { return nil }
        return (id, String(key[key.index(after: colon)...]))
    }

    // MARK: - Week parity

    /// The semester-week index of `date` (0-based) under the schedule's
    /// parity anchor. Nil when the anchor is missing (recurrences that
    /// need no parity) or the date precedes the anchor's week.
    static func semesterWeekIndex(of date: Date, schedule: CourseSchedule) -> Int? {
        guard let anchor = schedule.weekParityAnchor else { return nil }
        let tz = zone(schedule)
        let anchorWeek = weekStart(of: anchor, timeZone: tz)
        let dateWeek = weekStart(of: date, timeZone: tz)
        let weeks = daysBetween(anchorWeek, dateWeek, timeZone: tz) / 7
        return weeks >= 0 ? weeks : nil
    }

    /// Whether the schedule runs during `date`'s semester week. Biweekly
    /// counts from the anchor's week 1 (index % 2 == 0).
    static func weekMatches(date: Date, schedule: CourseSchedule) -> Bool {
        switch schedule.recurrence {
        case .weekly, .once:
            return true
        case .biweekly, .oddWeeks, .evenWeeks:
            guard let index = semesterWeekIndex(of: date, schedule: schedule) else {
                // No anchor / before the anchor: the recurrence cannot be
                // resolved — treat as no class rather than guessing.
                return false
            }
            let weekIsOdd = (index % 2 == 0) == schedule.firstWeekIsOdd
            switch schedule.recurrence {
            case .biweekly: return index % 2 == 0
            case .oddWeeks: return weekIsOdd
            case .evenWeeks: return !weekIsOdd
            default: return true
            }
        }
    }

    static func zone(_ schedule: CourseSchedule) -> TimeZone {
        TimeZone(identifier: schedule.timezoneID) ?? .current
    }

    // MARK: - Occurrence generation

    /// One computed concrete class. Value type — safe to hand around.
    struct Occurrence: Identifiable, Sendable, Equatable {
        /// The occurrence key (stable id).
        var id: String { occurrenceKey }
        var occurrenceKey: String
        var scheduleID: UUID
        var courseID: UUID?
        /// Local day the class runs on (day anchor).
        var date: Date
        /// Absolute start/end in the schedule's timezone.
        var start: Date
        var end: Date
        /// Effective cover values (exception overrides win, then
        /// schedule overrides, then the course defaults resolved by the
        /// caller — the calculator never touches the course row).
        var teacher: String?
        var location: String?
        var note: String?
        /// Exception state applied to this occurrence.
        var isCancelled: Bool
        var isTimeChanged: Bool
        var isAdHoc: Bool

        /// Effective wall-clock seconds since midnight (exception-aware).
        var effectiveStartSecs: Int
        var effectiveEndSecs: Int
    }

    /// Computes occurrences of ONE schedule within a day window
    /// (inclusive start day, exclusive end day — day anchors). The window
    /// should stay small (a couple of weeks); the whole semester is never
    /// materialized.
    ///
    /// `exceptions` are the schedule's exceptions (any order); the caller
    /// filters by scheduleID before passing them.
    static func occurrences(
        of schedule: CourseSchedule,
        from startDay: Date,
        to endDay: Date,
        exceptions: [ScheduleException]
    ) -> [Occurrence] {
        guard schedule.isEnabled else { return [] }
        let tz = zone(schedule)
        let startAnchor = dayAnchor(startDay, timeZone: tz)
        let endAnchor = dayAnchor(endDay, timeZone: tz)
        guard endAnchor >= startAnchor else { return [] }

        var byOriginal = [String: ScheduleException]()
        for e in exceptions where e.scheduleID == schedule.id {
            if let original = e.originalDate {
                byOriginal[formatDay(dayAnchor(original, timeZone: tz))] = e
            }
        }

        var result: [Occurrence] = []
        let cal = ScheduleCalculator.dayCalendar(tz)

        if schedule.recurrence == .once {
            if let once = schedule.onceDate {
                let day = dayAnchor(once, timeZone: tz)
                if day >= startAnchor && day < endAnchor {
                    if let occ = buildOccurrence(
                        schedule: schedule, day: day, exception: nil,
                        calendar: cal, timeZone: tz
                    ) { result.append(occ) }
                }
            }
            // Ad-hoc extras still appear even for once-recurrences.
            for e in exceptions where e.scheduleID == schedule.id && e.kind == .adHoc {
                let day = dayAnchor(e.movedToDate ?? e.originalDate ?? .now, timeZone: tz)
                if day >= startAnchor && day < endAnchor {
                    if let occ = buildOccurrence(
                        schedule: schedule, day: day, exception: e,
                        calendar: cal, timeZone: tz
                    ) { result.append(occ) }
                }
            }
            return result
        }

        var day = startAnchor
        while day < endAnchor {
            defer { day = cal.date(byAdding: .day, value: 1, to: day) ?? day }
            let weekday = cal.component(.weekday, from: day) - 1 // 0=Sun
            guard weekday == schedule.weekday else { continue }
            guard day >= dayAnchor(schedule.semesterStart, timeZone: tz) else { continue }
            guard day <= dayAnchor(schedule.semesterEnd, timeZone: tz) else { continue }
            guard weekMatches(date: day, schedule: schedule) else { continue }

            let exception = byOriginal[formatDay(day)]
            if let occ = buildOccurrence(
                schedule: schedule, day: day, exception: exception,
                calendar: cal, timeZone: tz
            ) {
                result.append(occ)
            }
        }

        // Ad-hoc extras: one-off classes attached to this schedule.
        for e in exceptions where e.scheduleID == schedule.id && e.kind == .adHoc {
            let day = dayAnchor(e.movedToDate ?? e.originalDate ?? .now, timeZone: tz)
            guard day >= startAnchor && day < endAnchor else { continue }
            if let occ = buildOccurrence(
                schedule: schedule, day: day, exception: e,
                calendar: cal, timeZone: tz
            ) {
                // A moved class landing on the same day as a cancelled
                // regular occurrence stays distinct (different key).
                result.append(occ)
            }
        }
        return result
    }

    private static func dayCalendar(_ tz: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return cal
    }

    /// Builds one occurrence for a specific day, applying the exception.
    private static func buildOccurrence(
        schedule: CourseSchedule,
        day: Date,
        exception: ScheduleException?,
        calendar: Calendar,
        timeZone: TimeZone
    ) -> Occurrence? {
        var startSecs = schedule.startSecs
        var endSecs = schedule.endSecs
        var effectiveDay = day
        var isCancelled = false
        var isTimeChanged = false
        var isAdHoc = false
        var teacher: String?
        var location: String?
        var note: String?

        if let e = exception {
            note = e.note.isEmpty ? nil : e.note
            if !e.teacherOverride.isEmpty { teacher = e.teacherOverride }
            if !e.locationOverride.isEmpty { location = e.locationOverride }
            switch e.kind {
            case .cancelled:
                isCancelled = true
            case .timeChanged:
                isTimeChanged = true
                if let s = e.changedStart { startSecs = s }
                if let en = e.changedEnd { endSecs = en }
                if let moved = e.movedToDate { effectiveDay = dayAnchor(moved, timeZone: timeZone) }
            case .adHoc:
                isAdHoc = true
                if let s = e.changedStart { startSecs = s }
                if let en = e.changedEnd { endSecs = en }
                if let moved = e.movedToDate { effectiveDay = dayAnchor(moved, timeZone: timeZone) }
            }
        }
        if teacher == nil && !schedule.teacherOverride.isEmpty { teacher = schedule.teacherOverride }
        if location == nil && !schedule.locationOverride.isEmpty { location = schedule.locationOverride }
        if note == nil && !schedule.note.isEmpty { note = schedule.note }

        let start = calendar.date(byAdding: .second, value: startSecs, to: effectiveDay)
            ?? effectiveDay
        let end = calendar.date(byAdding: .second, value: endSecs, to: effectiveDay)
            ?? effectiveDay

        return Occurrence(
            occurrenceKey: occurrenceKey(scheduleID: schedule.id, date: day, timeZone: timeZone),
            scheduleID: schedule.id,
            courseID: exception?.courseID ?? schedule.courseID,
            date: effectiveDay,
            start: start,
            end: end,
            teacher: teacher,
            location: location,
            note: note,
            isCancelled: isCancelled,
            isTimeChanged: isTimeChanged,
            isAdHoc: isAdHoc,
            effectiveStartSecs: startSecs,
            effectiveEndSecs: endSecs
        )
    }

    // MARK: - Session-matching queries

    /// The effective teacher for display (exception override → schedule
    /// override → course default). The course default is resolved by the
    /// caller because the calculator never reads the course row.
    static func effectiveTeacher(occurrence: Occurrence, courseTeacher: String) -> String {
        occurrence.teacher ?? courseTeacher
    }

    static func effectiveLocation(occurrence: Occurrence, courseLocation: String) -> String {
        occurrence.location ?? courseLocation
    }

    /// Occurrence-window status relative to `now`, in the schedule zone.
    enum OccurrenceStatus: Sendable, Equatable {
        case upcoming
        case inProgress
        case ended
    }

    static func status(of occurrence: Occurrence, at now: Date) -> OccurrenceStatus {
        if now < occurrence.start { return .upcoming }
        if now < occurrence.end { return .inProgress }
        return .ended
    }
}
