import SwiftUI
import CoreSpotlight

/// Root layout: native `TabView(selection:)` keeps all five tabs alive
/// (首页 · 课堂记录 · 复习 · 搜索 · 我的) so each tab's scroll position,
/// search text, filters and its own `NavigationStack` path survive tab
/// switches — the system tab bar is hidden and the reference design's
/// floating dark bar is overlaid instead. A live classroom is presented
/// full-screen above everything and supplies its own internal toolbar
/// (转写 / 笔记 / 书签 / 搜索).
struct RootTabView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSession.self) private var session
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            LTBackground()

            // Native TabView: switching tabs only changes visibility, never
            // view identity — each screen's @State view models, scroll
            // offsets and navigation paths persist. Data freshness is
            // handled by each screen's .onAppear reload.
            TabView(selection: tabBinding) {
                HomeScreen()
                    .toolbar(.hidden, for: .tabBar)
                    .tag(LTTab.home)
                RecordsScreen()
                    .toolbar(.hidden, for: .tabBar)
                    .tag(LTTab.records)
                ReviewCenterScreen()
                    .toolbar(.hidden, for: .tabBar)
                    .tag(LTTab.review)
                SearchScreen()
                    .toolbar(.hidden, for: .tabBar)
                    .tag(LTTab.search)
                SettingsScreen()
                    .toolbar(.hidden, for: .tabBar)
                    .tag(LTTab.profile)
            }
            .padding(.bottom, LTSpacing.tabBarReserve)

            // The floating bar hides while a live classroom is the front
            // presentation (the classroom provides its own controls).
            if !environment.flow.isLivePresented {
                VStack {
                    Spacer()
                    LTFloatingTabBar(selection: tabBinding)
                }
            }
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: liveBinding) {
            LiveScreen(viewModel: environment.acquireLiveViewModel())
                .environment(environment)
        }
        // Password-reset deep link (Universal Link / livetranslate://
        // scheme). The token lives only in AppSession memory + this view's
        // sheet state; dismissed or completed, it is cleared immediately.
        .sheet(isPresented: resetBinding) {
            NavigationStack {
                PasswordRecoveryView(prefilledToken: session.pendingResetToken)
            }
        }
        .task {
            environment.reconcileAbnormalTerminations()
            environment.modelManager.refreshStates()
            environment.cloudSync?.start()
            await environment.refreshClassReminders()
            // Shared inbox: launch-time reconciliation (interrupted
            // receives, orphan temp files, missing payloads).
            environment.inbox.reconcile()
            // System integration: routes queued while the app was dead,
            // stale Live Activities from the previous run, initial
            // snapshot + widget refresh, command observer.
            environment.systemCoordinator?.handleLaunch()
            #if DEBUG
            environment.presentDemoLaunchScreenIfNeeded()
            #endif
        }
        // Returning to the foreground is a sync trigger: anything that
        // accumulated while the app was backgrounded flushes now, and the
        // reminder rolling window re-arms (schedules may have changed via
        // pull). The shared inbox re-reads too — the Share Extension may
        // have landed new items while the app was backgrounded.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                environment.cloudSync?.syncNow()
                Task { await environment.refreshClassReminders() }
                environment.inbox.reconcile()
                // A backgrounded learning timer keeps counting by
                // timestamps; the checkpoint folds the elapsed stretch
                // into the row so the synced duration stays honest.
                environment.studyActivityTracker.checkpoint()
                // System surfaces: consume routes/commands queued while
                // backgrounded (widgets stay live off the snapshot) and
                // refresh the snapshot itself.
                environment.systemCoordinator?.handleForeground()
            }
        }
        // Study-timer observation: in-app pause/resume/finish reflect
        // into the study Live Activity + snapshot.
        .onChange(of: environment.studyActivityTracker.currentActivity?.id) { _, _ in
            environment.systemCoordinator?.syncStudyActivity(startIfMissing: true)
            environment.systemCoordinator?.refreshSnapshotAndWidgets(force: true)
        }
        .onChange(of: environment.studyActivityTracker.isPaused) { _, _ in
            environment.systemCoordinator?.syncStudyActivity(startIfMissing: false)
            environment.systemCoordinator?.refreshSnapshotAndWidgets(force: true)
        }
        // System-route honest feedback: a deleted target lands as a
        // one-shot banner instead of a silent dead tab.
        .alert(
            "内容已不存在",
            isPresented: Binding(
                get: { environment.missingTargetMessage != nil },
                set: { if !$0 { environment.consumeMissingTargetMessage() } }
            )
        ) {
            Button("好", role: .cancel) { environment.consumeMissingTargetMessage() }
        } message: {
            Text(environment.missingTargetMessage ?? "")
        }
        // Spotlight taps arrive as continue-userActivity with the item's
        // identifier; route through the unified coordinator.
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            if let identifier = activity.userInfo?
                .first(where: { $0.key == CSSearchableItemActivityIdentifier })?
                .value as? String {
                environment.systemCoordinator?.handleSpotlightIdentifier(identifier)
            }
        }
    }

    /// Presents while a reset token is parked; clearing the token (dismiss
    /// or completion) closes the sheet.
    private var resetBinding: Binding<Bool> {
        Binding(
            get: { session.pendingResetToken != nil },
            set: { presented in
                if !presented {
                    session.consumeResetToken()
                }
            }
        )
    }

    private var tabBinding: Binding<LTTab> {
        Binding(
            get: { environment.flow.selectedTab },
            set: { environment.flow.selectedTab = $0 }
        )
    }

    private var liveBinding: Binding<Bool> {
        Binding(
            get: { environment.flow.isLivePresented },
            set: { presented in
                if presented {
                    environment.presentLive()
                } else {
                    // Swipe dismissal is disabled while a classroom runs,
                    // so reaching here means the classroom has ended.
                    environment.flow.collapseLive()
                }
            }
        )
    }
}
