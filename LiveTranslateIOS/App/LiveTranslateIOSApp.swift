import SwiftUI
import SwiftData

@main
struct LiveTranslateIOSApp: App {
    /// Account-scoped session: owns the environment and rebuilds it on
    /// account switches (multi-profile isolation). In the Debug UI-demo
    /// mode the demo environment is assembled once and never switched.
    @State private var session = AppSession()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(session)
                .environment(session.environment)
                // Identity tied to the active profile: switching accounts
                // tears the whole view tree down (fresh @State, fresh
                // navigation) so no screen leaks the previous account's
                // data.
                .id(session.profileKey)
                // App Links: password-reset deep links (Universal Link with
                // the AASA configured, or the livetranslate:// scheme). The
                // token stays in memory; RootTabView presents the flow.
                .onOpenURL { url in
                    session.handleDeepLink(url)
                }
        }
        .modelContainer(session.environment.modelContainer)
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

    /// Assembly-level capability switches. The Debug UI demo environment
    /// swaps these at composition time; views consult the environment
    /// rather than any global demo flag.
    struct Capabilities: Sendable {
        /// Whether the new-classroom flow may raise the system microphone
        /// permission prompt (the demo environment never prompts).
        var requestsMicrophonePermission = true
        /// Readiness displays report the microphone as authorized without
        /// touching AVAudioApplication (demo keeps 全部就绪 deterministic).
        var assumesMicrophoneAuthorized = false
    }

    let capabilities: Capabilities
    let modelContainer: ModelContainer
    let settings: SettingsStore
    let engineManager: any ASREngineManaging
    let keychain: any KeychainStoring
    let repository: any ClassroomRepositoryProtocol
    let modelManager: any ModelManaging
    let benchmarkRunner: ASRBenchmarkRunner
    let coordinator: any LiveTranslationCoordinating
    /// UI navigation state (selected tab, live-classroom presentation).
    let flow = AppFlow()
    /// UI-layer bookmarks & session favorites (UserDefaults-backed, IDs only).
    let bookmarks: BookmarkStore
    /// Local-notification reminders for tasks (device-only, account-scoped
    /// defaults; never synced, never server-side).
    let taskReminders: TaskReminderScheduler
    /// Private-server cloud sync. Nil when the build configures no server
    /// URL (and always nil in the Debug demo environment — demo mode never
    /// touches the production server). One instance per app lifetime.
    let cloudSync: CloudSyncService?
    /// Guest-data migration for the signed-in account (nil for the guest
    /// profile itself and demo mode). Owns the 本机记录待归属 flow.
    let guestMigration: GuestDataMigration?
    /// Post-class study-review generation (separate domain from the live
    /// translation service; shares the OpenAI-compatible transport).
    private(set) var studyReviewService: any StudyReviewModelService
    /// Lets the generator read the current service without capturing the
    /// environment (same pattern as TranslationServiceBox).
    private let studyServiceBox: StudyServiceBox
    /// One generator per profile; owns in-flight review generations.
    let studyReviewGenerator: StudyReviewGenerator
    /// Classroom-image understanding (multimodal) — its own domain, same
    /// transport primitives as the study service.
    private(set) var attachmentAnalysisService: any AttachmentAnalysisModelService
    private let attachmentServiceBox: AttachmentServiceBox
    /// One analysis generator per profile; owns in-flight image analyses.
    let attachmentAnalysisGenerator: AttachmentAnalysisGenerator
    /// Import pipeline for camera/photo-library images.
    let attachmentImporter: AttachmentImportService
    /// The profile's attachment file store (paths, renditions, cleanup).
    let attachmentStore: AttachmentFileStore

    /// Rebuilt whenever translation settings change (Settings screen calls
    /// `refreshTranslationService()` on commit and after key changes).
    private(set) var translationService: any TranslationService

    /// Lets the coordinator's provider read the current translator without
    /// capturing `AppEnvironment` itself (which is not yet initialized when
    /// the coordinator is created). The lock is only for the nonisolated
    /// closure crossing — both setters and getters are MainActor in practice.
    private let translationServiceBox: TranslationServiceBox

    /// Presentation view model for the live classroom. Owned here (not as
    /// @State inside LiveScreen) so collapsing the full-screen cover never
    /// destroys in-classroom UI state: selected tab, auto-follow, manual
    /// browse position, search text, error hint, bookmark focus. One view
    /// model per coordinator session — a new session gets a fresh one, and
    /// the model is released when the classroom ends.
    private(set) var liveViewModel: LiveViewModel?
    private var liveViewModelSessionID: UUID?

    /// Production assembly for the given profile: the guest (local-only)
    /// store or one account's isolated store.
    convenience init(profile: LocalProfile = .guest) {
        let accountID: UUID? = if case .account(let account) = profile { account.id } else { nil }
        let settings = SettingsStore.shared
        // The attachment file store is built FIRST and registered globally
        // so repository deletes can reap files (guest keeps the legacy
        // global path; accounts are isolated — 多账号不共享附件目录).
        let attachmentStore = AttachmentFileStore(accountID: accountID)
        AttachmentFileStoreShared.store = attachmentStore
        let modelContainer: ModelContainer
        do {
            let schema = Schema([
                ClassroomSession.self, TranscriptEntry.self,
                Course.self, SessionNote.self, StudyReview.self,
                SessionAttachment.self,
                GlossaryTerm.self, StudyCard.self, StudyTask.self
            ])
            let config = ModelConfiguration(
                "LiveTranslate",
                schema: schema,
                url: AppEnvironment.databaseURL(accountID: accountID)
            )
            modelContainer = try ModelContainer(for: schema, configurations: [config])
        } catch {
            // A corrupt store must not brick the app; start fresh and let
            // the user's existing records show as unreadable rather than
            // crash-looping on launch.
            assertionFailure("ModelContainer failed: \(error)")
            modelContainer = try! ModelContainer(
                for: Schema([
                    ClassroomSession.self, TranscriptEntry.self,
                    Course.self, SessionNote.self, StudyReview.self,
                    SessionAttachment.self,
                    GlossaryTerm.self, StudyCard.self, StudyTask.self
                ])
            )
        }
        let engineManager = ASREngineManager(settings: settings)
        let repository = TranscriptRepository(container: modelContainer)
        let keychain = KeychainStore()
        let modelManager = ModelManager()
        // Real delete protection: the manager refuses to remove files a
        // running classroom is using (not just the disabled UI button).
        modelManager.isBackendInUse = { [weak engineManager] kind in
            guard let engineManager else { return false }
            return engineManager.sessionActive
                && engineManager.residentBackendKind == kind
        }
        let service = AppEnvironment.makeTranslationService(
            settings: settings, keychain: keychain
        )
        let box = TranslationServiceBox()
        box.set(service)
        // The coordinator resolves the translator through the box on every
        // use, so `refreshTranslationService()` takes effect without any
        // explicit coordinator update. The provider deliberately does NOT
        // consult the live-translation toggle: the coordinator reads that
        // user-intent flag itself (together with the service's
        // `isConfiguredNow`) so "user turned translation off" stays
        // distinguishable from "service not configured" — the former never
        // enqueues a request at all. The provider is @MainActor and only
        // resolved on the main actor, so reading the toggle is
        // concurrency-safe.
        let coordinator = LiveTranslationCoordinator(
            engineManager: engineManager,
            repository: repository,
            settings: settings,
            translationServiceProvider: { box.get() }
        )
        // Cloud sync only when this build carries a server URL (Debug →
        // local/LAN server, Release → the HTTPS production domain). The
        // service observes repository + bookmark mutations from here on.
        // Per-account isolation: the SwiftData store, the outbox file, the
        // cursor/bookmark defaults and the keychain scope all live in the
        // account's namespace; the guest keeps the legacy global paths.
        let syncDefaults = accountID.map(AccountStore.defaultsSuite(accountID:)) ?? .standard
        let bookmarks = BookmarkStore(
            defaults: syncDefaults,
            repository: repository,
            storageKey: AccountStore.bookmarkKey(accountID: accountID)
        )
        let taskReminders = TaskReminderScheduler(defaults: syncDefaults)
        let cloudSync: CloudSyncService?
        if let baseURL = ServerConfiguration.baseURL {
            cloudSync = CloudSyncService(
                baseURL: baseURL,
                keychain: keychain,
                repository: repository,
                bookmarks: bookmarks,
                defaults: syncDefaults,
                outboxFileURL: accountID.map {
                    AccountScope.outboxURL(accountID: $0)
                },
                accountID: accountID
            )
        } else {
            cloudSync = nil
        }
        // Guest-data migration exists only for a signed-in account (the
        // guest profile IS the source; it cannot migrate into itself).
        let guestMigration: GuestDataMigration?
        if let accountID, let cloudSync {
            guestMigration = GuestDataMigration(
                accountID: accountID,
                repository: repository,
                bookmarks: bookmarks,
                sync: cloudSync
            )
        } else {
            guestMigration = nil
        }
        let studyService = AppEnvironment.makeStudyReviewService(
            settings: settings, keychain: keychain
        )
        let studyBox = StudyServiceBox()
        studyBox.set(studyService)
        let studyGenerator = StudyReviewGenerator(
            repository: repository,
            serviceProvider: { [weak studyBox] in studyBox?.get() }
        )
        let attachmentService = AppEnvironment.makeAttachmentAnalysisService(
            settings: settings, keychain: keychain
        )
        let attachmentBox = AttachmentServiceBox()
        attachmentBox.set(attachmentService)
        let attachmentGenerator = AttachmentAnalysisGenerator(
            repository: repository,
            fileStore: { AttachmentFileStoreShared.store },
            serviceProvider: { [weak attachmentBox] in attachmentBox?.get() }
        )
        let attachmentImporter = AttachmentImportService(
            repository: repository, fileStore: attachmentStore
        )
        self.init(
            capabilities: Capabilities(),
            modelContainer: modelContainer,
            settings: settings,
            engineManager: engineManager,
            keychain: keychain,
            repository: repository,
            modelManager: modelManager,
            benchmarkRunner: ASRBenchmarkRunner(engineManager: engineManager),
            coordinator: coordinator,
            translationService: service,
            translationServiceBox: box,
            bookmarks: bookmarks,
            taskReminders: taskReminders,
            cloudSync: cloudSync,
            guestMigration: guestMigration,
            studyReviewService: studyService,
            studyServiceBox: studyBox,
            studyReviewGenerator: studyGenerator,
            attachmentAnalysisService: attachmentService,
            attachmentServiceBox: attachmentBox,
            attachmentAnalysisGenerator: attachmentGenerator,
            attachmentImporter: attachmentImporter,
            attachmentStore: attachmentStore
        )
    }

    /// Full dependency-injection initializer — the composition boundary the
    /// Debug demo environment also assembles through.
    init(
        capabilities: Capabilities,
        modelContainer: ModelContainer,
        settings: SettingsStore,
        engineManager: any ASREngineManaging,
        keychain: any KeychainStoring,
        repository: any ClassroomRepositoryProtocol,
        modelManager: any ModelManaging,
        benchmarkRunner: ASRBenchmarkRunner,
        coordinator: any LiveTranslationCoordinating,
        translationService: any TranslationService,
        translationServiceBox: TranslationServiceBox,
        bookmarks: BookmarkStore,
        taskReminders: TaskReminderScheduler? = nil,
        cloudSync: CloudSyncService?,
        guestMigration: GuestDataMigration? = nil,
        studyReviewService: any StudyReviewModelService = OpenAICompatibleStudyService(
            config: StudyReviewModelConfig(apiBase: "", apiKey: nil, model: "")
        ),
        studyServiceBox: StudyServiceBox = StudyServiceBox(),
        studyReviewGenerator: StudyReviewGenerator? = nil,
        attachmentAnalysisService: any AttachmentAnalysisModelService = OpenAICompatibleAttachmentService(
            config: AttachmentAnalysisModelConfig(apiBase: "", apiKey: nil, model: "")
        ),
        attachmentServiceBox: AttachmentServiceBox = AttachmentServiceBox(),
        attachmentAnalysisGenerator: AttachmentAnalysisGenerator? = nil,
        attachmentImporter: AttachmentImportService? = nil,
        attachmentStore: AttachmentFileStore? = nil
    ) {
        self.capabilities = capabilities
        self.modelContainer = modelContainer
        self.settings = settings
        self.engineManager = engineManager
        self.keychain = keychain
        self.repository = repository
        self.modelManager = modelManager
        self.benchmarkRunner = benchmarkRunner
        self.coordinator = coordinator
        self.translationService = translationService
        self.translationServiceBox = translationServiceBox
        self.bookmarks = bookmarks
        self.taskReminders = taskReminders ?? TaskReminderScheduler(defaults: .standard)
        self.cloudSync = cloudSync
        self.guestMigration = guestMigration
        self.studyReviewService = studyReviewService
        self.studyServiceBox = studyServiceBox
        if let studyReviewGenerator {
            self.studyReviewGenerator = studyReviewGenerator
        } else {
            // DI init without a generator (tests, demo): wire one to this
            // environment's repository + service box.
            studyServiceBox.set(studyReviewService)
            self.studyReviewGenerator = StudyReviewGenerator(
                repository: repository,
                serviceProvider: { [weak studyServiceBox] in studyServiceBox?.get() }
            )
        }
        self.attachmentAnalysisService = attachmentAnalysisService
        self.attachmentServiceBox = attachmentServiceBox
        if let attachmentAnalysisGenerator {
            self.attachmentAnalysisGenerator = attachmentAnalysisGenerator
        } else {
            attachmentServiceBox.set(attachmentAnalysisService)
            self.attachmentAnalysisGenerator = AttachmentAnalysisGenerator(
                repository: repository,
                fileStore: { AttachmentFileStoreShared.store },
                serviceProvider: { [weak attachmentServiceBox] in attachmentServiceBox?.get() }
            )
        }
        if let attachmentImporter {
            self.attachmentImporter = attachmentImporter
        } else {
            self.attachmentImporter = AttachmentImportService(
                repository: repository,
                fileStore: attachmentStore ?? AttachmentFileStore(accountID: nil)
            )
        }
        if let attachmentStore {
            self.attachmentStore = attachmentStore
            AttachmentFileStoreShared.store = attachmentStore
        } else {
            self.attachmentStore = AttachmentFileStore(accountID: nil)
            AttachmentFileStoreShared.store = self.attachmentStore
        }
    }

    /// Profile store location — delegated to `AccountScope` (the single
    /// source of truth for the account-ID → storage mapping).
    static func databaseURL(accountID: UUID? = nil) -> URL {
        AccountScope.databaseURL(accountID: accountID)
    }

    // MARK: - Translation configuration (single source of truth)

    /// Whether a usable translation service is configured. Delegates
    /// synchronously to the *current* translator's `TranslatorConfig`
    /// check (`TranslationService.isConfiguredNow`) so UI presentation
    /// and the pipeline's dispatch-time triage can never disagree. The
    /// API key itself never leaves the service — views only see this Bool.
    var isTranslationConfigured: Bool {
        translationService.isConfiguredNow
    }

    /// Build a translator from current settings; the API key comes from the
    /// Keychain only.
    static func makeTranslationService(
        settings: SettingsStore, keychain: any KeychainStoring
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
        // The study and image services inherit the API base + key; rebuild
        // them too.
        studyReviewService = AppEnvironment.makeStudyReviewService(
            settings: settings, keychain: keychain
        )
        studyServiceBox.set(studyReviewService)
        attachmentAnalysisService = AppEnvironment.makeAttachmentAnalysisService(
            settings: settings, keychain: keychain
        )
        attachmentServiceBox.set(attachmentAnalysisService)
    }

    /// Study-review service from current settings: the same API base and
    /// key as translation, with a dedicated model when the user chose one.
    static func makeStudyReviewService(
        settings: SettingsStore, keychain: any KeychainStoring
    ) -> any StudyReviewModelService {
        let apiKey = (try? keychain.get(forKey: apiKeychainKey)) ?? ""
        let model = settings.studyReviewModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return OpenAICompatibleStudyService(config: StudyReviewModelConfig(
            apiBase: settings.apiBase,
            apiKey: apiKey.isEmpty ? nil : apiKey,
            model: model.isEmpty ? settings.translationModel : model
        ))
    }

    /// Image-understanding service from current settings: same API base
    /// and key as translation (the user never re-enters it); the model
    /// falls back study-review model → translation model. Whether the
    /// chosen model actually accepts images is the server's call — the
    /// settings copy never claims support it cannot verify.
    static func makeAttachmentAnalysisService(
        settings: SettingsStore, keychain: any KeychainStoring
    ) -> any AttachmentAnalysisModelService {
        let apiKey = (try? keychain.get(forKey: apiKeychainKey)) ?? ""
        let model = settings.attachmentAnalysisModel
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved: String
        if !model.isEmpty {
            resolved = model
        } else if !settings.studyReviewModel.isEmpty {
            resolved = settings.studyReviewModel
        } else {
            resolved = settings.translationModel
        }
        return OpenAICompatibleAttachmentService(config: AttachmentAnalysisModelConfig(
            apiBase: settings.apiBase,
            apiKey: apiKey.isEmpty ? nil : apiKey,
            model: resolved
        ))
    }

    // MARK: - Live classroom presentation

    /// Present the live classroom full-screen. The presentation view model
    /// is created once per coordinator session and reused across collapse /
    /// re-open, so in-classroom state survives. A *different* coordinator
    /// session (or a not-running classroom) always gets a fresh view model —
    /// re-entering never re-attaches, re-registers observers or restarts
    /// anything: the model is a passive mirror of the coordinator.
    func presentLive() {
        let sessionID = coordinator.activeSessionID
        if liveViewModel == nil
            || liveViewModelSessionID != sessionID
            || !coordinator.isRunning {
            let viewModel = LiveViewModel()
            viewModel.attach(self)
            liveViewModel = viewModel
            liveViewModelSessionID = sessionID
        }
        flow.openLive()
    }

    /// Fallback accessor used by the full-screen cover's content builder
    /// (in practice `presentLive()` has already created the model).
    func acquireLiveViewModel() -> LiveViewModel {
        if let liveViewModel { return liveViewModel }
        let viewModel = LiveViewModel()
        viewModel.attach(self)
        liveViewModel = viewModel
        liveViewModelSessionID = coordinator.activeSessionID
        return viewModel
    }

    /// End the classroom: stop the coordinator, release the presentation
    /// view model (its state is meaningless once the session is over) and
    /// collapse back to the tabs.
    func endLiveSession() async {
        await coordinator.stop()
        liveViewModel = nil
        liveViewModelSessionID = nil
        flow.collapseLive()
    }

    /// Mark sessions that never got a clean `endTime` as abnormally
    /// terminated — the app was killed mid-classroom. Routed through the
    /// repository so the mutation observer (cloud sync) learns about the
    /// recovered rows.
    func reconcileAbnormalTerminations() {
        try? repository.markAbnormalTerminations()
        // Same launch-time reconciliation for interrupted image analyses.
        attachmentAnalysisGenerator.reconcileInterruptedAnalyses()
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

/// Same holder pattern for the study-review model service.
final class StudyServiceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var service: (any StudyReviewModelService)?

    func set(_ service: (any StudyReviewModelService)?) {
        lock.lock()
        defer { lock.unlock() }
        self.service = service
    }

    func get() -> (any StudyReviewModelService)? {
        lock.lock()
        defer { lock.unlock() }
        return service
    }
}

