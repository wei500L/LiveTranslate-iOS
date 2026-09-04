import SwiftUI
import WidgetKit
import AppIntents

// Control Center + Action Button controls (iOS 18+ availability-guarded;
// the app's deployment target stays iOS 17). Every control is a ROUTE —
// it opens the app at the right place; none of them starts the
// microphone, pauses recording or takes any business action by itself
// (system-integration honesty rule: no unconfirmed recording from the
// lock screen, no fake control success).

// MARK: - Tile intents

@available(iOS 18.0, *)
struct OpenClassroomTileIntent: AppIntent {
    static let title: LocalizedStringResource = "当前课堂"
    /// Controls only navigate — the app opens at the classroom (or the
    /// start form when none runs).
    static let openAppWhenRun = true

    init() {}

    func perform() async throws -> some IntentResult {
        let snapshot = currentSnapshot()
        let running = snapshot?.classroom != nil
        SystemRouteStore.push(running ? .currentClassroom : .newSession)
        return .result()
    }
}

@available(iOS 18.0, *)
struct CaptureBlackboardTileIntent: AppIntent {
    static let title: LocalizedStringResource = "拍黑板"
    static let openAppWhenRun = true

    init() {}

    func perform() async throws -> some IntentResult {
        let snapshot = currentSnapshot()
        let running = snapshot?.classroom != nil
        SystemRouteStore.push(running ? .captureBlackboard : .newSession)
        return .result()
    }
}

@available(iOS 18.0, *)
struct TodayStudyTileIntent: AppIntent {
    static let title: LocalizedStringResource = "今日学习"
    static let openAppWhenRun = true

    init() {}

    func perform() async throws -> some IntentResult {
        SystemRouteStore.push(.todayStudy)
        return .result()
    }
}

private func currentSnapshot() -> WidgetSnapshot? {
    let store = SystemSnapshotStore()
    let scope = SystemScope.currentScopeKey(defaults: SystemSnapshotStore.defaults)
    return store.load(activeScopeKey: scope)
}

// MARK: - Control widgets

@available(iOS 18.0, *)
struct OpenClassroomControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: "com.livetranslate.ios.control.openClassroom"
        ) {
            ControlWidgetButton(action: OpenClassroomTileIntent()) {
                Label("打开课堂", systemImage: "waveform")
                    .foregroundStyle(WidgetPalette.accent)
            }
        }
        .displayName("打开课堂")
        .description("回到正在进行的课堂")
    }
}

@available(iOS 18.0, *)
struct CaptureBlackboardControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: "com.livetranslate.ios.control.captureBlackboard"
        ) {
            ControlWidgetButton(action: CaptureBlackboardTileIntent()) {
                Label("拍黑板", systemImage: "camera")
                    .foregroundStyle(WidgetPalette.accent)
            }
        }
        .displayName("拍黑板")
        .description("在课堂中拍摄黑板与讲义")
    }
}

@available(iOS 18.0, *)
struct TodayStudyControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: "com.livetranslate.ios.control.todayStudy"
        ) {
            ControlWidgetButton(action: TodayStudyTileIntent()) {
                Label("今日学习", systemImage: "graduationcap")
                    .foregroundStyle(WidgetPalette.accent)
            }
        }
        .displayName("今日学习")
        .description("查看今天的学习计划")
    }
}
