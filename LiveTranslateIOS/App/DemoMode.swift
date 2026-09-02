#if DEBUG
import Foundation
import SwiftData

// MARK: - Launch options

/// Parsed `--ui-demo --demo-screen <page>` launch arguments (or the
/// equivalent `UI_DEMO` / `DEMO_SCREEN` environment variables, which
/// `SIMCTL_CHILD_` forwarding can populate). Debug builds only — this type
/// does not exist in Release, so no demo launch path can be compiled in.
struct DemoLaunchOptions {
    enum Screen: String {
        case home
        case newSession = "new-session"
        case live
        case records
        case detail
    }

    let screen: Screen

    static func parse(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment env: [String: String] = ProcessInfo.processInfo.environment
    ) -> DemoLaunchOptions? {
        let wantsDemo = arguments.contains("--ui-demo") || env["UI_DEMO"] == "1"
        guard wantsDemo else { return nil }

        var screen = Screen.home
        if let index = arguments.firstIndex(of: "--demo-screen"),
           index + 1 < arguments.count,
           let parsed = Screen(rawValue: arguments[index + 1]) {
            screen = parsed
        } else if let raw = env["DEMO_SCREEN"], let parsed = Screen(rawValue: raw) {
            screen = parsed
        }
        return DemoLaunchOptions(screen: screen)
    }
}

// MARK: - Demo composition

extension AppEnvironment {
    /// Launch-time composition for Debug builds: real environment unless
    /// the demo launch arguments opt into the UI demo mode.
    static func makeForLaunch() -> AppEnvironment {
        guard let options = DemoLaunchOptions.parse() else { return AppEnvironment() }
        return AppEnvironment.makeDemo(options: options)
    }

    /// Assemble the isolated UI demo environment. Everything user-real is
    /// swapped for in-memory or no-op stand-ins behind the same
    /// presentation interfaces:
    ///
    /// - SwiftData: in-memory container (never touches the real store);
    /// - UserDefaults: dedicated `ui-demo` suite, wiped on every demo run;
    /// - Keychain: in-memory store (never touches the real keychain);
    /// - translation: canned local service (never touches the network);
    /// - ASR: scripted demo coordinator (no model load, no audio capture,
    ///   no microphone permission);
    /// - model management: no-op manager reporting both backends installed
    ///   (no downloads can ever be triggered from the demo).
    static func makeDemo(options: DemoLaunchOptions) -> AppEnvironment {
        // Fresh, isolated defaults every demo run.
        let suiteName = "ui-demo"
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard

        let schema = Schema([ClassroomSession.self, TranscriptEntry.self])
        let configuration = ModelConfiguration(
            "ui-demo", schema: schema, isStoredInMemoryOnly: true
        )
        let container: ModelContainer
        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // A demo environment that cannot be built falls back to the
            // real one rather than crashing the launch path.
            return AppEnvironment()
        }

        // Settings on the isolated suite; configured so readiness shows
        // 全部就绪 deterministically.
        let settings = SettingsStore(defaults: defaults)
        settings.apiBase = "https://demo.local/v1"
        settings.translationModel = "demo-translator"
        settings.liveTranslationEnabled = true

        let repository = TranscriptRepository(container: container)
        let demoCoordinator = DemoLiveCoordinator()
        let service = DemoTranslationService()
        let box = TranslationServiceBox()
        box.set(service)
        let environment = AppEnvironment(
            capabilities: AppEnvironment.Capabilities(
                requestsMicrophonePermission: false,
                assumesMicrophoneAuthorized: true
            ),
            modelContainer: container,
            settings: settings,
            engineManager: DemoEngineManager(),
            keychain: DemoKeychainStore(),
            repository: repository,
            modelManager: DemoModelManager(),
            benchmarkRunner: ASRBenchmarkRunner(engineManager: ASREngineManager(settings: settings)),
            coordinator: demoCoordinator,
            translationService: service,
            translationServiceBox: box,
            bookmarks: BookmarkStore(defaults: defaults, repository: repository),
            // Demo mode never touches the production sync server.
            cloudSync: nil
        )

