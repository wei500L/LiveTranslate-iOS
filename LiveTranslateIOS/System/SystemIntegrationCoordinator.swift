import Foundation
import OSLog
import WidgetKit

/// The system-integration driver — ONE per production profile, owned by
/// the AppEnvironment. It bridges the app's REAL state to the system
/// surfaces and back:
///
/// - observes the real coordinator (a bounded-cadence task mirroring the
///   @Observable pipeline — never per-audio-level, never per-ASR-window)
///   and reflects state into the classroom Live Activity + snapshot;
/// - consumes system commands (pause/resume from the lock screen /
///   Dynamic Island) against the real coordinator, validated by session
///   and scope, idempotently;
/// - consumes system route requests through the SystemRouteCoordinator;
/// - maintains the Core Spotlight index (SpotlightIndexer);
/// - refreshes widgets (throttled, event-driven);
/// - reconciles stale activities at launch.
///
/// Failure tolerance: every path here is a side effect. If ActivityKit is
/// disabled, the App Group is unavailable, Spotlight fails or the widget
/// extension crashes, the classroom, study timer and all data flows keep
/// working untouched.
@MainActor
final class SystemIntegrationCoordinator {
    private static let logger = Logger(
        subsystem: "com.livetranslate.ios", category: "system-integration"
    )

    private let environment: AppEnvironment
    private let scopeKey: String
    let snapshotUpdater: SystemSnapshotUpdater
    let classroomActivity: ClassroomActivityController
    let studyActivity: StudyActivityController
    private let routeCoordinator: SystemRouteCoordinator
    private let commandStore = SystemCommandStore()
    private let spotlight = SpotlightIndexer()

    /// Darwin-notification observer (commands arriving while the app runs
    /// under background audio). CF callbacks arrive on an arbitrary
    /// thread — the observer hops to the main actor.
    private var darwinObserverInstalled = false
    /// Recently executed command ids (idempotent consumption).
    private var executedCommandIDs: Set<UUID> = []
    /// The session the current classroom observation tracks (also the
    /// end-of-flow target when the coordinator has already cleared).
    private var lastClassroomSessionID: UUID?

    /// Pipeline observation task (phase / pause / elapsed / latest line).
    private var pipelineTask: Task<Void, Never>?
    /// Snapshot regeneration throttle state.
    private var lastFullUpdate = Date.distantPast

    init(environment: AppEnvironment, scopeKey: String) {
        self.environment = environment
        self.scopeKey = scopeKey
        self.snapshotUpdater = SystemSnapshotUpdater(
            repository: environment.repository,
            scopeKey: scopeKey,
            isTranslationConfigured: { [weak environment] in
                environment?.isTranslationConfigured ?? false
            }
        )
        self.classroomActivity = ClassroomActivityController()
        self.studyActivity = StudyActivityController()
        self.routeCoordinator = SystemRouteCoordinator(
            environment: environment, scopeKey: scopeKey
        )
    }

    // MARK: - Lifecycle (launch / foreground)

    /// Launch-time reconciliation: routes queued while dead, stale
    /// activities from a previous run / profile, initial snapshot.
    func handleLaunch() {
        routeCoordinator.consumePendingRoutes()
        ClassroomActivityController.reconcileStaleActivities(
            activeSessionID: nil, scopeKey: scopeKey
        )
        StudyActivityController.reconcileStaleActivities(
            activeActivityID: environment.studyActivityTracker.currentActivity?.id,
            scopeKey: scopeKey
        )
        // A running classroom cannot survive an app relaunch (the whole
        // pipeline is in-memory); the tracker CAN — sync its activity.
        syncStudyActivity(startIfMissing: true)
        refreshSnapshotAndWidgets(force: true)
        // Watch for commands while alive (background audio keeps the
        // process around during a classroom).
        installDarwinObserver()
    }

    /// Foreground entry: consume routes + commands, refresh everything.
    func handleForeground() {
        routeCoordinator.consumePendingRoutes()
        consumeCommands()
        syncStudyActivity(startIfMissing: true)
        refreshSnapshotAndWidgets(force: true)
    }

