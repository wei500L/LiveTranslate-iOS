#if DEBUG
import EventKit
import Foundation
import SwiftData
import UIKit
import UserNotifications

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
        case interpreter
        /// 随身翻译现场文件 demo：一份虚构的宿舍登记表 + canned OCR/AI
        /// 驱动真实 ViewModel 状态机（绝不打开相机/相册/App Group）。
        case interpreterDocument = "interpreter-document"
        /// 柜台办理 demo（第十九轮）：虚构的宿舍入住登记草稿对话 ——
        /// 多状态回合（成功/等待/失败/长文本）+ 办事事项上下文条 +
        /// canned 翻译链（绝不打开麦克风；`--demo-interpreter-state`
        /// 可选注入 listening/showmode/facing/sheet 视觉状态）。
        case interpreterCounter = "interpreter-counter"
        /// 办事事项 demo：完全虚构的宿舍登记案例（候选材料/已确认预约/
        /// 现场问题/不确定费用/跟进 + 本地来源两种状态），fake 通知与
        /// 日历（绝不触真实 UNUserNotificationCenter / EventKit）。
        case administrativeCase = "administrative-case"
    }

    let screen: Screen
    /// `--demo-interpreter-state <state>`：interpreter-counter demo 的
    /// 确定性视觉状态（conversation/failure/listening/showmode/facing/
    /// sheet/longtext）。
    let interpreterState: String?

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
        var interpreterState: String? = nil
        if let index = arguments.firstIndex(of: "--demo-interpreter-state"),
           index + 1 < arguments.count {
            interpreterState = arguments[index + 1]
        }
        return DemoLaunchOptions(
            screen: screen, interpreterState: interpreterState
        )
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
        // Demo material storage: the same fresh temp directory rule —
        // demo material files never reach the real per-account store.
        let demoMaterialStore = MaterialFileStore(
            root: demoStoreRoot.appendingPathComponent("Materials", isDirectory: true)
        )
        MaterialFileStoreShared.store = demoMaterialStore
        // Demo interpreter-document storage: same fresh temp directory
        // rule (虚构的宿舍登记表 lives ONLY in the demo temp dir — the
        // real per-account store is never touched).
        let demoDocumentStore = InterpreterDocumentStore(
            root: demoStoreRoot.appendingPathComponent("InterpreterDocuments", isDirectory: true)
        )
        InterpreterDocumentStoreShared.store = demoDocumentStore
        let demoExtractionRunner = MaterialExtractionRunner(
            repository: repository,
            fileStore: { MaterialFileStoreShared.store }
        )
        let demoAttachmentService = DemoAttachmentAnalysisService()
        let demoAttachmentBox = AttachmentServiceBox()
        demoAttachmentBox.set(demoAttachmentService)
        let demoDigestGenerator = MaterialDigestGenerator(
            repository: repository,
            textServiceProvider: { [weak studyBox] in studyBox?.get() },
            imageServiceProvider: { [weak demoAttachmentBox] in demoAttachmentBox?.get() }
        )
        // Demo inbox: a FRESH throwaway store (never the real App Group —
        // demo shares are never registered anywhere real). The real
        // SharedInboxStore interface is reused so the demo exercises the
        // same coordinator code.
        let demoInboxStore = SharedInboxStore(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("ui-demo-inbox-\(UUID().uuidString)", isDirectory: true)
        )
        let demoInbox = InboxCoordinator(
            store: demoInboxStore,
            imageServiceProvider: { [weak demoAttachmentBox] in demoAttachmentBox?.get() },
            textServiceProvider: { [weak studyBox] in studyBox?.get() }
        )
        let demoAssistant = CourseAssistantService(
            repository: repository,
            textServiceProvider: { [weak studyBox] in studyBox?.get() },
            imageServiceProvider: { [weak demoAttachmentBox] in demoAttachmentBox?.get() }
        )
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
            // Demo errand reminders/calendar: FAKE centers — the demo
            // never touches the real UNUserNotificationCenter or EventKit
            // (the injectable protocols make the same real ViewModel and
            // real UI run against in-memory stand-ins).
            errandReminders: ErrandReminderScheduler(
                defaults: defaults, center: DemoErrandNotificationCenter()
            ),
            errandCalendar: ErrandCalendarMirror(
                defaults: defaults, store: DemoErrandEventStore()
            ),
            // Demo mode never touches the production sync server.
            cloudSync: nil,
            studyReviewService: studyService,
            studyServiceBox: studyBox,
            attachmentAnalysisService: demoAttachmentService,
            attachmentServiceBox: demoAttachmentBox,
            attachmentStore: demoAttachmentStore,
            materialStore: demoMaterialStore,
            materialExtractionRunner: demoExtractionRunner,
            materialDigestGenerator: demoDigestGenerator,
            courseAssistant: demoAssistant,
            inbox: demoInbox
        )

        environment.flow.demoGreeting = "晚上好，学习者"
        environment.flow.demoPrefilledSessionName = "高等数学 II · 第6讲"
        DemoSeed.populate(
            container: container,
            bookmarks: environment.bookmarks,
            flow: environment.flow
        )
        // The errand demo seeds its fictional dorm-registration case into
        // the same in-memory container (real repository, fake surfaces).
        DemoSeed.populateErrandDemo(container: container)
        // 柜台办理 demo：虚构的宿舍入住登记草稿对话（多状态回合）。
        if options.screen == .interpreterCounter {
            DemoSeed.populateInterpreterCounterDemo(
                container: container, state: options.interpreterState
            )
            environment.flow.demoInterpreterCaseID = DemoSeed.errandDemoCaseID
        }
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
                    await coordinator.start(
                        title: "高等数学 II · 第6讲 多元函数微分",
                        courseID: nil, schedule: nil
                    )
                }
                presentLive()
            }
        case .newSession:
            // HomeScreen's onPresent opens the new-classroom sheet.
            flow.selectedTab = .home
        case .detail:
            // RecordsScreen's onAppear pushes the seeded detail.
            flow.selectedTab = .records
        case .interpreter:
            // HomeScreen's onAppear consumes the interpreter pending
            // route (the demo never opens the microphone — the canned
            // conversation is seeded in the demo SwiftData store).
            flow.selectedTab = .home
            flow.requestInterpreterScreen()
        case .interpreterDocument:
            // Same route as interpreter (the seeded demo conversation
            // carries a document context row; the panel is one tap away —
            // the demo never opens camera/photos/real App Group).
            flow.selectedTab = .home
            flow.requestInterpreterScreen()
        case .interpreterCounter:
            // 柜台办理 demo：HomeScreen pushes InterpreterScreen with the
            // seeded errand case attached（上下文条/待问问题来自种子数据；
            // 绝不自动开麦 —— listening 状态由 --demo-interpreter-state
            // 注入真实状态机）。
            flow.selectedTab = .home
            flow.requestInterpreterScreen()
        case .administrativeCase:
            // The seeded dorm-registration case opens from the errand
            // list (seeded in the demo SwiftData store; the demo never
            // arms real notifications or EventKit).
            flow.selectedTab = .home
            flow.requestErrandCaseList()
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
    // The demo never starts a real listening loop — these exist so the
    // conformance compiles; a demo tap on 听对方说 fails honestly rather
    // than loading any model.
    func ensureLoaded(_ kind: ASRBackendKind) async throws {
        throw ASREngineError.engineNotLoaded
    }
    func beginSession() throws {}
    func endSession() {}
    func transcribe(_ segment: SpeechSegment) async throws -> ASRResult {
        throw ASREngineError.engineNotLoaded
    }
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
        // 随身翻译 (interpreter) demo：一次宿舍办理对话的 canned 结构化
        // 响应 —— 驱动真实的 ViewModel / 解析 / 持久化链路。绝不进入
        // Release（整文件 #if DEBUG）。
        if systemPrompt.hasPrefix("你是一位现场口译助手") {
            if userPrompt.contains("对方刚刚说") {
                return """
                {"chinese": "您有护照复印件吗？", "stressedRussian": "У вас есть ко́пия па́спорта?", "intent": "询问材料", "keywords": ["паспорт 护照", "копия 复印件"], "ambiguity": "", "suggestions": ["我只有原件，可以在这里复印吗？", "我明天带来复印件"]}
                """
            }
            return """
            {"russian": "У меня есть только оригинал. Мо́жно сде́лать ко́пию здесь?", "stressedRussian": "У меня есть то́лько оригина́л. Мо́жно сде́лать ко́пию здесь?", "backTranslation": "我只有原件。可以在这里复印吗？", "keywords": ["оригинал 原件", "копия 复印件"], "politeAlternative": "Не могли бы вы подсказать, где можно сделать копию документа?", "simpleAlternative": "Где можно сделать копию?", "uncertainties": []}
            """
        }
        if systemPrompt.hasPrefix("你是一位现场文件理解助手") {
            // 随身翻译现场文件 demo：虚构宿舍登记表的 canned 文件分析
            // （明确标记的虚构数据 —— 不使用真实护照、地址或文件）。
            if userPrompt.contains("请分析这份文件并返回 JSON") {
                return """
                {"documentType": "宿舍入住登记表（演示虚构数据）", "summaryChinese": "这是一份演示用的宿舍入住登记表：需要填写个人信息、入住日期，并附护照复印件。所有内容均为虚构。", "keyFacts": ["Заселение 入住", "Паспорт 护照", "Дата вселения 入住日期"], "requiredActions": ["填写登记表各字段", "提交护照复印件"], "requiredDocuments": ["护照复印件"], "deadlines": ["Дата вселения: 01.09.2026（演示虚构日期）"], "fees": [], "addresses": ["演示地址：ул. Примерная, 1（虚构）"], "contacts": [], "formFields": [{"russianLabel": "Фамилия", "chineseMeaning": "姓", "expectedType": "姓名", "existingValue": "", "preparationHint": "按护照拼音填写", "exampleFormat": "IVANOV（示例格式）", "pageNumber": 1, "riskNote": ""}, {"russianLabel": "Дата вселения", "chineseMeaning": "入住日期", "expectedType": "日期", "existingValue": "01.09.2026", "preparationHint": "格式为 DD.MM.YYYY", "exampleFormat": "01.09.2026（示例格式）", "pageNumber": 1, "riskNote": ""}], "questionsToAsk": ["Подскажите, пожалуйста, куда прикрепить копию паспорта?"], "warnings": [], "uncertainties": ["演示数据：OCR 置信度均为虚构"], "citations": [{"source": "S1", "page": 1, "snippet": "Фамилия Имя Отчество"}]}
                """
            }
            // 字段值核对。
            return """
            {"answerChinese": "格式正确（演示响应）：日期按 DD.MM.YYYY 填写即可。", "suggestedRussian": "", "stressedRussian": "", "backTranslation": "", "citations": [], "uncertainties": []}
            """
        }
        if systemPrompt.hasPrefix("你是一位现场口译与办事助手") {
            // 按文件提问（结合最近对话）的 canned 回答。
            return """
            {"answerChinese": "（演示响应）这份登记表需要你在前台填写个人信息并提交护照复印件。", "suggestedRussian": "Скажите, пожалуйста, я правильно заполнил эту форму?", "stressedRussian": "Скажи́те, пожа́луйста, я пра́вильно заполнил э́ту фо́рму?", "backTranslation": "请问我这张表填对了吗？", "politeAlternative": "Не могли бы вы проверить, правильно ли заполнена форма?", "simpleAlternative": "Проверьте форму, пожалуйста.", "citations": [{"source": "S1", "page": 1, "snippet": "Фамилия Имя Отчество"}], "uncertainties": ["演示数据"]}
            """
        }
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

        // 随身翻译 demo：一条已保存的宿舍办理对话（canned 种子直接走
        // context.insert —— 不经 repository → 不进 outbox，生产代码没有
        // 任何硬编码翻译结果）。
        let demoConversation = InterpreterConversation(
            title: "宿舍办理 · 9月5日",
            sceneRaw: InterpreterScene.dorm.rawValue,
            contextNote: "我是莫斯科国立大学留学生",
            statusRaw: InterpreterConversationStatus.saved.rawValue,
            startedAt: day(0, hour: 10),
            endedAt: day(0, hour: 10, minute: 12)
        )
        context.insert(demoConversation)
        // 现场文件 demo：一份虚构的宿舍登记表（明确标记的虚构数据）。
        // 原始文件与提取 sidecar 只写入 demo 临时目录，绝不触碰真实
        // App Group 或账号存储。
        let demoDocument = InterpreterDocument(
            conversationID: demoConversation.id,
            sourceRaw: InterpreterDocumentSource.scan.rawValue,
            originalFileName: "宿舍登记表（演示）.pdf",
            formatRaw: InterpreterDocumentFormat.pdf.rawValue,
            mimeType: "application/pdf",
            fileSize: 0,
            contentHash: "",
            pageCount: 1,
            statusRaw: InterpreterDocumentStatus.ready.rawValue,
            originalRelativePath: "",
            extractionRelativePath: "",
            keepOriginalFile: false // 演示：无原始文件（提取文本足够驱动 demo）
        )
        context.insert(demoDocument)
        if let demoStore = InterpreterDocumentStoreShared.store {
            let fakeText = """
            АНКЕТА ВСЕЛЯЮЩЕГОСЯ (демо, все данные вымышлены)
            Фамилия Имя Отчество: ______
            Дата вселения: 01.09.2026
            Паспорт: копия обязательна
            Комната: № 412
            """
            let extraction = InterpreterDocumentExtraction(
                pages: [InterpreterDocumentPageText(
                    pageNumber: 1,
                    extractedText: fakeText,
                    ocrText: fakeText,
                    ocrConfidence: 0.93,
                    ocrStatusRaw: InterpreterPageOCRStatus.done.rawValue
                )],
                extractionVersion: "1"
            )
            try? demoStore.writeExtraction(extraction, documentID: demoDocument.id)
            demoDocument.extractionRelativePath = "\(demoDocument.id.uuidString)/extraction.json"
            demoDocument.updatedAt = .now
        }
        context.insert(InterpreterTurn(
            conversationID: demoConversation.id,
            speakerRaw: InterpreterSpeaker.counterpart.rawValue,
            directionRaw: InterpreterDirection.ru2zh.rawValue,
            inputMethodRaw: InterpreterInputMethod.audio.rawValue,
            sequence: 1,
            sourceText: "У вас есть копия паспорта?",
            plainRussian: "У вас есть копия паспорта?",
            stressedRussian: "У вас есть ко́пия па́спорта?",
            chineseText: "您有护照复印件吗？",
            translationStatusRaw: InterpreterTurnTranslationStatus.completed.rawValue
        ))
        context.insert(InterpreterTurn(
            conversationID: demoConversation.id,
            speakerRaw: InterpreterSpeaker.user.rawValue,
            directionRaw: InterpreterDirection.zh2ru.rawValue,
            inputMethodRaw: InterpreterInputMethod.text.rawValue,
            sequence: 2,
            sourceText: "我只有原件，可以在这里复印吗？",
            plainRussian: "У меня есть только оригинал. Можно сделать копию здесь?",
            stressedRussian: "У меня есть то́лько оригина́л. Мо́жно сде́лать ко́пию здесь?",
            chineseText: "我只有原件，可以在这里复印吗？",
            backTranslation: "我只有原件。可以在这里复印吗？",
            translationStatusRaw: InterpreterTurnTranslationStatus.completed.rawValue
        ))
        try? context.save()

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

