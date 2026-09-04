import Foundation
import AppIntents
import OSLog

/// Process-wide access point App Intents use to reach the ACTIVE
/// profile's environment. App Intents (Siri, Shortcuts, Spotlight
/// suggestions, the Action Button) perform IN THE APP PROCESS — the
/// system launches the app in the background if needed — so they can
/// legitimately call the real coordinator / repository. The host is
/// re-pointed on every profile switch (AppSession owns it); the Debug
/// demo environment never attaches, and its intents answer honestly.
@MainActor
enum AppIntentHost {
    private static let logger = Logger(
        subsystem: "com.livetranslate.ios", category: "app-intents"
    )

    /// The active environment (nil before first attach / demo mode).
    private(set) static weak var environment: AppEnvironment?

    static func attach(_ environment: AppEnvironment) {
        self.environment = environment
    }

    /// Run `body` against the active environment on the main actor.
    /// Returns nil when no production environment is attached (demo
    /// mode / very early launch) — callers surface an honest result.
    static func withEnvironment<T>(
        _ body: @MainActor (AppEnvironment) -> T
    ) async -> T? {
        guard let environment else { return nil }
        return await MainActor.run { body(environment) }
    }

    /// Navigate through the unified system-route coordinator.
    static func open(_ route: SystemRouteRequest) async {
        guard let environment = await withEnvironment({ $0 }) else { return }
        await MainActor.run {
            SystemRouteCoordinator(
                environment: environment,
                scopeKey: SystemScope.currentScopeKey(
                    defaults: SystemSnapshotStore.defaults
                )
            ).navigate(to: route)
        }
    }
}
