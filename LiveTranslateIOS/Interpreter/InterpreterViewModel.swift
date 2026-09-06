import Foundation
import AVFoundation
import OSLog
import Observation

/// 随身翻译（Interpreter）视图模型 —— 面对面办事口译的编排层。
///
/// 复用与互斥（第十三轮既有约束的延伸）：
/// - 音频采集复用 `AudioCaptureService`（每次收音新建实例，会话内自管
///   AVAudioSession）+ Silero VAD + `SpeechSegmenter` 分句 + 共享的
///   `ASREngineManager`（每 AppEnvironment 一个 —— 绝不创建第二个
///   GigaAM/sherpa 实例；interpreter 收音前 `ensureLoaded` +
///   `beginSession` pin 后端，结束时 `endSession` 释放）。
/// - 课堂运行中（coordinator.isRunning）不能开启收音；随身翻译收音时
///   开始课堂由 `LiveScreen`/`NewSessionSheet` 一侧的互斥提醒兜底
///   （startInterpreterListening 拒绝 + 界面提示）。
/// - 朗读（InterpreterSpeechService）与收音互斥：开始收音先停 TTS；
///   课堂开始时 AppEnvironment.presentLive() 的 playback.stop() 之外，
///   interpreter TTS 由本类在课堂开始通知时停止（见 AppFlow 观察）。
///
/// 草稿生命周期：第一次翻译动作建立当前账号本地草稿；每个已完成回合
/// 及时落本地；草稿不进 outbox、不上传。保存 → 正式历史 + 云同步；
/// 丢弃 → 删除草稿及回合。不保存音频（SpeechSegment 的 samples 只在
/// 内存中过 ASR，绝不落盘）。
@MainActor
@Observable
final class InterpreterViewModel {
    static let logger = Logger(subsystem: "com.livetranslate.ios", category: "interpreter")

    // MARK: - Dependencies

    private let environment: AppEnvironment
    private let repository: any ClassroomRepositoryProtocol
    private let speech: InterpreterSpeechService
    /// 模型服务（demo 环境注入 canned 实现）。
    private let translationServiceProvider: @MainActor () -> (any StudyReviewModelService)?

    // MARK: - Conversation state

    private(set) var conversation: InterpreterConversation?
    private(set) var turns: [InterpreterTurn] = []
    /// 当前场景 + 用户背景（界面可见、可编辑、可清除）。
    var scene: InterpreterScene = .general
    var contextNote: String = ""
    /// 用户回复的语气。
    var tone: InterpreterTone = .polite

    // MARK: - Listening state (听对方说)

    enum ListeningPhase: Equatable {
        case idle
        case requestingPermission
        case listening
        case transcribing
        case failed(String)
    }

    private(set) var listeningPhase: ListeningPhase = .idle
    /// 连续收听模式（第二十轮）：capture session 保活，VAD 持续分句，
    /// 每句独立落 turn。单句模式（听对方说）保持既有语义。
    private(set) var isContinuousListening = false
    /// 连续模式暂停原因（UI 展示"已暂停 + 继续听"；nil = 未暂停）。
    private(set) var continuousPauseReason: ContinuousPauseReason?
    /// 对方正在说话（segmenter 正在积累语音 —— 句子尚未闭合）。
    private(set) var counterpartIsSpeaking = false
    /// 真实电平（仅真实音量数据驱动显示；无数据时不显示波形）。
    private(set) var audioLevel: Float = 0
    private(set) var micPermissionDenied = false
    private(set) var asrModelInstalled = true

    /// 连续模式暂停原因（运行时状态 —— 绝不入库、不进 outbox）。
    enum ContinuousPauseReason: Equatable {
        /// 用户点击暂停 / 进入回复。
        case user
        /// 开始朗读或进入给对方看。
        case speaking
        /// 音频被系统中断（不自动恢复）。
        case audioInterrupted
        /// 收音管线故障（如实展示，用户可重试）。
        case captureFailed

        var displayName: String {
            switch self {
            case .user: return "已暂停"
            case .speaking: return "朗读时暂停"
            case .audioInterrupted: return "音频被中断"
            case .captureFailed: return "收音中断"
            }
        }
    }

    private var capture: AudioCaptureService?
    private var processingTask: Task<Void, Never>?
    private var vad: SherpaSileroVAD?
    private var segmenter: SpeechSegmenter?
    /// 上一句识别文本（相邻段重叠去重，课堂惯例）。
    private var lastRecognizedRussian = ""

    // MARK: - Reply state (我要回复)

    /// 输入框草稿（中文）。
    var replyDraft: String = ""
    /// 提交中（防重复提交）。
    private(set) var isTranslatingReply = false
    /// 正在翻译的对方回合 id（逐条重试标记）。
    private(set) var translatingTurnIDs: Set<UUID> = []
    /// 最近一次模型错误（真实错误类别）。
    var lastTranslationError: String?

    // MARK: - Document context (现场文件)

    /// 文件上下文模型（导入/提取/选择/预览/ AI 动作的编排层）。
    private(set) var documentContext: InterpreterDocumentContextModel?

    /// 本会话仍存在的本地来源文件 ID（来源可用性渲染 —— 文件被删除
    /// 后，回合里的本地来源如实变为不可用）。
    var availableDocumentIDs: Set<UUID> {
        Set((documentContext?.documents ?? []).map(\.id))
    }

    /// The configured AI endpoint base for disclosure UI (round 17 —
    /// the send preview shows which host content goes to; the API key
    /// itself never leaves the service layer).
    var apiBaseForDisclosure: String {
        environment.settings.apiBase
    }

    // MARK: - Presentation state (UI-only, never synced)

    /// 展开的回合卡片（展开状态属于 UI 状态，不上传）。
    var expandedTurnIDs: Set<UUID> = []
    /// 给对方看模式正在展示的回合（锁定 —— 新回合不得替换展示内容）。
    var presentedTurnID: UUID?
    /// 滚动跟随状态机（底部跟随 / 回看暂停 + 未读计数 / 回到最新）。
    var follow = InterpreterFollowState()
    /// 编程式滚动进行中（时间线在自动跟随滚动时抑制"远离底部"信号，
    /// 防止内容增长被误判为用户回看）。
    var isProgrammaticScrollActive = false
    /// 关联的办事事项（从 ErrandCase 进入时建立；nil = 普通进入）。
    private(set) var errandCaseID: UUID?
    /// 办事上下文条数据（轻量派生模型；仅在有 case 时存在）。
    private(set) var counterContext: InterpreterCounterContext?