// MARK: - Errand demo (办事事项 · fake 通知/日历 + 虚构宿舍登记案例)

/// Fake notification center — in-memory pending requests only; the demo
/// NEVER touches the real UNUserNotificationCenter (no permission prompt,
/// no real delivery).
@MainActor
final class DemoErrandNotificationCenter: ErrandNotificationScheduling {
    private var pending: [ErrandNotificationRequest] = []

    var authorizationState: UNAuthorizationStatus { .notDetermined }

    func requestAuthorization() async -> Bool {
        // The demo never grants: arming honestly reports 未创建.
        false
    }

    func add(_ request: ErrandNotificationRequest) async throws {
        pending.removeAll { $0.identifier == request.identifier }
        pending.append(request)
    }

    func removePending(withIdentifiers identifiers: [String]) {
        pending.removeAll { identifiers.contains($0.identifier) }
    }

    func pendingIdentifiers() async -> [String] {
        pending.map(\.identifier)
    }
}

/// Fake EventKit store — in-memory events; the demo NEVER touches the
/// real EKEventStore (no calendar permission, no real writes).
@MainActor
final class DemoErrandEventStore: ErrandEventStoring {
    private var events: [String: ErrandEventInfo] = [:]

    var authorizationStatus: EKAuthorizationStatus { .notDetermined }

