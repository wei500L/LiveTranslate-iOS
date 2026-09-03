import SwiftUI

/// Compact status chip used across live, records, model management and
/// settings. Restyled to the design-system tokens but kept under its
/// original name/signature so existing screens keep compiling.
struct StatusChip: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(LTTypography.statusChip)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(tint.opacity(0.16), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 0.5))
            .foregroundStyle(tint)
            .lineLimit(1)
    }
}

/// Read-only label/value row used in forms and detail sections.
struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

/// URL wrapper so `.sheet(item:)` can present the share sheet.
/// File-scope (not nested) so BenchmarkScreen can use it too.
/// `companions` carry extra files of one share action (the 课堂资料包:
/// document + image files share together).
struct SharedFile: Identifiable {
    let id = UUID()
    let url: URL
    var companions: [URL] = []

    init(url: URL, companions: [URL] = []) {
        self.url = url
        self.companions = companions
    }

    /// All URLs of this share (document first).
    var allURLs: [URL] { [url] + companions }
}

/// Rolling waveform of recent input levels. Drawn from a bounded ring of
/// RMS values pushed by the capture service (~10 Hz); rendering cost is
/// deliberately trivial (single Canvas, no timeline animation) so it never
/// competes with ASR. Redraws only when real audio data arrives — silent
/// when the session is paused or backgrounded.
struct WaveformView: View {
    /// Newest last, values in [0, 1].
    let levels: [Float]
    var tint: Color = LTColors.accentCyan
    /// Number of bars drawn; the trailing `levels` window fills it.
    var barCount: Int = 48

    var body: some View {
        Canvas { context, size in
            guard !levels.isEmpty else {
                // Flat idle line so the slot keeps its geometry when quiet.
                let idle = CGRect(x: 0, y: size.height / 2 - 0.75, width: size.width, height: 1.5)
                context.fill(Path(roundedRect: idle, cornerRadius: 0.75),
                             with: .color(LTColors.textTertiary.opacity(0.4)))
                return
            }
            let step = size.width / CGFloat(barCount)
            let barWidth = max(1.5, step - 2)
            let visible = levels.suffix(barCount)
            let startIdx = barCount - visible.count
            for (i, level) in visible.enumerated() {
                let h = max(2, CGFloat(level) * size.height)
                let rect = CGRect(
                    x: CGFloat(startIdx + i) * step + 1,
                    y: (size.height - h) / 2,
                    width: barWidth,
                    height: h
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: barWidth / 2),
                    with: .color(tint.opacity(0.85))
                )
            }
        }
        .accessibilityLabel(Text("Input level"))
    }
}

// MARK: - Pipeline phase presentation

extension PipelinePhase {
    /// User-facing labels — plain language, no engine/quantization jargon.
    var localizedLabel: String {
        switch self {
        case .idle: return String(localized: "待开始")
        case .modelNotInstalled: return String(localized: "语言资源未准备好")
        case .downloading: return String(localized: "正在下载语言资源")
        case .verifying: return String(localized: "正在校验语言资源")
        case .compilingCoreML: return String(localized: "正在准备语言资源")
        case .loadingModel: return String(localized: "正在准备语言资源")
        case .warmingUp: return String(localized: "正在准备语言资源")
        case .ready: return String(localized: "已就绪")
        case .listening: return String(localized: "正在监听俄语")
        case .speechDetected: return String(localized: "检测到语音")
        case .transcribing: return String(localized: "正在识别")
        case .translating: return String(localized: "正在翻译")
        case .paused: return String(localized: "已暂停")
        case .micInterrupted: return String(localized: "麦克风中断")
        case .networkOffline: return String(localized: "翻译服务不可用 · 转写继续")
        case .backendError: return String(localized: "转写引擎出错")
        case .diskSpaceLow: return String(localized: "磁盘空间不足")
        case .finished: return String(localized: "课堂已结束")
        }
    }

    var chipColor: Color {
        switch self {
        case .idle, .ready: return LTColors.textSecondary
        case .modelNotInstalled: return LTColors.warning
        case .downloading, .verifying, .compilingCoreML, .loadingModel, .warmingUp:
            return LTColors.accentBlue
        case .listening, .speechDetected: return LTColors.accentGreen
        case .transcribing, .translating: return LTColors.accentCyan
        case .paused: return LTColors.warning
        case .micInterrupted, .networkOffline, .backendError, .diskSpaceLow:
            return LTColors.destructive
        case .finished: return LTColors.accentGreen
        }
    }

    /// True while a session is being set up (engine loading/warm-up).
    var isPreparing: Bool {
        switch self {
        case .loadingModel, .warmingUp, .downloading, .verifying, .compilingCoreML:
            return true
        default:
            return false
        }
    }
}

extension TranslationStatus {
    var localizedLabel: String {
        switch self {
        case .pending: return String(localized: "正在翻译")
        case .completed: return String(localized: "翻译完成")
        case .failed: return String(localized: "翻译失败")
        case .notConfigured: return String(localized: "翻译服务未配置")
        case .skipped: return String(localized: "实时翻译已关闭")
        }
    }
}
