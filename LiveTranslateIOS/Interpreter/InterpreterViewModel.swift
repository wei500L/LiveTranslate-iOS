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

    // MARK: - Document context (现场文件)

    /// 文件上下文模型（导入/提取/选择/预览/ AI 动作的编排层）。
    private(set) var documentContext: InterpreterDocumentContextModel?
    /// 文档触发的 AI 动作进行中的 turn id（防重复 + 迟到回调 scope 校验）。
    private var documentTaskTurnIDs: Set<UUID> = []

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
    func reload() async {
        scene = environment.settings.interpreterDefaultScene
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
        parameters.minSpeechSeconds = TimeInterval(settings.vadMinSpeechMs) / 1000
        parameters.silenceEndSeconds = TimeInterval(settings.vadSilenceEndMs) / 1000
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
                recentTurns: projections
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
                details: Self.documentAnswerDetails(answer)
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
                sources: sources, scene: scene
            )
            guard self.conversation?.id == conversationID,
                  repository.interpreterConversation(id: conversationID) != nil else { return }
            try? repository.completeInterpreterTurnTranslation(
                turn,
                chinese: analysis.summaryChinese,
                russian: nil,
                stressedRussian: nil,
                backTranslation: nil,
                details: Self.documentAnalysisDetails(analysis)
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
                details: Self.documentAnswerDetails(answer)
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
                details: Self.documentAnalysisDetails(analysis)
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

    // MARK: - 文件上下文 details 构造（同步边界的关键）

    /// 问答详情：只存 citation 元数据（来源名/页码/短引文）与结构化
    /// 字段 —— 绝不存原始文件、OCR 全文或本机路径。其他设备看到
    /// citation 时显示"来源文件仅保存在原设备"（InterpreterTurnCard
    /// 依据 detailsAvailable + citations 渲染）。
    private static func documentAnswerDetails(
        _ answer: InterpreterDocumentAnswer
    ) -> InterpreterTurnDetails {
        var details = InterpreterTurnDetails(detailsAvailable: answer.detailsAvailable)
        details.keywords = answer.citations?.map(\.displayLabel)
        details.uncertainties = answer.uncertainties
        details.politeAlternative = answer.politeAlternative
        details.simpleAlternative = answer.simpleAlternative
        return details
    }

    /// 文件分析详情：分析结构（事项/材料/期限/费用/字段助手） +
    /// citation 元数据。短引文（≤300 字符）随 turn 同步 —— 用户明确
    /// 提交的内容；完整 OCR 文本永远留在本机。
    private static func documentAnalysisDetails(
        _ analysis: InterpreterDocumentAnalysis
    ) -> InterpreterTurnDetails {
        var details = InterpreterTurnDetails(detailsAvailable: analysis.detailsAvailable)
        details.intentSummary = analysis.documentType
        var keywords: [String] = analysis.keyFacts ?? []
        if let citations = analysis.citations {
            keywords.append(contentsOf: citations.map(\.displayLabel))
        }
        if !keywords.isEmpty { details.keywords = keywords }
        details.uncertainties = analysis.uncertainties
        details.suggestedReplies = analysis.questionsToAsk
        details.ambiguity = analysis.warnings?.joined(separator: "；")
        return details
    }
}