    func requestWriteOnlyAccess() async -> Bool { false }

    func writableCalendars() -> [ErrandCalendarInfo] {
        [ErrandCalendarInfo(id: "demo-calendar", title: "演示日历")]
    }

    func event(identifier: String) -> ErrandEventInfo? { events[identifier] }

    func save(
        title: String, location: String, notes: String,
        start: Date, duration: TimeInterval,
        calendarIdentifier: String, existingIdentifier: String?
    ) -> String? {
        let identifier = existingIdentifier ?? "demo-event-\(UUID().uuidString.prefix(8))"
        events[identifier] = ErrandEventInfo(
            identifier: identifier, title: title, location: location,
            notes: notes, startDate: start,
            endDate: start.addingTimeInterval(duration)
        )
        return identifier
    }

    func remove(identifier: String) -> Bool {
        events.removeValue(forKey: identifier) != nil
    }
}

extension DemoSeed {
    /// The seeded errand demo case's ID (for the interpreter-counter demo
    /// to attach as counter context; Debug builds only).
    @MainActor static var errandDemoCaseID: UUID?

    /// The fictional 宿舍登记 case: two pending materials, one confirmed
    /// appointment, two questions to ask, one uncertain fee, one follow-up,
    /// local sources in both states (present + origin-deleted), and the
    /// AI-candidate vs user-confirmed distinction. Fully canned data in
    /// the in-memory container — nothing here is a real record.
    @MainActor
    static func populateErrandDemo(container: ModelContainer) {
        let context = ModelContext(container)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)

