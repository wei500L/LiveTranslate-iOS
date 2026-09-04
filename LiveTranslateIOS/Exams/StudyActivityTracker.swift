import Foundation
import Observation

/// The learning-timer controller (真实学习计时) — one per profile, owned
/// by AppEnvironment.
///
/// Design (per the 考试中心 spec):
/// - elapsed time is computed FROM TIMESTAMPS (`StudyActivity.
///   liveElapsedSeconds`), never by a per-second task; a 1-minute UI
/// tick is display-only;
/// - background time counts (the student keeps studying with the screen
/// off — timestamps cover it);
/// - a pause bookkeeping key persists in account defaults so an
/// interrupted run resumes after app restarts;
/// - exactly one in-progress activity exists at a time (the repository
/// enforces it; the UI offers resume/finish instead of a second start);
/// - starting a CLASSROOM recording prompts the user to pause/finish
/// (the check lives in the start funnels, reading `hasActiveActivity`);
/// - classroom recording time NEVER becomes study time — only these
///   rows count (repository.studyActivityMinutes).
@MainActor
@Observable
final class StudyActivityTracker {
    private let repository: any ClassroomRepositoryProtocol
    private let defaults: UserDefaults

    /// The in-progress activity row (loaded at init, reloaded on
    /// mutations).
    private(set) var currentActivity: StudyActivity?

    /// The persisted active-stretch anchor (survives restarts). Keyed by
    /// activity id so a stale anchor never applies to a new row.
    private static let activeSinceKey = "study.activeSince"
    private static let activeActivityKey = "study.activeActivityID"

    init(repository: any ClassroomRepositoryProtocol, defaults: UserDefaults) {
        self.repository = repository
        self.defaults = defaults
        currentActivity = try? repository.currentStudyActivity()
        restorePauseState()
    }

    /// Whether a learning timer is running (the classroom-start funnels
    /// check this to offer pause/finish).
    var hasActiveActivity: Bool {
        currentActivity?.status == .inProgress
    }

    var isPaused: Bool {
        currentActivity?.pausedAt != nil
    }

    /// Display-only elapsed seconds (the view ticks a timer itself).
    var elapsedSeconds: Int {
        currentActivity?.liveElapsedSeconds ?? 0
    }

    var elapsedLabel: String {
        let seconds = elapsedSeconds
        let minutes = seconds / 60
        return String(format: "%02d:%02d", minutes, seconds % 60)
    }

    // MARK: - Lifecycle

    /// Starts a new activity for a plan item. Returns false when another
    /// one is already running (the exactly-one invariant).
    @discardableResult
    func start(draft: StudyActivityDraft) -> Bool {
        guard currentActivity == nil else { return false }
        guard let activity = try? repository.startStudyActivity(draft) else { return false }
        currentActivity = activity
        activity.activeSince = .now
        activity.pausedAt = nil
        persistAnchors(activityID: activity.id, activeSince: activity.activeSince)
        try? repository.checkpointStudyActivity(activity)
        return true
    }

    /// Pause: the folded duration rides the next checkpoint.
    func pause() {
        guard let activity = currentActivity else { return }
        try? repository.pauseStudyActivity(activity)
        persistAnchors(activityID: activity.id, activeSince: nil)
    }

    /// Resume after a pause.
    func resume() {
        guard let activity = currentActivity else { return }
        try? repository.resumeStudyActivity(activity)
        activity.activeSince = .now
        persistAnchors(activityID: activity.id, activeSince: activity.activeSince)
        try? repository.checkpointStudyActivity(activity)
    }

    /// Finish (completed) — the measured minutes flow back onto the plan
    /// item; never faked as done when nothing was studied.
    func complete(note: String = "") {
        finish(status: .completed, note: note)
    }

    /// Abandon — recorded honestly as 放弃, never disguised as completed.
    func abandon(note: String = "") {
        finish(status: .abandoned, note: note)
    }

    private func finish(status: StudyActivityStatus, note: String) {
        guard let activity = currentActivity else { return }
        try? repository.finishStudyActivity(activity, status: status, note: note)
        currentActivity = nil
        clearAnchors()
    }

    /// Background/foreground checkpoint: fold the elapsed stretch into
    /// the row so the synced duration stays honest.
    func checkpoint() {
        guard let activity = currentActivity else { return }
        try? repository.checkpointStudyActivity(activity)
    }

    // MARK: - Pause-state persistence

    private func persistAnchors(activityID: UUID, activeSince: Date?) {
        defaults.set(activityID.uuidString, forKey: Self.activeActivityKey)
        if let activeSince {
            defaults.set(activeSince, forKey: Self.activeSinceKey)
        } else {
            defaults.removeObject(forKey: Self.activeSinceKey)
        }
    }

    private func clearAnchors() {
        defaults.removeObject(forKey: Self.activeActivityKey)
        defaults.removeObject(forKey: Self.activeSinceKey)
    }

    /// Restores the pause bookkeeping after a restart: if the activity
    /// is in progress but not paused, the persisted anchor (or the row's
    /// startedAt) resumes counting — background time was real studying.
    private func restorePauseState() {
        guard let activity = currentActivity else { return }
        let storedID = defaults.string(forKey: Self.activeActivityKey)
        guard storedID == activity.id.uuidString else {
            clearAnchors()
            activity.activeSince = activity.startedAt
            return
        }
        if let since = defaults.object(forKey: Self.activeSinceKey) as? Date {
            activity.activeSince = since
            if activity.pausedAt == nil {
                // Not paused: the anchor is the active-stretch start.
                return
            }
        } else {
            activity.activeSince = activity.startedAt
        }
    }
}
