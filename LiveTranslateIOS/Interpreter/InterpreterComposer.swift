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
    let onOpenDocuments: () -> Void
    let onOpenQuestions: () -> Void
    /// 结束本次翻译（确认对话框由页面持有）。
    let onEndRequested: () -> Void
    /// 待问问题数（无事项上下文时入口隐藏）。
    var pendingQuestionCount: Int = 0

    @FocusState private var replyFieldFocused: Bool

    private var isListening: Bool {
        viewModel.listeningPhase == .listening || viewModel.listeningPhase == .transcribing
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
        Button(action: onToggleListening) {
            Label(
                isListening ? "停止收音" : "收音",
                systemImage: isListening ? "stop.circle.fill" : "mic.circle"
            )
            .font(LTTypography.interpreterStatus)
            .foregroundStyle(isListening ? LTColors.warning : LTColors.accentCyan)
            .frame(minHeight: LTSpacing.minTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isListening ? "停止收音" : "开始收音")
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
            if viewModel.listeningPhase == .listening {
                // 真实电平指示（仅真实音量数据；无数据不显示波形）。
                ListeningIndicator(level: viewModel.audioLevel) {
                    Task { await viewModel.finishCurrentUtteranceManually() }
                }
            } else if case .failed(let message) = viewModel.listeningPhase {
                Text(message)
                    .font(LTTypography.interpreterStatus)
                    .foregroundStyle(LTColors.warning)
                    .lineLimit(2)
            }
            HStack(spacing: LTSpacing.m) {
                Button(action: onToggleListening) {
                    HStack(spacing: LTSpacing.s) {
                        Image(systemName: isListening ? "stop.circle.fill" : "ear.fill")
                            .font(.system(size: 22, weight: .semibold))
                        Text(listeningButtonLabel)
                            .font(LTTypography.button)
                    }
                    .foregroundStyle(Color.black.opacity(0.85))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, LTSpacing.m)
                    .background(
                        Capsule().fill(
                            LinearGradient(
                                colors: isListening
                                    ? [LTColors.warning.opacity(0.9), LTColors.warning]
                                    : [LTColors.accentCyan.opacity(0.9), LTColors.accentCyan],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                    )
                }
                .buttonStyle(LTPrimaryButtonStyle(tint: LTColors.accentCyan))
                .accessibilityLabel(listeningButtonLabel)

                if viewModel.turns.contains(where: { !$0.sourceText.isEmpty }) {
                    endButton
                }
            }
        }
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

    private var listeningButtonLabel: String {
        switch viewModel.listeningPhase {
        case .requestingPermission: return "请求权限…"
        case .listening: return "正在听对方说…"
        case .transcribing: return "识别中…"
        case .failed: return "重试收音"
        case .idle: return "听对方说"
        }
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
                .font(LTTypography.interpreterStatus)
                .foregroundStyle(LTColors.accentBlue)
                .frame(minHeight: LTSpacing.minTouchTarget)
                .contentShape(Rectangle())
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("正在收音，电平 \(Int(min(1, max(0, level)) * 100))%")
    }
}
