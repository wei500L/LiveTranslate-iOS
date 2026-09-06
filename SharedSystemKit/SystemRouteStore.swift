import Foundation

// System route requests — "open the app and go somewhere". Extensions
// (widgets, Live Activity buttons, control widgets) cannot navigate the
// app; they persist a route request in the App Group and open the app
// (openAppWhenRun). The app consumes the request at launch / foreground
// entry through the unified SystemRouteCoordinator (AppFlow mapping) —
// consume-once, scope-validated, with honest feedback for deleted targets.
//
// No custom URL scheme is involved anywhere: routes are plain Codable
// values in the App Group, unreachable from other apps.

// MARK: - Route model

/// One navigation target. The associated values are stable persisted IDs
/// (never titles) so the app can re-resolve them honestly at consumption
/// time and show real feedback when the entity was deleted.
enum SystemRouteRequest: Codable, Sendable, Equatable {
    /// The running classroom (or the live screen when none runs — the app
    /// explains).
    case currentClassroom
    /// The running classroom with the END confirmation presented (never
    /// destroys anything by itself).
    case endClassroomConfirmation
    /// One classroom record's detail (transcript / review).
    case session(UUID)
    /// One course's detail page.
    case course(UUID)
    /// One material, optionally at a page.
    case material(UUID, page: Int?)
    /// One exam's detail page.
    case exam(UUID)
    /// The review center's 今天 segment.
    case todayStudy
    /// One study plan item (resolved to its owning plan detail).
    case planItem(UUID)
    /// The shared inbox, optionally opening one item.
    case inbox(UUID?)
    /// The live classroom's blackboard capture sheet (requires a running
    /// classroom).
    case captureBlackboard
    /// Home's next-class card (the controlled start chain).
    case nextClass
    /// The new-classroom form (explicit user confirmation before the
    /// microphone starts).
    case newSession
    /// The interpreter screen (随身翻译 — face-to-face errand dialogs).
    /// Opens the page only; the microphone is never started by a route.
    case interpreter
    /// The errand-case list (办事事项 — 导航 only; nothing is created or
    /// armed by a route).
    case errandCaseList
    /// One errand case's detail page. The id resolves at consumption
    /// time (a deleted case shows the honest empty state).
    case errandCase(UUID)
}

// MARK: - Route store

/// Pending route requests in the App Group. Multiple entries may queue
/// while the app is dead; the app consumes them in order at launch /
/// foreground entry and only the LAST one survives navigation (each
/// navigation resets the previous — a queue of "go somewhere" taps is
/// naturally last-wins, and each entry is consumed exactly once).
struct SystemRouteStore {
    private let fileURL: URL?

    init() {
        fileURL = SystemSnapshotStore.containerURL?
            .appendingPathComponent("SystemRoutes.json")
    }

    /// Persist a route from an extension, scoped to the active profile.
    static func push(_ route: SystemRouteRequest) {
        let scopeKey = SystemScope.currentScopeKey(
            defaults: SystemSnapshotStore.defaults
        )
        let store = SystemRouteStore()
        var pending = store.loadQueue()
        pending.append(SystemRouteEntry(
            route: route, scopeKey: scopeKey, createdAt: .now
        ))
        // Last-wins navigation: keep only the newest few.
        if pending.count > 4 {
            pending = Array(pending.suffix(4))
        }
        store.write(pending)
    }

    /// All unconsumed requests (the app filters by scope when consuming).
    func loadQueue() -> [SystemRouteEntry] {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([SystemRouteEntry].self, from: data)) ?? []
    }

    func replace(_ entries: [SystemRouteEntry]) {
        write(entries)
    }

    /// Drop everything (account switch: the old profile's routes never
    /// execute against the new profile).
    func clear() {
        write([])
    }

    private func write(_ entries: [SystemRouteEntry]) {
        guard let fileURL else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(entries)
            let tmp = fileURL.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            try? FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
        } catch {
            // Non-fatal by design.
        }
    }
}

struct SystemRouteEntry: Codable, Sendable, Equatable {
    var route: SystemRouteRequest
    var scopeKey: String
    var createdAt: Date
}
