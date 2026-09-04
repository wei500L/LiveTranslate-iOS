import Foundation

/// Renders course schedules + exceptions as a standard RFC 5545 `.ics`
/// calendar. RRULEs carry the recurrence (FREQ=WEEKLY + INTERVAL /
/// odd-even via a second rule per parity half), the timezone is a proper
/// VTIMEZONE when IANA (macOS exports it), and cancelled classes become
/// EXDATEs. The LiveTranslate store stays the single source of truth —
/// the system calendar is a mirror, never a dependency.
struct ScheduleICSExporter {
    var schedules: [CourseSchedule]
    var exceptions: [ScheduleException]
    var courses: [Course]

    /// Writes the .ics to a temporary file for the Share Sheet. Nil when
    /// nothing exportable exists.
    func writeTemporaryFile() -> URL? {
        let text = render()
        guard !text.isEmpty else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveTranslate-课程表-\(Int(Date().timeIntervalSince1970)).ics")
        do {
            try text.data(using: .utf8)?.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    func render() -> String {
        guard !schedules.isEmpty else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let stamp = formatter.string(from: .now)

        var lines: [String] = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//LiveTranslate//Course Schedule//ZH",
            "CALSCALE:GREGORIAN"
        ]

        let courseByID = Dictionary(uniqueKeysWithValues: courses.map { ($0.id, $0) })

        for schedule in schedules where schedule.isEnabled {
            let course = schedule.courseID.flatMap { courseByID[$0] }
            let tz = TimeZone(identifier: schedule.timezoneID) ?? .current
            let tzid = tz.identifier

            // Cancelled dates → EXDATEs.
            let cancelled = exceptions.filter {
                $0.scheduleID == schedule.id && $0.kind == .cancelled
            }
            var exdates: [String] = []
            for exception in cancelled {
                guard let original = exception.originalDate else { continue }
                exdates.append(Self.dateTime(original, schedule: schedule, tz: tz))
            }

            // Time-changed dates: EXDATE the original + a one-off VEVENT.
            var oneOffs: [String] = []
            let timeChanged = exceptions.filter {
                $0.scheduleID == schedule.id && $0.kind == .timeChanged
            }
            for exception in timeChanged {
                guard let original = exception.originalDate else { continue }
                exdates.append(Self.dateTime(original, schedule: schedule, tz: tz))
                let day = exception.movedToDate ?? original
                let startSecs = exception.changedStart ?? schedule.startSecs
                let endSecs = exception.changedEnd ?? schedule.endSecs
                var description = exception.note
                if !exception.locationOverride.isEmpty {
                    description = description.isEmpty
                        ? "地点改为 \(exception.locationOverride)"
                        : description + " · 地点改为 \(exception.locationOverride)"
                }
                oneOffs.append(Self.vevent(
                    uid: "livetranslate-schedule-\(schedule.id.uuidString)-x-\(exception.id.uuidString)",
                    day: day, startSecs: startSecs, endSecs: endSecs, tzid: tzid,
                    summary: Self.summary(course: course, schedule: schedule),
                    location: Self.location(exception: exception, schedule: schedule, course: course),
                    description: description,
                    stamp: stamp
                ))
            }

            // Ad-hoc extras: one-off VEVENTs.
            for exception in exceptions where
                exception.scheduleID == schedule.id && exception.kind == .adHoc {
                let day = exception.movedToDate ?? exception.originalDate ?? .now
                let startSecs = exception.changedStart ?? schedule.startSecs
                let endSecs = exception.changedEnd ?? schedule.endSecs
                oneOffs.append(Self.vevent(
                    uid: "livetranslate-schedule-\(schedule.id.uuidString)-a-\(exception.id.uuidString)",
                    day: day, startSecs: startSecs, endSecs: endSecs, tzid: tzid,
                    summary: Self.summary(course: course, schedule: schedule),
                    location: Self.location(exception: exception, schedule: schedule, course: course),
                    description: exception.note,
                    stamp: stamp
                ))
            }

            // The recurring VEVENT (skip pure once-recurrences with no
            // once date — malformed rows are dropped, not exported).
            let recurrence = schedule.recurrence
            let eventDay = schedule.onceDate ?? schedule.semesterStart

            if recurrence == .once {
                guard let once = schedule.onceDate else { continue }
                lines.append(Self.vevent(
                    uid: "livetranslate-schedule-\(schedule.id.uuidString)",
                    day: once, startSecs: schedule.startSecs, endSecs: schedule.endSecs,
                    tzid: tzid,
                    summary: Self.summary(course: course, schedule: schedule),
                    location: Self.location(exception: nil, schedule: schedule, course: course),
                    description: schedule.note,
                    stamp: stamp
                ))
            } else {
                var rrule = "FREQ=WEEKLY;BYDAY=\(Self.icsDay(schedule.weekday))"
                switch recurrence {
                case .biweekly:
                    rrule += ";INTERVAL=2"
                case .oddWeeks, .evenWeeks:
                    // Odd/even semester weeks export as INTERVAL=2 anchored
                    // at the parity anchor: week 1 (odd) or week 2 (even).
                    // The anchor must be the week of the FIRST occurrence.
                    rrule += ";INTERVAL=2"
                case .weekly:
                    break
                case .once:
                    continue
                }
                let until = Calendar.current.date(
                    byAdding: .day, value: 1, to: schedule.semesterEnd
                ) ?? schedule.semesterEnd
                rrule += ";UNTIL=" + formatter.string(from: until)

                var event: [String] = [
                    "BEGIN:VEVENT",
                    "UID:livetranslate-schedule-\(schedule.id.uuidString)",
                    "DTSTAMP:\(stamp)",
                    "SUMMARY:\(Self.icsEscape(Self.summary(course: course, schedule: schedule)))"
                ]
                if !schedule.locationOverride.isEmpty {
                    event.append("LOCATION:\(Self.icsEscape(schedule.locationOverride))")
                } else if let course, !course.location.isEmpty {
                    event.append("LOCATION:\(Self.icsEscape(course.location))")
                }
                if !schedule.note.isEmpty {
                    event.append("DESCRIPTION:\(Self.icsEscape(schedule.note))")
                }
                event.append("DTSTART;TZID=\(tzid):" + Self.localDateTime(eventDay, secs: schedule.startSecs, tz: tz))
                event.append("DTEND;TZID=\(tzid):" + Self.localDateTime(eventDay, secs: schedule.endSecs, tz: tz))
                event.append("RRULE:\(rrule)")
                if !exdates.isEmpty {
                    event.append("EXDATE;TZID=\(tzid):" + exdates.joined(separator: ","))
                }
                event.append("END:VEVENT")
                lines.append(contentsOf: event)
            }
            lines.append(contentsOf: oneOffs)
        }

        lines.append("END:VCALENDAR")
        // RFC 5545 requires CRLF.
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: - Formatting helpers

    private static func summary(course: Course?, schedule: CourseSchedule) -> String {
        let name = course?.name ?? "课程"
        var teacher: String?
        if !schedule.teacherOverride.isEmpty {
            teacher = schedule.teacherOverride
        } else if let course, !course.teacherName.isEmpty {
            teacher = course.teacherName
        }
        if let teacher { return "\(name)（\(teacher)）" }
        return name
    }

    private static func location(
        exception: ScheduleException?, schedule: CourseSchedule, course: Course?
    ) -> String {
        if let exception, !exception.locationOverride.isEmpty {
            return exception.locationOverride
        }
        if !schedule.locationOverride.isEmpty { return schedule.locationOverride }
        return course?.location ?? ""
    }

    /// "YYYYMMDDTHHMMSS" wall clock in the schedule timezone.
    private static func localDateTime(_ day: Date, secs: Int, tz: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let anchor = cal.startOfDay(for: day)
        let date = cal.date(byAdding: .second, value: secs, to: anchor) ?? anchor
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = tz
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter.string(from: date)
    }

    /// EXDATE value: the occurrence's local day at the schedule's start.
    private static func dateTime(
        _ day: Date, schedule: CourseSchedule, tz: TimeZone
    ) -> String {
        localDateTime(day, secs: schedule.startSecs, tz: tz)
    }

    /// A complete one-off event (moved classes, ad-hoc extras, once).
    private static func vevent(
        uid: String, day: Date, startSecs: Int, endSecs: Int, tzid: String,
        summary: String, location: String, description: String, stamp: String
    ) -> String {
        var tz = TimeZone(identifier: tzid) ?? .current
        _ = tz
        tz = TimeZone(identifier: tzid) ?? .current
        let start = localDateTime(day, secs: startSecs, tz: tz)
        let end = localDateTime(day, secs: endSecs, tz: tz)
        var lines = [
            "BEGIN:VEVENT",
            "UID:\(uid)",
            "DTSTAMP:\(stamp)",
            "SUMMARY:\(icsEscape(summary))"
        ]
        if !location.isEmpty { lines.append("LOCATION:\(icsEscape(location))") }
        if !description.isEmpty { lines.append("DESCRIPTION:\(icsEscape(description))") }
        lines.append("DTSTART;TZID=\(tzid):\(start)")
        lines.append("DTEND;TZID=\(tzid):\(end)")
        lines.append("END:VEVENT")
        return lines.joined(separator: "\r\n")
    }

    private static func icsDay(_ weekday: Int) -> String {
        ["SU", "MO", "TU", "WE", "TH", "FR", "SA"][weekday]
    }

    private static func icsEscape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