    /// Profile teardown (account switch): everything the old profile owns
    /// in the system surfaces goes away before the new profile builds.
    func handleProfileTearDown() {
        pipelineTask?.cancel()
        pipelineTask = nil
        classroomActivity.endOwnedActivity()
        studyActivity.endOwnedActivity()
        removeDarwinObserver()
        snapshotUpdater.clear()
        spotlight.deactivate()
        SystemRouteStore().clear()
        SystemCommandStore().replace([])
    }

    // MARK: - Classroom lifecycle bridge

    /// A classroom just STARTED successfully — called only after the real
    /// coordinator reports a running session with a persisted id. Creates
    /// the Live Activity, starts observation, refreshes the snapshot.
    func handleClassroomStarted() {
        let coordinator = environment.coordinator
        guard coordinator.isRunning, let sessionID = coordinator.activeSessionID else {
            return
        }
        lastClassroomSessionID = sessionID
        // Product rule (§10): the classroom is THE one primary activity.
        // A study activity paused by the start funnel gives up its Live
        // Activity here (the row stays paused and honest); it returns when
        // studying actually resumes (classroom over — the funnels and the
        // command consumer both enforce the mutual exclusion).
        studyActivity.endOwnedActivity()
        classroomActivity.startActivity(
            sessionID: sessionID,
            courseID: coordinator.activeSessionCourseID,
            title: coordinator.activeSessionTitle ?? "课堂",
            scopeKey: scopeKey,
            accumulatedSeconds: Int(coordinator.state.elapsed),
            isPaused: coordinator.isPaused,
            translation: translationHealth(coordinator),
            latestChinese: latestChinese(for: coordinator)
        )
        startPipelineObservation()
        refreshSnapshotAndWidgets(force: true)
    }

    /// The classroom END flow began (AppEnvironment.endLiveSession,
    /// BEFORE the coordinator's stop drains the final segment) — show the
    /// honest 正在保存 state.
    func handleClassroomStopping() {
        let coordinator = environment.coordinator
        if let sessionID = coordinator.activeSessionID {
            lastClassroomSessionID = sessionID
            classroomActivity.markFinalizing(
                sessionID: sessionID,
                accumulatedSeconds: Int(coordinator.state.elapsed)
            )
        }
    }

    /// The classroom ENDED (the coordinator's stop finished). saved=false
    /// only for the failed path.
    func handleClassroomEnded(saved: Bool) {
        let sessionID = lastClassroomSessionID
            ?? environment.coordinator.activeSessionID
        if let sessionID {
            classroomActivity.finishSession(
                sessionID: sessionID,
                saved: saved,
                accumulatedSeconds: Int(environment.coordinator.state.elapsed)
            )
        } else {
            classroomActivity.endOwnedActivity()
        }
        lastClassroomSessionID = nil
        pipelineTask?.cancel()
        pipelineTask = nil
        refreshSnapshotAndWidgets(force: true)
    }

    // MARK: - Study activity sync (tracker → activity)

    /// Mirrors the tracker's current row into the study Live Activity.
    /// The classroom/study mutual exclusion is enforced by the app's
    /// start funnels, not here; this only reflects reality — and never
    /// starts a study activity while a classroom runs (the classroom is
    /// the one primary activity).
    func syncStudyActivity(startIfMissing: Bool) {
        let tracker = environment.studyActivityTracker
        if let activity = tracker.currentActivity, activity.status == .inProgress {
            let classroomRunning = environment.coordinator.isRunning
            if studyActivity.currentActivitySessionID == nil {
                if startIfMissing, !classroomRunning {
                    let info = studyDisplayInfo(activity)
                    studyActivity.startActivity(
                        activityID: activity.id,
                        planItemID: activity.planItemID,
                        title: info.title,
                        courseName: info.courseName,
                        scopeKey: scopeKey,
                        startedAt: activity.startedAt,
                        accumulatedSeconds: activity.durationSeconds,
                        isPaused: tracker.isPaused,
                        estimatedMinutes: info.estimatedMinutes
                    )
                }
            } else {
                let info = studyDisplayInfo(activity)
                studyActivity.update(
                    activityID: activity.id,
                    phase: tracker.isPaused ? .paused : .running,
                    startedAt: activity.startedAt,
                    accumulatedSeconds: activity.durationSeconds,
                    isPaused: tracker.isPaused,
                    estimatedMinutes: info.estimatedMinutes
                )
            }
        } else if let id = studyActivity.currentActivitySessionID {
            // Row gone (completed / abandoned) — the activity ends AFTER
            // the data, never before.
            studyActivity.endActivity(activityID: id)
        }
    }

