import SwiftUI

/// 随身翻译主页面 —— 面对面办事口译（第十九轮柜台重构）。
///
/// 四个稳定区域（站在柜台前单手操作）：
/// - 紧凑状态栏：场景、收音、ASR 资源、翻译可用性、朗读；
/// - 可折叠办事上下文条：ErrandCase 轻量上下文 + 文件 chip（一到两行）；
/// - 聚焦式双语时间线：当前回合最清晰，历史逐级降权（非聊天气泡）；
/// - 固定底部操作区：听对方说大按钮 + 中文输入 + 快捷回复 + 附件入口。
///
/// 状态不只靠颜色（文字标签 + SF Symbol）；Dynamic Type / VoiceOver /
/// Reduce Motion 全部走系统（LT 设计系统）。草稿永不上传（同步只发生在
/// 保存后 —— 既有语义，本轮不改）。
struct InterpreterScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var viewModel: InterpreterViewModel?
    @State private var showScenePicker = false
    @State private var showHistory = false
    @State private var showEndConfirmation = false
    /// 文件上下文面板。
    @State private var showDocumentPanel = false
    /// 办事上下文 sheet（待问问题/材料/已确认信息）。
    @State private var showErrandContextSheet = false
    /// 结束保存时的文件处理选择。
    @State private var endFileDisposition: InterpreterViewModel.EndFileDisposition = .discardDocuments
    /// 整理为办事事项（当前对话 → 事项草稿的本地来源链接）。
    @State private var showErrandEditor = false
    /// 办事事项带入的现场问题（只填入输入框 —— 不自动翻译、不自动
    /// 朗读、不自动开麦；nil = 普通进入）。
    var prefilledQuestion: String? = nil
    /// 关联的办事事项（从 ErrandCase 的"开始现场沟通"进入；nil = 普通
    /// 进入 —— 不显示空占位上下文条）。
    var errandCaseID: UUID? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LTPage {
                if let viewModel {
                    mainContent(viewModel)
                } else {
                    Color.clear
                }
            }
            // Round 17: 随身翻译 carries the most sensitive on-screen
            // content (证件文件、OCR、对话) — mask while the screen is
            // being recorded or mirrored.
            .screenCaptureMask()
            .navigationTitle("随身翻译")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showHistory = true
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .accessibilityLabel("最近记录")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // 整理为办事事项：用当前对话创建事项草稿（默认只建
                    // 立本地来源链接 —— 不复制对话、不修改原对话）。
                    Button {
                        showErrandEditor = true
                    } label: {
                        Image(systemName: "checklist")
                    }
                    .accessibilityLabel("整理为办事事项")
                    .disabled(viewModel?.conversation == nil)
                }
            }
        }
        .task {
            if viewModel == nil {
                viewModel = InterpreterViewModel(environment: environment)
                viewModel?.attachErrandContext(caseID: errandCaseID)
                // 办事事项带入的问题只填入输入框（applySuggestion 的
                // 语义：不自动翻译、不自动朗读）。
                if let prefilledQuestion, !prefilledQuestion.isEmpty {
                    viewModel?.applySuggestion(prefilledQuestion)
                }
            }
            await viewModel?.reload()
            #if DEBUG
            applyDemoStateIfNeeded()
            #endif
        }
        .sheet(isPresented: $showScenePicker) {
            if let viewModel {
                InterpreterScenePickerSheet(
                    scene: Binding(
                        get: { viewModel.scene },
                        set: { viewModel.scene = $0 }
                    ),
                    contextNote: Binding(
                        get: { viewModel.contextNote },
                        set: { viewModel.contextNote = $0 }
                    )
                )
                .presentationDetents([.medium, .large])
            }
        }
        .sheet(isPresented: $showHistory) {
            if let viewModel {
                InterpreterHistorySheet(
                    environment: environment
                ) { conversationID in
                    // 继续作为新对话的上下文副本：载入场景与背景。
                    if let conversation = environment.repository.interpreterConversation(id: conversationID) {
                        viewModel.scene = conversation.scene
                        viewModel.contextNote = conversation.contextNote
                    }
                }
            }
        }
        .sheet(isPresented: $showErrandEditor) {
            // 当前对话 → 事项草稿（本地来源链接，不复制/不修改原对话）。
            ErrandCaseEditorView(
                sourceConversationID: viewModel?.conversation?.id
            )
            .environment(environment)
        }
        .confirmationDialog(
            "结束本次翻译",
            isPresented: $showEndConfirmation,
            titleVisibility: .visible
        ) {
            if viewModel?.documentContext?.hasContext == true {
                Button("保存记录，文件上下文只留本机") {
                    endFileDisposition = .keepOriginals
                    Task { await endConversation(save: true) }
                }
                Button("保存记录，保留提取文字、删除原始文件") {
                    endFileDisposition = .keepTextOnly
                    Task { await endConversation(save: true) }
                }
                Button("保存记录，删除文件上下文") {
                    endFileDisposition = .discardDocuments
                    Task { await endConversation(save: true) }
                }
            } else {
                Button("保存记录") {
                    Task { await endConversation(save: true) }
                }
            }
            Button("丢弃", role: .destructive) {
                Task { await endConversation(save: false) }
            }
            Button("继续翻译", role: .cancel) {}
        } message: {
            if viewModel?.documentContext?.hasContext == true {
                Text("保存后进入正式记录并同步到云端；丢弃将删除本次草稿、全部回合与文件上下文。原始文件与完整识别文本不会上传——\"只留本机\"指的是保存在这台设备上，不是云端同步。")
            } else {
                Text("保存后进入正式记录并同步到云端；丢弃将删除本次草稿与全部回合。")
            }
        }
        .sheet(isPresented: $showDocumentPanel) {
            if let viewModel {
                InterpreterDocumentPanel(
                    viewModel: viewModel,
                    isPresented: $showDocumentPanel
                )
                .environment(environment)
                .onDisappear {
                    // 文件上下文变化后刷新上下文条（就绪数/选中状态）。
                    viewModel.refreshCounterContext()
                }
            }
        }
        .sheet(isPresented: $showErrandContextSheet) {
            if let viewModel {
                InterpreterErrandContextSheet(
                    caseID: errandCaseID ?? viewModel.counterContext?.caseID,
                    onPrefillQuestion: { question in
                        // 只填入输入框 —— 不自动翻译、不自动发送、不自动朗读。
                        viewModel.applySuggestion(question)
                    },
                    onOpenDocuments: { showDocumentPanel = true }
                )
                .environment(environment)
            }
        }
        .onDisappear {
            // 切后台/离开页面不打断草稿；只停收音与朗读。
            Task { await viewModel?.suspend() }
        }
    }

    // MARK: - Main content（四个稳定区域）

    @ViewBuilder
    private func mainContent(_ viewModel: InterpreterViewModel) -> some View {
        VStack(spacing: 0) {
            InterpreterStatusBar(
                viewModel: viewModel,
                onOpenScenePicker: { showScenePicker = true }
            )
            InterpreterContextBar(
                counterContext: viewModel.counterContext,
                documentSummary: documentSummary(viewModel),
                onOpenSheet: { showErrandContextSheet = true },
                onOpenDocuments: { showDocumentPanel = true },
                onRemoveDocumentContext: { viewModel.clearDocumentContextSelection() }
            )
            InterpreterTimeline(viewModel: viewModel) { turn in
                turnActions(viewModel, turn)
            }
            InterpreterComposer(
                viewModel: viewModel,
                onSubmitReply: {
                    Task { await viewModel.submitReply() }
                },
                onToggleListening: {
                    if viewModel.listeningPhase == .listening
                        || viewModel.listeningPhase == .transcribing {
                        Task { await viewModel.stopListening() }
                    } else {
                        Task { await viewModel.startListening() }
                    }
                },
                onOpenDocuments: { showDocumentPanel = true },
                onOpenQuestions: { showErrandContextSheet = true },
                onEndRequested: {
                    if environment.settings.interpreterAskToSave {
                        showEndConfirmation = true
                    } else {
                        Task { await endConversation(save: true) }
                    }
                },
                pendingQuestionCount: viewModel.counterContext?.pendingQuestionCount ?? 0
            )
        }
        .onChange(of: viewModel.documentContext?.documents.count) { _, _ in
            // 文件导入/删除后刷新上下文条。
            viewModel.refreshCounterContext()
        }
        .fullScreenCover(item: Binding(
            get: {
                viewModel.presentedTurnID.flatMap { id in
                    viewModel.turns.first { $0.id == id }
                }
            },
            set: { newValue in
                viewModel.presentedTurnID = newValue?.id
            }
        )) { turn in
            InterpreterShowModeView(
                turn: turn,
                isSpeaking: viewModel.speechIsSpeaking,
                onSpeak: { viewModel.speakTurn(turn) },
                onStopSpeak: { viewModel.stopSpeaking() },
                onDismiss: { viewModel.presentedTurnID = nil }
            )
        }
    }

    // MARK: - 回合动作接线

    private func turnActions(
        _ viewModel: InterpreterViewModel, _ turn: InterpreterTurn
    ) -> InterpreterTurnActions {
        InterpreterTurnActions(
            onSpeak: { viewModel.speakTurn(turn) },
            onCopy: { text in
                ClipboardService.shared.copySensitive(text)
            },
            onPresent: { viewModel.presentTurn(turn) },
            onRetry: {
                if turn.direction == .ru2zh {
                    viewModel.translateCounterpartTurn(turn)
                } else {
                    Task { await viewModel.retryUserTurn(turn) }
                }
            },
            onEditSource: { text in
                viewModel.updateTurnSource(turn, text: text)
            },
            onDelete: { viewModel.deleteTurn(turn) },
            onToggleExpanded: {
                if viewModel.expandedTurnIDs.contains(turn.id) {
                    viewModel.expandedTurnIDs.remove(turn.id)
                } else {
                    viewModel.expandedTurnIDs.insert(turn.id)
                }
            }
        )
    }

    // MARK: - 文件上下文

    private func documentSummary(
        _ viewModel: InterpreterViewModel
    ) -> InterpreterContextBar.DocumentSummary? {
        guard let documentModel = viewModel.documentContext,
              !documentModel.documents.isEmpty else { return nil }
        let selectedPages = documentModel.selectedPages
        let hasSelection = documentModel.documents.contains { document in
            guard document.allowsModelUse else { return false }
            if let pages = selectedPages[document.id] {
                return !pages.isEmpty
            }
            return true
        }
        return InterpreterContextBar.DocumentSummary(
            readyCount: documentModel.readyDocumentCount,
            totalCount: documentModel.documents.count,
            extracting: documentModel.documents.contains {
                documentModel.extractionProgress(for: $0.id) != nil
            },
            hasSelection: hasSelection
        )
    }

    // MARK: - 结束会话

    private func endConversation(save: Bool) async {
        await viewModel?.endConversation(save: save, fileDisposition: endFileDisposition)
        dismiss()
    }

    // MARK: - Demo 注入点（Debug 构建；Release 无此路径）

    #if DEBUG
    /// `--ui-demo --demo-screen interpreter-counter --demo-interpreter-state X`
    /// 的确定性视觉状态（截图验收用）：真实页面 + 真实状态机，仅注入
    /// UI 状态。
    private func applyDemoStateIfNeeded() {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--demo-interpreter-state"),
              index + 1 < args.count,
              let viewModel else { return }
        switch args[index + 1] {
        case "listening":
            viewModel.debugApplyDemoListeningState()
        case "showmode":
            if let turn = viewModel.turns.last(where: { !$0.plainRussian.isEmpty }) {
                viewModel.presentedTurnID = turn.id
            }
        case "facing":
            // 对向展示初始态由 ShowModeView 内部解析（Debug-only）。
            if let turn = viewModel.turns.last(where: { !$0.plainRussian.isEmpty }) {
                viewModel.presentedTurnID = turn.id
            }
        case "sheet":
            showErrandContextSheet = true
        default:
            break
        }
    }
    #endif
}
