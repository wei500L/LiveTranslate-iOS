import SwiftUI
import SwiftData

@main
struct LiveTranslateIOSApp: App {
    /// Account-scoped session: owns the environment and rebuilds it on
    /// account switches (multi-profile isolation). In the Debug UI-demo
    /// mode the demo environment is assembled once and never switched.
    @State private var session = AppSession()
    /// Class-reminder notification routing (tap + 开始课堂 action). The
    /// delegate is a plain NSObject kept here so it outlives views; it
    /// hops to the MainActor to steer AppFlow.
    @State private var notificationRouter = NotificationRouter()

    init() {
        // Register the course-reminder category (开始课堂 action) before
        // any reminder can fire. Plain registration — never prompts.
        NotificationRouter.registerCategories()
    }

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
                .onAppear {
                    notificationRouter.attach(flow: session.environment.flow)
                }
                .onChange(of: session.profileKey) {
                    // The view tree reset (account switch) re-attaches via
                    // onAppear; also re-point immediately so a notification
                    // tapped mid-switch is never lost.
                    notificationRouter.attach(flow: session.environment.flow)
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
    /// The profile's server account id (nil = guest). Storage roots are
    /// derived from it (AccountScope); the launch protection reconcile
    /// and per-account teardown need it too.
    let accountID: UUID?
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
    /// Local-notification 上课提醒 (rolling window over schedule
    /// occurrences; device-only, account-scoped defaults; never synced).
    let classReminders: ClassReminderScheduler
    /// Exam-center reminders (考试提醒 + 每日学习提醒汇总; device-only,
    /// account-scoped defaults; never synced).
    let examReminders: ExamReminderScheduler
    /// Errand-case reminders (办事事项预约/截止/跟进提醒; device-only,
    /// account-scoped defaults; never synced). Injectable center so the
    /// demo and tests never touch the real notification center.
    let errandReminders: ErrandReminderScheduler
    /// Errand-appointment calendar mirroring (write-only EventKit layer,
    /// the ExamCalendarService pattern; identifiers are device-local and
    /// never sync). Injectable store so demo/tests never touch EventKit.
    let errandCalendar: ErrandCalendarMirror
    /// The real learning-timer controller (真实学习计时) — one per profile;
    /// elapsed time is computed from timestamps, never a per-second task.
    let studyActivityTracker: StudyActivityTracker
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
    /// The profile's course-material file store (paths, page caches).
    let materialStore: MaterialFileStore
    /// The profile's interpreter (随身翻译) document file store — the
    /// on-site file context. Device-local files, never synced.
    let interpreterDocumentStore: InterpreterDocumentStore
    /// Device-local biometric privacy lock (round 17). Owned per profile:
    /// a rebuilt environment starts LOCKED, so a profile switch can never
    /// inherit the previous profile's unlock authorization.
    let privacyLock: PrivacyLockController
    /// The profile's local AI activity ledger (round 17 — metadata only).
    /// Also registered as AIActivityLog.shared for the transport layer.
    let aiActivityLog: AIActivityLog
    /// 智能收件箱 — the App Group shared inbox (reconcile, inspect,
    /// counts). Items are device-local until confirmed into formal
    /// entities; the store is shared with the Share Extension but the
    /// coordinator belongs to the active profile (items are filtered by
    /// the scope that received them).
    let inbox: InboxCoordinator
    /// Confirmed-action executor (nil only when the App Group is
    /// unavailable).
    let inboxExecutor: InboxActionExecutor?
    /// Course-material import pipeline (Files picker → hash → store → row).
    let materialImporter: MaterialImportService
    /// Page-text extraction + per-page Vision OCR (resumable runs).
    let materialExtractionRunner: MaterialExtractionRunner
    /// Material digest (导读) generation — chunked, resumable, text-first.
    let materialDigestGenerator: MaterialDigestGenerator
    /// The course assistant (问这门课) — grounded local retrieval + one
    /// model call over the selected sources.
    let courseAssistant: CourseAssistantService
    /// Classroom-recording playback (one engine per app so starting a new
    /// live classroom or switching accounts can stop it from one place).
    let playback: ClassroomPlaybackService
    /// Waveform precompute + cache for recordings (device-local).
    let waveformStore: RecordingWaveformStore
    /// System-integration driver (Live Activities, widgets, commands,
    /// system routes, Spotlight). Nil in the Debug demo environment and
    /// the DI test composition (demo mode must never touch the real App
    /// Group, ActivityKit or Spotlight).
    /// `var` (never reassigned after init): the coordinator takes `self`,
    /// so the property must be nil-initialized first and filled in the
    /// init's final phase.
    private(set) var systemCoordinator: SystemIntegrationCoordinator?
    /// Honest feedback when a system route pointed at a deleted target:
    /// a one-shot banner consumed by the root view (never a dead tab).
    private(set) var missingTargetMessage: String?

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
            let schema = AppEnvironment.librarySchema
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
                for: AppEnvironment.librarySchema
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
        let classReminders = ClassReminderScheduler(defaults: syncDefaults)
        let examReminders = ExamReminderScheduler(defaults: syncDefaults)
        // 办事事项提醒/日历镜像：同样的账号域隔离（通知状态与 EventKit
        // identifier 都是设备本地，绝不同步）。demo 组合通过注入参数换
        // fake —— 生产路径始终用系统实现。
        let errandReminders = ErrandReminderScheduler(defaults: syncDefaults)
        let errandCalendar = ErrandCalendarMirror(defaults: syncDefaults)
        let studyActivityTracker = StudyActivityTracker(
            repository: repository, defaults: syncDefaults
        )
        // System-calendar mirroring binds to the account-scoped defaults
        // (EventKit identifiers are device-local and never sync).
        ExamCalendarService.shared.configure(defaults: syncDefaults)
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
        // Course-material library: the file store is built FIRST and
        // registered globally (repository deletes reap files); the
        // extraction/digest/assistant services share the same model
        // service boxes as study review and image analysis — one API key,
        // one HTTP transport, one provider config.
        let materialStore = MaterialFileStore(accountID: accountID)
        MaterialFileStoreShared.store = materialStore
        // 随身翻译现场文件 (interpreter document context): the same
        // build-first-and-register-globally rule — repository deletes
        // and the launch reconcile reap files through the holder.
        let interpreterDocumentStore = InterpreterDocumentStore(accountID: accountID)
        InterpreterDocumentStoreShared.store = interpreterDocumentStore
        let materialExtractionRunner = MaterialExtractionRunner(
            repository: repository,
            fileStore: { MaterialFileStoreShared.store }
        )
        let materialImporter = MaterialImportService(
            repository: repository,
            fileStore: materialStore,
            extractionRunner: materialExtractionRunner
        )
        let materialDigestGenerator = MaterialDigestGenerator(
            repository: repository,
            textServiceProvider: { [weak studyBox] in studyBox?.get() },
            imageServiceProvider: { [weak attachmentBox] in attachmentBox?.get() }
        )
        let courseAssistant = CourseAssistantService(
            repository: repository,
            textServiceProvider: { [weak studyBox] in studyBox?.get() },
            imageServiceProvider: { [weak attachmentBox] in attachmentBox?.get() }
        )
        let playback = ClassroomPlaybackService()
        let waveformStore = RecordingWaveformStore()
        // Shared inbox: the store lives in the App Group (shared with
        // the Share Extension); the coordinator reads the LIVE model
        // service boxes so settings changes apply without a rebuild.
        let inboxStore = SharedInboxStore()
        let inbox = InboxCoordinator(
            store: inboxStore,
            imageServiceProvider: { [weak attachmentBox] in attachmentBox?.get() },
            textServiceProvider: { [weak studyBox] in studyBox?.get() }
        )
        let inboxExecutor = inboxStore.map {
            InboxActionExecutor(
                repository: repository,
                materialImporter: materialImporter,
                attachmentImporter: attachmentImporter,
                store: $0
            )
        }
        let privacyLock = PrivacyLockController(settings: settings)
        // Round 17: the profile's local AI activity ledger (metadata
        // only — 30-day retention, never synced). Registered globally so
        // the transport services can record; rebuilt per profile.
        AIActivityLog.shared = AIActivityLog(accountID: accountID)
        self.init(
            capabilities: Capabilities(),
            modelContainer: modelContainer,
            settings: settings,
            accountID: accountID,
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
            classReminders: classReminders,
            examReminders: examReminders,
            errandReminders: errandReminders,
            errandCalendar: errandCalendar,
            studyActivityTracker: studyActivityTracker,
            cloudSync: cloudSync,
            guestMigration: guestMigration,
            studyReviewService: studyService,
            studyServiceBox: studyBox,
            studyReviewGenerator: studyGenerator,
            attachmentAnalysisService: attachmentService,
            attachmentServiceBox: attachmentBox,
            attachmentAnalysisGenerator: attachmentGenerator,
            attachmentImporter: attachmentImporter,
            attachmentStore: attachmentStore,
            materialStore: materialStore,
            interpreterDocumentStore: interpreterDocumentStore,
            materialImporter: materialImporter,
            materialExtractionRunner: materialExtractionRunner,
            materialDigestGenerator: materialDigestGenerator,
            courseAssistant: courseAssistant,
            playback: playback,
            waveformStore: waveformStore,
            inbox: inbox,
            inboxExecutor: inboxExecutor,
            privacyLock: privacyLock,
            aiActivityLog: AIActivityLog.shared,
            systemIntegrationScopeKey: accountID.map { $0.uuidString }
                ?? SharedInboxScopeStore.guestScope
        )
    }

