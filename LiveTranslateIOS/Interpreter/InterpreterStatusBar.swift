import SwiftUI

// 紧凑状态栏（第十九轮柜台重构）。
//
// 持续可见但不抢内容：场景（可点击切换）、收音状态、本地 ASR 资源、
// 翻译服务可用性、朗读状态。模型名、host、延迟诊断不常驻 —— 详细
// 诊断留在既有设置页。状态不只靠颜色（SF Symbol + 文字标签）。

struct InterpreterStatusBar: View {
    let viewModel: InterpreterViewModel
    let onOpenScenePicker: () -> Void

    var body: some View {
        HStack(spacing: LTSpacing.s) {
            sceneButton
            Spacer(minLength: LTSpacing.xs)
            micStatus
            translationStatus
            speakingStatus
        }
        .font(LTTypography.statusChip)
        .padding(.horizontal, LTSpacing.m)
        .padding(.vertical, LTSpacing.xs + 2)
        .background(
            Rectangle().fill(LTColors.surfaceElevated.opacity(0.35))
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(LTColors.separator)
                .frame(height: 0.5)
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - 场景（点击切换）

    private var sceneButton: some View {
        Button(action: onOpenScenePicker) {
            HStack(spacing: LTSpacing.xs) {
                Image(systemName: viewModel.scene.symbol)
                    .font(.caption)
                    .foregroundStyle(LTColors.accentCyan)
                Text(viewModel.scene.displayName)
                    .foregroundStyle(LTColors.textPrimary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("当前场景 \(viewModel.scene.displayName)，点击切换")
    }

    // MARK: - 收音状态

    private var micStatus: some View {
        let (symbol, text, tint) = micStatusValues
        return HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(tint)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("收音状态：\(text)")
    }

    private var micStatusValues: (symbol: String, text: String, tint: Color) {
        if viewModel.micPermissionDenied {
            return ("mic.slash", "麦克风未授权", LTColors.warning)
        }
        if viewModel.classroomActive {
            return ("person.2.wave.2", "课堂占用", LTColors.warning)
        }
        // 连续模式优先展示（暂停/中断是用户最需要知道的状态）。
        if viewModel.isContinuousListening {
            if let reason = viewModel.continuousPauseReason {
                return ("pause.circle", reason.displayName, LTColors.textSecondary)
            }
            if viewModel.captureInterrupted {
                return ("exclamationmark.triangle", "音频中断", LTColors.warning)
            }
            if viewModel.listeningPhase == .transcribing {
                return ("text.bubble", "识别中", LTColors.accentCyan)
            }
            return (
                "waveform",
                viewModel.counterpartIsSpeaking ? "对方在说" : "连续听中",
                LTColors.accentCyan
            )
        }
        switch viewModel.listeningPhase {
        case .idle:
            return ("mic", "未收音", LTColors.textTertiary)
        case .requestingPermission:
            return ("mic.badge.questionmark", "请求权限", LTColors.textSecondary)
        case .listening:
            return ("waveform", "正在听", LTColors.accentCyan)
        case .transcribing:
            return ("text.bubble", "识别中", LTColors.accentCyan)
        case .failed:
            return ("exclamationmark.triangle", "收音失败", LTColors.warning)
        }
    }

    // MARK: - 本地 ASR 与翻译服务

    private var translationStatus: some View {
        HStack(spacing: 4) {
            if !viewModel.asrModelInstalled {
                Image(systemName: "arrow.down.circle")
                Text("识别资源未安装")
                    .lineLimit(1)
            } else if !viewModel.isModelConfigured {
                Image(systemName: "wifi.slash")
                Text("翻译未配置")
                    .lineLimit(1)
            } else {
                Image(systemName: "checkmark.circle")
                Text("翻译就绪")
                    .lineLimit(1)
            }
        }
        .foregroundStyle(
            viewModel.asrModelInstalled && viewModel.isModelConfigured
                ? LTColors.textTertiary
                : LTColors.warning
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            !viewModel.asrModelInstalled
                ? "语音识别资源未安装"
                : (!viewModel.isModelConfigured ? "翻译服务未配置" : "翻译服务就绪")
        )
    }

    // MARK: - 朗读状态

    @ViewBuilder
    private var speakingStatus: some View {
        if viewModel.speechIsSpeaking {
            HStack(spacing: 4) {
                Image(systemName: "speaker.wave.2")
                Text("朗读中")
                    .lineLimit(1)
            }
            .foregroundStyle(LTColors.accentBlue)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("正在朗读俄语")
        }
    }
}
