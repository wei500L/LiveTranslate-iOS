import Foundation
import ActivityKit

// Live Activity definitions — shared between the main app (creates and
// updates activities) and the Widget Extension (renders them). The
// attributes are the IMMUTABLE per-activity identity; the content state is
// the mutable, re-pushed status.
//
// Content design (spec §6–§7): the lock screen shows classroom name,
// recorded time, recording/paused/saving status, local-transcription and
// translation health, and — only when the user opted in — ONE latest
// Chinese line. No model names, no CPU/RAM, no error strings, no full
// transcripts, no fake waveform. Timing text uses Text(timerInterval:)
// (system-driven, no per-second updates).
//
// Stale content is marked via `staleAfter` on states that should not
// linger (saving / failure); a healthy running classroom sets nil (it may
// legitimately go hours between content pushes).

// MARK: - Classroom Live Activity

/// User-safe classroom phase for the lock screen. Deliberately coarse:
/// the lock screen answers "is it working?", not "which stage exactly?".
enum LiveClassroomPhase: String, Codable, Sendable {
    /// Recording (mic + ASR alive).
    case recording
    /// Paused by the user.
    case paused
    /// Ending: the final segment is being flushed / saved.
    case finalizing
    /// Ended and saved (shown briefly, then dismissed).
    case ended
    /// Ended after a failure — honest, non-technical.
    case failed
}

/// Translation health for the lock screen.
enum LiveTranslationHealth: String, Codable, Sendable {
    case unavailable
    case available
    case waitingForNetwork
    case notConfigured

    var label: String {
        switch self {
        case .unavailable: return "翻译不可用"
        case .available: return "翻译正常"
        case .waitingForNetwork: return "等待网络 · 转录继续"
        case .notConfigured: return "未配置翻译"
        }
    }
}

struct ClassroomSessionActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        /// Coarse user-safe phase (drives icon + label + timer behavior).
        var phase: LiveClassroomPhase
        /// Session start (fixed anchor; the timer text derives from
        /// accumulated seconds, not from raw wall time).
        var startedAt: Date
        /// Effective classroom seconds at the last push (excludes pause).
        var accumulatedSeconds: Int
        /// Anchor of the current RUNNING stretch (nil while paused) —
        /// `Text(timerInterval:)` counts live from here.
        var activeSince: Date?
        /// Local ASR health (always true while phase == .recording).
        var isTranscribing: Bool
        var translation: LiveTranslationHealth
        /// The single latest Chinese line, ONLY when the user's lock-screen
        /// privacy allows it; capped at capture time. Empty otherwise.
        var latestChinese: String
        /// Content older than this is dimmed by the system (set only for
        /// short-lived states; nil for a healthy running classroom).
        var staleAfter: Date?
        var updatedAt: Date
    }

    /// Stable persisted session identity.
    var sessionID: UUID
    var courseID: UUID?
    /// Classroom title as the user named it. The privacy setting decides
    /// whether system surfaces ever display it; the value itself is not
    /// sensitive beyond the name.
    var title: String
    /// Owning account scope ("guest" or account UUID) — the launch-time
    /// reconciler ends activities that outlived their profile.
    var scopeKey: String
}

// MARK: - Study Live Activity

enum LiveStudyPhase: String, Codable, Sendable {
    case running
    case paused
}

struct StudyActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        var phase: LiveStudyPhase
        var startedAt: Date
        /// Folded seconds at the last push (excludes the live stretch).
        var accumulatedSeconds: Int
        /// Anchor of the current running stretch (nil while paused).
        var activeSince: Date?
        /// Plan item's estimated minutes (0 = unknown).
        var estimatedMinutes: Int
        var staleAfter: Date?
        var updatedAt: Date
    }

    /// Stable persisted activity identity.
    var activityID: UUID
    var planItemID: UUID?
    /// What the user is studying (plan item title / exam title).
    var title: String
    var courseName: String
    var scopeKey: String
}

// MARK: - Task-carry box

/// Carries an `Activity` reference into a `Task` closure. ActivityKit does
/// not mark `Activity` Sendable, but its async `update`/`end` methods are
/// safe to call from any isolation (the system hops internally) — the
/// same wrapper pattern Apple's Live Activity samples use. The box only
/// makes that contract explicit for Swift 6's capture checks.
struct ActivityBox<Attributes: ActivityAttributes>: @unchecked Sendable {
    let activity: Activity<Attributes>
}
