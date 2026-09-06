import SwiftUI
import UIKit

// 给对方看模式（第十九轮柜台重构）—— 受控的柜台展示。
//
// - 全屏只显示锁定的那一条俄语（普通俄语优先 —— 对方是俄语母语者，
//   重音标注是给学习者看的，切换项提供）；
// - 大字号（≥44pt 基线，随 Dynamic Type 缩放），长文本滚动；
// - 底部小号中文回译供本人核对（可一键隐藏）；
// - 可选"柜台对向展示"：俄语区旋转 180°，手机平放在柜台上让对面阅
//   读；用户一侧（底边）保留中文核对与控件 —— 旋转只作用于俄语文
//   本，不旋转系统返回手势与按钮；VoiceOver 开启时不提供旋转布局
//   （普通大字模式即替代布局）；
// - 不自动朗读、不自动调节系统亮度；进入前停掉正在播放的旧句；
// - 绝不显示：历史对话、ErrandCase 标题、文件名/页码、翻译错误、
//   模型名、账号信息。
struct InterpreterShowModeView: View {
    let turn: InterpreterTurn
    let isSpeaking: Bool
    let onSpeak: () -> Void
    let onStopSpeak: () -> Void
    let onDismiss: () -> Void
    /// 初始即为柜台对向展示（Debug UI-demo 截图注入；生产恒为 false）。
    var initiallyFacing: Bool = false

    /// 普通俄语优先（给对方看）；带重音是核对切换项。
    @State private var showStressed = false
    /// 中文回译默认显示（本人核对），可一键隐藏。
    @State private var showBackTranslation = true
    /// 柜台对向展示（俄语区旋转 180°）。
    @State private var facingMode = false
    /// 大字号基线（随 Dynamic Type 缩放）。
    @ScaledMetric(relativeTo: .largeTitle) private var russianBaseSize: CGFloat = 48

    init(
        turn: InterpreterTurn,
        isSpeaking: Bool,
        onSpeak: @escaping () -> Void,
        onStopSpeak: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        initiallyFacing: Bool = false
    ) {
        self.turn = turn
        self.isSpeaking = isSpeaking
        self.onSpeak = onSpeak
        self.onStopSpeak = onStopSpeak
        self.onDismiss = onDismiss
        self.initiallyFacing = initiallyFacing
        #if DEBUG
        // UI-demo 注入（--demo-interpreter-state facing）：Debug 构建的
        // 截图路径；Release 恒为 false。
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--demo-interpreter-state"),
           index + 1 < args.count, args[index + 1] == "facing" {
            _facingMode = State(initialValue: true)
        } else {
            _facingMode = State(initialValue: initiallyFacing)
        }
        #else
        _facingMode = State(initialValue: initiallyFacing)
        #endif
    }

    private var displayText: String {
        if showStressed, !turn.stressedRussian.isEmpty {
            return turn.stressedRussian
        }
        return turn.plainRussian
    }

    private var voiceOverActive: Bool {
        UIAccessibility.isVoiceOverRunning
    }

    var body: some View {
        ZStack {
            LTColors.backgroundPrimary.ignoresSafeArea()
                .screenCaptureMask()
            VStack(spacing: LTSpacing.l) {
                if facingMode {
                    // 对向展示：俄语区旋转 180°（对面读），占主体；
                    // 中文核对与控件留在用户一侧（底边，不旋转）。
                    Spacer(minLength: LTSpacing.s)
                    russianText
                        .rotationEffect(.degrees(180))
                    Spacer(minLength: LTSpacing.m)
                } else {
                    Spacer(minLength: LTSpacing.s)
                    russianText
                    Spacer(minLength: LTSpacing.m)
                }
                userPanel
            }
            .padding(.horizontal, LTSpacing.screenPadding)
            .padding(.bottom, LTSpacing.l)
        }
        .onAppear {
            // 进入前停掉正在播放的旧句（不自动恢复 —— 用户手动触发）。
            onStopSpeak()
        }
        .onDisappear {
            onStopSpeak()
        }
    }

    // MARK: - 俄语主阅读区

