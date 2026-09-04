import Foundation
import EventKit

/// System-calendar (EventKit) integration — the 克制 write-only layer.
///
/// Boundaries (per the spec):
/// - the LiveTranslate store stays the SOURCE OF TRUTH: the system
///   calendar is a one-way MIRROR the user explicitly asks for;
/// - authorization is requested ONLY on the user's explicit action
///   (write-only access — the app never reads the user's calendars);
/// - the user picks the destination calendar (any EKCalendar the store
///   can write, including a Google account connected to Apple Calendar);
/// - EventKit identifiers live in DEVICE-LOCAL storage (account-scoped
///   UserDefaults) and NEVER sync;
/// - updating/deleting an exam offers to update/remove the mirrored
///   event; an event the user deleted system-side is detected honestly
///   (the mirror entry is dropped, never recreated behind the user's
///   back);
/// - permission denial changes nothing in-app — plans and reminders
///   keep working.
@MainActor
final class ExamCalendarService {
    static let shared = ExamCalendarService()

    private let store = EKEventStore()

    /// Account-scoped defaults (injected by AppEnvironment at profile
    /// composition; .standard until then).
    private var defaultsBound: UserDefaults

    init(defaults: UserDefaults = .standard) {
        defaultsBound = defaults
    }

    /// Rebinds to the account-scoped defaults store (profile switch).
    /// Mirror state is per-device; rebinding drops the old account's
    /// bindings (their EK events stay in the user's calendar until
    /// removed system-side — we never delete another account's data).
    func configure(defaults: UserDefaults) {
        defaultsBound = defaults
    }

    private var mirrorKey: String { "calendar.examMirrors" }

    private func mirrorTable() -> [String: String] {
        guard let data = defaultsBound.data(forKey: mirrorKey),
              let table = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return table
    }

    private func saveMirrorTable(_ table: [String: String]) {
        if let data = try? JSONEncoder().encode(table) {
            defaultsBound.set(data, forKey: mirrorKey)
        }
    }

    // MARK: - Authorization (user-initiated only)

    var isAuthorized: Bool {
        get async {
            let status = await requestStatus()
            switch status {
            case .authorized, .writeOnly:
                return true
            default:
                return false
            }
        }
    }

