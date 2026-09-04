import Foundation

// System-integration shared contract — the ONLY types compiled into BOTH
// the main app and the Widget Extension (SharedSystemKit), plus the
// ActivityKit Live-Activity definitions (LiveActivityDefinitions.swift,
// which additionally imports ActivityKit — still only these two targets).
//
// The kit is deliberately dependency-light (Foundation only in this file):
// the widget extension must be able to render system surfaces without
// SwiftData, ASR, Keychain, networking or any app stack. The extension
// NEVER assembles business data itself — it only consumes the snapshot the
// main app writes, and only forwards user intents back as commands/routes.
//
// Storage boundary: the App Group container (same group as the shared
// inbox). Everything written here is non-sensitive by construction —
// no API keys, no tokens, no emails, no full transcripts, no file paths.

// MARK: - Snapshot schema

/// What the lock screen / Live Activity may reveal about the running
/// classroom. Restrained by default: status + title, never the transcript
/// body. Stored globally (SettingsStore) because it is a device-level
/// privacy preference, not per-account data.
enum LockScreenPrivacy: String, Codable, Sendable, CaseIterable, Equatable {
    /// Only "正在记录 / 已暂停" — no title, no text.
    case statusOnly
    /// Status + classroom name (the default).
    case statusAndTitle
    /// Status + name + the single latest Chinese translation line
    /// (user opted in; still one line, never a transcript reader).
    case statusTitleAndLatestText
}

/// The account scope a snapshot (or command, or route) belongs to.
/// Same non-sensitive marker vocabulary the shared inbox uses ("guest" or
/// an account UUID string). System surfaces render only for the active
/// scope; a stale scope shows an honest empty state, never another
/// account's data.
enum SystemScope {
    static let guest = "guest"

    /// UserDefaults key inside the App Group suite carrying the ACTIVE
    /// profile's scope marker. Same key `SharedInboxScopeStore` writes —
    /// re-declared here because SharedInboxKit is not compiled into the
    /// widget extension; the string must stay in sync.
    static let activeScopeKey = "sharedinbox.activeScope"

    static func currentScopeKey(defaults: UserDefaults?) -> String {
        guard let defaults,
              let value = defaults.string(forKey: activeScopeKey),
              !value.isEmpty else { return guest }
        return value
    }
}

/// One widget-facing "next class" derived from the schedule calculator at
/// snapshot time. The widget never recomputes occurrences (no SwiftData,
/// no schedule math in the extension).
struct WidgetNextClass: Codable, Sendable, Equatable {
    var occurrenceKey: String
    var courseName: String
    var start: Date
    var end: Date
    var location: String
    /// Cancelled (停课) or time-changed (调课) — the label shows it.
    var isCancelled: Bool
    var isTimeChanged: Bool
}

/// One widget-facing "next exam".
struct WidgetNextExam: Codable, Sendable, Equatable {
    var examID: UUID
    var title: String
    var courseName: String
    /// Exam day start (midnight anchor of the exam date key).
    var examDate: Date
    /// Days remaining from the snapshot's generation date (≥ 0).
    var daysUntil: Int
}

/// Today's study-plan aggregate.
struct WidgetTodayStudy: Codable, Sendable, Equatable {
    var planTotal: Int
    var planDone: Int
    /// The next undone item's title ("" when none).
    var nextItemTitle: String
    var nextItemEstimatedMinutes: Int
}

/// The running learning-timer state.
struct WidgetStudyActivity: Codable, Sendable, Equatable {
    var activityID: UUID
    var planItemID: UUID?
    var title: String
    var courseName: String
    var startedAt: Date
    /// Seconds already folded into the row (excludes the live stretch).
    var accumulatedSeconds: Int
    /// Anchor of the CURRENT stretch (nil while paused) — the widget's
    /// timer text derives live elapsed from it.
    var activeSince: Date?
    var isPaused: Bool
    var estimatedMinutes: Int
}

/// The running classroom state (mirrors the coordinator at snapshot time).
struct WidgetClassroom: Codable, Sendable, Equatable {
    var sessionID: UUID
    var title: String
    var startedAt: Date
    /// Effective classroom seconds at snapshot time (excludes pauses).
    var accumulatedSeconds: Int
    var isPaused: Bool
    /// Anchor of the current running stretch (nil while paused).
    var activeSince: Date?
    /// User-safe phase summary — never technical backend names.
    var isRecording: Bool
    /// Local ASR is alive (transcription continues).
    var isTranscribing: Bool
    /// Translation state: available / waiting for network / not configured.
    var translationState: String
    /// Latest Chinese line, ONLY when `privacy` allows it; capped length.
    var latestChinese: String
}

/// The versioned, minimal system snapshot the main app writes and the
/// widgets read. Schema evolution: bump `schemaVersion`; readers safely
/// ignore (render empty state) anything they cannot decode.
struct WidgetSnapshot: Codable, Sendable, Equatable {
    static let schemaVersion = 1

    var schemaVersion: Int
    var scopeKey: String
    var generatedAt: Date
    var classroom: WidgetClassroom?
    var study: WidgetStudyActivity?
    var nextClass: WidgetNextClass?
    var nextExam: WidgetNextExam?
    var today: WidgetTodayStudy
    var inboxPendingCount: Int
    /// The privacy level the snapshot was generated under (the classroom
    /// title / latest text are already filtered at generation; this rides
    /// along so system surfaces can adapt labels).
    var privacy: LockScreenPrivacy

    static func empty(scopeKey: String) -> WidgetSnapshot {
        WidgetSnapshot(
            schemaVersion: schemaVersion,
            scopeKey: scopeKey,
            generatedAt: .now,
            classroom: nil,
            study: nil,
            nextClass: nil,
            nextExam: nil,
            today: WidgetTodayStudy(
                planTotal: 0, planDone: 0,
                nextItemTitle: "", nextItemEstimatedMinutes: 0
            ),
            inboxPendingCount: 0,
            privacy: .statusAndTitle
        )
    }
}

// MARK: - Snapshot store

/// Atomic, versioned snapshot storage in the App Group. The main app is
/// the ONLY writer; the widget extension only reads. Writes go
/// tmp-file + rename so a reader never sees a torn file, and a reader that
/// fails to decode (future schema) renders an honest empty state.
struct SystemSnapshotStore {
    static let appGroupIdentifier = "group.com.livetranslate.ios"

    /// The App Group container root (nil when the group is unavailable —
    /// callers treat that as "system integration off", honestly).
    static var containerURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        )
    }

    static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }

    private let fileURL: URL?

    init() {
        fileURL = Self.containerURL?
            .appendingPathComponent("SystemSnapshot.json")
    }

    /// Atomic write: encode → tmp path → replace. Never throws outward
    /// (a failed snapshot write must not disturb the classroom).
    func save(_ snapshot: WidgetSnapshot) {
        guard let fileURL else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            let tmp = fileURL.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            try? FileManager.default.replaceItemAt(
                fileURL, withItemAt: tmp
            )
        } catch {
            // Non-fatal by design: widgets show the previous snapshot.
        }
    }

    /// Reads and decodes the snapshot for `scopeKey`. Nil when absent,
    /// unreadable, future-schema, or belonging to a different scope.
    func load(activeScopeKey: String) -> WidgetSnapshot? {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(WidgetSnapshot.self, from: data),
              snapshot.schemaVersion <= WidgetSnapshot.schemaVersion,
              snapshot.scopeKey == activeScopeKey else { return nil }
        return snapshot
    }

    /// Removes the snapshot file (account switch: the old profile's data
    /// leaves the group before the new profile's snapshot lands).
    func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
