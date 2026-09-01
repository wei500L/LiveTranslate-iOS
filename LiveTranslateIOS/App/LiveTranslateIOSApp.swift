import SwiftUI
import SwiftData

@main
struct LiveTranslateIOSApp: App {
    let environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(environment)
        }
        .modelContainer(environment.modelContainer)
    }
}

/// Composition root. Owns the singletons that must outlive views:
/// the engine manager, pipeline coordinator, translation service and the
/// SwiftData container.
@MainActor
@Observable
final class AppEnvironment {
    /// Keychain account for the translation API key.
    static let apiKeychainKey = "translation.apiKey"

    let modelContainer: ModelContainer
    let settings: SettingsStore
    let engineManager: ASREngineManager
    let keychain: KeychainStore
    let repository: any ClassroomRepositoryProtocol
    let modelManager: ModelManager
    let benchmarkRunner: ASRBenchmarkRunner
    let coordinator: LiveTranslationCoordinator

    /// Rebuilt whenever translation settings change (Settings screen calls
    /// `refreshTranslationService()` on commit and after key changes).
    private(set) var translationService: any TranslationService

    init() {
        self.settings = SettingsStore.shared
        do {
            let schema = Schema([ClassroomSession.self, TranscriptEntry.self])
            let config = ModelConfiguration(
                "LiveTranslate",
                schema: schema,
                url: AppEnvironment.databaseURL()
            )
            self.modelContainer = try ModelContainer(for: schema, configurations: [config])
        } catch {
            // A corrupt store must not brick the app; start fresh and let
            // the user's existing records show as unreadable rather than
            // crash-looping on launch.
            assertionFailure("ModelContainer failed: \(error)")
            self.modelContainer = try! ModelContainer(
                for: Schema([ClassroomSession.self, TranscriptEntry.self])
            )
        }
        self.keychain = KeychainStore()
        self.engineManager = ASREngineManager(settings: settings)
        self.repository = TranscriptRepository(modelContainer: modelContainer)
        self.modelManager = ModelManager()
        self.benchmarkRunner = ASRBenchmarkRunner(engineManager: engineManager)
        self.translationService = AppEnvironment.makeTranslationService(
            settings: settings, keychain: keychain
        )
        self.coordinator = LiveTranslationCoordinator(
            engineManager: engineManager,
            repository: repository,
            settings: settings,
            translationService: translationService
        )
    }

    static func databaseURL() -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return support.appendingPathComponent("LiveTranslate.sqlite")
    }

    /// Build a translator from current settings; the API key comes from the
    /// Keychain only.
    static func makeTranslationService(
        settings: SettingsStore, keychain: KeychainStore
    ) -> any TranslationService {
        let apiKey = (try? keychain.get(forKey: apiKeychainKey)) ?? ""
        return OpenAICompatibleTranslator(
            apiBase: settings.apiBase,
            apiKey: apiKey,
            model: settings.translationModel,
            streaming: settings.streaming,
            contextTurns: settings.contextTurns,
            temperature: settings.temperature,
            maxTokens: settings.maxTokens,
            timeout: settings.timeout,
            thinkingStyle: ThinkingStyle(rawValue: settings.thinkingStyle) ?? .auto,
            customSystemPrompt: settings.customSystemPrompt.isEmpty ? nil : settings.customSystemPrompt
        )
    }

    /// Call after translation settings or the stored API key change so new
    /// requests use the fresh configuration.
    func refreshTranslationService() {
        translationService = AppEnvironment.makeTranslationService(
            settings: settings, keychain: keychain
        )
        coordinator.updateTranslationService(translationService)
    }

    /// Mark sessions that never got a clean `endTime` as abnormally
    /// terminated — the app was killed mid-classroom.
    func reconcileAbnormalTerminations() {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<ClassroomSession>(
            predicate: #Predicate { $0.endTime == nil }
        )
        guard let unfinished = try? context.fetch(descriptor), !unfinished.isEmpty else { return }
        for session in unfinished {
            session.abnormalTermination = true
            session.endTime = session.updatedAt
            session.duration = session.endTime!.timeIntervalSince(session.startTime)
        }
        try? context.save()
    }
}

/// Root three-tab layout: Live translation, classroom records, settings.
struct RootTabView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        TabView {
            LiveScreen()
                .tabItem { Label("Live", systemImage: "waveform") }
            RecordsScreen()
                .tabItem { Label("Records", systemImage: "list.bullet.rectangle") }
            SettingsScreen()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .task {
            environment.reconcileAbnormalTerminations()
            await environment.modelManager.refreshStates()
        }
    }
}