    /// Full dependency-injection initializer — the composition boundary the
    /// Debug demo environment also assembles through. Pass
    /// `systemIntegrationScopeKey` to arm the system surfaces for that
    /// profile's scope (production); nil (default) keeps every system
    /// integration off (demo / tests).
    init(
        capabilities: Capabilities,
        modelContainer: ModelContainer,
        settings: SettingsStore,
        accountID: UUID? = nil,
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
        classReminders: ClassReminderScheduler? = nil,
        examReminders: ExamReminderScheduler? = nil,
        errandReminders: ErrandReminderScheduler? = nil,
        errandCalendar: ErrandCalendarMirror? = nil,
        studyActivityTracker: StudyActivityTracker? = nil,
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
        attachmentStore: AttachmentFileStore? = nil,
        materialStore: MaterialFileStore? = nil,
        interpreterDocumentStore: InterpreterDocumentStore? = nil,
        materialImporter: MaterialImportService? = nil,
        materialExtractionRunner: MaterialExtractionRunner? = nil,
        materialDigestGenerator: MaterialDigestGenerator? = nil,
        courseAssistant: CourseAssistantService? = nil,
        playback: ClassroomPlaybackService? = nil,
        waveformStore: RecordingWaveformStore? = nil,
        inbox: InboxCoordinator? = nil,
        inboxExecutor: InboxActionExecutor? = nil,
        privacyLock: PrivacyLockController? = nil,
        aiActivityLog: AIActivityLog? = nil,
        systemIntegrationScopeKey: String? = nil
    ) {
        self.capabilities = capabilities
        self.modelContainer = modelContainer
        self.settings = settings
        self.accountID = accountID
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
        self.classReminders = classReminders ?? ClassReminderScheduler(defaults: .standard)
        self.examReminders = examReminders ?? ExamReminderScheduler(defaults: .standard)
        self.errandReminders = errandReminders ?? ErrandReminderScheduler(defaults: .standard)
        self.errandCalendar = errandCalendar ?? ErrandCalendarMirror(defaults: .standard)
        self.studyActivityTracker = studyActivityTracker ?? StudyActivityTracker(
            repository: repository, defaults: .standard
        )
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
        // Course-material library: same DI-default pattern as attachments
        // (tests/demo may inject in-memory replacements; production gets
        // the real store + repository-backed services).
        if let materialStore {
            self.materialStore = materialStore
            MaterialFileStoreShared.store = materialStore
        } else {
            self.materialStore = MaterialFileStore(accountID: nil)
            MaterialFileStoreShared.store = self.materialStore
        }
        // 随身翻译 document context: same DI-default pattern (tests/demo
        // inject temp-root stores; production registers the profile's
        // real store at composition time above).
        if let interpreterDocumentStore {
            self.interpreterDocumentStore = interpreterDocumentStore
            InterpreterDocumentStoreShared.store = interpreterDocumentStore
        } else {
            self.interpreterDocumentStore = InterpreterDocumentStore(accountID: nil)
            InterpreterDocumentStoreShared.store = self.interpreterDocumentStore
        }
        if let materialExtractionRunner {
            self.materialExtractionRunner = materialExtractionRunner
        } else {
            self.materialExtractionRunner = MaterialExtractionRunner(
                repository: repository,
                fileStore: { MaterialFileStoreShared.store }
            )
        }
        if let materialImporter {
            self.materialImporter = materialImporter
        } else {
            self.materialImporter = MaterialImportService(
                repository: repository,
                fileStore: self.materialStore,
                extractionRunner: self.materialExtractionRunner
            )
        }
        if let materialDigestGenerator {
            self.materialDigestGenerator = materialDigestGenerator
        } else {
            self.materialDigestGenerator = MaterialDigestGenerator(
                repository: repository,
                textServiceProvider: { [weak studyServiceBox] in studyServiceBox?.get() },
                imageServiceProvider: { [weak attachmentServiceBox] in attachmentServiceBox?.get() }
            )
        }
        if let courseAssistant {
            self.courseAssistant = courseAssistant
        } else {
            self.courseAssistant = CourseAssistantService(
                repository: repository,
                textServiceProvider: { [weak studyServiceBox] in studyServiceBox?.get() },
                imageServiceProvider: { [weak attachmentServiceBox] in attachmentServiceBox?.get() }
            )
        }
        self.playback = playback ?? ClassroomPlaybackService()
        self.waveformStore = waveformStore ?? RecordingWaveformStore()
        // Shared inbox: the DI default is a store-less coordinator (tests
        // / composition without the App Group); production builds pass
        // the real one from the profile init.
        self.inbox = inbox ?? InboxCoordinator(store: nil)
        self.inboxExecutor = inboxExecutor
        self.privacyLock = privacyLock ?? PrivacyLockController(settings: settings)
        // DI compositions without a log (tests, the Debug demo) keep
        // their own throwaway file — the demo never touches the real
        // ledger and never records (its fake services bypass the
        // transport hooks).
        self.aiActivityLog = aiActivityLog ?? AIActivityLog(fileURL: FileManager
            .default.temporaryDirectory
            .appendingPathComponent("ui-ai-activity-\(UUID().uuidString).json"))
        // System integration (Live Activities, widgets, commands, system
        // routes, Spotlight): armed only when the profile init passes a
        // scope key (production); demo/tests keep it off entirely.
        // (Initialize the property first — the coordinator takes `self`,
        // which is only usable once every stored property is set.)
        self.systemCoordinator = nil
        if let systemIntegrationScopeKey {
            let coordinator = SystemIntegrationCoordinator(
                environment: self, scopeKey: systemIntegrationScopeKey
            )
            self.systemCoordinator = coordinator
            // Repository mutations drive Spotlight indexing + widget
            // snapshot refresh (covers local edits, cloud-sync applies
            // and inbox imports — the repository is the single choke
            // point). Registered as an AUXILIARY observer; the sync
            // service's own observer slot is untouched.
            repository.auxiliaryMutationObservers = [
                SystemMutationBridge(
                    coordinator: coordinator,
                    errandReminders: errandReminders,
                    errandCalendar: errandCalendar
                )
            ]
        }
    }