        // A fictional source conversation (本地来源"存在"状态) — plain
        // canned text, the same fictional dorm scenario.
        let conversation = InterpreterConversation(
            title: "宿舍管理处 · 登记咨询",
            sceneRaw: InterpreterScene.dorm.rawValue,
            contextNote: "我是莫斯科国立大学留学生",
            statusRaw: InterpreterConversationStatus.saved.rawValue,
            startedAt: calendar.date(byAdding: .day, value: -1, to: today) ?? .now
        )
        context.insert(conversation)

        let errandCase = ErrandCase(
            title: "宿舍入住登记",
            sceneRaw: InterpreterScene.dorm.rawValue,
            statusRaw: ErrandCaseStatus.preparing.rawValue,
            purpose: "办理宿舍入住登记并领取门禁卡",
            userNote: "带好全部材料的原件与复印件",
            timezoneID: "Europe/Moscow",
            location: "宿舍管理处 203 室（虚构地址）",
            contact: "管理处值班电话（虚构）",
            hasLocalSources: true
        )
        context.insert(errandCase)
        errandCase.storeLocalSources([
            ErrandLocalSource(
                kind: .conversation, conversationID: conversation.id
            ),
            ErrandLocalSource(
                kind: .document, documentID: UUID(),
                documentName: "已删除的登记表扫描件", pageNumber: 1
            )
        ])

