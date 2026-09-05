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
    /// 真实电平（仅真实音量数据驱动显示；无数据时不显示波形）。
    private(set) var audioLevel: Float = 0
    private(set) var micPermissionDenied = false
    private(set) var asrModelInstalled = true

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

    // MARK: - Presentation state (UI-only, never synced)

    /// 展开的回合卡片（展开状态属于 UI 状态，不上传）。
    var expandedTurnIDs: Set<UUID> = []
    /// 给对方看模式正在展示的回合。
    var presentedTurnID: UUID?
    /// 滚动跟随（用户靠近底部时新回合自动跟随）。
    var shouldAutoFollow = true

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
    func reload() {
        scene = environment.settings.interpreterDefaultScene
        asrModelInstalled = (try? environment.engineManager.isInstalled(
            environment.settings.preferredBackend
        )) ?? true
        micPermissionDenied = AVAudioApplication.shared.recordPermission == .denied
        // 恢复上次未结束的草稿（App 被杀后重新进入）。
        if let draft = repository.interpreterDraft {
            conversation = draft
            scene = draft.scene
            contextNote = draft.contextNote
            turns = (try? repository.interpreterTurns(conversationID: draft.id)) ?? []
            Self.logger.info("resumed interpreter draft (\(turns.count) turns)")
        }
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

    /// 收音主循环：VAD → 分句 → ASR（串行）。每个完成回合立即落本地
    /// 并触发翻译。
    private func startListeningLoop(chunks: AsyncStream<AudioChunk>) {
        let settings = environment.settings
        do {
            vad = try SherpaSileroVAD()
        } catch {
            listeningPhase = .failed("语音活动检测初始化失败")
            return
        }
        var parameters = SpeechSegmenter.Parameters()
        parameters.vadMinSpeechMs = settings.vadMinSpeechMs
        parameters.vadSilenceEndMs = settings.vadSilenceEndMs
        segmenter = SpeechSegmenter(parameters: parameters)

        let vad = self.vad!
        let segmenter = self.segmenter!
        processingTask = Task.detached(priority: .userInitiated) { [weak self] in
            for await chunk in chunks {
                guard let self else { break }
                // 真实电平（仅真实数据驱动 UI 波形）。
                let rms = chunk.rms
                await MainActor.run { self.audioLevel = rms }
                let isSpeech = vad.process(window: chunk.samples[...])
                let segments = segmenter.push(window: chunk.samples[...], isSpeech: isSpeech)
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
        guard !Task.isCancelled else { return }
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
        listeningPhase = (capture?.state.isDeliveringAudio ?? false) ? .listening : .idle
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

    /// 停止收音（保留草稿与回合）。
    func stopListening() async {
        processingTask?.cancel()
        processingTask = nil
        // 发出分句器中的尾段（诚实收尾）。
        if let segmenter {
            let segments = segmenter.flush()
            for segment in segments {
                await handleSpeechSegment(segment)
            }
        }
        await capture?.stop()
        capture = nil
        vad = nil
        segmenter = nil
        environment.engineManager.endSession()
        audioLevel = 0
        listeningPhase = .idle
        Self.logger.info("interpreter listening stopped")
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
                    details: result.details
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
                details: result.details
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
                details: result.details
            )
            reloadTurns()
        } catch is CancellationError {
        } catch {
            lastTranslationError = Self.describeTranslationError(error)
            try? repository.failInterpreterTurnTranslation(turn)
            reloadTurns()
        }
    }

    // MARK: - 回合操作

    /// 删除一个回合（草稿或已保存均可）。
    func deleteTurn(_ turn: InterpreterTurn) {
        do {
            try repository.deleteInterpreterTurn(turn)
            reloadTurns()
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

    // MARK: - 朗读（给对方听）

    func speakTurn(_ turn: InterpreterTurn) {
        let russian = turn.plainRussian.isEmpty ? turn.stressedRussian : turn.plainRussian
        guard !russian.isEmpty else { return }
        // 收音时先停收音再朗读由用户控制；朗读前停止正在进行的朗读。
        speech.speak(russian)
    }

    func stopSpeaking() {
        speech.stop()
    }

    // MARK: - 结束会话

    /// 结束：保存或丢弃。返回 true 表示可以离开页面。
    func endConversation(save: Bool) async {
        await stopListening()
        speech.stop()
        guard let conversation, conversation.status == .draft else { return }
        do {
            if save {
                try repository.saveInterpreterDraft(title: nil)
            } else {
                try repository.discardInterpreterDraft()
            }
        } catch {
            Self.logger.error("end conversation failed: \(error)")
        }
        self.conversation = nil
        turns = []
        lastRecognizedRussian = ""
    }

    /// 离开页面（不打断草稿 —— 切后台/误退出不丢对话）。
    func suspend() async {
        if listeningPhase == .listening || listeningPhase == .transcribing {
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
            return translationError.localizedDescription
        }
        return error.localizedDescription
    }
}
