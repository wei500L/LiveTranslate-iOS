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

        let schema = AppEnvironment.librarySchema
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
        let studyService = DemoStudyReviewService()
        let studyBox = StudyServiceBox()
        studyBox.set(studyService)
        // Demo attachment storage: a fresh temp directory per demo run —
        // never the real per-account store.
        let demoStoreRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ui-demo-attachments-\(UUID().uuidString)", isDirectory: true)
        let demoAttachmentStore = AttachmentFileStore(root: demoStoreRoot)
        AttachmentFileStoreShared.store = demoAttachmentStore
        let attachmentService = DemoAttachmentAnalysisService()
        let attachmentBox = AttachmentServiceBox()
        attachmentBox.set(attachmentService)
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
            // Demo reminders use the wiped demo defaults (and never fire:
            // the demo never grants notification permission).
            taskReminders: TaskReminderScheduler(defaults: defaults),
            // Demo mode never touches the production sync server.
            cloudSync: nil,
            studyReviewService: studyService,
            studyServiceBox: studyBox,
            attachmentAnalysisService: attachmentService,
            attachmentServiceBox: attachmentBox,
            attachmentStore: demoAttachmentStore
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

// MARK: - Demo study review service (canned, no network)

/// Debug-only stand-in for the study-review model service: the REAL
/// pipeline (chunking, parsing, persistence) runs end to end against these
/// canned responses — no network is ever touched, and this type does not
/// exist in Release builds.
struct DemoStudyReviewService: StudyReviewModelService {
    var isConfiguredNow: Bool { true }

    func complete(systemPrompt: String, userPrompt: String, maxTokens: Int) async throws -> String {
        if systemPrompt == StudyReviewPrompt.extractionSystemPrompt() {
            return """
            {"topic": "多元函数微分的引入", "keyPoints": [{"text": "偏导数描述多元函数沿单一方向的变化率", "cites": [1]}, {"text": "可微要求所有偏导数存在且连续", "cites": [2]}], "terms": [{"russian": "частная производная", "chinese": "偏导数", "explanation": "其余变量固定时函数对一个变量的导数", "cites": [1]}], "assignments": [{"text": "完成习题集第 4 章第 1–8 题", "cites": [2]}], "uncertainties": [{"text": "一段关于几何解释的话转录不完整", "cites": [1]}]}
            """
        }
        if systemPrompt == StudyReviewPrompt.mergeSystemPrompt() {
            return """
            {"topic": "多元函数的偏导数与可微性", "summary": "本讲从 ε−δ 定义的回顾出发，引入偏导数的概念：把其余变量固定，只考察函数对某一个自变量的变化率。随后给出了偏导数的形式化定义（增量比的极限），并通过具体二元函数的例子演示了计算方法。在几何上，偏导数对应曲面被坐标平面所截曲线的切线斜率。最后讨论了可微性：当所有偏导数存在且连续时函数可微，并预告了下一讲的微分与近似计算应用。", "outline": [{"title": "从 ε−δ 定义到多元函数", "detail": "回顾一元极限定义，说明多元情形的思路", "cites": [1], "children": []}, {"title": "偏导数的定义与计算", "detail": "固定其余变量，对单一变量求导；∂z/∂x 的极限形式", "cites": [2], "children": [{"title": "示例：具体二元函数求偏导", "detail": "课堂演算的两个例子", "cites": [3], "children": []}]}, {"title": "几何意义", "detail": "截面曲线切线的斜率", "cites": [4], "children": []}, {"title": "可微性条件与下一讲预告", "detail": "偏导数连续 ⇒ 可微；下一讲：全微分与近似计算", "cites": [5], "children": []}], "keyPoints": [{"text": "偏导数 = 其余变量固定时函数对单一变量的变化率", "cites": [2]}, {"text": "∂z/∂x 定义为增量比在增量趋于零时的极限", "cites": [2]}, {"text": "所有偏导数存在且连续 ⇒ 函数在该点可微", "cites": [5]}], "terms": [{"russian": "частная производная", "chinese": "偏导数", "explanation": "多元函数对单一自变量的导数（其余变量固定）", "cites": [2]}, {"russian": "дифференцируемая функция", "chinese": "可微函数", "explanation": "在该点可用线性逼近良好近似的函数", "cites": [5]}, {"russian": "окрестность точки", "chinese": "点的邻域", "explanation": "该点附近的一个小区域", "cites": [3]}], "assignments": [{"text": "完成习题集第 4 章第 1–8 题，下节课检查", "cites": [5]}], "uncertainties": [{"text": "几何解释一段的转录不完整，建议回看 [01:18] 附近原文", "cites": [1]}]}
            """
        }
        throw TranslationError.emptyResponse
    }
}