    // MARK: - Command consumption

    /// Execute queued system commands against the REAL coordinator /
    /// tracker. Validation: scope match, session/activity match, expiry,
    /// idempotency. A dropped command is honestly dropped (the lock
    /// screen shows the next snapshot's truth). The queue is consumed
    /// exactly once per entry — executed, expired, foreign or duplicate.
    func consumeCommands() {
        let queue = commandStore.loadQueue()
        guard !queue.isEmpty else { return }
        let now = Date()
        var changed = false
        for command in queue {
            guard !executedCommandIDs.contains(command.id) else { continue }
            // Expired or foreign-scope commands are dropped, not run.
            guard command.createdAt > now.addingTimeInterval(-SystemCommandStore.expiry),
                  command.scopeKey == scopeKey else { continue }
            let executed = execute(command)
            executedCommandIDs.insert(command.id)
            changed = changed || executed
        }
        commandStore.replace([])
        if changed {
            refreshSnapshotAndWidgets(force: true)
        }
        // Bound the memory of executed ids.
        if executedCommandIDs.count > 256 {
            executedCommandIDs = Set(Array(executedCommandIDs).suffix(128))
        }
    }

    @discardableResult
    private func execute(_ command: SystemCommand) -> Bool {
        let coordinator = environment.coordinator
        switch command.kind {
        case .pauseClassroom:
            guard coordinator.isRunning, !coordinator.isPaused,
                  coordinator.activeSessionID == command.sessionID else { return false }
            coordinator.pause()
            pushClassroomUpdate()
            return true
        case .resumeClassroom:
            guard coordinator.isRunning, coordinator.isPaused,
                  coordinator.activeSessionID == command.sessionID else { return false }
            coordinator.resume()
            pushClassroomUpdate()
            return true
        case .pauseStudy:
            let tracker = environment.studyActivityTracker
            guard tracker.hasActiveActivity, !tracker.isPaused,
                  tracker.currentActivity?.id == command.activityID else { return false }
            tracker.pause()
            syncStudyActivity(startIfMissing: false)
            refreshSnapshotAndWidgets(force: true)
            return true
        case .resumeStudy:
            let tracker = environment.studyActivityTracker
            // Mutual exclusion: study time never overlaps classroom
            // recording — a resume command arriving while a classroom
            // runs is honestly refused (the tracker stays paused).
            guard !environment.coordinator.isRunning,
                  tracker.hasActiveActivity, tracker.isPaused,
                  tracker.currentActivity?.id == command.activityID else { return false }
            tracker.resume()
            syncStudyActivity(startIfMissing: false)
            refreshSnapshotAndWidgets(force: true)
            return true
        }
    }

    // MARK: - Snapshot & widgets

    /// Full snapshot regeneration + widget reload request. Throttled at
    /// 2s — the pipeline observer and the command consumer both funnel
    /// here (force bypasses for user-visible transitions).
    func refreshSnapshotAndWidgets(force: Bool = false) {
        let now = Date()
        if !force, now.timeIntervalSince(lastFullUpdate) < 2 {
            return
        }
        lastFullUpdate = now
        snapshotUpdater.update(
            coordinator: environment.coordinator,
            studyTracker: environment.studyActivityTracker,
            inboxPendingCount: environment.inbox.pendingCount,
            privacy: SettingsStore.shared.lockScreenPrivacy
        )
        let kinds = [
            "NextClassWidget", "TodayStudyWidget", "NextExamWidget"
        ]
        Task.detached {
            for kind in kinds {
                WidgetCenter.shared.reloadTimelines(ofKind: kind)
            }
        }
    }

    // MARK: - Pipeline observation