    /// 大字号俄语：长文本滚动，字号不因长度缩到无法阅读（只在
    /// Dynamic Type 大字号下轻度收缩兜底单行溢出）。
    private var russianText: some View {
        ScrollView {
            Text(displayText)
                .font(.system(size: russianBaseSize, weight: .semibold, design: .rounded))
                .foregroundStyle(LTColors.textPrimary)
                .multilineTextAlignment(.center)
                .lineSpacing(russianBaseSize * 0.12)
                .padding(.horizontal, LTSpacing.l)
                .padding(.vertical, LTSpacing.l)
                .minimumScaleFactor(0.7)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity)
        }
        .accessibilityLabel(displayText)
        .accessibilityHint(showStressed ? "当前显示带重音俄语" : "当前显示普通俄语")
    }

    // MARK: - 用户一侧（控件不随对向展示旋转）

    private var userPanel: some View {
        VStack(spacing: LTSpacing.s) {
            backTranslationRow
            facingToggleRow
            controlRow
        }
    }

    // MARK: - 中文回译核对（小字、可隐藏）

    @ViewBuilder
    private var backTranslationRow: some View {
        if !turn.backTranslation.isEmpty {
            HStack(spacing: LTSpacing.s) {
                if showBackTranslation {
                    Text(turn.backTranslation)
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textTertiary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                Button {
                    showBackTranslation.toggle()
                } label: {
                    Label(
                        showBackTranslation ? "隐藏回译" : "查看回译",
                        systemImage: showBackTranslation ? "eye.slash" : "eye"
                    )
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textSecondary)
                    .frame(minHeight: LTSpacing.minTouchTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showBackTranslation ? "隐藏中文回译" : "查看中文回译")
            }
        }
    }

    // MARK: - 切换行（普通/重音 + 对向）

    private var facingToggleRow: some View {
        HStack(spacing: LTSpacing.m) {
            ToggleStressButton(
                isStressed: $showStressed,
                stressedAvailable: !turn.stressedRussian.isEmpty
            )
            facingToggleButton
            Spacer()
        }
    }

    private var facingToggleButton: some View {
        Button {
            facingMode.toggle()
        } label: {
            Label(
                facingMode ? "退出对向" : "对向展示",
                systemImage: facingMode ? "arrow.uturn.down.circle" : "arrow.uturn.up.circle"
            )
            .font(LTTypography.caption)
            .foregroundStyle(LTColors.accentCyan)
            .padding(.horizontal, LTSpacing.m)
            .padding(.vertical, LTSpacing.xs)
            .background(Capsule().fill(LTColors.accentCyan.opacity(0.12)))
            .frame(minHeight: LTSpacing.minTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // VoiceOver：旋转布局对辅助阅读不友好 —— 普通大字模式即替代
        // 布局，不提供旋转。
        .disabled(voiceOverActive)
        .accessibilityLabel(facingMode ? "退出柜台对向展示" : "切换柜台对向展示，俄语旋转一百八十度方便对面阅读")
        .accessibilityHint(voiceOverActive ? "VoiceOver 开启时不可用" : "")
    }

    // MARK: - 操作行（稳定区域：朗读 / 复制 / 完成）

    private var controlRow: some View {
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
                    .frame(minWidth: LTSpacing.minTouchTarget, minHeight: LTSpacing.minTouchTarget)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(isSpeaking ? "停止朗读" : "朗读俄语")

            Button {
                ClipboardService.shared.copySensitive(turn.plainRussian)
            } label: {
                Image(systemName: "doc.on.doc.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(LTColors.textSecondary)
                    .frame(minWidth: LTSpacing.minTouchTarget, minHeight: LTSpacing.minTouchTarget)
                    .contentShape(Rectangle())
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
                    .frame(minHeight: LTSpacing.minTouchTarget)
            }
            .accessibilityLabel("关闭展示")
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
                .frame(minHeight: LTSpacing.minTouchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!stressedAvailable)
        .accessibilityLabel(isStressed ? "切换到普通俄语" : "切换到带重音俄语")
    }
}