    // MARK: - Init

    init(
        environment: AppEnvironment,
        speech: InterpreterSpeechService? = nil,
        translationServiceProvider: @escaping @MainActor () -> (any StudyReviewModelService)? = { nil }
    ) {
        self.environment = environment
        self.repository = environment.repository
        // 共享 TTS（AppEnvironment 持有 —— 课堂开始/账号切换可从一处停止）。
        self.speech = speech ?? environment.interpreterSpeech
        self.translationServiceProvider = translationServiceProvider
    }

    // MARK: - Lifecycle

    /// 进入页面：加载设置默认值、恢复草稿提示、检查资源。
    func reload() async {
        scene = environment.settings.interpreterDefaultScene
        // 事项场景优先于全局默认（从 ErrandCase 进入的现场沟通）；
        // 草稿连续性仍最优先（既有语义：未结束的对话原样恢复）。
        if let errandCaseID,
           let errandCase = repository.errandCase(id: errandCaseID) {
            scene = errandCase.scene
        }
        asrModelInstalled = await environment.engineManager.isInstalled(
            environment.settings.preferredBackend
        )
        micPermissionDenied = AVAudioApplication.shared.recordPermission == .denied
        // 恢复上次未结束的草稿（App 被杀后重新进入）。
        if let draft = repository.interpreterDraft {
            conversation = draft
            scene = draft.scene
            contextNote = draft.contextNote
            let resumed = (try? repository.interpreterTurns(conversationID: draft.id)) ?? []
            Self.logger.info("resumed interpreter draft (\(resumed.count) turns)")
            turns = resumed
        }
        // 文件上下文模型随会话建立（同一环境与模型服务注入）。
        if documentContext == nil {
            documentContext = InterpreterDocumentContextModel(
                environment: environment,
                aiServiceProvider: translationServiceProvider,
                imageServiceProvider: { [weak self] in
                    self?.environment.attachmentServiceBoxForInterpreter?.get()
                }
            )
        }
        documentContext?.reload(conversationID: conversation?.id)
        refreshCounterContext()
    }

    /// 关联办事事项（从 ErrandCase 的"开始现场沟通"进入时调用；普通
    /// 进入传 nil）。只建立只读上下文与场景 —— 绝不自动开麦、自动
    /// 发送或把对话写回事项。
    func attachErrandContext(caseID: UUID?) {
        errandCaseID = caseID
        refreshCounterContext()
    }

    /// 重算办事上下文条数据（进入、事项清单变化、文件上下文变化后）。
    func refreshCounterContext() {
        guard let errandCaseID,
              let errandCase = repository.errandCase(id: errandCaseID) else {
            counterContext = nil
            return
        }
        let items = (try? repository.errandCaseItems(caseID: errandCaseID)) ?? []
        counterContext = InterpreterCounterContext.make(
            errandCase: errandCase,
            items: items,
            hasLocalDocuments: documentContext?.hasContext ?? false,
            surfacePrivacy: environment.settings.systemSurfacePrivacy
        )
    }

    /// 移除文件上下文 chip：只清除页面选择（之后按文件提问/分析的 AI
    /// 请求不再自动携带文件内容）；原文件与提取文本保留在本机，需要
    /// 时在文件面板重新选用。绝不删除文件本身。
    func clearDocumentContextSelection() {
        guard let documentContext else { return }
        for document in documentContext.documents {
            documentContext.selectedPages[document.id] = []
        }
    }

    /// 翻译服务是否已配置（状态栏如实显示；未配置时翻译不可用，
    /// 本地 ASR 与文本输入不受影响）。
    var isModelConfigured: Bool {
        guard let service = resolveModelService() else { return false }
        return service.isConfiguredNow
    }

    /// 是否存在可恢复的草稿（进入页面时的"继续上次翻译"提示）。
    var hasResumableDraft: Bool {
        guard repository.interpreterDraft != nil else { return false }
        let count = (try? repository.interpreterDraftTurnCount()) ?? nil ?? 0
        return count > 0
    }

    // MARK: - 会话建立

    /// 开始一次新的随身翻译（建立草稿）。
    func startConversation() {
        guard conversation == nil || conversation?.status != .draft else { return }
        do {
            let draft = try repository.startInterpreterDraft(
                scene: scene, contextNote: contextNote
            )
            conversation = draft
            turns = []
            lastRecognizedRussian = ""
        } catch {
            Self.logger.error("start draft failed: \(error)")
        }
    }

    private func ensureConversation() {
        if conversation?.status != .draft {
            startConversation()
        }
    }

    // MARK: - 听对方说

    /// 开始收音。课堂运行中拒绝；无模型拒绝；权限拒绝给设置入口。
    func startListening() async {
        guard listeningPhase != .listening, listeningPhase != .transcribing else { return }
        // 课堂正在运行时不能开启随身翻译麦克风。
        guard !environment.coordinator.isRunning else {
            listeningPhase = .failed("课堂正在进行，请先结束课堂再使用随身翻译")
            return
        }
        guard asrModelInstalled else {
            listeningPhase = .failed("语音识别资源未安装，请先在模型管理中下载")
            return
        }
        // 朗读让路：开始麦克风前停止 TTS。
        speech.stop()

        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            break
        case .undetermined:
            listeningPhase = .requestingPermission
            guard await AudioCaptureService.recordPermission() else {
                micPermissionDenied = true
                listeningPhase = .idle
                return
            }
        case .denied:
            micPermissionDenied = true
            listeningPhase = .idle
            return
        @unknown default:
            micPermissionDenied = true
            listeningPhase = .idle
            return
        }

        ensureConversation()

