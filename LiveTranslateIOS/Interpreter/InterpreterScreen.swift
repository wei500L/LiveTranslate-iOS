import SwiftUI

/// 随身翻译主页面 —— 面对面办事口译。
///
/// 信息架构（站在柜台前单手操作）：
/// - 顶部：场景 + 语言方向（俄 ⇄ 中）；
/// - 主体：全宽阅读卡片形式的对话历史（非社交聊天气泡），中文理解
///   结果占视觉主体（字号大于俄语原文）；
/// - 底部：显眼的"听对方说"大按钮 + "我要回复"输入区（系统键盘/
///   系统听写/粘贴，TextEditor 原生组件）；
/// - 对话历史自然向上滚动；手动上滚不强制跳回底部，用户靠近底部时
///   新回合完成才自动跟随。
///
/// 状态不只靠颜色（文字标签 + SF Symbol）；Dynamic Type / VoiceOver /
/// Reduce Motion 全部走系统（LT 设计系统）。
struct InterpreterScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var viewModel: InterpreterViewModel?
    @State private var showScenePicker = false
    @State private var showHistory = false
    @State private var showEndConfirmation = false
    /// 文件上下文面板。
    @State private var showDocumentPanel = false
    /// 结束保存时的文件处理选择。
    @State private var endFileDisposition: InterpreterViewModel.EndFileDisposition = .discardDocuments
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
            }
        }
        .task {
            if viewModel == nil {
                viewModel = InterpreterViewModel(environment: environment)
            }
            await viewModel?.reload()
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
            }
        }
        .onDisappear {
            // 切后台/离开页面不打断草稿；只停收音与朗读。
            Task { await viewModel?.suspend() }
        }
    }

    // MARK: - Main content

    @ViewBuilder
    private func mainContent(_ viewModel: InterpreterViewModel) -> some View {
        VStack(spacing: 0) {
            headerBar(viewModel)
            documentContextBar(viewModel)
            turnList(viewModel)
            replyComposer(viewModel)
        }
        .safeAreaInset(edge: .bottom) {
            listeningControls(viewModel)
        }
    }

    /// 文件上下文紧凑状态条：已加载文档数与状态（点击进入面板）。
    @ViewBuilder
    private func documentContextBar(_ viewModel: InterpreterViewModel) -> some View {
        if let documentModel = viewModel.documentContext {
            let ready = documentModel.readyDocumentCount
            let total = documentModel.documents.count
            let extracting = documentModel.documents.contains {
                documentModel.extractionProgress(for: $0.id) != nil
            }
            Button {
                showDocumentPanel = true
            } label: {
                HStack(spacing: LTSpacing.s) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(total > 0 ? LTColors.accentCyan : LTColors.textTertiary)
                    VStack(alignment: .leading, spacing: 1) {
                        if total > 0 {
                            Text("文件上下文：\(ready > 0 ? "\(ready) 份就绪" : "提取中")\(ready < total ? " · 共 \(total) 份" : "")")
                                .font(LTTypography.caption)
                                .foregroundStyle(LTColors.textSecondary)
                        } else {
                            Text("添加现场文件（表格、通知、回执）")
                                .font(LTTypography.caption)
                                .foregroundStyle(LTColors.textTertiary)
                        }
                    }
                    Spacer()
                    if extracting {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(LTColors.textTertiary)
                }
                .padding(.horizontal, LTSpacing.m)
                .padding(.vertical, LTSpacing.xs + 2)
                .background(
                    RoundedRectangle(cornerRadius: LTRadius.medium)
                        .fill(LTColors.surfaceElevated.opacity(0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: LTRadius.medium)
                        .strokeBorder(LTColors.border, lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, LTSpacing.screenPadding)
            .padding(.top, LTSpacing.xs)
            .accessibilityLabel(
                total > 0
                    ? "文件上下文，\(total) 份文件，\(ready) 份就绪，点击管理"
                    : "添加现场文件，点击打开"
            )
        }
    }

    /// 顶部：场景与语言方向。
    private func headerBar(_ viewModel: InterpreterViewModel) -> some View {
        Button {
            showScenePicker = true
        } label: {
            HStack(spacing: LTSpacing.s) {
                Image(systemName: viewModel.scene.symbol)
                    .foregroundStyle(LTColors.accentCyan)
                Text(viewModel.scene.displayName)
                    .font(LTTypography.cardTitle)
                    .foregroundStyle(LTColors.textPrimary)
                if !viewModel.contextNote.isEmpty {
                    Image(systemName: "note.text")
                        .foregroundStyle(LTColors.textSecondary)
                }
                Spacer()
                Text("俄 ⇄ 中")
                    .font(LTTypography.statusChip)
                    .foregroundStyle(LTColors.textSecondary)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(LTColors.textTertiary)
            }
            .ltCard(padding: LTSpacing.m)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, LTSpacing.screenPadding)
        .padding(.top, LTSpacing.s)
        .accessibilityLabel("当前场景 \(viewModel.scene.displayName)，点击切换")
    }

    // MARK: - Turn list

    @ViewBuilder
    private func turnList(_ viewModel: InterpreterViewModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: LTSpacing.s) {
                    if viewModel.turns.isEmpty {
                        emptyState
                    }
                    ForEach(viewModel.turns, id: \.id) { turn in
                        // Decomposed into small statements — the inline
                        // compound expression (several @Observable reads
                        // chained with &&/||) exceeded the type-checker's
                        // budget.
                        let isExpanded = viewModel.expandedTurnIDs.contains(turn.id)
                        let isTranslating: Bool = {
                            if viewModel.translatingTurnIDs.contains(turn.id) {
                                return true
                            }
                            guard turn.direction == .zh2ru,
                                  viewModel.isTranslatingReply else {
                                return false
                            }
                            return viewModel.turns.last?.id == turn.id
                        }()
                        InterpreterTurnCard(
                            turn: turn,
                            isExpanded: isExpanded,
                            showStress: environment.settings.interpreterShowStress,
                            availableDocumentIDs: viewModel.availableDocumentIDs,
                            isTranslating: isTranslating,
                            onToggleExpanded: {
                                if viewModel.expandedTurnIDs.contains(turn.id) {
                                    viewModel.expandedTurnIDs.remove(turn.id)
                                } else {
                                    viewModel.expandedTurnIDs.insert(turn.id)
                                }
                            },
                            onRetry: {
                                if turn.direction == .ru2zh {
                                    viewModel.translateCounterpartTurn(turn)
                                } else {
                                    Task { await viewModel.retryUserTurn(turn) }
                                }
                            },
                            onSpeak: { viewModel.speakTurn(turn) },
                            onPresent: { viewModel.presentedTurnID = turn.id },
                            onDelete: { viewModel.deleteTurn(turn) },
                            onUpdateSource: { text in
                                viewModel.updateTurnSource(turn, text: text)
                            }
                        )
                        .id(turn.id)
                    }
                }
                .padding(.horizontal, LTSpacing.screenPadding)
                .padding(.vertical, LTSpacing.s)
            }
            .onChange(of: viewModel.turns.count) { _, _ in
                // 新回合完成且用户靠近底部时才自动跟随。
                guard viewModel.shouldAutoFollow,
                      let last = viewModel.turns.last else { return }
                withAnimation(LTMotion.quick) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onTapGesture {
                dismissKeyboard()
            }
            .scrollDismissesKeyboard(.interactively)
        }
        if let error = viewModel.lastTranslationError {
            Text(error)
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.warning)
                .padding(.horizontal, LTSpacing.screenPadding)
                .padding(.bottom, LTSpacing.xs)
        }
    }

    private var emptyState: some View {
        LTEmptyState(
            symbol: "person.2.wave.2",
            title: "开始你们的对话",
            message: "点击下方\"听对方说\"收录对方的俄语，或直接输入中文回复。"
        )
    }

    // MARK: - Reply composer (我要回复)

    private func replyComposer(_ viewModel: InterpreterViewModel) -> some View {
        VStack(spacing: LTSpacing.xs) {
            // 快捷回复建议（对方回合翻译完成后最多 3 个，中文显示，
            // 点击只填入输入框，不自动翻译不自动朗读）。
            let suggestions = quickReplySuggestions(viewModel)
            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: LTSpacing.s) {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button {
                                viewModel.applySuggestion(suggestion)
                            } label: {
                                Text(suggestion)
                                    .font(LTTypography.caption)
                                    .foregroundStyle(LTColors.accentCyan)
                                    .padding(.horizontal, LTSpacing.m)
                                    .padding(.vertical, LTSpacing.xs + 2)
                                    .background(
                                        Capsule().fill(LTColors.accentCyan.opacity(0.12))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .bottom, spacing: LTSpacing.s) {
                // 语气选择（影响中→俄生成的礼貌层级）。
                Menu {
                    ForEach(InterpreterTone.allCases) { tone in
                        Button(tone.displayName) {
                            viewModel.tone = tone
                        }
                    }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "text.bubble")
                        Text(viewModel.tone.displayName)
                            .font(LTTypography.timestamp)
                    }
                    .foregroundStyle(LTColors.textSecondary)
                    .frame(minWidth: 56)
                }

                TextField("我要回复（中文）", text: Binding(
                    get: { viewModel.replyDraft },
                    set: { viewModel.replyDraft = $0 }
                ), axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .font(LTTypography.body)
                .padding(LTSpacing.s)
                .background(
                    RoundedRectangle(cornerRadius: LTRadius.medium)
                        .fill(LTColors.surfaceElevated.opacity(0.6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: LTRadius.medium)
                        .strokeBorder(LTColors.border, lineWidth: 0.5)
                )

                Button {
                    Task { await viewModel.submitReply() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(
                            viewModel.replyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || viewModel.isTranslatingReply
                                ? LTColors.textTertiary
                                : LTColors.accentGreen
                        )
                }
                .disabled(viewModel.replyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || viewModel.isTranslatingReply)
                .accessibilityLabel("生成俄语回复")
            }
        }
        .padding(.horizontal, LTSpacing.screenPadding)
        .padding(.vertical, LTSpacing.s)
        .background(LTColors.backgroundPrimary.opacity(0.85))
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

    // MARK: - Listening controls (听对方说)

    @ViewBuilder
    private func listeningControls(_ viewModel: InterpreterViewModel) -> some View {
        VStack(spacing: LTSpacing.xs) {
            if viewModel.listeningPhase == .listening {
                // 真实电平指示（仅真实音量数据；无数据不显示波形）。
                ListeningIndicator(level: viewModel.audioLevel) {
                    Task { await viewModel.finishCurrentUtteranceManually() }
                }
            } else if case .failed(let message) = viewModel.listeningPhase {
                Text(message)
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.warning)
            }
            HStack(spacing: LTSpacing.m) {
                Button {
                    if viewModel.listeningPhase == .listening
                        || viewModel.listeningPhase == .transcribing {
                        Task { await viewModel.stopListening() }
                    } else {
                        Task { await viewModel.startListening() }
                    }
                } label: {
                    HStack(spacing: LTSpacing.s) {
                        Image(systemName: isListening(viewModel)
                            ? "stop.circle.fill" : "ear.fill")
                            .font(.system(size: 22, weight: .semibold))
                        Text(listeningButtonLabel(viewModel))
                            .font(LTTypography.button)
                    }
                    .foregroundStyle(Color.black.opacity(0.85))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, LTSpacing.m)
                    .background(
                        Capsule().fill(
                            LinearGradient(
                                colors: isListening(viewModel)
                                    ? [LTColors.warning.opacity(0.9), LTColors.warning]
                                    : [LTColors.accentCyan.opacity(0.9), LTColors.accentCyan],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                    )
                }
                .buttonStyle(LTPrimaryButtonStyle(tint: LTColors.accentCyan))
                .accessibilityLabel(listeningButtonLabel(viewModel))

                if viewModel.turns.contains(where: { !$0.sourceText.isEmpty }) {
                    Button {
                        if environment.settings.interpreterAskToSave {
                            showEndConfirmation = true
                        } else {
                            Task { await endConversation(save: true) }
                        }
                    } label: {
                        Text("结束")
                            .font(LTTypography.cardTitle)
                            .foregroundStyle(LTColors.textSecondary)
                            .padding(.horizontal, LTSpacing.l)
                            .padding(.vertical, LTSpacing.m)
                            .background(Capsule().fill(LTColors.textSecondary.opacity(0.12)))
                    }
                    .accessibilityLabel("结束本次翻译")
                }
            }
            if viewModel.micPermissionDenied {
                micPermissionHint
            }
        }
        .padding(.horizontal, LTSpacing.screenPadding)
        .padding(.top, LTSpacing.s)
        .padding(.bottom, LTSpacing.s)
        .background(LTColors.backgroundPrimary.opacity(0.92))
    }

    private var micPermissionHint: some View {
        HStack(spacing: LTSpacing.s) {
            Image(systemName: "mic.slash")
                .foregroundStyle(LTColors.warning)
            Text("麦克风未授权，文本输入翻译仍可用")
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.textSecondary)
            Spacer()
            Button("去设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(LTTypography.caption)
            .foregroundStyle(LTColors.accentBlue)
        }
    }

    // MARK: - Helpers

    private func isListening(_ viewModel: InterpreterViewModel) -> Bool {
        viewModel.listeningPhase == .listening || viewModel.listeningPhase == .transcribing
    }

    private func listeningButtonLabel(_ viewModel: InterpreterViewModel) -> String {
        switch viewModel.listeningPhase {
        case .requestingPermission: return "请求权限…"
        case .listening: return "正在听对方说…"
        case .transcribing: return "识别中…"
        case .failed: return "重试收音"
        case .idle: return "听对方说"
        }
    }

    /// 快捷回复：本地静态通用短语 + 最近对方回合的 AI 建议合并，最多 3 个。
    private func quickReplySuggestions(_ viewModel: InterpreterViewModel) -> [String] {
        var result: [String] = []
        // 与当前话题相关的建议来自同一次 AI 结果（对方最近回合的 details）。
        if let lastCounterpart = viewModel.turns.last(where: { $0.speaker == .counterpart }),
           let suggestions = lastCounterpart.details?.suggestedReplies {
            result.append(contentsOf: suggestions.prefix(3))
        }
        // 通用短语补充（本地静态模板）。
        let universal = ["好的，我明白了", "请您再说慢一点", "您可以写下来吗？"]
        for phrase in universal where result.count < 3 {
            if !result.contains(phrase) {
                result.append(phrase)
            }
        }
        return Array(result.prefix(3))
    }

    private func endConversation(save: Bool) async {
        await viewModel?.endConversation(save: save, fileDisposition: endFileDisposition)
        dismiss()
    }
}

// MARK: - Listening indicator

/// 收音中的真实电平指示（LinearGradient 高度由真实 RMS 驱动；无数据
/// 时整条不显示 —— 绝不做假声波动画）。
private struct ListeningIndicator: View {
    var level: Float
    var onManualFinish: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: LTSpacing.s) {
            Image(systemName: "waveform")
                .foregroundStyle(LTColors.accentCyan)
            // 电平条：真实 RMS → 高度（10 pt 基线 + 0–20 pt 动态）。
            Capsule()
                .fill(LTColors.accentCyan.opacity(0.7))
                .frame(width: 120, height: 4 + CGFloat(min(0.3, max(0, level))) * 60)
                .animation(reduceMotion ? nil : LTMotion.quick, value: level)
            Spacer()
            Button("结束这句", action: onManualFinish)
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.accentBlue)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("正在收音，电平 \(Int(min(1, max(0, level)) * 100))%")
    }
}

// MARK: - Keyboard dismissal

@MainActor
private func dismissKeyboard() {
    UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
    )
}
