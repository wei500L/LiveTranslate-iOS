import Foundation
import ActivityKit
import OSLog

/// Owns the learning-timer Live Activity — same discipline as the
/// classroom controller: a pure side effect of the REAL StudyActivityTracker,
/// fed by the SystemIntegrationCoordinator. The tracker's data semantics
/// (timestamps, folded minutes, exactly-one activity) are untouched; the
/// activity ENDS when the activity row ends, and completion never happens
/// here — the data writes happen in the app's real completion flow.
@MainActor
final class StudyActivityController {
    private static let logger = Logger(
        subsystem: "com.livetranslate.ios", category: "study-activity"
    )

    private var activity: Activity<StudyActivityAttributes>?
    private var activityID: UUID?

    // MARK: - Lifecycle

    func startActivity(
        activityID: UUID,
        planItemID: UUID?,
        title: String,
        courseName: String,
        scopeKey: String,
        startedAt: Date,
        accumulatedSeconds: Int,
        isPaused: Bool,
        estimatedMinutes: Int
    ) {
        guard activity == nil || self.activityID != activityID else { return }
        endOwnedActivity()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            Self.logger.info("live activities disabled; study timer continues without one")
            return
        }
        let attributes = StudyActivityAttributes(
            activityID: activityID,
            planItemID: planItemID,
            title: title,
            courseName: courseName,
            scopeKey: scopeKey
        )
        let state = StudyActivityAttributes.ContentState(
            phase: isPaused ? .paused : .running,
            startedAt: startedAt,
            accumulatedSeconds: accumulatedSeconds,
            activeSince: isPaused ? nil : .now,
            estimatedMinutes: estimatedMinutes,
            staleAfter: nil,
            updatedAt: .now
        )
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            self.activityID = activityID
            Self.logger.info("study live activity started")
        } catch {
            Self.logger.info("study live activity unavailable: \(error.localizedDescription)")
            activity = nil
            self.activityID = nil
        }
    }

    func update(
        activityID: UUID,
        phase: LiveStudyPhase,
        startedAt: Date,
        accumulatedSeconds: Int,
        isPaused: Bool,
        estimatedMinutes: Int
    ) {
        guard let activity, self.activityID == activityID else { return }
        let state = StudyActivityAttributes.ContentState(
            phase: phase,
            startedAt: startedAt,
            accumulatedSeconds: accumulatedSeconds,
            activeSince: isPaused ? nil : .now,
            estimatedMinutes: estimatedMinutes,
            staleAfter: nil,
            updatedAt: .now
        )
        let session = activity
        Task {
            await session.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    /// The activity row ended (completed or abandoned — the real data
    /// writes already happened in the tracker). Dismiss the activity.
    func endActivity(activityID: UUID) {
        guard let activity, self.activityID == activityID else { return }
        let session = activity
        Task {
            await session.end(dismissalPolicy: .immediate)
        }
        self.activity = nil
        self.activityID = nil
    }

    func endOwnedActivity() {
        guard let activity else { return }
        let session = activity
        Task {
            await session.end(dismissalPolicy: .immediate)
        }
        self.activity = nil
        self.activityID = nil
    }

    /// Launch-time cleanup: end study activities that outlived their
    /// tracker row (or belong to another profile).
    static func reconcileStaleActivities(activeActivityID: UUID?, scopeKey: String) {
        let mismatched = Activity<StudyActivityAttributes>.activities
            .filter { activity in
                activity.attributes.activityID != activeActivityID
                    || activity.attributes.scopeKey != scopeKey
            }
        for activity in mismatched {
            Task {
                await activity.end(dismissalPolicy: .immediate)
            }
        }
    }
}