        // 复用共享引擎管理器（绝不创建第二个 ASR 实例）。
        do {
            try await environment.engineManager.ensureLoaded(
                environment.settings.preferredBackend
            )
            try environment.engineManager.beginSession()
        } catch {
            listeningPhase = .failed("语音识别引擎启动失败：\(error.localizedDescription)")
            return
        }

        let service = AudioCaptureService()
        do {
            let chunks = try await service.start()
            capture = service
            startListeningLoop(chunks: chunks)
            listeningPhase = .listening
            Self.logger.info("interpreter listening started")
        } catch {
            environment.engineManager.endSession()
            listeningPhase = .failed("麦克风启动失败：\(error.localizedDescription)")
        }
    }

    /// 快捷接话：暂停连续听并请求聚焦中文输入框（UI-only token ——
    /// composer 观察 ID 变化执行聚焦；不入库、不进 outbox）。
    private(set) var replyFocusRequestID: UUID?

    /// 开始回复（快速接话入口）：连续听暂停；输入框聚焦由 composer
    /// 响应 replyFocusRequestID。
    func beginReply() {
        if isContinuousListening, continuousPauseReason == nil {
            pauseContinuousListening(reason: .user)
        }
        replyFocusRequestID = UUID()
    }

    // MARK: - 连续收听（第二十轮）

    /// 开始连续收听。与单句模式共用同一条链路（同一 AudioCaptureService
    /// / VAD / SpeechSegmenter / ASREngineManager / turn 落库 / 翻译回填）。
    func startContinuousListening() async {
        // 已在连续模式（含暂停中）：恢复即可。
        if isContinuousListening {
            resumeContinuousListening(reason: .user)
            return
        }
        isContinuousListening = true
        continuousPauseReason = nil
        await startListening()
        // 启动失败（含权限拒绝回到 idle）时不留在连续模式。
        if listeningPhase != .listening {
            isContinuousListening = false
        }
    }

    /// 暂停连续收听。session、segmenter 与 ASR 引擎全部保活；已形成的
    /// segment 照常完成，尚未形成有效语音的缓冲被丢弃 —— 不创建伪 turn。
    func pauseContinuousListening(reason: ContinuousPauseReason) {
        guard isContinuousListening, continuousPauseReason == nil else { return }
        // 捕获真实中断/故障状态（如实展示，不假装修好）。
        var effectiveReason = reason
        if let capture {
            switch capture.state {
            case .interrupted, .recovering: effectiveReason = .audioInterrupted
            case .failed: effectiveReason = .captureFailed
            default: break
            }
        }
        pauseGate.isPaused = true
        // 丢弃尚未形成有效语音的缓冲（诚实收尾：语音积累不足一段的
        // 尾巴直接结束，不落伪 turn）。
        _ = segmenter?.flush()
        continuousPauseReason = effectiveReason
        counterpartIsSpeaking = false
        audioLevel = 0
        listeningPhase = .idle
        Self.logger.info("interpreter continuous listening paused (\(String(describing: effectiveReason), privacy: .public))")
    }

    /// 用户明确点击"继续听"恢复（音频中断后绝不自动恢复）。
    func resumeContinuousListening(reason: ContinuousPauseReason = .user) {
        guard isContinuousListening, continuousPauseReason != nil else { return }
        guard let capture else {
            // session 已不存在（停止/失败后）：回到普通入口。
            isContinuousListening = false
            continuousPauseReason = nil
            return
        }
        switch capture.state {
        case .running:
            // 收音前停止 TTS（朗读让路 —— 与开始收音同一规则）。
            speech.stop()
            pauseGate.isPaused = false
            continuousPauseReason = nil
            listeningPhase = .listening
            Self.logger.info("interpreter continuous listening resumed")
        case .interrupted, .recovering:
            // 中断未恢复：保持暂停（显示"音频被中断"，用户可稍后再试）。
            continuousPauseReason = .audioInterrupted
        case .failed:
            // 管线已死：结束连续模式，用户从"听一句/连续听"重新开始。
            continuousPauseReason = .captureFailed
        case .idle:
            // session 已被停止（suspend/结束）：回到普通入口。
            isContinuousListening = false
            continuousPauseReason = nil
        }
    }

    /// 暂停门（原子标志 —— detached 音频循环读，主线程写）。
    private let pauseGate = InterpreterPauseGate()

    /// 收音主循环：VAD → 分句 → ASR（串行）。每个完成回合立即落本地
    /// 并触发翻译。
    private func startListeningLoop(chunks: AsyncStream<AudioChunk>) {
        do {
            vad = try SherpaSileroVAD()
        } catch {
            await teardownListening()
            listeningPhase = .failed("语音活动检测初始化失败")
            return
        }
        let settings = environment.settings
        var parameters = SpeechSegmenter.Parameters()
        parameters.minSpeechSeconds = TimeInterval(settings.vadMinSpeechMs) / 1000
        parameters.silenceEndSeconds = TimeInterval(settings.vadSilenceEndMs) / 1000
        segmenter = SpeechSegmenter(parameters: parameters)

        let vad = self.vad!
        let segmenter = self.segmenter!
        let pauseFlag = pauseGate
        processingTask = Task.detached(priority: .userInitiated) { [weak self] in
            for await chunk in chunks {
                guard let self else { break }
                // 暂停窗口：丢弃音频（麦克风仍在运行，VAD 状态重置 ——
                // 恢复后从干净的语音起点重新分句）。
                if pauseFlag.isPaused {
                    vad.reset()
                    continue
                }
                // 真实电平（仅真实数据驱动 UI 波形）。
                let rms = chunk.rms
                let wasSpeaking = segmenter.isAccumulatingSpeech
                let isSpeech = vad.process(window: chunk.samples[...])
                let segments = segmenter.push(window: chunk.samples[...], isSpeech: isSpeech)
                let nowSpeaking = segmenter.isAccumulatingSpeech
                await MainActor.run {
                    self.audioLevel = rms
                    if nowSpeaking != wasSpeaking {
                        self.counterpartIsSpeaking = nowSpeaking
                    }
                }
                for segment in segments {
                    await self.handleSpeechSegment(segment)
                }
            }
        }
    }

    /// 手动结束当前一句（VAD 尚未判定静音结束时）。
    func finishCurrentUtterance() {
        guard let segmenter else { return }
        let segments = segmenter.flush()
        guard !segments.isEmpty else { return }
        Task { @MainActor in
            for segment in segments {
                await self.handleSpeechSegment(segment)
            }
        }
    }

    /// 界面入口（结束这句按钮）。
    func finishCurrentUtteranceManually() {
        finishCurrentUtterance()
    }

    /// TTS 是否正在朗读（界面状态显示）。
    var speechIsSpeaking: Bool {
        speech.isSpeaking
    }

    /// 课堂是否正在运行（收音入口禁用 + 现有提示）。
    var classroomActive: Bool {
        environment.coordinator.isRunning
    }

    /// 收音管线是否被系统中断/正在恢复（如实透出 —— AudioCaptureService
    /// 的 observable state，View 直接读取即可随真实状态刷新）。
    var captureInterrupted: Bool {
        guard let capture else { return false }
        return capture.state == .interrupted || capture.state == .recovering
    }

    /// 一个语音段完成：本地 ASR → 落本地俄语回合 → 翻译。
    private func handleSpeechSegment(_ segment: SpeechSegment) async {
        guard listeningPhase == .listening || listeningPhase == .transcribing else { return }
        listeningPhase = .transcribing
        do {
            let result = try await environment.engineManager.transcribe(segment)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                listeningPhase = .listening
                return
            }
            // 相邻段重叠去重（课堂惯例）。
            var finalText = text
            if !lastRecognizedRussian.isEmpty {
                finalText = SpeechSegmenter.deduplicateOverlap(
                    previous: lastRecognizedRussian, next: text
                )
            }
            lastRecognizedRussian = finalText
            appendCounterpartTurn(russian: finalText)
        } catch {
            Self.logger.error("asr failed: \(error)")
            // ASR 失败：回到收音，不创建回合。
        }
        // 收音相位收尾：单句模式（听一句）一句完成即停 —— capture 一并
        // 拆除（正在积累的下一句缓冲直接丢弃，不创建伪 turn）；连续模式
        // 继续监听下一句（暂停中保持 idle —— 暂停窗口的门已挡住新音频）。
        if isContinuousListening {
            if continuousPauseReason == nil {
                listeningPhase = (capture?.state.isDeliveringAudio ?? false) ? .listening : .idle
            } else {
                listeningPhase = .idle
            }
        } else {
            await teardownListening()
        }
    }

    /// 对方回合落本地 + 触发翻译（失败保留原文）。
    private func appendCounterpartTurn(russian: String) {
        guard let conversation else { return }
        do {
            let turn = try repository.addInterpreterCounterpartTurn(
                conversationID: conversation.id, russian: russian, inputMethod: .audio
            )
            turns.append(turn)
            translateCounterpartTurn(turn)
        } catch {
            Self.logger.error("append counterpart turn failed: \(error)")
        }
    }

    /// 停止收音（保留草稿与回合）。连续模式状态一并清除。
    func stopListening() async {
        processingTask?.cancel()
        processingTask = nil
        #if DEBUG
        debugDemoLevelTask?.cancel()
        #endif
        // 发出分句器中的尾段（诚实收尾）。
        if let segmenter {
            let segments = segmenter.flush()
            for segment in segments {
                await handleSpeechSegment(segment)
            }
        }
        await teardownListening()
        Self.logger.info("interpreter listening stopped")
    }

    /// 拆除收音链（capture 停止、VAD/segmenter 释放、ASR session 释放、
    /// 连续模式状态清零）。暂停不经过这里 —— 只有真正停止才拆。
    private func teardownListening() async {
        pauseGate.isPaused = false
        await capture?.stop()
        capture = nil
        vad = nil
        segmenter = nil
        environment.engineManager.endSession()
        isContinuousListening = false
        continuousPauseReason = nil
        counterpartIsSpeaking = false
        audioLevel = 0
        listeningPhase = .idle
    }

    // MARK: - 翻译：对方俄语 → 中文

    /// 翻译一个对方回合（也用于逐条重试）。
    func translateCounterpartTurn(_ turn: InterpreterTurn) {
        guard !translatingTurnIDs.contains(turn.id) else { return }
        guard let modelService = resolveModelService() else {
            lastTranslationError = "翻译模型未配置，请在设置中填写 API 地址与模型"
            return
        }
        translatingTurnIDs.insert(turn.id)
        lastTranslationError = nil
        let service = InterpreterTranslationService(model: modelService)
        let scene = self.scene
        let contextNote = self.contextNote
        let projections = contextProjections()
        Task {
            defer { translatingTurnIDs.remove(turn.id) }
            do {
                let result = try await service.translateCounterpart(
                    russian: turn.sourceText,
                    scene: scene,
                    contextNote: contextNote,
                    recentTurns: projections
                )
                try? repository.completeInterpreterTurnTranslation(
                    turn,
                    chinese: result.mainText,
                    russian: nil,
                    stressedRussian: result.stressedRussian,
                    backTranslation: nil,
                    details: result.details,
                    localSources: nil
                )
                reloadTurns()
            } catch is CancellationError {
                // 取消的请求不标成失败。
            } catch {
                lastTranslationError = Self.describeTranslationError(error)
                try? repository.failInterpreterTurnTranslation(turn)
                reloadTurns()
            }
        }
    }

    // MARK: - 翻译：用户中文 → 俄语

    /// 提交中文回复（提交按钮防重复；输入保留）。
    func submitReply() async {
        let chinese = replyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chinese.isEmpty, !isTranslatingReply else { return }
        guard let modelService = resolveModelService() else {
            lastTranslationError = "翻译模型未配置，请在设置中填写 API 地址与模型"
            return
        }
        ensureConversation()
        guard let conversation else { return }

        isTranslatingReply = true
        lastTranslationError = nil
        defer { isTranslatingReply = false }

        // 中文先落本地（pending），再翻译。
        let turn: InterpreterTurn
        do {
            turn = try repository.addInterpreterUserTurn(
                conversationID: conversation.id, chinese: chinese, inputMethod: .text
            )
            turns.append(turn)
        } catch {
            Self.logger.error("append user turn failed: \(error)")
            return
        }

        let service = InterpreterTranslationService(model: modelService)
        let scene = self.scene
        let contextNote = self.contextNote
        let tone = self.tone
        let projections = contextProjections()
        do {
            let result = try await service.translateUser(
                chinese: chinese,
                scene: scene,
                contextNote: contextNote,
                tone: tone,
                recentTurns: projections
            )
            try? repository.completeInterpreterTurnTranslation(
                turn,
                chinese: nil,
                russian: result.mainText,
                stressedRussian: result.stressedRussian,
                backTranslation: result.backTranslation,
                details: result.details,
                localSources: nil
            )
            reloadTurns()
            // 保留用户输入原文在回合里；清空输入框。
            replyDraft = ""
        } catch is CancellationError {
            // 取消的请求不标成失败。
        } catch {
            lastTranslationError = Self.describeTranslationError(error)
            try? repository.failInterpreterTurnTranslation(turn)
            reloadTurns()
        }
    }

    /// 重新生成（用户编辑原文后重译 / 对结果不满意重试）。
    func retryUserTurn(_ turn: InterpreterTurn) async {
        // 复用 submit 的翻译路径：以现有中文为输入。
        let chinese = turn.sourceText
        guard !chinese.isEmpty, !isTranslatingReply else { return }
        guard let modelService = resolveModelService() else {
            lastTranslationError = "翻译模型未配置，请在设置中填写 API 地址与模型"
            return
        }
        isTranslatingReply = true
        defer { isTranslatingReply = false }
        let service = InterpreterTranslationService(model: modelService)
        let projections = contextProjections()
        do {
            let result = try await service.translateUser(
                chinese: chinese,
                scene: scene,
                contextNote: contextNote,
                tone: tone,
                recentTurns: projections
            )
            try? repository.completeInterpreterTurnTranslation(
                turn,
                chinese: nil,
                russian: result.mainText,
                stressedRussian: result.stressedRussian,
                backTranslation: result.backTranslation,
                details: result.details,
                localSources: nil
            )
            reloadTurns()
        } catch is CancellationError {
        } catch {
            lastTranslationError = Self.describeTranslationError(error)
            try? repository.failInterpreterTurnTranslation(turn)
            reloadTurns()
        }
    }

    // MARK: - 文件上下文问答（文档触发的 AI 动作）

    /// 用户确认预览后提交基于文件的问题：中文问题先落本地（持久化），
    /// 再带（已遮盖的）文件 chunk 与最近对话请求模型；结果写回同一
    /// turn。会话切换/删除后迟到的回调被 scope 校验拒绝 —— 绝不写入
    /// 当前正在查看的另一会话。
    func submitDocumentQuestion(question: String) async {
        guard let documentContext,
              !documentContext.currentPreviewSources.isEmpty else { return }
        let sources = documentContext.currentPreviewSources
        let chinese = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chinese.isEmpty, !isTranslatingReply else { return }
        guard let modelService = resolveModelService() else {
            lastTranslationError = "翻译模型未配置，请在设置中填写 API 地址与模型"
            return
        }
        ensureConversation()
        guard let conversation else { return }
        let conversationID = conversation.id

        isTranslatingReply = true
        documentContext.setAsking(true)
        lastTranslationError = nil
        documentContext.clearAIError()
        defer {
            isTranslatingReply = false
            documentContext.setAsking(false)
        }

        // 中文问题先落本地（pending）。
        let turn: InterpreterTurn
        do {
            turn = try repository.addInterpreterUserTurn(
                conversationID: conversationID, chinese: chinese, inputMethod: .text
            )
            turns.append(turn)
        } catch {
            Self.logger.error("append user turn failed: \(error)")
            return
        }

        // 提交即清除预览（确认的载荷只在这一次请求中使用）。
        documentContext.cancelPreview()

        let service = InterpreterDocumentAIService(model: modelService)
        let scene = self.scene
        let contextNote = self.contextNote
        let projections = contextProjections()
        do {
            let answer = try await service.answerQuestion(
                question: chinese,
                sources: sources,
                scene: scene,
                contextNote: contextNote,
                recentTurns: projections,
                masked: documentContext.previewIsMasked
            )
            // Scope 校验：会话已切换/删除 → 丢弃迟到结果。
            guard self.conversation?.id == conversationID,
                  repository.interpreterConversation(id: conversationID) != nil else { return }
            try? repository.completeInterpreterTurnTranslation(
                turn,
                chinese: nil,
                russian: answer.suggestedRussian,
                stressedRussian: answer.stressedRussian,
                backTranslation: answer.backTranslation,
                details: Self.documentAnswerDetails(answer),
                localSources: Self.localSources(
                    citations: answer.citations, sources: sources
                )
            )
            reloadTurns()
        } catch is CancellationError {
            // 取消的请求不标成失败。
        } catch {
            // Scope 校验同样适用于失败写回。
            if repository.interpreterConversation(id: conversationID) != nil,
               self.conversation?.id == conversationID {
                lastTranslationError = Self.describeTranslationError(error)
                try? repository.failInterpreterTurnTranslation(turn)
                reloadTurns()
            }
        }
    }

    /// 文件分析的落地：分析结果作为用户可见的结构化详情进入一个
    /// 专用"文档分析"回合（不产生俄语 —— 用户读的是解释）。文字与
    /// 用户提交的中文摘要沿既有 turn 同步；原始文件与 OCR 全文绝不
    /// 进入 details（只存 citation 元数据与短引文）。
    func submitDocumentAnalysis() async {
        guard let documentContext,
              !documentContext.currentPreviewSources.isEmpty,
              let modelService = resolveModelService() else { return }
        ensureConversation()
        guard let conversation else { return }
        let conversationID = conversation.id

        isTranslatingReply = true
        documentContext.setAsking(true)
        lastTranslationError = nil
        documentContext.clearAIError()
        defer {
            isTranslatingReply = false
            documentContext.setAsking(false)
        }

        let sources = documentContext.currentPreviewSources
        let documentNames = Array(Set(sources.map { $0.chunk.documentName })).sorted()
        let chinese = "请解释文件：\(documentNames.joined(separator: "、"))"

        let turn: InterpreterTurn
        do {
            turn = try repository.addInterpreterUserTurn(
                conversationID: conversationID, chinese: chinese, inputMethod: .text
            )
            turns.append(turn)
        } catch {
            Self.logger.error("append user turn failed: \(error)")
            return
        }
        documentContext.cancelPreview()

        let service = InterpreterDocumentAIService(model: modelService)
        let scene = self.scene
        do {
            let analysis = try await service.analyzeDocument(
                sources: sources, scene: scene,
                masked: documentContext.previewIsMasked
            )
            guard self.conversation?.id == conversationID,
                  repository.interpreterConversation(id: conversationID) != nil else { return }
            try? repository.completeInterpreterTurnTranslation(
                turn,
                chinese: analysis.summaryChinese,
                russian: nil,
                stressedRussian: nil,
                backTranslation: nil,
                details: Self.documentAnalysisDetails(analysis),
                localSources: Self.localSources(
                    citations: analysis.citations, sources: sources
                )
            )
            // 分析结果写入来源文档（字段助手数据源；设备本地）。
            let sourceDocumentIDs = Set(sources.map { $0.chunk.documentID })
            for documentID in sourceDocumentIDs {
                if let document = repository.interpreterDocument(id: documentID) {
                    try? repository.setInterpreterDocumentAnalysis(
                        document, analysis: analysis
                    )
                }
            }
            documentContext.reload(conversationID: conversationID)
            reloadTurns()
        } catch is CancellationError {
        } catch {
            if repository.interpreterConversation(id: conversationID) != nil,
               self.conversation?.id == conversationID {
                lastTranslationError = Self.describeTranslationError(error)
                try? repository.failInterpreterTurnTranslation(turn)
                reloadTurns()
            }
        }
    }

    /// 字段值核对结果进入对话（用户手动输入自己的值之后）。
    func submitFieldCheck(field: InterpreterFormField, value: String) async {
        let chinese = "字段「\(field.chineseMeaning)」填 \(value) 对吗？"
        guard let modelService = resolveModelService() else {
            lastTranslationError = "翻译模型未配置，请在设置中填写 API 地址与模型"
            return
        }
        ensureConversation()
        guard let conversation else { return }
        let conversationID = conversation.id
        isTranslatingReply = true
        defer { isTranslatingReply = false }

        let turn: InterpreterTurn
        do {
            turn = try repository.addInterpreterUserTurn(
                conversationID: conversationID, chinese: chinese, inputMethod: .text
            )
            turns.append(turn)
        } catch { return }

        let service = InterpreterDocumentAIService(model: modelService)
        do {
            let answer = try await service.checkFieldValue(field: field, userValue: value)
            guard self.conversation?.id == conversationID,
                  repository.interpreterConversation(id: conversationID) != nil else { return }
            try? repository.completeInterpreterTurnTranslation(
                turn,
                chinese: nil,
                russian: answer.suggestedRussian,
                stressedRussian: answer.stressedRussian,
                backTranslation: answer.backTranslation,
                details: Self.documentAnswerDetails(answer),
                // 字段核对没有文件 chunk —— 引文一律为空。
                localSources: nil
            )
            reloadTurns()
        } catch is CancellationError {
        } catch {
            if repository.interpreterConversation(id: conversationID) != nil,
               self.conversation?.id == conversationID {
                lastTranslationError = Self.describeTranslationError(error)
                try? repository.failInterpreterTurnTranslation(turn)
                reloadTurns()
            }
        }
    }

    /// 多模态页面分析（用户明确确认后执行；图像只含选定页面的受限
    /// 尺寸副本，绝不发送整份 PDF）。分析结果作为文档分析回合落地。
    func submitMultimodalAnalysis(question: String) async {
        guard let documentContext,
              let imageService = documentContext.resolveImageService() else {
            lastTranslationError = "图片理解模型未配置，请在设置中填写"
            return
        }
        ensureConversation()
        guard let conversation, let modelService = resolveModelService() else { return }
        let conversationID = conversation.id
        isTranslatingReply = true
        documentContext.setAsking(true)
        documentContext.clearAIError()
        defer {
            isTranslatingReply = false
            documentContext.setAsking(false)
        }
        let documents = documentContext.documents.filter {
            documentContext.selectedPages[$0.id]?.isEmpty == false
        }
        let images = await documentContext.prepareMultimodalImages(documents: documents)
        guard !images.isEmpty else {
            lastTranslationError = "无法渲染选定的页面（先完成文字提取或检查文件）"
            return
        }
        documentContext.cancelPreview()

        let turn: InterpreterTurn
        do {
            turn = try repository.addInterpreterUserTurn(
                conversationID: conversationID,
                chinese: question.isEmpty ? "请分析这些页面的内容" : question,
                inputMethod: .text
            )
            turns.append(turn)
        } catch { return }

        let scene = self.scene
        let service = InterpreterDocumentAIService(model: modelService)
        do {
            let analysis = try await service.analyzePages(
                images: images, question: question, scene: scene, imageService: imageService
            )
            guard self.conversation?.id == conversationID,
                  repository.interpreterConversation(id: conversationID) != nil else { return }
            try? repository.completeInterpreterTurnTranslation(
                turn,
                chinese: analysis.summaryChinese,
                russian: nil,
                stressedRussian: nil,
                backTranslation: nil,
                details: Self.documentAnalysisDetails(analysis),
                // 多模态兜底不携带可校验的 source ID —— 引文一律为空
                // （analyzePages 已置 citations = nil）。
                localSources: nil
            )
            // 多模态分析结果同样写入来源文档（字段助手数据源）。
            for document in documents {
                try? repository.setInterpreterDocumentAnalysis(document, analysis: analysis)
            }
            documentContext.reload(conversationID: conversationID)
            reloadTurns()
        } catch is CancellationError {
        } catch {
            if repository.interpreterConversation(id: conversationID) != nil,
               self.conversation?.id == conversationID {
                lastTranslationError = Self.describeTranslationError(error)
                try? repository.failInterpreterTurnTranslation(turn)
                reloadTurns()
            }
        }
    }

    // MARK: - 回合操作

    /// 删除一个回合（草稿或已保存均可）。删除聚焦（最新）回合后聚焦
    /// 邻近回合（聚焦 = 最新回合的派生值，自动跟随；不触发跳底滚动）。
    func deleteTurn(_ turn: InterpreterTurn) {
        do {
            try repository.deleteInterpreterTurn(turn)
            reloadTurns()
            expandedTurnIDs.remove(turn.id)
            if presentedTurnID == turn.id { presentedTurnID = nil }
        } catch {
            Self.logger.error("delete turn failed: \(error)")
        }
    }

    /// 编辑回合原文后重译。
    func updateTurnSource(_ turn: InterpreterTurn, text: String) {
        do {
            try repository.updateInterpreterTurnSource(turn, text: text)
            reloadTurns()
        } catch {
            Self.logger.error("update turn source failed: \(error)")
        }
    }

    /// 快捷回复建议填入输入框（不自动翻译、不自动朗读）。
    func applySuggestion(_ text: String) {
        replyDraft = text
    }

    // MARK: - 时间线跟随（纯 UI 状态机）

    /// 滚动位置探测（时间线视图带滞回调用；编程式滚动期间抑制）。
    func userScrolledTimeline(nearBottom: Bool) {
        guard !isProgrammaticScrollActive else { return }
        follow.userScrolled(nearBottom: nearBottom)
    }

    /// 新回合落定（turns 增长）：跟随中由视图滚到底；回看中计未读。
    func noteNewTurnLanded() {
        follow.turnLanded()
    }

    /// 用户点击"回到最新"。
    func resumeFollowing() {
        follow.resumeFollowing()
    }

    /// 当前聚焦回合（最新回合；Apple-Music 式聚焦由数据决定，
    /// 不依赖几何测量）。
    var focusedTurnID: UUID? {
        turns.last?.id
    }

    /// 一个回合的排版决策（纯函数派生 —— 视图不自行猜测主次语言）。
    /// isFocused = 该回合是当前聚焦（最新）回合。
    func presentation(
        for turn: InterpreterTurn, isTranslating: Bool
    ) -> InterpreterTurnPresentation {
        InterpreterTurnPresentation.make(
            turn: turn,
            isTranslating: isTranslating,
            showStress: environment.settings.interpreterShowStress,
            isFocused: turn.id == focusedTurnID
        )
    }

    /// 我的回复翻译是否进行中（含逐条重试标记）—— 供时间线渲染。
    func isTranslating(turn: InterpreterTurn) -> Bool {
        if translatingTurnIDs.contains(turn.id) {
            return true
        }
        guard turn.direction == .zh2ru, isTranslatingReply else { return false }
        return turns.last?.id == turn.id
    }

    /// 快捷回复建议（本地静态短语 + 最近对方回合的 AI 建议合并）。
    func quickReplies() -> [InterpreterQuickReply] {
        let aiSuggestions = turns
            .last(where: { $0.speaker == .counterpart })?
            .details?.suggestedReplies ?? []
        return InterpreterQuickReplyCatalog.merged(
            aiSuggestions: aiSuggestions, scene: scene
        )
    }

    // MARK: - 朗读（给对方听）

    func speakTurn(_ turn: InterpreterTurn) {
        let russian = turn.plainRussian.isEmpty ? turn.stressedRussian : turn.plainRussian
        guard !russian.isEmpty else { return }
        // 朗读前暂停连续收听（麦克风与扬声器让路；用户明确点"继续听"
        // 恢复 —— 绝不自动恢复）。单句收音保持既有语义：用户控制。
        if isContinuousListening, continuousPauseReason == nil {
            pauseContinuousListening(reason: .speaking)
        }
        // 收音时先停收音再朗读由用户控制；朗读前停止正在进行的朗读。
        speech.speak(russian)
    }

    func stopSpeaking() {
        speech.stop()
    }

    /// 进入"给对方看"：锁定该回合并停止正在播放的旧句（展示期间新
    /// 回合、同步或后台翻译完成都不得替换锁定内容）。连续收听同时
    /// 暂停（展示期间不收音；用户明确点"继续听"恢复）。
    func presentTurn(_ turn: InterpreterTurn) {
        if isContinuousListening, continuousPauseReason == nil {
            pauseContinuousListening(reason: .speaking)
        }
        speech.stop()
        presentedTurnID = turn.id
    }

    // MARK: - 结束会话

    /// 结束：保存或丢弃。返回 true 表示可以离开页面。
    /// 保存且存在文件上下文时的文件处理由 fileDisposition 决定（UI
    /// 在确认对话框中收集用户选择）。
    enum EndFileDisposition: Equatable, Sendable {
        /// 仅保留对话，删除文件上下文（默认）。
        case discardDocuments
        /// 保留提取文字与分析，删除原始文件。
        case keepTextOnly
        /// 在本机保留原始文件（不等于"已同步"）。
        case keepOriginals
    }

    func endConversation(
        save: Bool, fileDisposition: EndFileDisposition = .discardDocuments
    ) async {
        await stopListening()
        speech.stop()
        guard let conversation, conversation.status == .draft else { return }
        do {
            if save {
                try repository.saveInterpreterDraft(title: nil)
                // 保存后的文件上下文处理（用户明确选择）：
                switch fileDisposition {
                case .discardDocuments:
                    try repository.deleteInterpreterDocuments(
                        conversationID: conversation.id,
                        store: InterpreterDocumentStoreShared.store
                    )
                case .keepTextOnly:
                    try repository.dropInterpreterDocumentOriginals(
                        conversationID: conversation.id,
                        store: InterpreterDocumentStoreShared.store
                    )
                case .keepOriginals:
                    break // 原始文件留在本机（绝不上传）
                }
            } else {
                try repository.discardInterpreterDraft()
            }
        } catch {
            Self.logger.error("end conversation failed: \(error)")
        }
        self.conversation = nil
        turns = []
        lastRecognizedRussian = ""
        documentContext?.reload(conversationID: nil)
    }

    /// 离开页面（不打断草稿 —— 切后台/误退出不丢对话）。连续模式暂停中
    /// 也一并停止（capture session 不得在页面外存活）。
    func suspend() async {
        if listeningPhase == .listening || listeningPhase == .transcribing
            || isContinuousListening {
            await stopListening()
        }
        speech.stop()
    }

    // MARK: - Demo / canned 注入点

    /// 模型服务解析（真实环境从环境 box；demo 注入 canned）。
    private func resolveModelService() -> (any StudyReviewModelService)? {
        // 默认走环境 box；构造时注入的 provider（demo）非空时优先。
        if let injected = translationServiceProvider(), injected != nil {
            return injected
        }
        return environment.studyServiceBoxForInterpreter?.get()
    }

    // MARK: - Helpers

    private func reloadTurns() {
        guard let conversation else { return }
        turns = (try? repository.interpreterTurns(conversationID: conversation.id)) ?? turns
    }

    /// 有界上下文投影（最近有效回合，绝不带课堂内容）。
    private func contextProjections() -> [InterpreterContextBuilder.TurnProjection] {
        turns.map { turn in
            InterpreterContextBuilder.TurnProjection(
                speaker: turn.speaker,
                direction: turn.direction,
                sourceText: turn.sourceText,
                translatedText: turn.direction == .ru2zh
                    ? (turn.chineseText.isEmpty ? nil : turn.chineseText)
                    : (turn.plainRussian.isEmpty ? nil : turn.plainRussian),
                translationFailed: turn.translationFailed
            )
        }
    }

    private static func describeTranslationError(_ error: Error) -> String {
        if let translationError = error as? TranslationError {
            // Runtime surface: the stable actionable summary — the
            // provider's raw response text stays out of the UI (it rides
            // only the settings test-connection flow).
            return translationError.userActionableSummary
        }
        return error.localizedDescription
    }

    // MARK: - 文件上下文 details 构造（同步边界的关键）

    /// 问答详情：只存非来源型结构信息 —— 文件名/页码/引文绝不进入
    /// 可同步 details，它们走 localSources（设备本地）。其他设备看到
    /// hasLocalSources 时显示"来源文件仅保存在原设备"。
    private static func documentAnswerDetails(
        _ answer: InterpreterDocumentAnswer
    ) -> InterpreterTurnDetails {
        var details = InterpreterTurnDetails(detailsAvailable: answer.detailsAvailable)
        details.uncertainties = answer.uncertainties
        details.politeAlternative = answer.politeAlternative
        details.simpleAlternative = answer.simpleAlternative
        details.hasLocalSources = answer.citations?.isEmpty == false
        return details
    }

    /// 文件分析详情：分析结构（类型/关键事实/建议/警告）+ 无内容的
    /// 本地来源标记。关键事实与中文摘要同为用户选择保留的分析内容
    /// （摘要作为回合主文本同步）；完整 OCR 文本与来源标签永远留在
    /// 本机。
    private static func documentAnalysisDetails(
        _ analysis: InterpreterDocumentAnalysis
    ) -> InterpreterTurnDetails {
        var details = InterpreterTurnDetails(detailsAvailable: analysis.detailsAvailable)
        details.intentSummary = analysis.documentType
        if let keyFacts = analysis.keyFacts, !keyFacts.isEmpty {
            details.keywords = keyFacts
        }
        details.uncertainties = analysis.uncertainties
        details.suggestedReplies = analysis.questionsToAsk
        details.ambiguity = analysis.warnings?.joined(separator: "；")
        details.hasLocalSources = analysis.citations?.isEmpty == false
        return details
    }

    /// 校验通过的 citation → 设备本地来源列表。documentID 从请求
    /// sources 反解（citation 只带 source ID）；snippet 就是模型引用
    /// 的短引文 —— 与实际发送给模型的那份文本（默认遮盖后）一致，
    /// 因为引文校验要求 snippet 出现在发送文本中。绝不上传。
    private static func localSources(
        citations: [InterpreterCitation]?,
        sources: [InterpreterDocumentChunker.RequestSource]
    ) -> [InterpreterLocalSource]? {
        guard let citations, !citations.isEmpty else { return nil }
        return citations.map { citation in
            let documentID = sources
                .first { $0.sourceID == citation.sourceID }?
                .chunk.documentID
            return InterpreterLocalSource(
                documentID: documentID,
                documentName: citation.documentName,
                pageNumber: citation.pageNumber,
                snippet: citation.snippet
            )
        }
    }

    // MARK: - Demo 注入点（Debug 构建；Release 无此路径）

    #if DEBUG
    /// UI-demo（--demo-interpreter-state listening/continuous）：把收音
    /// 状态置为真实状态机的对应相位，并用确定性脚本驱动真实电平显示
    /// （无麦克风、无音频 —— 状态机本身与真实路径完全一致）。
    func debugApplyDemoListeningState(continuous: Bool = false) {
        if continuous {
            isContinuousListening = true
            continuousPauseReason = nil
            // "对方正在说"指示（真实 VAD 派生状态的确定性注入）。
            counterpartIsSpeaking = true
        }
        guard listeningPhase == .idle else { return }
        listeningPhase = .listening
        debugDemoLevelTask?.cancel()
        let base = Date()
        debugDemoLevelTask = Task { [weak self] in
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(base)
                // 确定性低频电平（与课堂 demo 的脚本惯例一致）。
                let level = Float(
                    0.28 + 0.14 * sin(elapsed / 1.7) + 0.05 * sin(elapsed / 0.6)
                )
                self?.audioLevel = max(0.05, min(0.6, level))
                try? await Task.sleep(for: .milliseconds(220))
            }
        }
    }

    private var debugDemoLevelTask: Task<Void, Never>?
    #endif
}

/// 连续收听暂停门（原子布尔 —— detached 音频循环无锁读取，主线程
/// 暂停/恢复时翻转）。
final class InterpreterPauseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false

    var isPaused: Bool {
        get {
            lock.lock(); defer { lock.unlock() }
            return paused
        }
        set {
            lock.lock(); defer { lock.unlock() }
            paused = newValue
        }
    }
}
