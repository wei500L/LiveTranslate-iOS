import SwiftUI

/// 给对方看模式 —— 全屏展示俄语。
///
/// - 默认优先显示带重音版本，可切换普通俄语；
/// - 字号足够大，长文本滚动；
/// - 保留一行中文回译供用户核对，但不抢占对方阅读区域（底部小字）；
/// - 横竖屏自然适配（系统自动）；
/// - 提供关闭、复制、朗读；不自动朗读（用户手动触发）；
/// - 不自动提高系统亮度；不在本页暴露历史对话、API 错误或模型名称。
struct InterpreterShowModeView: View {
    let turn: InterpreterTurn
    var isSpeaking: Bool
    var onSpeak: () -> Void
    var onStopSpeak: () -> Void
    var onDismiss: () -> Void

    @State private var showStressed = true
    @State private var showBackTranslation = false

    private var displayText: String {
        if showStressed, !turn.stressedRussian.isEmpty {
            return turn.stressedRussian
        }
        return turn.plainRussian
    }

    var body: some View {
        ZStack {
            LTColors.backgroundPrimary.ignoresSafeArea()
            VStack(spacing: LTSpacing.l) {
                // 主阅读区：大字号俄语，长文本滚动。
                ScrollView {
                    Text(displayText)
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .foregroundStyle(LTColors.textPrimary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, LTSpacing.l)
                        .padding(.top, LTSpacing.xl)
                        .minimumScaleFactor(0.5)
                        .textSelection(.enabled)
                }

                // 重音切换 + 回译核对（小字，不抢占阅读区域）。
                VStack(spacing: LTSpacing.s) {
                    HStack(spacing: LTSpacing.m) {
                        ToggleStressButton(
                            isStressed: $showStressed,
                            stressedAvailable: !turn.stressedRussian.isEmpty
                        )
                        if !turn.backTranslation.isEmpty {
                            Button {
                                showBackTranslation.toggle()
                            } label: {
                                Label(
                                    showBackTranslation ? "隐藏回译" : "查看回译",
                                    systemImage: showBackTranslation ? "eye.slash" : "eye"
                                )
                                .font(LTTypography.caption)
                                .foregroundStyle(LTColors.textSecondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if showBackTranslation, !turn.backTranslation.isEmpty {
                        Text(turn.backTranslation)
                            .font(LTTypography.caption)
                            .foregroundStyle(LTColors.textTertiary)
                            .padding(.horizontal, LTSpacing.l)
                            .textSelection(.enabled)
                    }
                }
                .padding(.bottom, LTSpacing.s)

                // 操作行：朗读 / 复制 / 关闭。
                HStack(spacing: LTSpacing.l) {
                    Button {
                        if isSpeaking {
                            onStopSpeak()
                        } else {
                            onSpeak()
                        }
                    } label: {
                        Image(systemName: isSpeaking ? "stop.circle.fill" : "speaker.wave.2.circle.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(LTColors.accentBlue)
                    }
                    .accessibilityLabel(isSpeaking ? "停止朗读" : "朗读俄语")

                    Button {
                        UIPasteboard.general.string = turn.plainRussian
                    } label: {
                        Image(systemName: "doc.on.doc.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(LTColors.textSecondary)
                    }
                    .accessibilityLabel("复制俄语")

                    Spacer()

                    Button(action: onDismiss) {
                        Text("完成")
                            .font(LTTypography.button)
                            .foregroundStyle(Color.black.opacity(0.85))
                            .padding(.horizontal, LTSpacing.xl)
                            .padding(.vertical, LTSpacing.s + 2)
                            .background(Capsule().fill(LTColors.accentGreen))
                    }
                    .accessibilityLabel("关闭展示")
                }
                .padding(.horizontal, LTSpacing.screenPadding)
                .padding(.bottom, LTSpacing.l)
            }
        }
        // 朗读使用普通俄语（InterpreterSpeechService 内部去重音）。
        .onDisappear {
            onStopSpeak()
        }
    }
}

/// 重音/普通切换。
private struct ToggleStressButton: View {
    @Binding var isStressed: Bool
    var stressedAvailable: Bool

    var body: some View {
        Button {
            guard stressedAvailable else { return }
            isStressed.toggle()
        } label: {
            Text(isStressed ? "重音" : "普通")
                .font(LTTypography.statusChip)
                .foregroundStyle(stressedAvailable ? LTColors.accentCyan : LTColors.textTertiary)
                .padding(.horizontal, LTSpacing.m)
                .padding(.vertical, LTSpacing.xs)
                .background(Capsule().fill(LTColors.accentCyan.opacity(stressedAvailable ? 0.12 : 0.04)))
        }
        .buttonStyle(.plain)
        .disabled(!stressedAvailable)
        .accessibilityLabel(isStressed ? "切换到普通俄语" : "切换到带重音俄语")
    }
}