        environment.flow.demoGreeting = "晚上好，学习者"
        environment.flow.demoPrefilledSessionName = "高等数学 II · 第6讲"
        DemoSeed.populate(
            container: container,
            bookmarks: environment.bookmarks,
            flow: environment.flow
        )
        environment.flow.pendingDemoScreen = options.screen
        return environment
    }

    /// Consume the demo launch directive exactly once (called from the
    /// root view's launch task). Screens the directive points at but that
    /// need view-level presentation (new-session sheet, detail push)
    /// leave the marker in place for their own `onAppear` to consume.
    func presentDemoLaunchScreenIfNeeded() {
        guard let screen = flow.pendingDemoScreen else { return }
        switch screen {
        case .home:
            flow.selectedTab = .home
            flow.pendingDemoScreen = nil
        case .records:
            flow.selectedTab = .records
            flow.pendingDemoScreen = nil
        case .live:
            flow.selectedTab = .home
            flow.pendingDemoScreen = nil
            Task { @MainActor in
                if !coordinator.isRunning {
                    await coordinator.start(title: "高等数学 II · 第6讲 多元函数微分")
                }
                presentLive()
            }
        case .newSession:
            // HomeScreen's onPresent opens the new-classroom sheet.
            flow.selectedTab = .home
        case .detail:
            // RecordsScreen's onAppear pushes the seeded detail.
            flow.selectedTab = .records
        }
    }
}

// MARK: - Demo ASR engine (status-only stand-in)

/// Reports both backends installed without touching disk, so home
/// readiness and the new-classroom form show 本地转写 · 已就绪 and no model
/// download is ever reachable.
@MainActor
final class DemoEngineManager: ASREngineManaging {
    var loaded: ASREngineManager.LoadedEngine? { nil }
    var sessionActive: Bool { false }
    nonisolated func isInstalled(_ kind: ASRBackendKind) async -> Bool { true }
}

// MARK: - Demo model manager (no-op stand-in)

/// Every action is a no-op and both backends report installed — the demo
/// can never trigger a real download, verification or deletion.
@MainActor
final class DemoModelManager: ModelManaging {
    private static let installedStates: [ASRBackendKind: ModelManager.BackendInstallState] = [
        .coreMLFP16: ModelManager.BackendInstallState(
            kind: .coreMLFP16,
            isInstalled: true,
            installedBytes: 168_000_000,
            version: "demo",
            integrityVerified: true,
            coreMLCompiled: true
        ),
        .sherpaONNXInt8: ModelManager.BackendInstallState(
            kind: .sherpaONNXInt8,
            isInstalled: true,
            installedBytes: 96_000_000,
            version: "demo",
            integrityVerified: true,
            coreMLCompiled: false
        ),
    ]

    var states: [ASRBackendKind: ModelManager.BackendInstallState] { Self.installedStates }
    var isInstalling: Bool { false }
    var manifestAvailable: Bool { true }

    func refreshStates() {}
    func install(_ kind: ASRBackendKind) {}
    func pause(_ kind: ASRBackendKind) {}
    func resume(_ kind: ASRBackendKind) {}
    func reverify(_ kind: ASRBackendKind) async {}
    func delete(_ kind: ASRBackendKind) throws {}
    func backendInfo(_ kind: ASRBackendKind) -> ModelManifest.BackendInfo? { nil }
}

// MARK: - Demo keychain (in-memory stand-in)

/// Dictionary-backed keychain stand-in: the demo never reads or writes the
/// device keychain (no real API key is ever touched).
final class DemoKeychainStore: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    func set(_ value: String, forKey key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = value
    }

    func get(forKey key: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    func delete(forKey key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: key)
    }
}

// MARK: - Demo translation service (canned, no network)