    /// Profile store location — delegated to `AccountScope` (the single
    /// source of truth for the account-ID → storage mapping).
    static func databaseURL(accountID: UUID? = nil) -> URL {
        AccountScope.databaseURL(accountID: accountID)
    }

    /// The full model schema — one shared definition so every
    /// composition site (main container, demo, guest-migration reader,
    /// tests) enumerates the same entities. Recording and correction
    /// entities are device-cloud split: `SessionRecording` never syncs
    /// (audio stays local), `TranscriptCorrection` syncs as its own
    /// entity. The pre-class layer (`CourseSchedule`,
    /// `ScheduleException`) and the material library (`CourseMaterial`,
    /// `MaterialPage`, `MaterialAnnotation`, `CourseAssistantThread`,
    /// `CourseAssistantMessage`) sync as their own entities as well.
    static let librarySchema = Schema([
        ClassroomSession.self, TranscriptEntry.self,
        Course.self, SessionNote.self, StudyReview.self,
        SessionAttachment.self,
        GlossaryTerm.self, StudyCard.self, StudyTask.self,
        SessionRecording.self, TranscriptCorrection.self,
        CourseSchedule.self, ScheduleException.self,
        CourseMaterial.self, MaterialPage.self, MaterialAnnotation.self,
        CourseAssistantThread.self, CourseAssistantMessage.self,
        Exam.self, ExamTopic.self, StudyPlan.self, StudyPlanItem.self,
        StudyActivity.self,
        InterpreterConversation.self, InterpreterTurn.self,
        InterpreterDocument.self,
        ErrandCase.self, ErrandCaseItem.self
    ])