        func item(
            _ title: String, kind: ErrandCaseItemKind, sequence: Int,
            status: ErrandCaseItemStatus = .pending,
            detail: String = "", dateText: String = "",
            isRelative: Bool = false, uncertain: Bool = false,
            origin: ErrandCaseItemOrigin = .manual,
            dueAt: Date? = nil, feeText: String = ""
        ) {
            context.insert(ErrandCaseItem(
                caseID: errandCase.id,
                title: title,
                kindRaw: kind.rawValue,
                statusRaw: status.rawValue,
                sequence: sequence,
                detail: detail,
                dueAt: dueAt,
                dateText: dateText,
                dateIsRelative: isRelative,
                dateUncertain: uncertain,
                originRaw: origin.rawValue,
                confirmed: status != .unconfirmed,
                feeText: feeText
            ))
        }

        // 用户已确认的材料（手动加入 —— 与 AI 候选视觉区分）。
        item("护照原件", kind: .requiredDocument, sequence: 0, detail: "原件 + 复印件两份")
        item("落地签复印件", kind: .requiredDocument, sequence: 1)
        // 已确认预约（周四上午 —— 相对日期换算，用户已确认时间）。
        item(
            "宿舍登记预约", kind: .appointment, sequence: 2,
            dateText: "周四上午", isRelative: true,
            dueAt: calendar.date(
                byAdding: .day, value: 2, to: today
            )?.addingTimeInterval(10 * 3600)
        )
        // 现场要问的两个问题。
        item("登记完成后多久能拿到门禁卡？", kind: .question, sequence: 3)
        item("是否需要缴纳押金（Какой залог）？", kind: .question, sequence: 4)
        // 不确定费用（原文保留，未换算 —— 持续可见，不用漂亮 UI 隐藏）。
        item(
            "登记费用", kind: .payment, sequence: 5,
            feeText: "工作人员口头提到 200₽，单据上未写金额 —— 待核对"
        )
        // 办理后跟进。
        item(
            "下周四回管理处领取门禁卡", kind: .followUp, sequence: 6,
            dateText: "下周四", isRelative: true
        )
        // AI 候选（未确认 —— 设备本地，不入同步；与用户确认内容区分）。
        item(
            "通常需要的居住证明（通常需要，请核实）", kind: .requiredDocument,
            sequence: 7, status: .unconfirmed, origin: .ai
        )