/// Same holder pattern for the image-understanding model service.
final class AttachmentServiceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var service: (any AttachmentAnalysisModelService)?

    func set(_ service: (any AttachmentAnalysisModelService)?) {
        lock.lock()
        defer { lock.unlock() }
        self.service = service
    }

    func get() -> (any AttachmentAnalysisModelService)? {
        lock.lock()
        defer { lock.unlock() }
        return service
    }
}

/// UI navigation state owned by the composition root: the selected global
/// tab and whether the live classroom is presented full-screen. Screens
/// drive it through `AppEnvironment.flow`.
@MainActor
@Observable
final class AppFlow {
    var selectedTab: LTTab = .home
    /// True while the live classroom is the front-most presentation.
    var isLivePresented = false

    /// Present the live classroom (full-screen).
    func openLive() {
        isLivePresented = true
    }

    /// Collapse the classroom back to a tab without stopping the session —
    /// the home screen shows an ongoing-classroom banner. `tab` lets an
    /// in-classroom hint (e.g. "前往设置" when translation is not configured)
    /// land on the tab it points at.
    func collapseLive(to tab: LTTab = .home) {
        isLivePresented = false
        selectedTab = tab
    }

    #if DEBUG
    /// UI-demo navigation directive (Debug builds only): set at launch by
    /// the demo composition, consumed exactly once by the screen it points
    /// at.
    var pendingDemoScreen: DemoLaunchOptions.Screen?
    /// Demo override that freezes the home greeting so demo screenshots are
    /// deterministic (Debug builds only).
    var demoGreeting: String?
    /// Seeded session the demo `--demo-screen detail` directive pushes.
    var demoDetailSessionID: UUID?
    /// Demo prefill for the new-classroom name field (Debug builds only).
    var demoPrefilledSessionName: String?
    #endif
}
