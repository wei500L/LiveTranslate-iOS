import SwiftUI

// 固定底部操作区（第十九轮柜台重构）。
//
// 兼顾"听对方说"和"我来回复"，单手可达：
// - 快捷回复：本地静态短语与 AI 建议视觉区分，点击只填输入框；
// - 中文输入行：系统键盘/系统听写/粘贴，发送键始终可达；
// - 附件行：紧凑收音开关、文件上下文、待问问题入口（键盘弹出时
//   大按钮收敛为图标，避免误触）；
// - 收音主按钮：大命中区；收音中变为"停止"并提供"结束这句"；
//   键盘弹出时整行隐藏（输入优先，紧凑收音开关仍可用）。

struct InterpreterComposer: View {
    let viewModel: InterpreterViewModel
    let onSubmitReply: () -> Void
    let onToggleListening: () -> Void
    /// 连续听（开/暂停/继续）。
    let onToggleContinuousListening: () -> Void
    /// 快速接话：暂停连续听并聚焦中文输入框（由 ViewModel 处理暂停；
    /// 聚焦状态在本视图内）。
    let onBeginReply: () -> Void
    let onOpenDocuments: () -> Void
    let onOpenQuestions: () -> Void
    /// 围绕文件提问（模板 sheet；有选中的文件上下文时显示）。
    let onOpenDocumentQuestionTemplates: () -> Void
    /// 结束本次翻译（确认对话框由页面持有）。
    let onEndRequested: () -> Void
    /// 待问问题数（无事项上下文时入口隐藏）。
    var pendingQuestionCount: Int = 0
    /// 当前是否有选中的文件上下文（chip）。
    var hasDocumentSelection: Bool = false

    @FocusState private var replyFieldFocused: Bool

    private var isListening: Bool {
        viewModel.listeningPhase == .listening || viewModel.listeningPhase == .transcribing
    }

    /// 连续听运行中（未暂停）。
    private var isContinuousActive: Bool {
        viewModel.isContinuousListening && viewModel.continuousPauseReason == nil
    }

    /// 连续模式暂停中（显示醒目"继续听"）。
    private var isContinuousPaused: Bool {
        viewModel.isContinuousListening && viewModel.continuousPauseReason != nil
    }

    private var canSubmit: Bool {
        !viewModel.replyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !viewModel.isTranslatingReply
    }

    var body: some View {
        VStack(spacing: LTSpacing.xs) {
            quickReplyRow
            inputRow
            accessoryRow
            if !replyFieldFocused {
                listeningRow
            }
            if viewModel.micPermissionDenied {
                micPermissionHint
            }
        }
        .padding(.horizontal, LTSpacing.screenPadding)
        .padding(.top, LTSpacing.s)
        .padding(.bottom, LTSpacing.s)
        .background(
            LTColors.backgroundPrimary.opacity(0.92)
                .ignoresSafeArea(edges: .bottom)
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(LTColors.separator)
                .frame(height: 0.5)
        }
        // 快速接话：VM 的聚焦请求（回复按钮 / 暂停行的"回复对方"）。
        .onChange(of: viewModel.replyFocusRequestID) { _, _ in
            replyFieldFocused = true
        }
    }

    // MARK: - 快捷回复（本地短语 vs AI 建议视觉区分）