/// Reports configured and answers with a canned translation. The demo
/// coordinator never actually requests translations — this exists so the
/// environment's `isTranslationConfigured` reads true.
struct DemoTranslationService: TranslationService {
    var isConfigured: Bool { true }
    var isConfiguredNow: Bool { true }

    func translate(_ request: TranslationRequest) async -> TranslationOutcome {
        TranslationOutcome(
            sequenceID: request.sequenceID,
            text: "（演示翻译）" + request.text,
            latency: 0.05,
            isRetryable: false,
            errorDescription: nil
        )
    }

    func testConnection() async -> Result<String, TranslationError> {
        .success("演示模式 · 未连接真实服务")
    }
}

// MARK: - Demo live coordinator (scripted classroom)

/// Scripted stand-in for `LiveTranslationCoordinator`: seeds the reference
/// transcript, advances a deterministic classroom clock (~4 Hz) and a
/// deterministic low-frequency waveform, and cycles the pipeline phase
/// through 等待讲话 → 正在监听 → 正在识别 → 正在翻译. No model, no audio
/// capture, no network — pause/resume/bookmark/end only mutate demo state.
@MainActor
@Observable
final class DemoLiveCoordinator: LiveTranslationCoordinating {
    private(set) var state = PipelineState()
    private(set) var entries: [LiveTranscriptItem] = []
    private(set) var isNetworkAvailable = true
    private(set) var audioLevels: [Float] = []
    private(set) var isPaused = false

    private var sessionID: UUID?
    private var sessionTitleValue: String = "课堂"
    private var demoTask: Task<Void, Never>?
    private var waveformPhase: Float = 0

    var activeSessionID: UUID? { sessionID }
    var activeSessionTitle: String? { sessionTitleValue }
    var isRunning: Bool {
        sessionID != nil && state.phase != .finished
    }

