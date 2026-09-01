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

    /// Lets the coordinator's provider read the current translator without
    /// capturing `AppEnvironment` itself (which is not yet initialized when
    /// the coordinator is created). The lock is only for the nonisolated
    /// closure crossing — both setters and getters are MainActor in practice.
    private let translationServiceBox: TranslationServiceBox

    init() {
        let box = TranslationServiceBox()
        self.translationServiceBox = box
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
        self.repository = TranscriptRepository(container: modelContainer)
        self.modelManager = ModelManager()
        self.benchmarkRunner = ASRBenchmarkRunner(engineManager: engineManager)
        let service = AppEnvironment.makeTranslationService(
            settings: settings, keychain: keychain
        )
        self.translationService = service
        // The coordinator resolves the translator through the box on every
        // use, so `refreshTranslationService()` takes effect without any
        // explicit coordinator update. The closure captures the local `box`
        // — capturing `self` here would be use-before-initialization.
        box.set(service)
        self.coordinator = LiveTranslationCoordinator(
            engineManager: engineManager,
            repository: repository,
            settings: settings,
            translationServiceProvider: { box.get() }
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
        let config = TranslatorConfig(
            apiBase: settings.apiBase,
            apiKey: apiKey.isEmpty ? nil : apiKey,
            model: settings.translationModel,
            streaming: settings.streaming,
            contextTurns: settings.contextTurns,
            temperature: settings.temperature,
            maxTokens: settings.maxTokens,
            timeout: settings.timeout,
            thinkingStyle: ThinkingStyle(rawValue: settings.thinkingStyle) ?? .auto,
            customSystemPrompt: settings.customSystemPrompt
        )
        return OpenAICompatibleTranslator(config: config)
    }

    /// Call after translation settings or the stored API key change so new
    /// requests use the fresh configuration. The coordinator picks the new
    /// service up through the box on the next request.
    func refreshTranslationService() {
        translationService = AppEnvironment.makeTranslationService(
            settings: settings, keychain: keychain
        )
        translationServiceBox.set(translationService)
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

/// Thread-safe holder for the current translator. Exists so the coordinator
/// can be handed a provider closure that does not capture the (not yet
/// fully initialized) `AppEnvironment`.
final class TranslationServiceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var service: (any TranslationService)?

    func set(_ service: (any TranslationService)?) {
        lock.lock()
        defer { lock.unlock() }
        self.service = service
    }

    func get() -> (any TranslationService)? {
        lock.lock()
        defer { lock.unlock() }
        return service
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
            environment.modelManager.refreshStates()
        }
    }
}
