import SwiftUI

/// Root layout: native `TabView(selection:)` keeps all five tabs alive
/// (首页 · 课堂记录 · 书签 · 搜索 · 我的) so each tab's scroll position,
/// search text, filters and its own `NavigationStack` path survive tab
/// switches — the system tab bar is hidden and the reference design's
/// floating dark bar is overlaid instead. A live classroom is presented
/// full-screen above everything and supplies its own internal toolbar
/// (转写 / 笔记 / 书签 / 搜索).
struct RootTabView: View {
    @Environment(AppEnvironment.self) private var environment

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
                BookmarksScreen()
                    .toolbar(.hidden, for: .tabBar)
                    .tag(LTTab.bookmarks)
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
        .task {
            environment.reconcileAbnormalTerminations()
            environment.modelManager.refreshStates()
            #if DEBUG
            environment.presentDemoLaunchScreenIfNeeded()
            #endif
        }
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