    @ViewBuilder
    private var quickReplyRow: some View {
        let suggestions = viewModel.quickReplies()
        if !suggestions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: LTSpacing.s) {
                    ForEach(suggestions) { suggestion in
                        Button {
                            // 只填入输入框 —— 不自动翻译、不自动朗读。
                            viewModel.applySuggestion(suggestion.text)
                            replyFieldFocused = true
                        } label: {
                            HStack(spacing: 4) {
                                if suggestion.origin == .aiSuggestion {
                                    Image(systemName: "sparkle")
                                        .font(.caption2)
                                        .foregroundStyle(LTColors.accentBlue)
                                }
                                Text(suggestion.text)
                                    .lineLimit(1)
                            }
                            .font(LTTypography.interpreterStatus)
                            .foregroundStyle(
                                suggestion.origin == .aiSuggestion
                                    ? LTColors.accentBlue
                                    : LTColors.textSecondary
                            )
                            .padding(.horizontal, LTSpacing.m)
                            .padding(.vertical, LTSpacing.xs + 2)
                            .background(
                                Capsule().fill(
                                    suggestion.origin == .aiSuggestion
                                        ? LTColors.accentBlue.opacity(0.12)
                                        : LTColors.surfaceElevated.opacity(0.6)
                                )
                            )
                            .overlay(
                                Capsule().strokeBorder(LTColors.border, lineWidth: 0.5)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            "填入输入框：\(suggestion.text)"
                                + (suggestion.origin == .aiSuggestion ? "，AI 建议" : "，常用短语")
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 中文输入行

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: LTSpacing.s) {
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
            .accessibilityLabel("语气选择，当前 \(viewModel.tone.displayName)")

            TextField("我要回复（中文）", text: Binding(
                get: { viewModel.replyDraft },
                set: { viewModel.replyDraft = $0 }
            ), axis: .vertical)
            .lineLimit(1...4)
            .focused($replyFieldFocused)
            // 快速接话：点输入框聚焦即暂停连续听（session 保活，用户
            // 完成后明确点"继续听"—— 绝不自动恢复）。
            .onChange(of: replyFieldFocused) { _, focused in
                if focused, viewModel.isContinuousListening,
                   viewModel.continuousPauseReason == nil {
                    viewModel.pauseContinuousListening(reason: .user)
                }
            }
            .textFieldStyle(.plain)
            .font(LTTypography.body)
            .padding(LTSpacing.s)
            .background(
                RoundedRectangle(cornerRadius: LTRadius.medium)
                    .fill(LTColors.surfaceElevated.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: LTRadius.medium)
                    .strokeBorder(
                        replyFieldFocused ? LTColors.accentCyan.opacity(0.6) : LTColors.border,
                        lineWidth: replyFieldFocused ? 1 : 0.5
                    )
            )

            Button(action: onSubmitReply) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(canSubmit ? LTColors.accentGreen : LTColors.textTertiary)
                    .frame(minWidth: LTSpacing.minTouchTarget, minHeight: LTSpacing.minTouchTarget)
                    .contentShape(Rectangle())
            }
            .disabled(!canSubmit)
            .accessibilityLabel("生成俄语回复")
        }
    }

    // MARK: - 附件行（紧凑入口，键盘弹出时仍可用）

    private var accessoryRow: some View {
        HStack(spacing: LTSpacing.m) {
            compactMicButton
            documentButton
            if hasDocumentSelection {
                Button {
                    onOpenDocumentQuestionTemplates()
                } label: {
                    Label("围绕这项提问", systemImage: "text.magnifyingglass")
                        .font(LTTypography.interpreterStatus)
                        .foregroundStyle(LTColors.accentBlue)
                }
                .buttonStyle(.plain)
                .frame(minHeight: LTSpacing.minTouchTarget)
                .contentShape(Rectangle())
                .accessibilityLabel("围绕选中的文件提问")
            }
            if pendingQuestionCount > 0 {
                Button {
                    onOpenQuestions()
                } label: {
                    Label("待问 \(pendingQuestionCount)", systemImage: "questionmark.bubble")
                        .font(LTTypography.interpreterStatus)
                        .foregroundStyle(LTColors.accentCyan)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("打开待问问题，共 \(pendingQuestionCount) 个")
            }
            Spacer()
        }
    }

    private var compactMicButton: some View {
        Button(action: compactMicAction) {
            Label(
                compactMicLabel,
                systemImage: compactMicSymbol
            )
            .font(LTTypography.interpreterStatus)
            .foregroundStyle(compactMicTint)
            .frame(minHeight: LTSpacing.minTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(compactMicAccessibility)
    }

    /// 键盘弹出时的紧凑收音开关：连续模式 → 暂停/继续；单句 → 停止/
    /// 开始。
    private var compactMicAction: () -> Void {
        if isContinuousActive {
            return { viewModel.pauseContinuousListening(reason: .user) }
        }
        if isContinuousPaused {
            return { viewModel.resumeContinuousListening() }
        }
        return onToggleListening
    }

    private var compactMicLabel: String {
        if isContinuousActive { return "暂停连续听" }
        if isContinuousPaused { return "继续听" }
        return isListening ? "停止收音" : "收音"
    }

    private var compactMicSymbol: String {
        if isContinuousActive { return "pause.circle.fill" }
        if isContinuousPaused { return "play.circle.fill" }
        return isListening ? "stop.circle.fill" : "mic.circle"
    }

    private var compactMicTint: Color {
        if isContinuousActive { return LTColors.warning }
        if isContinuousPaused { return LTColors.accentGreen }
        return isListening ? LTColors.warning : LTColors.accentCyan
    }

    private var compactMicAccessibility: String {
        if isContinuousActive { return "暂停连续收听" }
        if isContinuousPaused { return "继续连续收听" }
        return isListening ? "停止收音" : "开始收音"
    }

    private var documentButton: some View {
        let count = viewModel.documentContext?.documents.count ?? 0
        return Button {
            onOpenDocuments()
        } label: {
            Label(
                count > 0 ? "文件 ×\(count)" : "现场文件",
                systemImage: "doc.text.magnifyingglass"
            )
            .font(LTTypography.interpreterStatus)
            .foregroundStyle(LTColors.accentBlue)
            .frame(minHeight: LTSpacing.minTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("文件上下文，\(count) 份文件")
    }

    // MARK: - 收音主按钮行（键盘弹出时隐藏）

    private var listeningRow: some View {
        VStack(spacing: LTSpacing.xs) {
            if isContinuousPaused {
                continuousPausedRow
            } else if viewModel.listeningPhase == .listening {
                // 真实电平指示（仅真实音量数据；无数据不显示波形）。
                ListeningIndicator(
                    level: viewModel.audioLevel,
                    isContinuous: viewModel.isContinuousListening,
                    counterpartSpeaking: viewModel.counterpartIsSpeaking,
                    pendingTranslationCount: viewModel.translatingTurnIDs.count,
                    onManualFinish: {
                        Task { await viewModel.finishCurrentUtteranceManually() }
                    },
                    onPauseContinuous: {
                        viewModel.pauseContinuousListening(reason: .user)
                    }
                )
            } else if case .failed(let message) = viewModel.listeningPhase {
                Text(message)
                    .font(LTTypography.interpreterStatus)
                    .foregroundStyle(LTColors.warning)
                    .lineLimit(2)
            }
            HStack(spacing: LTSpacing.m) {
                if isContinuousActive {
                    continuousActiveButtons
                } else if isListening {
                    stopListeningButton
                    if viewModel.turns.contains(where: { !$0.sourceText.isEmpty }) {
                        endButton
                    }
                } else {
                    listeningButton
                    if viewModel.turns.contains(where: { !$0.sourceText.isEmpty }) {
                        endButton
                    }
                }
            }
        }
    }

    /// 连续听运行中：突出"暂停"，保留"结束这句"。
    private var continuousActiveButtons: some View {
        HStack(spacing: LTSpacing.m) {
            Button {
                viewModel.pauseContinuousListening(reason: .user)
            } label: {
                HStack(spacing: LTSpacing.s) {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 22, weight: .semibold))
                    Text("暂停连续听")
                        .font(LTTypography.button)
                }
                .foregroundStyle(Color.black.opacity(0.85))
                .frame(maxWidth: .infinity)
                .padding(.vertical, LTSpacing.m)
                .background(
                    Capsule().fill(
                        LinearGradient(
                            colors: [LTColors.warning.opacity(0.9), LTColors.warning],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                )
            }
            .buttonStyle(LTPrimaryButtonStyle(tint: LTColors.warning))
            .accessibilityLabel("暂停连续收听")
        }
    }

    /// 连续听暂停中：醒目"继续听" + 回到普通入口。
    private var continuousPausedRow: some View {
        VStack(spacing: LTSpacing.xs) {
            HStack(spacing: LTSpacing.s) {
                Image(systemName: "pause.circle")
                    .foregroundStyle(LTColors.textSecondary)
                Text(viewModel.continuousPauseReason?.displayName ?? "已暂停")
                    .font(LTTypography.interpreterStatus)
                    .foregroundStyle(LTColors.textSecondary)
                Spacer()
            }
            HStack(spacing: LTSpacing.m) {
                Button {
                    viewModel.resumeContinuousListening()
                } label: {
                    HStack(spacing: LTSpacing.s) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 22, weight: .semibold))
                        Text("继续听")
                            .font(LTTypography.button)
                    }
                    .foregroundStyle(Color.black.opacity(0.85))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, LTSpacing.m)
                    .background(
                        Capsule().fill(
                            LinearGradient(
                                colors: [LTColors.accentGreen.opacity(0.9), LTColors.accentGreen],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                    )
                }
                .buttonStyle(LTPrimaryButtonStyle(tint: LTColors.accentGreen))
                .accessibilityLabel("继续连续收听")

                // 回复入口（暂停下的主路径：聚焦输入框准备回复）。
                Button(action: onBeginReply) {
                    Text("回复对方")
                        .font(LTTypography.button)
                        .foregroundStyle(LTColors.accentCyan)
                        .padding(.horizontal, LTSpacing.l)
                        .padding(.vertical, LTSpacing.m)
                        .background(Capsule().fill(LTColors.accentCyan.opacity(0.14)))
                        .frame(minHeight: LTSpacing.minTouchTarget)
                }
                .accessibilityLabel("回复对方，聚焦中文输入框")

                if viewModel.turns.contains(where: { !$0.sourceText.isEmpty }) {
                    endButton
                }
            }
        }
    }

    /// 空闲收音入口：听一句 + 连续听。
    private var listeningButton: some View {
        HStack(spacing: LTSpacing.m) {
            Button(action: onToggleListening) {
                HStack(spacing: LTSpacing.s) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 22, weight: .semibold))
                    Text("听一句")
                        .font(LTTypography.button)
                }
                .foregroundStyle(Color.black.opacity(0.85))
                .frame(maxWidth: .infinity)
                .padding(.vertical, LTSpacing.m)
                .background(
                    Capsule().fill(
                        LinearGradient(
                            colors: [LTColors.accentCyan.opacity(0.9), LTColors.accentCyan],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                )
            }
            .buttonStyle(LTPrimaryButtonStyle(tint: LTColors.accentCyan))
            .accessibilityLabel("听对方说一句")
            .disabled(captureUnavailable)

            Button(action: onToggleContinuousListening) {
                HStack(spacing: LTSpacing.s) {
                    Image(systemName: "ear.fill")
                        .font(.system(size: 22, weight: .semibold))
                    Text("连续听")
                        .font(LTTypography.button)
                }
                .foregroundStyle(Color.black.opacity(0.85))
                .frame(maxWidth: .infinity)
                .padding(.vertical, LTSpacing.m)
                .background(
                    Capsule().fill(
                        LinearGradient(
                            colors: [LTColors.accentGreen.opacity(0.9), LTColors.accentGreen],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                )
            }
            .buttonStyle(LTPrimaryButtonStyle(tint: LTColors.accentGreen))
            .accessibilityLabel("开启连续收听")
            .disabled(captureUnavailable)
        }
    }

    /// 收音入口禁用条件（权限拒绝 / ASR 未装 / 课堂占用）。
    private var captureUnavailable: Bool {
        viewModel.micPermissionDenied
            || !viewModel.asrModelInstalled
            || viewModel.classroomActive
            || viewModel.listeningPhase == .requestingPermission
    }

    private var endButton: some View {
        Button(action: onEndRequested) {
            Text("结束")
                .font(LTTypography.cardTitle)
                .foregroundStyle(LTColors.textSecondary)
                .padding(.horizontal, LTSpacing.l)
                .padding(.vertical, LTSpacing.m)
                .background(Capsule().fill(LTColors.textSecondary.opacity(0.12)))
                .frame(minHeight: LTSpacing.minTouchTarget)
        }
        .accessibilityLabel("结束本次翻译")
    }

    /// 单句模式收音中的主按钮（停止）。
    private var stopListeningButton: some View {
        Button(action: onToggleListening) {
            HStack(spacing: LTSpacing.s) {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                Text("停止收音")
                    .font(LTTypography.button)
            }
            .foregroundStyle(Color.black.opacity(0.85))
            .frame(maxWidth: .infinity)
            .padding(.vertical, LTSpacing.m)
            .background(
                Capsule().fill(
                    LinearGradient(
                        colors: [LTColors.warning.opacity(0.9), LTColors.warning],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
            )
        }
        .buttonStyle(LTPrimaryButtonStyle(tint: LTColors.warning))
        .accessibilityLabel("停止收音")
    }

    private var micPermissionHint: some View {
        HStack(spacing: LTSpacing.s) {
            Image(systemName: "mic.slash")
                .foregroundStyle(LTColors.warning)
            Text("麦克风未授权，文本输入翻译仍可用")
                .font(LTTypography.interpreterStatus)
                .foregroundStyle(LTColors.textSecondary)
            Spacer()
            Button("去设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(LTTypography.interpreterStatus)
            .foregroundStyle(LTColors.accentBlue)
        }
    }
}

// MARK: - Listening indicator

/// 收音中的真实电平指示（LinearGradient 高度由真实 RMS 驱动；无数据
/// 时整条不显示 —— 绝不做假声波动画）。
struct ListeningIndicator: View {
    var level: Float
    /// 连续模式（显示"对方正在说话"与翻译积压计数）。
    var isContinuous: Bool = false
    var counterpartSpeaking: Bool = false
    var pendingTranslationCount: Int = 0
    var onManualFinish: () -> Void
    var onPauseContinuous: () -> Void = {}
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
            if isContinuous {
                // 真实 VAD 派生状态：对方正在说话 / 识别上一句。
                Text(counterpartSpeaking ? "对方正在说" : "连续听中")
                    .font(LTTypography.interpreterStatus)
                    .foregroundStyle(LTColors.textSecondary)
                    .lineLimit(1)
                if pendingTranslationCount > 0 {
                    Text("翻译中 ×\(pendingTranslationCount)")
                        .font(LTTypography.interpreterStatus)
                        .foregroundStyle(LTColors.accentBlue)
                        .lineLimit(1)
                }
                Spacer()
                Button("结束这句", action: onManualFinish)
                    .font(LTTypography.interpreterStatus)
                    .foregroundStyle(LTColors.accentBlue)
                    .frame(minHeight: LTSpacing.minTouchTarget)
                    .contentShape(Rectangle())
                Button(action: onPauseContinuous) {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(LTColors.warning)
                        .frame(minWidth: LTSpacing.minTouchTarget, minHeight: LTSpacing.minTouchTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("暂停连续收听")
            } else {
                Spacer()
                Button("结束这句", action: onManualFinish)
                    .font(LTTypography.interpreterStatus)
                    .foregroundStyle(LTColors.accentBlue)
                    .frame(minHeight: LTSpacing.minTouchTarget)
                    .contentShape(Rectangle())
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = ["正在收音，电平 \(Int(min(1, max(0, level)) * 100))%"]
        if isContinuous {
            parts.append(counterpartSpeaking ? "对方正在说话" : "连续收听中")
            if pendingTranslationCount > 0 {
                parts.append("\(pendingTranslationCount) 句等待翻译")
            }
        }
        return parts.joined(separator: "，")
    }
}