    private func requestStatus() async -> EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    /// Requests WRITE-ONLY access (the restrained scope — the app never
    /// needs to read the user's calendars). Returns false when denied.
    @discardableResult
    func requestAccessIfNeeded() async -> Bool {
        let status = await requestStatus()
        switch status {
        case .authorized, .writeOnly:
            return true
        case .notDetermined:
            if #available(iOS 17.0, *) {
                return (try? await store.requestWriteOnlyAccessToEvents()) ?? false
            }
            return false
        default:
            return false
        }
    }

    // MARK: - Calendars

    /// The user-writable event calendars (any source — iCloud, Google
    /// connected via Apple Calendar, …). Nil until authorized.
    func writableCalendars() async -> [EKCalendar]? {
        guard await requestAccessIfNeeded() else { return nil }
        return store.calendars(for: .event).filter { calendar in
            !calendar.isImmutable
        }
    }

    // MARK: - Exam mirroring

    /// Whether an exam currently has a mirrored event.
    func hasMirroredEvent(examID: UUID) -> Bool {
        mirrorTable()[examID.uuidString] != nil
    }

    /// Adds (or updates) the exam's event in the chosen calendar.
    /// Returns false when access was denied.
    @discardableResult
    func mirror(exam: Exam, courseName: String?, calendar: EKCalendar) async -> Bool {
        guard await requestAccessIfNeeded() else { return false }
        // The anchor: the exam's start moment when the time is known,
        // otherwise the exam DAY's morning (09:00 — never a fake time).
        let anchor: Date
        if let start = exam.startDateTime {
            anchor = start
        } else if let day = exam.examDate {
            anchor = Calendar.current.date(
                bySettingHour: 9, minute: 0, second: 0, of: day
            ) ?? day
        } else {
            return false
        }
        let duration: TimeInterval = exam.endSecs > exam.startSecs && exam.startSecs >= 0
            ? TimeInterval(exam.endSecs - exam.startSecs)
            : 90 * 60 // no time known: a day-block placeholder
        var title = exam.title
        if let courseName, !courseName.isEmpty {
            title = "\(courseName) · \(title)"
        }

        var table = mirrorTable()
        let event: EKEvent
        if let existingID = table[exam.id.uuidString],
           let existing = fetchEvent(id: existingID) {
            // Update in place — never a duplicate.
            event = existing
        } else {
            event = EKEvent(eventStore: store)
            event.calendar = calendar
        }
        event.title = title
        event.startDate = anchor
        event.endDate = anchor.addingTimeInterval(duration)
        event.notes = exam.scopeText.isEmpty ? exam.note : exam.scopeText
        if !exam.location.isEmpty { event.location = exam.location }
        do {
            // Save covers both the new event and the in-place update —
            // EventKit assigns the identifier on first save, and a
            // re-save of the fetched event keeps it (no duplicates).
            try store.save(event, span: .thisEvent)
            table[exam.id.uuidString] = event.eventIdentifier
            saveMirrorTable(table)
            return true
        } catch {
            return false
        }
    }

    /// Removes the mirrored event (exam deleted or the user asked to
    /// stop mirroring). A system-side deletion is detected by the
    /// missing event and drops the stale binding.
    func removeMirroredEvent(examID: UUID) {
        var table = mirrorTable()
        guard let eventID = table[examID.uuidString] else { return }
        if let event = fetchEvent(id: eventID) {
            try? store.remove(event, span: .thisEvent)
        }
        table[examID.uuidString] = nil
        saveMirrorTable(table)
    }

    /// Drops bindings whose events no longer exist system-side (the user
    /// deleted the event in Calendar — the app reflects that state).
    func pruneStaleMirrors() {
        var table = mirrorTable()
        let stale = table.filter { fetchEvent(id: $0.value) == nil }
        guard !stale.isEmpty else { return }
        for key in stale.keys { table[key] = nil }
        saveMirrorTable(table)
    }

    private func fetchEvent(id: String) -> EKEvent? {
        // Direct identifier lookup — never a range scan over the user's
        // calendars (the restrained read model: the app only ever asks
        // for the exact events it created).
        store.event(withIdentifier: id)
    }

    // MARK: - Plan-item mirroring

    /// Mirrors selected plan items (a week's schedule, one item) as
    /// calendar events, keyed by item id.
    @discardableResult
    func mirrorPlanItem(
        item: StudyPlanItem, planTitle: String, calendar: EKCalendar
    ) async -> Bool {
        guard await requestAccessIfNeeded() else { return false }
        guard let day = item.itemDate else { return false }
        // A plan block at 19:00 (the default evening study slot) with
        // the estimated duration.
        let start = Calendar.current.date(
            bySettingHour: 19, minute: 0, second: 0, of: day
        ) ?? day
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = "学习：\(item.title)"
        event.startDate = start
        event.endDate = start.addingTimeInterval(TimeInterval(item.estimatedMinutes * 60))
        event.notes = planTitle
        do {
            try store.save(event, span: .thisEvent)
            var table = mirrorTable()
            table["planitem-\(item.id.uuidString)"] = event.eventIdentifier
            saveMirrorTable(table)
            return true
        } catch {
            return false
        }
    }

    func removeMirroredPlanItem(itemID: UUID) {
        var table = mirrorTable()
        let key = "planitem-\(itemID.uuidString)"
        guard let eventID = table[key] else { return }
        if let event = fetchEvent(id: eventID) {
            try? store.remove(event, span: .thisEvent)
        }
        table[key] = nil
        saveMirrorTable(table)
    }
}