    func start(title: String? = nil) async {
        guard !isRunning else { return }
        sessionID = UUID()
        sessionTitleValue = title ?? "演示课堂"
        entries = []
        audioLevels = []
        isPaused = false
        state = PipelineState()
        state.phase = .listening

        // Seed the reference scenario: the previous segment is already
        // translated (dimmed history), the current one is mid-translation
        // (the lyric focus), and the next one lands a few seconds later.
        let previous = Self.item(
            sequenceID: 1, offset: 41,
            russian: "Мы вспомнили определение ε−δ и проиллюстрировали его геометрический смысл на примерах.",
            chinese: "我们回顾了 ε−δ 定义，并通过几个例子说明了它的几何意义。",
            status: .completed
        )
        let current = Self.item(
            sequenceID: 2, offset: 108,
            russian: "Теперь мы введём понятие частной производной, которая описывает скорость изменения функции нескольких переменных по одному направлению.",
            chinese: nil,
            status: .pending
        )
        entries = [previous, current]

        // Deterministic classroom clock + waveform + phase cycle (~4 Hz).
        let startedAt = Date()
        var currentCompleted = false
        var nextLanded = false
        var nextCompleted = false
        demoTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                guard self.isRunning else { return }
                guard !self.isPaused else { continue }

                let elapsed = Date().timeIntervalSince(startedAt)
                self.state.elapsed = elapsed

                // Deterministic low-frequency waveform (two sines, ~0.7 Hz
                // and a slow swell) — display only, no particle effects.
                self.waveformPhase += 0.075
                let swell = Float(0.55 + 0.35 * sin(elapsed / 9.0))
                let oscillation = 0.35
                    + 0.22 * sin(self.waveformPhase)
                    + 0.12 * sin(self.waveformPhase * 2.3)
                let level = max(0.04, min(1, swell * oscillation))
                self.audioLevels.append(level)
                if self.audioLevels.count > 64 {
                    self.audioLevels.removeFirst(self.audioLevels.count - 64)
                }

                // Phase cycle around the current segment's translation.
                switch elapsed {
                case ..<3.5:
                    self.state.phase = .listening
                case ..<5:
                    self.state.phase = .speechDetected
                case ..<6.5:
                    self.state.phase = .transcribing
                case ..<8:
                    self.state.phase = .translating
                default:
                    if !currentCompleted, elapsed >= 8 {
                        self.completeCurrentTranslation()
                        currentCompleted = true
                        self.state.phase = .listening
                    }
                    if !nextLanded, elapsed >= 12 {
                        self.entries.append(Self.item(
                            sequenceID: 3, offset: 176,
                            russian: "Пусть функция z = f(x,y) определена в некоторой окрестности точки (x₀,y₀).",
                            chinese: nil,
                            status: .pending
                        ))
                        nextLanded = true
                        self.state.phase = .transcribing
                    }
                    if !nextCompleted, elapsed >= 15 {
                        self.completeCurrentTranslation()
                        nextCompleted = true
                        self.state.phase = .listening
                    }
                }
            }
        }
    }

    private func completeCurrentTranslation() {
        guard let index = entries.indices.last,
              entries[index].translationStatus == .pending else { return }
        entries[index].translatedText = Self.chineseFor(entries[index].originalText)
            ?? entries[index].translatedText
        entries[index].translationStatus = .completed
    }

    /// Deterministic demo pairing so a resumed script can find the Chinese
    /// line for a seeded Russian line.
    private static func chineseFor(_ russian: String) -> String? {
        script.first { $0.russian == russian }?.chinese
    }

    private static let script: [(russian: String, chinese: String)] = [
        (
            "Мы вспомнили определение ε−δ и проиллюстрировали его геометрический смысл на примерах.",
            "我们回顾了 ε−δ 定义，并通过几个例子说明了它的几何意义。"
        ),
        (
            "Теперь мы введём понятие частной производной, которая описывает скорость изменения функции нескольких переменных по одному направлению.",
            "现在我们将讨论偏导数的概念，它描述了多元函数在某一方向上的变化率。"
        ),
        (
            "Пусть функция z = f(x,y) определена в некоторой окрестности точки (x₀,y₀).",
            "设函数 z = f(x,y) 在点 (x₀,y₀) 的某个邻域内有定义。"
        ),
    ]

    private static func item(
        sequenceID: Int,
        offset: TimeInterval,
        russian: String,
        chinese: String?,
        status: TranslationStatus
    ) -> LiveTranscriptItem {
        var item = LiveTranscriptItem(
            sequenceID: sequenceID,
            timestamp: "14:0\(min(sequenceID, 9))",
            startOffset: offset,
            originalText: russian,
            translatedText: chinese,
            translationStatus: status
        )
        item.entryID = UUID()
        return item
    }

    func pause() {
        guard isRunning, !isPaused else { return }
        isPaused = true
        state.phase = .paused
    }

    func resume() {
        guard isRunning, isPaused else { return }
        isPaused = false
        state.phase = .listening
    }

    func stop() async {
        demoTask?.cancel()
        demoTask = nil
        state.phase = .finished
    }

    func retryTranslation(sequenceID: Int) {}
    func retryFailedTranslations() {}
}

// MARK: - Demo seed data

/// Seeds the in-memory demo store: study statistics (今日 2 小时 15 分,
/// 本周 8 节), the records list (six spec courses plus the home recents)
/// with the required status coverage, the detail timeline (8 entries with
/// math symbols, a skipped translation, a failed one, bookmarks and long
/// text) and demo favorites.
enum DemoSeed {
    @MainActor
    static func populate(
        container: ModelContainer,
        bookmarks: BookmarkStore,
        flow: AppFlow
    ) {
        let context = ModelContext(container)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)