// MARK: - Demo attachment analysis service (canned, no network)

/// Debug-only stand-in for the multimodal image-analysis service: the REAL
/// pipeline (prompt build → parse → persist) runs end to end against a
/// canned structured response — no network is ever touched, no delay
/// animation simulates "thinking", and this type does not exist in Release
/// builds.
struct DemoAttachmentAnalysisService: AttachmentAnalysisModelService {
    var isConfiguredNow: Bool { true }

    func complete(
        systemPrompt: String, userPrompt: String,
        imageData: Data, imageMIME: String, maxTokens: Int
    ) async throws -> String {
        guard systemPrompt == AttachmentAnalysisPrompt.systemPrompt() else {
            throw TranslationError.emptyResponse
        }
        return """
        {"schemaVersion": 1, "title": "偏导数的定义与几何解释", "visibleText": ["∂z/∂x = lim(Δx→0) [f(x₀+Δx, y₀) − f(x₀, y₀)] / Δx", "z = f(x, y)", "Теорема: если частные производные непрерывны, функция дифференцируема"], "formulas": ["\\frac{\\partial z}{\\partial x} = \\lim_{\\Delta x \\to 0} \\frac{f(x_0+\\Delta x, y_0) - f(x_0, y_0)}{\\Delta x}"], "codeBlocks": [], "keyPoints": ["偏导数的极限定义", "偏导数连续 ⇒ 可微"], "explanation": "这块板书给出偏导数 ∂z/∂x 的形式化定义：固定 y = y₀，让 x 从 x₀ 增加 Δx，函数值的增量与 Δx 之比在 Δx→0 时的极限。结合本堂课上下文，这是从一元导数推广到多元函数的关键一步；右侧定理说明当所有偏导数存在且连续时函数可微。", "uncertainties": ["板书左侧第一行的下标 0 略有反光，无法完全确认是 x₀"], "transcriptReferences": [2]}
        """
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
    var activeSessionCourseID: UUID? { nil }
    var isRunning: Bool {
        sessionID != nil && state.phase != .finished
    }

    func start(
        title: String? = nil,
        courseID: UUID? = nil,
        schedule: ScheduleSessionContext? = nil
    ) async {
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
/// 本周 8 节), three demo courses (quick-start chips + course grouping),
/// the records list (six spec courses plus the home recents) with the
/// required status coverage, the detail timeline (8 entries with math
/// symbols, a skipped translation, a failed one, bookmarks, long text and
/// three notes — two anchored) and demo favorites.
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
        // Demo courses — the quick-start chips and course grouping have
        // real data behind them.
        let courseByName: [String: Course] = {
            let drafts: [(name: String, teacher: String, location: String, color: Int)] = [
                ("高等数学 II", "Иванова М.А.", "主楼 304", 0),
                ("现代俄语精读", "Петров С.Н.", "语言楼 210", 2),
                ("量子力学导论", "Смирнов А.В.", "", 5),
            ]
            var map: [String: Course] = [:]
            for draft in drafts {
                let course = Course(
                    name: draft.name,
                    teacherName: draft.teacher,
                    location: draft.location,
                    colorIndex: draft.color
                )
                context.insert(course)
                map[draft.name] = course
            }
            return map
        }()

        func courseID(forTitle title: String) -> UUID? {
            for (name, course) in courseByName where title.hasPrefix(name) {
                return course.id
            }
            return nil
        }

        // Demo schedules — a one-week real structure: a plain weekly
        // course, an odd/even course, one cancellation, one time change,
        // and a class happening around now (the next-class card / 进行中
        // states). Relative to today so screenshots stay deterministic;
        // demo mode never registers real notifications (classReminders'
        // refresh runs against the demo defaults but notifications are
        // never requested in demo composition).
        let anchorMonday = {
            var comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today)
            comps.weekday = 2
            return calendar.date(from: comps)!
        }()
        let semesterStart = calendar.date(byAdding: .day, value: -28, to: anchorMonday)!
        let semesterEnd = calendar.date(byAdding: .day, value: 84, to: anchorMonday)!
        func secs(_ hour: Int, _ minute: Int) -> Int { hour * 3600 + minute * 60 }
        func next(_ weekday: Int) -> Date {
            calendar.nextDate(
                after: today, matching: DateComponents(weekday: weekday + 1),
                matchingPolicy: .nextTime
            ) ?? today
        }

        let mathSchedule = CourseSchedule(
            courseID: courseByName["高等数学 II"]?.id,
            weekday: 1,
            startSecs: secs(10, 30),
            endSecs: secs(12, 5),
            recurrence: .weekly,
            weekParityAnchor: anchorMonday,
            firstWeekIsOdd: true,
            semesterStart: semesterStart,
            semesterEnd: semesterEnd,
            timezoneID: TimeZone.current.identifier,
            reminderLeadMins: 15
        )
        context.insert(mathSchedule)

        let russianSchedule = CourseSchedule(
            courseID: courseByName["现代俄语精读"]?.id,
            weekday: 3,
            startSecs: secs(15, 30),
            endSecs: secs(17, 5),
            recurrence: .oddWeeks,
            weekParityAnchor: anchorMonday,
            firstWeekIsOdd: true,
            semesterStart: semesterStart,
            semesterEnd: semesterEnd,
            timezoneID: TimeZone.current.identifier,
            locationOverride: "语言楼 210",
            reminderLeadMins: 30
        )
        context.insert(russianSchedule)

        // A class happening NOW (the home next-class card shows 正在上课).
        let nowComps = calendar.dateComponents([.hour, .minute], from: .now)
        let nowHour = nowComps.hour ?? 10
        let liveSchedule = CourseSchedule(
            courseID: courseByName["量子力学导论"]?.id,
            weekday: max(0, min(6, calendar.component(.weekday, from: today) - 1)),
            startSecs: secs(max(0, nowHour - 1), 30),
            endSecs: secs(nowHour + 1, 5),
            recurrence: .weekly,
            semesterStart: semesterStart,
            semesterEnd: semesterEnd,
            timezoneID: TimeZone.current.identifier,
            reminderLeadMins: -1
        )
        context.insert(liveSchedule)
        _ = next(1)

        // One cancelled date + one time change on the weekly course.
        let cancelDate = calendar.date(byAdding: .day, value: 7, to: next(1)) ?? today
        context.insert(ScheduleException(
            scheduleID: mathSchedule.id,
            courseID: mathSchedule.courseID,
            originalDate: cancelDate,
            kind: .cancelled,
            note: "老师出差"
        ))
        let moveDate = calendar.date(byAdding: .day, value: 14, to: next(1)) ?? today
        context.insert(ScheduleException(
            scheduleID: mathSchedule.id,
            courseID: mathSchedule.courseID,
            originalDate: moveDate,
            kind: .timeChanged,
            changedStart: secs(12, 0),
            changedEnd: secs(13, 35),
            note: "与下午课对调"
        ))
        // An ad-hoc extra class next Saturday.
        context.insert(ScheduleException(
            scheduleID: russianSchedule.id,
            courseID: russianSchedule.courseID,
            kind: .adHoc,
            changedStart: secs(10, 0),
            changedEnd: secs(11, 35),
            movedToDate: next(6),
            note: "补课"
        ))

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
                abnormalTermination: spec.abnormal,
                courseID: courseID(forTitle: spec.title)
            )
            context.insert(session)
            var detailEntryIDs: [UUID] = []
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
                if spec.title.hasPrefix("高等数学") {
                    detailEntryIDs.append(entry.id)
                    // The first and the long fourth line of today's math
                    // course carry the demo bookmarks.
                    if index == 0 || index == 3 {
                        bookmarkTargets.append((session.id, entry.id))
                    }
                }
                offset += 18
            }
            if spec.title.hasPrefix("高等数学") {
                detailSessionID = session.id
                // Demo study review: a completed review tied to the real
                // seeded entry ids, so the reading page and citations have
                // genuine data behind them.
                if detailEntryIDs.count > 3 {
                    var demoReviewContent = StudyReviewContent()
                    demoReviewContent.topic = "多元函数的偏导数与可微性"
                    demoReviewContent.summary = "本讲从 ε−δ 定义的回顾出发，引入偏导数的概念：把其余变量固定，只考察函数对某一个自变量的变化率。随后给出形式化定义并通过二元函数示例演示计算，几何上对应曲面截面曲线的切线斜率，最后讨论可微性条件并预告下一讲的全微分与近似计算。"
                    demoReviewContent.outline = [
                        .init(title: "从 ε−δ 定义到多元函数", detail: "回顾一元极限定义，说明多元情形的思路", refEntryIDs: [detailEntryIDs[0]], children: []),
                        .init(title: "偏导数的定义与计算", detail: "固定其余变量，对单一变量求导；增量比的极限形式", refEntryIDs: [detailEntryIDs[1], detailEntryIDs[3]], children: [
                            .init(title: "示例：具体二元函数求偏导", detail: "课堂演算的两个例子", refEntryIDs: [detailEntryIDs[6]], children: []),
                        ]),
                        .init(title: "可微性条件", detail: "偏导数存在且连续 ⇒ 可微", refEntryIDs: [detailEntryIDs[5]], children: []),
                    ]
                    demoReviewContent.keyPoints = [
                        .init(text: "偏导数 = 其余变量固定时函数对单一变量的变化率", refEntryIDs: [detailEntryIDs[1]]),
                        .init(text: "所有偏导数存在且连续 ⇒ 函数在该点可微", refEntryIDs: [detailEntryIDs[5]]),
                    ]
                    demoReviewContent.terms = [
                        .init(russian: "частная производная", chinese: "偏导数", explanation: "多元函数对单一自变量的导数（其余变量固定）", refEntryIDs: [detailEntryIDs[1]]),
                        .init(russian: "дифференцируемая функция", chinese: "可微函数", explanation: "在该点可用线性逼近良好近似的函数", refEntryIDs: [detailEntryIDs[5]]),
                    ]
                    demoReviewContent.assignments = [
                        .init(text: "完成习题集第 4 章第 1–8 题，下节课检查", refEntryIDs: [detailEntryIDs[6]]),
                    ]
                    demoReviewContent.uncertainties = [
                        .init(text: "几何解释一段的转录不完整，建议回看对应段落原文", refEntryIDs: [detailEntryIDs[4]]),
                    ]
                    demoReviewContent.userNotes = [
                        .init(text: "老师强调偏导数连续只是可微的充分条件"),
                    ]
                    if let reviewJSON = demoReviewContent.encodedString() {
                        let review = StudyReview(
                            id: session.id,
                            sessionID: session.id,
                            status: .completed,
                            contentJSON: reviewJSON,
                            generatedJSON: reviewJSON,
                            hasUserEdits: false,
                            chunkStateJSON: "",
                            reviewModel: "demo-review-model",
                            generatedAt: Date(),
                            sourceUpdatedAt: session.updatedAt
                        )
                        context.insert(review)
                    }
                }
                // Demo attachments: a blackboard-formula image and a
                // handwritten-note image, generated at runtime (no bundled
                // assets needed), stored through the REAL file store; the
                // formula board carries a canned analysis result anchored to
                // the definition entry so the viewer and review reference
                // chips have genuine data.
                if detailEntryIDs.count > 3, let demoStore = AttachmentFileStoreShared.store {
                    let attachmentSpecs: [(kind: AttachmentKind, title: String, anchorIndex: Int, draw: (CGSize) -> UIImage)] = [
                        (.blackboard, "偏导数定义板书", 1, Self.drawDemoBlackboard),
                        (.handwriting, "手写笔记 · 作业要求", 6, Self.drawDemoHandwriting),
                    ]
                    for (index, spec) in attachmentSpecs.enumerated() {
                        let image = spec.draw(CGSize(width: 1200, height: 900))
                        guard let data = image.jpegData(compressionQuality: 0.9) else { continue }
                        let attachmentID = UUID()
                        guard let processed = try? demoStore.processImport(data) else { continue }
                        try? demoStore.write(
                            original: data, importResult: processed,
                            attachmentID: attachmentID, sessionID: session.id
                        )
                        let attachment = SessionAttachment(
                            id: attachmentID,
                            sessionID: session.id,
                            courseID: courseID(forTitle: spec.title),
                            anchorEntryID: detailEntryIDs[spec.anchorIndex],
                            capturedAt: session.startTime.addingTimeInterval(TimeInterval(spec.anchorIndex * 300)),
                            title: spec.title,
                            caption: index == 0 ? "第二节黑板，定义和定理" : "下课前记的作业",
                            kind: spec.kind,
                            mimeType: processed.mimeType,
                            pixelWidth: processed.pixelWidth,
                            pixelHeight: processed.pixelHeight,
                            fileSize: processed.fileSize,
                            contentHash: processed.contentHash,
                            sortIndex: index
                        )
                        if index == 0 {
                            // Canned completed analysis on the board image
                            // (the demo service would produce the same
                            // result on demand; seeding it means the detail
                            // page shows a finished state immediately,
                            // without fake waiting).
                            let analysis = AttachmentAnalysisResult(
                                title: "偏导数的定义与几何解释",
                                visibleText: [
                                    "∂z/∂x = lim(Δx→0) [f(x₀+Δx, y₀) − f(x₀, y₀)] / Δx",
                                    "z = f(x, y)",
                                    "Теорема: если частные производные непрерывны, функция дифференцируема",
                                ],
                                formulas: [
                                    "\\frac{\\partial z}{\\partial x} = \\lim_{\\Delta x \\to 0} \\frac{f(x_0+\\Delta x, y_0) - f(x_0, y_0)}{\\Delta x}",
                                ],
                                codeBlocks: [],
                                keyPoints: [
                                    "偏导数的极限定义",
                                    "偏导数连续 ⇒ 可微",
                                ],
                                explanation: "这块板书给出偏导数 ∂z/∂x 的形式化定义：固定 y = y₀，让 x 从 x₀ 增加 Δx，函数增量与 Δx 之比在 Δx→0 时的极限。结合本堂课上下文，这是从一元导数推广到多元函数的关键一步；右侧定理说明当所有偏导数存在且连续时函数可微。",
                                uncertainties: [
                                    "板书左侧第一行的下标 0 略有反光，无法完全确认是 x₀",
                                ],
                                transcriptReferences: [detailEntryIDs[3]],
                                analysisModel: "demo-vision-model"
                            )
                            attachment.analysisJSON = analysis.encodedJSON() ?? ""
                            attachment.analysisStatus = .completed
                            attachment.ocrText = "∂z/∂x = lim … f(x₀+Δx, y₀)\nТеорема: частные производные непрерывны"
                        } else {
                            attachment.analysisStatus = .pending
                        }
                        context.insert(attachment)
                    }
                }
                // Demo notes: one anchored to the definition line, one to
                // the long formula line, one unanchored.
                if detailEntryIDs.count > 3 {
                    for note in [
                        SessionNote(
                            sessionID: session.id,
                            anchorEntryID: detailEntryIDs[0],
                            text: "ε−δ 定义必考，课后把三个例题重推一遍"
                        ),
                        SessionNote(
                            sessionID: session.id,
                            anchorEntryID: detailEntryIDs[3],
                            text: "偏导数极限的定义：其余变量固定不变——老师强调了两遍"
                        ),
                        SessionNote(
                            sessionID: session.id,
                            text: "下次课带《习题集》第 4 章，助教要检查作业"
                        ),
                    ] {
                        context.insert(note)
                    }

                    // Demo learning material (review center): terms saved
                    // from the seeded review, one card already mid-schedule,
                    // one new card awaiting its first review, one confirmed
                    // task with a deadline and one AI candidate awaiting
                    // confirmation. All rows go through direct context
                    // inserts (no repository, no mutation observer) — demo
                    // data never reaches a real account's outbox.
                    let mathCourseID = courseID(forTitle: "高等数学")
                    let terms: [GlossaryTerm] = [
                        GlossaryTerm(
                            russian: "частная производная",
                            chinese: "偏导数",
                            explanation: "多元函数对单一自变量的导数（其余变量固定）",
                            courseID: mathCourseID,
                            sessionID: session.id,
                            sourceEntryID: detailEntryIDs[1],
                            sourceReviewID: session.id,
                            sourceSessionIDs: [session.id],
                            isFavorite: true,
                            status: .learning
                        ),
                        GlossaryTerm(
                            russian: "дифференцируемая функция",
                            chinese: "可微函数",
                            explanation: "在该点可用线性逼近良好近似的函数",
                            courseID: mathCourseID,
                            sessionID: session.id,
                            sourceEntryID: detailEntryIDs[5],
                            sourceReviewID: session.id,
                            sourceSessionIDs: [session.id],
                            status: .new
                        ),
                    ]
                    for term in terms { context.insert(term) }

                    let reviewedCard = StudyCard(
                        front: "частная производная",
                        back: "偏导数：其余变量固定时，函数对单一自变量的变化率",
                        type: .ru2zh,
                        origin: .manual,
                        courseID: mathCourseID,
                        sessionID: session.id,
                        sourceEntryID: detailEntryIDs[1],
                        sourceTermID: terms[0].id,
                        stage: .young,
                        reviewCount: 3,
                        intervalHours: 24,
                        dueAt: Date().addingTimeInterval(-2 * 3600),
                        lastReviewedAt: Date().addingTimeInterval(-26 * 3600),
                        lastGrade: .good
                    )
                    context.insert(reviewedCard)
                    let newCard = StudyCard(
                        front: "偏导数存在且连续 ⇒ ？",
                        back: "函数在该点可微（充分条件，不必要）",
                        type: .qa,
                        origin: .manual,
                        courseID: mathCourseID,
                        sessionID: session.id,
                        sourceEntryID: detailEntryIDs[5]
                    )
                    context.insert(newCard)
                    // A card whose source session is gone — exercises the
                    // 来源已不存在 display path.
                    context.insert(StudyCard(
                        front: "Формула Тейлора",
                        back: "泰勒公式：用多项式逼近函数，余项刻画误差",
                        type: .formula,
                        origin: .manual,
                        stage: .learning,
                        reviewCount: 1,
                        intervalHours: 8,
                        dueAt: Date().addingTimeInterval(-3600),
                        lastReviewedAt: Date().addingTimeInterval(-9 * 3600),
                        lastGrade: .hard
                    ))

                    context.insert(StudyTask(
                        title: "完成习题集第 4 章第 1–8 题",
                        detail: "下节课检查，助教收作业本",
                        priority: .high,
                        status: .pending,
                        origin: .ai,
                        uncertainty: "老师口头布置，段落 7 有明确截止表述",
                        dueAt: Calendar.current.date(byAdding: .day, value: 2, to: Date()),
                        courseID: mathCourseID,
                        sessionID: session.id,
                        sourceEntryID: detailEntryIDs[6],
                        sourceReviewID: session.id
                    ))
                    context.insert(StudyTask(
                        title: "预习全微分一节（建议）",
                        detail: "老师提到下一讲会从全微分讲起",
                        priority: .low,
                        status: .pendingConfirm,
                        origin: .ai,
                        uncertainty: "原话是«有时间可以看»，可能不是强制作业",
                        courseID: mathCourseID,
                        sessionID: session.id,
                        sourceEntryID: detailEntryIDs[4],
                        sourceReviewID: session.id
                    ))
                }
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

    // MARK: - Demo image painters (runtime-generated, no bundled assets)

    /// A dark "blackboard" with white chalk formula lines.
    private static func drawDemoBlackboard(size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            UIColor(red: 0.13, green: 0.16, blue: 0.14, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let chalk = UIColor(white: 0.94, alpha: 1)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 46
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 40, weight: .medium),
                .foregroundColor: chalk,
                .paragraphStyle: paragraph,
            ]
            let text = """
            z = f(x, y)

            ∂z/∂x = lim [f(x₀+Δx, y₀) − f(x₀, y₀)] / Δx

            Теорема: если частные производные
            непрерывны, функция дифференцируема
            """
            (text as NSString).draw(
                in: CGRect(x: 70, y: 110, width: size.width - 140, height: size.height - 200),
                withAttributes: attrs
            )
        }
    }

    /// A light "paper" with handwritten-style assignment notes.
    private static func drawDemoHandwriting(size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            UIColor(red: 0.97, green: 0.96, blue: 0.93, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let ink = UIColor(red: 0.15, green: 0.2, blue: 0.4, alpha: 1)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 52
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 38, weight: .regular),
                .foregroundColor: ink,
                .paragraphStyle: paragraph,
            ]
            let text = """
            Домашнее задание:

            Задачник §4, № 1–8

            до пятницы ✏️
            """
            (text as NSString).draw(
                in: CGRect(x: 80, y: 130, width: size.width - 160, height: size.height - 220),
                withAttributes: attrs
            )
        }
    }
}
#endif