    /// Bounded observation of the classroom pipeline: a repeating task at
    /// 2s cadence while a classroom runs, pushing the activity content +
    /// snapshot when the user-visible state actually changed (phase,
    /// pause, network, translation health, latest Chinese line, minute
    /// granularity of elapsed). The classroom itself never depends on
    /// this loop.
    private func startPipelineObservation() {
        pipelineTask?.cancel()
        pipelineTask = Task { [weak self] in
            var lastPhase: PipelinePhase?
            var lastPaused: Bool?
            var lastNetwork: Bool?
            var lastTranslation: LiveTranslationHealth?
            var lastChinese: String?
            var lastElapsedMinute = -1
            while !Task.isCancelled {
                guard let self else { return }
                let coordinator = self.environment.coordinator
                if !coordinator.isRunning {
                    // The classroom left the running set OUTSIDE the normal
                    // end flow (backend error / missing resources): show
                    // the honest failed state and dismiss — never pretend
                    // recording continues.
                    switch coordinator.state.phase {
                    case .backendError, .modelNotInstalled, .diskSpaceLow:
                        if let sessionID = self.lastClassroomSessionID
                            ?? coordinator.activeSessionID {
                            self.classroomActivity.finishSession(
                                sessionID: sessionID, saved: false
                            )
                        } else {
                            self.classroomActivity.endOwnedActivity()
                        }
                    default:
                        break // The normal end flow handles its own states.
                    }
                    return
                }
                let phase = coordinator.state.phase
                let paused = coordinator.isPaused
                let network = coordinator.isNetworkAvailable
                let translation = self.translationHealth(coordinator)
                let chinese = self.latestChinese(for: coordinator)
                let elapsedMinute = Int(coordinator.state.elapsed) / 60
                if phase != lastPhase || paused != lastPaused || network != lastNetwork
                    || translation != lastTranslation || chinese != lastChinese
                    || elapsedMinute != lastElapsedMinute {
                    lastPhase = phase
                    lastPaused = paused
                    lastNetwork = network
                    lastTranslation = translation
                    lastChinese = chinese
                    lastElapsedMinute = elapsedMinute
                    if let sessionID = coordinator.activeSessionID {
                        self.lastClassroomSessionID = sessionID
                        self.classroomActivity.update(
                            sessionID: sessionID,
                            phase: Self.livePhase(for: phase, paused: paused),
                            accumulatedSeconds: Int(coordinator.state.elapsed),
                            isPaused: paused,
                            isTranscribing: coordinator.isRunning,
                            translation: translation,
                            latestChinese: chinese
                        )
                    }
                    self.refreshSnapshotAndWidgets()
                }
                if phase == .finished { return }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    // MARK: - Darwin notification observer (command wake)

    /// Installs the wake-up observer. The C callback hops to the main
    /// actor via a detached task; a duplicate install is a no-op.
    private func installDarwinObserver() {
        guard !darwinObserverInstalled else { return }
        darwinObserverInstalled = true
        DarwinWake.install { [weak self] in
            Task { @MainActor [weak self] in
                self?.consumeCommands()
            }
        }
    }

    private func removeDarwinObserver() {
        DarwinWake.removeObserver()
        darwinObserverInstalled = false
    }

    // MARK: - Spotlight bridge

    /// Re-index one entity after a real mutation (created / updated).
    func indexEntity(_ id: UUID, kind: SpotlightEntityKind) {
        spotlight.index(
            id: id, kind: kind,
            repository: environment.repository, scopeKey: scopeKey
        )
    }

    /// Remove one entity's index entry after a real deletion.
    func removeEntity(id: UUID, kind: SpotlightEntityKind) {
        spotlight.remove(id: id, kind: kind)
    }

    /// Full rebuild (batched; rare — after a full sync pull or a data
    /// restore).
    func rebuildSpotlightIndex() {
        spotlight.rebuildAll(
            repository: environment.repository, scopeKey: scopeKey
        )
    }

    /// Route from a Spotlight tap (the item's activity identifier).
    func handleSpotlightIdentifier(_ identifier: String) {
        guard let route = SpotlightIndexer.route(forIdentifier: identifier) else { return }
        routeCoordinator.navigate(to: route)
    }

    // MARK: - Helpers

    private func translationHealth(
        _ coordinator: any LiveTranslationCoordinating
    ) -> LiveTranslationHealth {
        switch coordinator.state.phase {
        case .networkOffline: return .waitingForNetwork
        default:
            return environment.isTranslationConfigured ? .available : .notConfigured
        }
    }

    private func latestChinese(for coordinator: any LiveTranslationCoordinating) -> String {
        guard SettingsStore.shared.lockScreenPrivacy == .statusTitleAndLatestText else { return "" }
        return coordinator.entries
            .last { $0.translationStatus == .completed }
            .flatMap { $0.translatedText } ?? ""
    }

    private static func livePhase(for phase: PipelinePhase, paused: Bool) -> LiveClassroomPhase {
        if paused { return .paused }
        switch phase {
        case .finished: return .ended
        case .backendError, .modelNotInstalled, .diskSpaceLow: return .failed
        default: return .recording
        }
    }

    private func studyDisplayInfo(_ activity: StudyActivity) -> (title: String, courseName: String, estimatedMinutes: Int) {
        let repository = environment.repository
        var title = "自主学习"
        var estimatedMinutes = 0
        if let itemID = activity.planItemID,
           let item = try? repository.studyPlanItem(id: itemID) {
            title = item.title
            estimatedMinutes = item.estimatedMinutes
        } else if let examID = activity.examID,
            let exam = try? repository.exam(id: examID) {
            title = exam.title
        }
        var courseName = ""
        if let courseID = activity.courseID,
           let course = try? repository.course(id: courseID) {
            courseName = course.name
        }
        return (title, courseName, estimatedMinutes)
    }

    /// Immediately push the classroom activity + snapshot (after a
    /// command executed — the lock screen must not wait for the loop).
    private func pushClassroomUpdate() {
        let coordinator = environment.coordinator
        guard coordinator.isRunning, let sessionID = coordinator.activeSessionID else {
            return
        }
        classroomActivity.update(
            sessionID: sessionID,
            phase: Self.livePhase(for: coordinator.state.phase, paused: coordinator.isPaused),
            accumulatedSeconds: Int(coordinator.state.elapsed),
            isPaused: coordinator.isPaused,
            isTranscribing: coordinator.isRunning,
            translation: translationHealth(coordinator),
            latestChinese: latestChinese(for: coordinator)
        )
    }
}

// MARK: - Darwin wake helper

/// CFNotificationCenter Darwin-observer bridge. The CF callback arrives
/// on an arbitrary thread; the handler must hop to the main actor
/// itself. Only ONE observer is installed app-wide (the coordinator is
/// rebuilt per profile — removeObserver precedes each reinstall).
@MainActor
enum DarwinWake {
    nonisolated(unsafe) private static var box: DarwinWakeBox?

    static func install(_ handler: @escaping @Sendable () -> Void) {
        removeObserver()
        let newBox = DarwinWakeBox(handler: handler)
        newBox.start()
        box = newBox
    }

    static func removeObserver() {
        box?.stop()
        box = nil
    }
}

private final class DarwinWakeBox: @unchecked Sendable {
    private let handler: @Sendable () -> Void
    /// CF observer token (opaque; also the info pointer passed back).
    private var token: UnsafeMutableRawPointer?

    init(handler: @escaping @Sendable () -> Void) {
        self.handler = handler
    }

    func start() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        // The info pointer carries the box reference into the C callback.
        let info = Unmanaged.passRetained(DarwinWakeRef(box: self)).toOpaque()
        let callback: CFNotificationCallback = { _, info, _, _, _ in
            guard let info else { return }
            let ref = Unmanaged<DarwinWakeRef>.fromOpaque(info).takeUnretainedValue()
            ref.box.handler()
        }
        CFNotificationCenterAddObserver(
            center,
            CFNotificationName((SystemCommandStore.darwinNotificationName as CFString)),
            callback,
            nil,
            info,
            .deliverImmediately
        )
        token = info
    }

    func stop() {
        guard let token else { return }
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveEveryObserver(center, token)
        // Release the retained ref; take it back so passRetained balances.
        Unmanaged<DarwinWakeRef>.fromOpaque(token).release()
        self.token = nil
    }
}

/// Retain-cycle-free wrapper: CF's info pointer must outlive the observer
/// while the box itself is owned by DarwinWake.
private final class DarwinWakeRef: @unchecked Sendable {
    let box: DarwinWakeBox
    init(box: DarwinWakeBox) { self.box = box }
}
