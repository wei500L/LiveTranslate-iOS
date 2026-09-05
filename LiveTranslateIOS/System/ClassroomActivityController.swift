import Foundation
import ActivityKit
import OSLog

/// Owns the classroom Live Activity lifecycle, strictly as a SIDE EFFECT
/// of the real coordinator: it observes nothing on its own — the pipeline
/// observer (SystemIntegrationCoordinator) feeds it state changes, and it
/// translates them into ActivityKit calls. The classroom never depends on
/// this: every call site is failure-tolerant (permission denied, no
/// activity, ActivityKit errors → the classroom keeps running untouched).
@MainActor
final class ClassroomActivityController {
    private static let logger = Logger(
        subsystem: "com.livetranslate.ios", category: "classroom-activity"
    )

    private var activity: Activity<ClassroomSessionActivityAttributes>?
    /// Session id the current activity renders (guards duplicate creation
    /// and stale updates after a restart of the same classroom).
    private var activitySessionID: UUID?

    /// True when the finalizing state was already pushed (dedupe: the
    /// observer may see several stop-path updates).
    private var pushedFinalizing = false

    // MARK: - Lifecycle

    /// Create the activity AFTER a real, running session exists. Never
    /// called for failed / refused starts (the observer checks
    /// `isRunning` + `activeSessionID` first). Any ActivityKit error is
    /// logged and swallowed — a missing lock-screen card never disturbs
    /// the classroom.
    func startActivity(
        sessionID: UUID,
        courseID: UUID?,
        title: String,
        scopeKey: String,
        accumulatedSeconds: Int,
        isPaused: Bool,
        translation: LiveTranslationHealth,
        latestChinese: String
    ) {
        guard activity == nil || activitySessionID != sessionID else {
            // Same session: update in place instead of a second activity.
            return
        }
        endStaleActivity()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            Self.logger.info("live activities disabled; classroom continues without one")
            return
        }
        let attributes = ClassroomSessionActivityAttributes(
            sessionID: sessionID,
            courseID: courseID,
            title: title,
            scopeKey: scopeKey
        )
        let state = ClassroomSessionActivityAttributes.ContentState(
            phase: isPaused ? .paused : .recording,
            startedAt: Date().addingTimeInterval(-TimeInterval(accumulatedSeconds)),
            accumulatedSeconds: accumulatedSeconds,
            activeSince: isPaused ? nil : .now,
            isTranscribing: true,
            translation: translation,
            latestChinese: latestChinese,
            staleAfter: nil,
            updatedAt: .now
        )
        do {
            let content = ActivityContent(state: state, staleDate: nil)
            activity = try Activity.request(
                attributes: attributes, content: content,
                pushType: nil // No push tokens — local updates only.
            )
            activitySessionID = sessionID
            pushedFinalizing = false
            Self.logger.info("classroom live activity started")
        } catch {
            Self.logger.info("classroom live activity unavailable: \(error.localizedDescription)")
            activity = nil
            activitySessionID = nil
        }
    }

    /// Update the running activity's content (pause / resume / network /
    /// translation health / latest Chinese line).
    func update(
        sessionID: UUID,
        phase: LiveClassroomPhase,
        accumulatedSeconds: Int,
        isPaused: Bool,
        isTranscribing: Bool,
        translation: LiveTranslationHealth,
        latestChinese: String
    ) {
        guard let activity, activitySessionID == sessionID else { return }
        let staleAfter: Date? = {
            switch phase {
            case .finalizing, .ended, .failed:
                return .now.addingTimeInterval(60)
            default:
                // A healthy classroom may go hours between content
                // updates; no stale date.
                return nil
            }
        }()
        let state = ClassroomSessionActivityAttributes.ContentState(
            phase: phase,
            startedAt: Date().addingTimeInterval(-TimeInterval(accumulatedSeconds)),
            accumulatedSeconds: accumulatedSeconds,
            activeSince: isPaused ? nil : .now,
            isTranscribing: isTranscribing,
            translation: translation,
            latestChinese: latestChinese,
            staleAfter: staleAfter,
            updatedAt: .now
        )
        let staleDate = staleAfter
        Task { @MainActor in
            await activity.update(
                ActivityContent(state: state, staleDate: staleDate)
            )
        }
    }

    /// End-of-classroom flow: first push the honest 正在保存 / 已保存
    /// state, then dismiss (the system's default dismissal shows the final
    /// state briefly; failures dismiss immediately).
    func finishSession(sessionID: UUID, saved: Bool, accumulatedSeconds: Int = 0) {
        guard let activity, activitySessionID == sessionID else { return }
        let phase: LiveClassroomPhase = saved ? .ended : .failed
        let state = ClassroomSessionActivityAttributes.ContentState(
            phase: phase,
            startedAt: .now,
            accumulatedSeconds: accumulatedSeconds,
            activeSince: nil,
            isTranscribing: false,
            translation: .unavailable,
            latestChinese: "",
            staleAfter: .now.addingTimeInterval(15),
            updatedAt: .now
        )
        let session = activity
        Task { @MainActor in
            await session.update(ActivityContent(
                state: state,
                staleDate: .now.addingTimeInterval(15)
            ))
            await session.end(dismissalPolicy: saved ? .default : .immediate)
        }
        self.activity = nil
        activitySessionID = nil
        pushedFinalizing = false
    }

    /// The saving state at the START of the end flow.
    func markFinalizing(sessionID: UUID, accumulatedSeconds: Int) {
        guard !pushedFinalizing else { return }
        pushedFinalizing = true
        update(
            sessionID: sessionID,
            phase: .finalizing,
            accumulatedSeconds: accumulatedSeconds,
            isPaused: false,
            isTranscribing: false,
            translation: .unavailable,
            latestChinese: ""
        )
    }

    /// Launch-time / profile-switch cleanup: end every classroom activity
    /// this app owns that does not match the given live session id (nil =
    /// no live session → all such activities are stale).
    static func reconcileStaleActivities(activeSessionID: UUID?, scopeKey: String) {
        let mismatched = Activity<ClassroomSessionActivityAttributes>.activities
            .filter { activity in
                activity.attributes.sessionID != activeSessionID
                    || activity.attributes.scopeKey != scopeKey
            }
        for activity in mismatched {
            Task { @MainActor in
                await activity.end(dismissalPolicy: .immediate)
            }
        }
    }

    /// End any activity this controller currently owns (teardown without
    /// a saving state — e.g. account switch, where the classroom is
    /// already stopping).
    func endOwnedActivity() {
        guard let activity else { return }
        let session = activity
        Task { @MainActor in
            await session.end(dismissalPolicy: .immediate)
        }
        self.activity = nil
        activitySessionID = nil
        pushedFinalizing = false
    }

    /// Whether an activity for the session already exists (used by the
    /// launch recovery: a lost in-memory handle with a live system
    /// activity for the SAME session is re-adopted by re-requesting).
    var currentActivitySessionID: UUID? { activitySessionID }

    private func endStaleActivity() {
        guard let activity else { return }
        let session = activity
        Task { @MainActor in
            await session.end(dismissalPolicy: .immediate)
        }
        self.activity = nil
        activitySessionID = nil
    }
}