        try? context.save()
        errandDemoCaseID = errandCase.id
    }

    // MARK: - 柜台办理 demo（第十九轮：多状态草稿对话）

    /// 虚构的宿舍入住登记草稿对话 —— 驱动真实 InterpreterScreen /
    /// InterpreterViewModel（reload 恢复草稿；种子直接 context.insert，
    /// 不经 repository → 不进 outbox，生产代码没有任何硬编码翻译
    /// 结果）。全部为虚构数据：不使用真实护照、地址、电话或对话。
    ///
    /// state 选择确定性视觉状态：
    /// - conversation / listening / continuous / showmode / facing / sheet：
    ///   完整对话（continuous 注入连续听状态机 + "对方在说"指示，两条
    ///   连续虚构对方回合展示连续分句排版）；
    /// - failure：仅失败 + 等待回合（首屏即见失败重试）；
    /// - longtext：仅超长中俄文本回合。
    @MainActor
    static func populateInterpreterCounterDemo(
        container: ModelContainer, state: String?
    ) {
        let context = ModelContext(container)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)

        let draft = InterpreterConversation(
            title: "宿舍入住登记 · 演示草稿",
            sceneRaw: InterpreterScene.dorm.rawValue,
            contextNote: "演示：我是莫斯科国立大学留学生（虚构）",
            statusRaw: InterpreterConversationStatus.draft.rawValue,
            startedAt: today.addingTimeInterval(10 * 3600)
        )
        context.insert(draft)

        func details(
            intent: String? = nil,
            keywords: [String]? = nil,
            suggestedReplies: [String]? = nil,
            polite: String? = nil,
            simple: String? = nil,
            uncertainties: [String]? = nil
        ) -> String {
            var value = InterpreterTurnDetails()
            value.intentSummary = intent
            value.keywords = keywords
            value.suggestedReplies = suggestedReplies
            value.politeAlternative = polite
            value.simpleAlternative = simple
            value.uncertainties = uncertainties
            let data = try? JSONEncoder().encode(value)
            return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }

        func counterpartTurn(
            _ sequence: Int, russian: String, stressed: String,
            chinese: String, status: InterpreterTurnTranslationStatus,
            detailsJSON: String = ""
        ) {
            context.insert(InterpreterTurn(
                conversationID: draft.id,
                speakerRaw: InterpreterSpeaker.counterpart.rawValue,
                directionRaw: InterpreterDirection.ru2zh.rawValue,
                inputMethodRaw: InterpreterInputMethod.audio.rawValue,
                sequence: sequence,
                sourceText: russian,
                plainRussian: russian,
                stressedRussian: status == .completed ? stressed : "",
                chineseText: status == .completed ? chinese : "",
                detailsJSON: detailsJSON,
                translationStatusRaw: status.rawValue
            ))
        }

        func userTurn(
            _ sequence: Int, chinese: String, russian: String,
            stressed: String, backTranslation: String,
            detailsJSON: String = ""
        ) {
            context.insert(InterpreterTurn(
                conversationID: draft.id,
                speakerRaw: InterpreterSpeaker.user.rawValue,
                directionRaw: InterpreterDirection.zh2ru.rawValue,
                inputMethodRaw: InterpreterInputMethod.text.rawValue,
                sequence: sequence,
                sourceText: chinese,
                plainRussian: russian,
                stressedRussian: stressed,
                chineseText: chinese,
                backTranslation: backTranslation,
                detailsJSON: detailsJSON,
                translationStatusRaw: InterpreterTurnTranslationStatus.completed.rawValue
            ))
        }

        // 完整对话（conversation/listening/showmode/facing/sheet 共用）。
        func seedFullConversation() {
            counterpartTurn(
                1,
                russian: "Здравствуйте! Вы приехали оформлять заселение в общежитие?",
                stressed: "Здра́вствуйте! Вы прие́хали оформля́ть заселе́ние в общежи́тие?",
                chinese: "您好！您是来办理宿舍入住登记的吗？",
                status: .completed,
                detailsJSON: details(
                    intent: "确认来意",
                    keywords: ["заселение 入住", "общежитие 宿舍"],
                    suggestedReplies: ["是的，我预约了今天上午办理", "请问需要哪些材料？"]
                )
            )
            userTurn(
                2,
                chinese: "是的，我预约了今天上午办理。请问需要哪些材料？",
                russian: "Да, я записан на сегодня на утро. Скажите, пожалуйста, какие документы нужны?",
                stressed: "Да, я запи́сан на сего́дня на у́тро. Скажи́те, пожа́луйста, каки́е докуме́нты ну́жны?",
                backTranslation: "是的，我预约了今天上午。请问需要哪些文件？",
                detailsJSON: details(
                    polite: "Не могли бы вы подсказать, какие документы необходимы для оформления?",
                    simple: "Какие документы нужны?"
                )
            )
            counterpartTurn(
                3,
                russian: "Нужны паспорт, миграционная карта и справка из университета. Копию паспорта можно сделать здесь.",
                stressed: "Ну́жны па́спорт, миграцио́нная ка́рта и спра́вка из университе́та. Ко́пию па́спорта мо́жно сде́лать здесь.",
                chinese: "需要护照、移民卡和学校证明。护照复印件可以在这里复印。",
                status: .completed,
                detailsJSON: details(
                    intent: "说明所需材料",
                    keywords: ["паспорт 护照", "миграционная карта 移民卡", "копия 复印件"]
                )
            )
            // 等待翻译（pending：俄语已落位，翻译未到）。
            counterpartTurn(
                4,
                russian: "Заполните, пожалуйста, анкету и подпишите договор.",
                stressed: "",
                chinese: "",
                status: .pending
            )
            // 翻译失败（失败重试直接可见）。
            counterpartTurn(
                5,
                russian: "Оформление займёт примерно десять минут, подождите здесь.",
                stressed: "",
                chinese: "",
                status: .failed
            )
            userTurn(
                6,
                chinese: "好的，我明白了。请问登记完成后多久能拿到门禁卡？",
                russian: "Хорошо, я понял. Подскажите, пожалуйста, как быстро выдадут ключ-карту после регистрации?",
                stressed: "Хорошо́, я по́нял. Подскажи́те, пожа́луйста, как бы́стро вы́дадут ключ-ка́рту по́сле регистра́ции?",
                backTranslation: "好的，我明白了。请问登记后多久能发门禁卡？"
            )
            // 超长文本（验证长文排版与滚动）。
            counterpartTurn(
                7,
                russian: "Обратите внимание: в договоре указано, что вы обязаны соблюдать правила проживания в общежитии, своевременно оплачивать проживание до пятого числа каждого месяца, не передавать ключ-карту третьим лицам и сообщать администрации о любых изменениях в личных данных в течение трёх рабочих дней.",
                stressed: "Обрати́те внима́ние: в догово́ре ука́зано, что вы обяза́ны соблюда́ть пра́вила прожива́ния в общежи́тии…",
                chinese: "请注意：合同中写明，您必须遵守宿舍的居住规定，在每月 5 日前及时缴纳住宿费，不得将门禁卡转交他人，并在个人资料发生任何变更后的三个工作日内告知管理处。",
                status: .completed,
                detailsJSON: details(
                    intent: "说明合同义务",
                    keywords: ["договор 合同", "оплата 缴费", "ключ-карта 门禁卡"],
                    uncertainties: ["数字与期限建议核对原文"]
                )
            )
        }

        func seedFailureOnly() {
            counterpartTurn(
                1,
                russian: "Заполните, пожалуйста, анкету и подпишите договор.",
                stressed: "",
                chinese: "",
                status: .pending
            )
            counterpartTurn(
                2,
                russian: "Оформление займёт примерно десять минут, подождите здесь.",
                stressed: "",
                chinese: "",
                status: .failed
            )
            counterpartTurn(
                3,
                russian: "Справку из университета нужно принести до пятницы.",
                stressed: "",
                chinese: "",
                status: .failed
            )
        }

        func seedLongTextOnly() {
            counterpartTurn(
                1,
                russian: "Обратите внимание: в договоре указано, что вы обязаны соблюдать правила проживания в общежитии, своевременно оплачивать проживание до пятого числа каждого месяца, не передавать ключ-карту третьим лицам и сообщать администрации о любых изменениях в личных данных в течение трёх рабочих дней.",
                stressed: "Обрати́те внима́ние: в догово́ре ука́зано, что вы обяза́ны соблюда́ть пра́вила прожива́ния в общежи́тии…",
                chinese: "请注意：合同中写明，您必须遵守宿舍的居住规定，在每月 5 日前及时缴纳住宿费，不得将门禁卡转交他人，并在个人资料发生任何变更后的三个工作日内告知管理处。",
                status: .completed
            )
            userTurn(
                2,
                chinese: "请问缴费可以用现金吗，还是必须用银行卡？另外我想确认一下，如果我在假期回国，房间可以保留吗？需要提前多久向管理处提交申请？",
                russian: "Подскажите, пожалуйста, можно ли оплатить наличными, или обязательно картой? И ещё я хотел бы уточнить: если я уеду домой на каникулы, сохранится ли за мной комната? За сколько дней нужно подать заявление в администрацию?",
                stressed: "Подскажи́те, пожа́луйста, мо́жно ли оплати́ть нали́чными, и́ли обяза́тельно ка́ртой?",
                backTranslation: "请问可以用现金支付还是必须刷卡？另外想确认：假期回国房间保留吗？需要提前多少天向管理处提交申请？"
            )
        }

        switch state {
        case "failure": seedFailureOnly()
        case "longtext": seedLongTextOnly()
        // form-filling：只种表单填写 demo（不与柜台对话种子共存 ——
        // interpreterDraft 一次只认一个草稿会话）。
        case "form-filling": break
        default: seedFullConversation()
        }

        // 表单逐项填写 demo（第二十一轮 `--demo-interpreter-state
        // form-filling`）：同一份虚拟宿舍登记表 + form-draft sidecar
        // （姓名已填、出生日期待确认、地址未填、来访目的待翻译、签名
        // 位置不适用 —— 全部虚构数据，写入 demo 临时目录）。真实页面
        // + 真实草稿模型 —— 仅种子数据是虚构的。
        if state == "form-filling" {
            seedFormFillingDemo(context: context)
        }
        try? context.save()
    }

    /// 表单填写 demo 种子：虚拟宿舍登记表文档 + 五个指定状态的字段
    /// 草稿（写入 demoInterpreterDocStore 临时目录，绝不触碰真实账号
    /// 存储）。
    private static func seedFormFillingDemo(context: ModelContext) {
        let draft = InterpreterConversation(
            title: "宿舍登记表填写 · 演示草稿",
            sceneRaw: InterpreterScene.dorm.rawValue,
            contextNote: "演示：我是莫斯科国立大学留学生（虚构）",
            statusRaw: InterpreterConversationStatus.draft.rawValue,
            startedAt: Date()
        )
        context.insert(draft)
        let demoDocument = InterpreterDocument(
            conversationID: draft.id,
            sourceRaw: InterpreterDocumentSource.scan.rawValue,
            originalFileName: "Анкета вселяющегося（演示）.pdf",
            formatRaw: InterpreterDocumentFormat.pdf.rawValue,
            mimeType: "application/pdf",
            fileSize: 0,
            contentHash: "",
            pageCount: 1,
            statusRaw: InterpreterDocumentStatus.ready.rawValue,
            originalRelativePath: "",
            extractionRelativePath: "",
            keepOriginalFile: false
        )
        context.insert(demoDocument)
        let fakeText = """
        АНКЕТА ВСЕЛЯЮЩЕГОСЯ (демо, все данные вымышлены)
        Фамилия Имя Отчество (латиницей): ______
        Дата рождения: ______
        Адрес проживания в России: ______
        Цель приезда: ______
        Подпись: ______
        """
        guard let store = InterpreterDocumentStoreShared.store else { return }
        try? store.writeExtraction(
            InterpreterDocumentExtraction(
                pages: [InterpreterDocumentPageText(
                    pageNumber: 1,
                    extractedText: fakeText,
                    ocrText: fakeText,
                    ocrConfidence: 0.94,
                    ocrStatusRaw: InterpreterPageOCRStatus.done.rawValue
                )],
                extractionVersion: "1"
            ),
            documentID: demoDocument.id
        )
        demoDocument.extractionRelativePath = "\(demoDocument.id.uuidString)/extraction.json"

        // 虚构字段草稿（五状态齐备 —— 姓名已填/出生日期待确认/地址
        // 未填/来访目的中文待翻译/签名位置不适用输入）。
        var formDraft = InterpreterFormDraft(documentID: demoDocument.id)
        formDraft.fields = [
            InterpreterFormDraftField(
                russianLabel: "Фамилия Имя Отчество (латиницей)",
                chineseMeaning: "姓名（姓、名、父称，用拉丁字母）",
                pageNumber: 1,
                sourceSnippet: "Фамилия Имя Отчество (латиницей): ______",
                type: .singleLine,
                requirement: .required,
                formatHint: "如护照拼写一致：Ivanov Ivan Ivanovich（格式示例）",
                userValue: "Wang Xiaoming（演示虚构值）",
                status: .filled
            ),
            InterpreterFormDraftField(
                russianLabel: "Дата рождения",
                chineseMeaning: "出生日期",
                pageNumber: 1,
                sourceSnippet: "Дата рождения: ______",
                type: .date,
                requirement: .required,
                formatHint: "DD.MM.YYYY（格式示例）",
                userValue: "2004.03.15（演示虚构值）",
                status: .needsConfirmation
            ),
            InterpreterFormDraftField(
                russianLabel: "Адрес проживания в России",
                chineseMeaning: "在俄居住地址",
                pageNumber: 1,
                sourceSnippet: "Адрес проживания в России: ______",
                type: .singleLine,
                requirement: .required,
                status: .empty
            ),
            InterpreterFormDraftField(
                russianLabel: "Цель приезда",
                chineseMeaning: "来访目的（自由文本，可翻译为俄语）",
                pageNumber: 1,
                sourceSnippet: "Цель приезда: ______",
                type: .multiline,
                requirement: .required,
                userValue: "我是莫斯科国立大学的留学生，来办理宿舍入住登记。（演示虚构文本）",
                status: .empty
            ),
            InterpreterFormDraftField(
                russianLabel: "Подпись",
                chineseMeaning: "签名位置（需要手写签名或填写姓名/日期）",
                pageNumber: 1,
                sourceSnippet: "Подпись: ______",
                type: .signature,
                requirement: .required,
                status: .notApplicable
            )
        ]
        try? store.writeFormDraft(formDraft, documentID: demoDocument.id)
    }
}
#endif