        func day(_ offset: Int, hour: Int, minute: Int = 0) -> Date {
            let base = calendar.date(byAdding: .day, value: -offset, to: today)!
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base)!
        }

        struct Spec {
            let title: String
            let start: Date
            let duration: TimeInterval
            let abnormal: Bool
            let favorite: Bool
            let entries: [(ru: String?, zh: String?, status: TranslationStatus)]
        }

        // The detail/demo timeline — bilingual, math symbols, one skipped
        // (translation off), one failed, long lines, two bookmarks.
        let detailEntries: [(ru: String?, zh: String?, status: TranslationStatus)] = [
            (
                "Мы вспомнили определение ε−δ и проиллюстрировали его геометрический смысл на примерах.",
                "我们回顾了 ε−δ 定义，并通过几个例子说明了它的几何意义。",
                .completed
            ),
            (
                "Теперь мы введём понятие частной производной.",
                "现在我们引入偏导数的概念。",
                .completed
            ),
            (
                "Пусть функция z = f(x,y) определена в некоторой окрестности точки (x₀,y₀).",
                nil,
                .skipped
            ),
            (
                "Частная производная ∂z/∂x определяется как предел отношения приращения функции к приращению аргумента, когда последнее стремится к нулю, при фиксированных значениях остальных переменных.",
                "偏导数 ∂z/∂x 定义为：在其余变量固定不变时，函数增量与自变量增量之比在后者趋于零时的极限。",
                .completed
            ),
            (
                "Геометрически частная производная равна тангенсу угла наклона касательной прямой к сечению поверхности плоскостью, параллельной координатной плоскости.",
                nil,
                .failed
            ),
            (
                "Если все частные производные существуют и непрерывны, функция называется дифференцируемой в данной точке.",
                "若所有偏导数都存在且连续，则称函数在该点可微。",
                .completed
            ),
            (
                "Рассмотрим несколько примеров вычисления частных производных для конкретных функций двух переменных.",
                "我们来举几个具体二元函数求偏导数的例子。",
                .completed
            ),
            (
                "На следующей лекции мы перейдём к дифференциалу функции нескольких переменных и его приложениям к приближённым вычислениям, а также обсудим геометрическую интерпретацию полного приращения функции в окрестности рассматриваемой точки.",
                "下一讲我们将进入多元函数的微分及其在近似计算中的应用，并讨论函数在所考虑点邻域内全增量的几何解释。",
                .completed
            ),
        ]

        let specs: [Spec] = [
            // Today — the home/live/detail demo course (2 h 15 m today).
            Spec(
                title: "高等数学 II · 第6讲 多元函数微分",
                start: day(0, hour: 14, minute: 30),
                duration: 8100,
                abnormal: false,
                favorite: false,
                entries: detailEntries
            ),
            // Yesterday — recent on home.
            Spec(
                title: "俄语听力训练 · 学术讲座",
                start: day(1, hour: 10),
                duration: 3300,
                abnormal: false,
                favorite: false,
                entries: [
                    ("Лекция посвящена академическому аудированию.", "本讲主题为学术听力训练。", .completed),
                    ("Обратите внимание на интонационные конструкции.", "请注意语调结构。", .completed),
                ]
            ),
            Spec(
                title: "现代俄语精读 · 句法结构分析",
                start: day(2, hour: 9),
                duration: 5400,
                abnormal: false,
                favorite: false,
                entries: [
                    ("Сложноподчинённое предложение состоит из главной и придаточной частей.", "主从复合句由主句和从句两部分构成。", .completed),
                    ("Рассмотрим союзные слова и союзы.", "我们来考察关联词和连接词。", .completed),
                ]
            ),
            Spec(
                title: "俄罗斯文学史 · 普希金与黄金时代",
                start: day(3, hour: 15),
                duration: 4500,
                abnormal: false,
                favorite: true,
                entries: [
                    ("Пушкин — солнце русской поэзии.", "普希金是俄罗斯诗歌的太阳。", .completed),
                    ("Золотой век длился примерно с 1810 по 1840 год.", "黄金时代大约从 1810 年持续到 1840 年。", .completed),
                ]
            ),
            // 部分翻译失败 + 收藏.
            Spec(
                title: "量子力学导论 · 第12讲",
                start: day(4, hour: 13),
                duration: 6300,
                abnormal: false,
                favorite: true,
                entries: [
                    ("Волновая функция описывает состояние квантовой системы.", "波函数描述量子系统的状态。", .completed),
                    ("Принцип суперпозиции допускает линейные комбинации состояний.", nil, .failed),
                    ("Измерение мгновенно коллапсирует волновую функцию.", "测量使波函数瞬间坍缩。", .completed),
                ]
            ),
            Spec(
                title: "编译原理 · 第8讲",
                start: day(5, hour: 8),
                duration: 5400,
                abnormal: false,
                favorite: false,
                entries: [
                    ("Синтаксический анализ строит дерево разбора.", "语法分析构建语法分析树。", .completed),
                    ("LL(1)-грамматики допускают нисходящий разбор.", "LL(1) 文法支持自顶向下分析。", .completed),
                ]
            ),
            Spec(
                title: "统计学习方法 · 第7讲",
                start: day(6, hour: 16),
                duration: 4800,
                abnormal: false,
                favorite: false,
                entries: [
                    ("Метод опорных векторов максимизирует зазор.", "支持向量机最大化间隔。", .completed),
                ]
            ),
            // 8th in-week classroom for 本周完成 8 节.
            Spec(
                title: "近代物理实验 · 第4讲",
                start: day(6, hour: 10),
                duration: 3600,
                abnormal: true,
                favorite: false,
                entries: [
                    ("Опыт Майкельсона — Морли опроверг эфир.", "迈克尔逊—莫雷实验否证了以太。", .completed),
                    ("Точность интерферометра имела решающее значение.", "干涉仪的精度起到了决定性作用。", .completed),
                ]
            ),
            // Out of week — older history.
            Spec(
                title: "有机化学 · 第10讲",
                start: day(9, hour: 11),
                duration: 5700,
                abnormal: false,
                favorite: false,
                entries: [
                    ("Механизм реакции SN1 включает карбокатион.", "SN1 反应机理包含碳正离子中间体。", .completed),
                ]
            ),
        ]

        var detailSessionID: UUID?
        var bookmarkTargets: [(sessionID: UUID, entryID: UUID)] = []
        for spec in specs {
            let session = ClassroomSession(
                title: spec.title,
                startTime: spec.start,
                endTime: spec.start.addingTimeInterval(spec.duration),
                duration: spec.duration,
                asrBackend: ASRBackendKind.coreMLFP16.rawValue,
                modelVersion: "demo",
                computePreference: "cpuAndGPU",
                translationModel: "demo-translator",
                entryCount: spec.entries.count,
                abnormalTermination: spec.abnormal
            )
            context.insert(session)
            var offset: TimeInterval = 0
            for (index, row) in spec.entries.enumerated() {
                let entry = TranscriptEntry(
                    sessionID: session.id,
                    sequenceID: index + 1,
                    startOffset: offset,
                    endOffset: offset + 18,
                    originalText: row.ru ?? "",
                    translatedText: row.zh,
                    translationStatus: row.status.rawValue,
                    asrBackend: ASRBackendKind.coreMLFP16.rawValue
                )
                entry.session = session
                context.insert(entry)
                // The first and the long fourth line of today's math course
                // carry the demo bookmarks.
                if spec.title.hasPrefix("高等数学"), index == 0 || index == 3 {
                    bookmarkTargets.append((session.id, entry.id))
                }
                offset += 18
            }
            if spec.title.hasPrefix("高等数学") {
                detailSessionID = session.id
            }
            if spec.favorite {
                _ = bookmarks.toggleFavorite(session.id)
            }
        }
        try? context.save()

        for target in bookmarkTargets {
            _ = bookmarks.toggleBookmark(sessionID: target.sessionID, entryID: target.entryID)
        }

        flow.demoDetailSessionID = detailSessionID
    }
}
#endif
