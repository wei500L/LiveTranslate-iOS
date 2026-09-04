import Foundation

// System command queue — the widget / Live Activity's ONLY way to act on
// real classroom & study state. Buttons in extensions cannot touch the
// coordinator (different process), so they enqueue a command here; the
// main app consumes it (Darwin-notification woken while it runs under
// background audio, or at foreground entry) and executes it against the
// REAL coordinator / tracker — after validating scope and session.
//
// A command is a *request*: the consumer validates it against live state
// and drops anything stale, wrong-scoped or wrong-session. Execution is
// idempotent (executed IDs are remembered to dedupe redelivery).

// MARK: - Command model

enum SystemCommandKind: String, Codable, Sendable {
    /// Pause the running classroom (coordinator.pause()).
    case pauseClassroom
    /// Resume a paused classroom (coordinator.resume()).
    case resumeClassroom
    /// Pause the running learning timer (tracker.pause()).
    case pauseStudy
    /// Resume the paused learning timer (tracker.resume()).
    case resumeStudy
}

struct SystemCommand: Codable, Sendable, Equatable, Identifiable {
    /// Stable, unique command id (idempotent consumption key).
    var id: UUID
    var kind: SystemCommandKind
    /// The session the sender believed was active — validated by the
    /// consumer against the live coordinator state.
    var sessionID: UUID?
    /// The study activity the sender believed was active (study commands).
    var activityID: UUID?
    var scopeKey: String
    var createdAt: Date
}

// MARK: - Queue store

/// App Group file queue. Extension writes (enqueue), app reads + rewrites
/// (consume). All writes are tmp+replace atomic; the queue is small
/// (bounded) so full-file rewrite is the simple honest protocol.
struct SystemCommandStore {
    /// Darwin notification posted after an enqueue; the app observes it to
    /// consume immediately (it typically runs under background audio).
    /// Darwin notifications carry no payload — the queue file is the truth.
    static let darwinNotificationName = "com.livetranslate.systemCommands"

    /// Commands older than this are dropped at consumption time (the user
    /// tapped long ago; executing now would lie about when it happened).
    static let expiry: TimeInterval = 10 * 60

    /// Cap: a malfunctioning writer must never grow the file unboundedly.
    private static let maxQueued = 16

    private let fileURL: URL?

    init() {
        fileURL = SystemSnapshotStore.containerURL?
            .appendingPathComponent("SystemCommands.json")
    }

    /// Enqueue from an extension process, then post the Darwin wake-up.
    /// Silent failure by design (a dead button must not crash a widget).
    static func enqueue(_ command: SystemCommand) {
        let store = SystemCommandStore()
        store.push(command)
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName(
                (darwinNotificationName as CFString)
            ),
            nil, nil, true
        )
    }

    /// Append + trim (atomically). App-side consumption also rewrites via
    /// this path with the remaining queue.
    func push(_ command: SystemCommand) {
        var commands = loadQueue()
        commands.append(command)
        if commands.count > Self.maxQueued {
            commands = Array(commands.suffix(Self.maxQueued))
        }
        write(commands)
    }

    func replace(_ commands: [SystemCommand]) {
        write(commands)
    }

    /// Raw queue read (no filtering) — the consumer applies scope/expiry.
    func loadQueue() -> [SystemCommand] {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([SystemCommand].self, from: data)) ?? []
    }

    private func write(_ commands: [SystemCommand]) {
        guard let fileURL else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(commands)
            let tmp = fileURL.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            try? FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
        } catch {
            // Non-fatal by design.
        }
    }
}