    // MARK: - Translation configuration (single source of truth)

    /// Whether a usable translation service is configured. Delegates
    /// synchronously to the *current* translator's `TranslatorConfig`
    /// check (`TranslationService.isConfiguredNow`) so UI presentation
    /// and the pipeline's dispatch-time triage can never disagree. The
    /// API key itself never leaves the service — views only see this Bool.
    var isTranslationConfigured: Bool {
        translationService.isConfiguredNow
    }

    /// Whether the image-understanding model is configured (visual Q&A
    /// gate). Reads the LIVE box — settings changes rebuild the service
    /// in place, so UI and dispatch can never disagree. Views only see
    /// this Bool; the key never leaves the service.
    var isImageModelConfigured: Bool {
        attachmentServiceBox.get()?.isConfiguredNow ?? false
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
        // Never play an old recording over an active microphone: opening
        // the live classroom stops playback outright (an honest stop, not
        // a mute — the playback screen re-loads on demand).
        playback.stop()
        // Same rule for interpreter speech: a live classroom's microphone
        // must never compete with TTS.
        interpreterSpeech.stop()
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
        // A freshly started classroom gets its Live Activity exactly now:
        // the session exists and is running (failed / refused starts never
        // reach here). A side effect only — the classroom itself never
        // depends on it.
        if coordinator.isRunning, sessionID != nil {
            systemCoordinator?.handleClassroomStarted()
            // In-classroom snapshot: the home banner and widgets learn
            // about the running session immediately.
            systemCoordinator?.refreshSnapshotAndWidgets(force: true)
        }
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
    /// collapse back to the tabs. The Live Activity first shows 正在保存
    /// (the stop drains the final segment), then dismisses when the data
    /// has actually been written.
    func endLiveSession() async {
        systemCoordinator?.handleClassroomStopping()
        await coordinator.stop()
        systemCoordinator?.handleClassroomEnded(saved: true)
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
        // Same launch-time reconciliation for interrupted material
        // extraction and digest runs (孤儿 analyzing 状态 → 可继续).
        materialExtractionRunner.reconcileInterrupted()
        materialDigestGenerator.reconcileInterrupted()
        // 随身翻译 document context: interrupted imports/extractions roll
        // back to honest states; stale temp files are reaped.
        InterpreterDocumentStoreShared.store?.removeStaleTempFiles()
        if let documentStore = InterpreterDocumentStoreShared.store {
            repository.reconcileInterpreterDocuments(store: documentStore)
            // Round 17: the user-chosen retention window for saved
            // conversations' documents (default: keep everything).
            _ = try? repository.applyInterpreterDocumentRetention(
                days: settings.interpreterDocumentRetentionDays,
                store: documentStore, asOf: .now
            )
        }
        // Recording rows ↔ disk: legacy raw.wav files gain metadata rows,
        // removed files flip isDeleted, orphan rows are reaped.
        try? repository.reconcileRecordingState()
        // File-protection attributes for files written by earlier builds
        // (idempotent in-place upgrade, off the main actor).
        DataProtectionReconciler.reconcileActiveProfile(accountID: accountID)
        // Round 17: reap expired share-sheet exports (the controlled
        // store) + the legacy loose files from pre-round-17 builds.
        TemporaryExportStore().reap()
        TemporaryExportStore.reapLegacyLooseFiles()
    }

    /// Re-arms the class-reminder rolling window (launch, foreground
    /// entry, schedule mutations). Pulls current rules + exceptions,
    /// resolves course names for the notification bodies, hands the window
    /// to the scheduler. A denied authorization just cancels — the
    /// timetable itself never depends on it.
    func refreshClassReminders() async {
        guard let schedules = try? repository.schedules(courseID: nil),
              let exceptions = try? repository.allExceptions()
        else { return }
        let courses = (try? repository.courses()) ?? []
        var names: [UUID: String] = [:]
        for course in courses { names[course.id] = course.name }
        await classReminders.refresh(
            schedules: schedules, exceptions: exceptions
        ) { courseID in names[courseID] }
    }

    /// Rebuilds the errand-reminder layer (launch, foreground entry,
    /// privacy-level change): forgets reminders whose items vanished,
    /// cancels terminal cases' reminders, and re-arms live ones under the
    /// CURRENT system-surface privacy policy (idempotent remove-then-add).
    /// Also prunes calendar mirrors whose events the user deleted
    /// system-side (honest state, never recreated behind the user's back).
    func refreshErrandReminders() async {
        guard let cases = try? repository.errandCases(includeArchived: true) else { return }
        var liveItemIDs: Set<UUID> = []
        var armed: [(item: ErrandCaseItem, caseTitle: String, kind: ErrandReminderScheduler.Kind)] = []
        for errandCase in cases {
            let items = (try? repository.errandCaseItems(caseID: errandCase.id)) ?? []
            // Terminal cases keep rows but lose their reminders.
            if errandCase.status.isTerminal {
                errandReminders.cancelCase(caseID: errandCase.id)
                continue
            }
            for item in items where item.status != .unconfirmed {
                liveItemIDs.insert(item.id)
                if let kind = errandReminders.armedKind(itemID: item.id) {
                    armed.append((item, errandCase.title, kind))
                }
            }
        }
        errandReminders.pruneMissingItems(liveItemIDs: liveItemIDs)
        for entry in armed {
            let lead = errandReminders.lead(itemID: entry.item.id)
            _ = await errandReminders.enable(
                item: entry.item, caseTitle: entry.caseTitle,
                kind: entry.kind, lead: lead
            )
        }
        errandCalendar.pruneStaleMirrors()
    }

    // MARK: - 随身翻译 (interpreter)

    /// The shared study-model service box (the interpreter translation
    /// service reuses the SAME OpenAI-compatible transport + key + model
    /// fallback chain — never a third HTTP client, never a second key).
    /// Read-only handing-out of the box itself; `refreshTranslationService`
    /// keeps it current.
    var studyServiceBoxForInterpreter: StudyServiceBox? {
        studyServiceBox
    }

    /// The image-understanding (multimodal) service box handed out the
    /// same way — the interpreter document page-image fallback rides the
    /// SAME attachment-analysis service (one key, one transport).
    var attachmentServiceBoxForInterpreter: AttachmentServiceBox? {
        attachmentServiceBox
    }

    /// Shared interpreter TTS engine — one per app so starting a live
    /// classroom, playback, or an account switch can stop it from one
    /// place (the ClassroomPlaybackService one-instance convention).
    /// Starting the live classroom stops interpreter speech outright:
    /// never speak over an active microphone.
    let interpreterSpeech = InterpreterSpeechService()

    // MARK: - System-integration bridge

    /// Honest feedback entry for the route coordinator.
    func reportMissingTarget(_ message: String) {
        missingTargetMessage = message
    }
    func consumeMissingTargetMessage() {
        missingTargetMessage = nil
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
    /// System-route parking (pending ids + live-screen directives),
    /// consumed exactly once by the owning screen. In-memory only.
    var systemRouteStorage = SystemRouteStorage()
    /// The live screen presents its existing end-confirmation dialog when
    /// this flag is set (a system surface asked to END the classroom —
    /// confirmation always happens in-app, never in the activity).
    var pendingEndConfirmation = false
    /// The live screen opens its blackboard capture sheet when set.
    var pendingBlackboardCapture = false
    /// Home presents the new-classroom form when set (a system surface
    /// asked to start a classroom — the full validation chain lives
    /// there, never in the widget).
    var pendingNewSessionForm = false

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

    // MARK: - Course-reminder routing

    /// A class-reminder notification tapped (or its 开始课堂 action fired).
    /// Non-nil means "route to the timetable and offer the class start" —
    /// IN-MEMORY ONLY, consumed by HomeScreen exactly once. The occurrence
    /// key identifies the concrete class; the schedule view resolves it
    /// against the current store (a deleted schedule shows 来源已不存在).
    var pendingClassOccurrenceKey: String?

    /// Routes a tapped class reminder: land on the home tab (where the
    /// next-class card handles the start flow with every permission and
    /// resource check) with the occurrence flagged.
    func openClassReminder(occurrenceKey: String) {
        selectedTab = .home
        pendingClassOccurrenceKey = occurrenceKey
    }

    /// The start flow consumed the reminder target.
    func consumeClassReminder() {
        pendingClassOccurrenceKey = nil
    }

    // MARK: - Exam-reminder routing

    /// A exam-reminder notification tapped. Non-nil means "route to the
    /// review tab's 计划 segment and push the exam's detail" — IN-MEMORY
    /// ONLY, consumed exactly once by ReviewCenterScreen.
    var pendingExamID: UUID?

    func openExamReminder(examID: UUID) {
        selectedTab = .review
        pendingExamID = examID
    }

    func consumeExamReminder() {
        pendingExamID = nil
    }

    /// A study-plan (今日学习) reminder tapped: land on the review tab's
    /// 今天 segment — IN-MEMORY ONLY, consumed exactly once.
    var pendingTodayStudy = false

    func openStudyPlanReminder() {
        selectedTab = .review
        pendingTodayStudy = true
    }

    func consumeStudyPlanReminder() {
        pendingTodayStudy = false
    }

    // MARK: - Errand-case routing (办事事项)

    /// An errand-reminder notification tapped. Non-nil means "land on the
    /// home tab and open that case's detail" — IN-MEMORY ONLY, consumed
    /// exactly once by HomeScreen. A deleted case shows the honest
    /// 事项已不存在 state in the detail screen.
    var pendingErrandCaseID: UUID?

    func openErrandCaseReminder(caseID: UUID) {
        selectedTab = .home
        pendingErrandCaseID = caseID
    }

    func consumeErrandCaseReminder() {
        pendingErrandCaseID = nil
    }

    // MARK: - Inbox routing (智能收件箱)

    /// A pending jump into one inbox item (in-memory only, consumed
    /// exactly once by HomeScreen). Set by internal routes that need to
    /// land on a specific shared item (e.g. the 今天 segment's pending
    /// candidate rows).
    var pendingInboxItemID: UUID?

    func openInboxItem(_ id: UUID) {
        selectedTab = .home
        pendingInboxItemID = id
    }

    func consumeInboxItemRoute() {
        pendingInboxItemID = nil
    }

    // MARK: - System-surface directives (consume-once flags)

    /// A system surface (Live Activity / control / intent) asked to end
    /// the classroom — the live screen presents its existing confirmation
    /// dialog; nothing is destroyed by the surface itself.
    func requestEndConfirmation() {
        pendingEndConfirmation = true
    }

    func consumeEndConfirmation() {
        pendingEndConfirmation = false
    }

    /// A system surface asked to capture the blackboard — the live screen
    /// opens its existing capture sheet.
    func requestBlackboardCapture() {
        pendingBlackboardCapture = true
    }

    func consumeBlackboardCapture() {
        pendingBlackboardCapture = false
    }

    /// A system surface asked to start a classroom — home presents the
    /// new-classroom form (name, permission, resource checks).
    func requestNewSessionForm() {
        selectedTab = .home
        pendingNewSessionForm = true
    }

    func consumeNewSessionForm() {
        pendingNewSessionForm = false
    }

    // MARK: - 随身翻译 (interpreter) routing

    /// A system surface (intent / shortcut / Spotlight) asked to open the
    /// interpreter screen — IN-MEMORY ONLY, consumed exactly once by
    /// HomeScreen, which pushes the page. The route NEVER starts the
    /// microphone; listening is always an explicit in-page action.
    var pendingInterpreterScreen = false

    func requestInterpreterScreen() {
        selectedTab = .home
        pendingInterpreterScreen = true
    }

    func consumeInterpreterScreen() {
        pendingInterpreterScreen = false
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
