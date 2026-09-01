import SwiftUI

/// Compact status chip used across the Live screen and model management.
struct StatusChip: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
            .lineLimit(1)
    }
}

extension PipelinePhase {
    var chipColor: Color {
        switch self {
        case .idle, .ready: return .secondary
        case .modelNotInstalled: return .orange
        case .downloading, .verifying, .compilingCoreML, .loadingModel, .warmingUp:
            return .blue
        case .listening, .speechDetected: return .green
        case .transcribing, .translating: return .indigo
        case .paused: return .yellow
        case .micInterrupted, .networkOffline, .backendError, .diskSpaceLow:
            return .red
        case .finished: return .mint
        }
    }

    var localizedLabel: String {
        switch self {
        case .idle: return String(localized: "Idle")
        case .modelNotInstalled: return String(localized: "Model not installed")
        case .downloading: return String(localized: "Downloading")
        case .verifying: return String(localized: "Verifying")
        case .compilingCoreML: return String(localized: "Compiling Core ML")
        case .loadingModel: return String(localized: "Loading model")
        case .warmingUp: return String(localized: "Warming up")
        case .ready: return String(localized: "Ready")
        case .listening: return String(localized: "Listening")
        case .speechDetected: return String(localized: "Speech detected")
        case .transcribing: return String(localized: "Transcribing")
        case .translating: return String(localized: "Translating")
        case .paused: return String(localized: "Paused")
        case .micInterrupted: return String(localized: "Microphone interrupted")
        case .networkOffline: return String(localized: "Offline — ASR continues")
        case .backendError: return String(localized: "Backend error")
        case .diskSpaceLow: return String(localized: "Not enough disk space")
        case .finished: return String(localized: "Finished")
        }
    }
}

/// Rolling waveform of recent input levels. Drawn from a bounded ring of RMS
/// values pushed by the capture service; rendering cost is deliberately
/// trivial so it never competes with ASR.
struct WaveformView: View {
    /// Newest last, values in [0, 1].
    let levels: [Float]

    var body: some View {
        Canvas { context, size in
            guard !levels.isEmpty else { return }
            let barWidth = max(1.5, size.width / 64 - 2)
            let step = size.width / 64
            let visible = levels.suffix(64)
            let startIdx = 64 - visible.count
            for (i, level) in visible.enumerated() {
                let h = max(2, CGFloat(level) * size.height)
                let rect = CGRect(
                    x: CGFloat(startIdx + i) * step + 1,
                    y: (size.height - h) / 2,
                    width: barWidth,
                    height: h
                )
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                             with: .color(.accentColor.opacity(0.8)))
            }
        }
        .accessibilityLabel(Text("Input level"))
    }
}

/// One bilingual subtitle card: Russian on top, Chinese below, translation
/// state on the trailing edge. Copy actions on long-press context menu.
struct SubtitleCard: View {
    let entry: SubtitleEntryViewModel
    var onRetryTranslation: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(timestamp)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer()
                translationBadge
            }
            Text(entry.originalText)
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            if let translated = entry.translatedText, !translated.isEmpty {
                Text(translated)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .contextMenu {
            Button(String(localized: "Copy Russian")) {
                UIPasteboard.general.string = entry.originalText
            }
            if let translated = entry.translatedText {
                Button(String(localized: "Copy Chinese")) {
                    UIPasteboard.general.string = translated
                }
                Button(String(localized: "Copy both")) {
                    UIPasteboard.general.string = "\(entry.originalText)\n\(translated)"
                }
            }
            if entry.translationStatus == .failed, onRetryTranslation != nil {
                Button(String(localized: "Retry translation")) { onRetryTranslation?() }
            }
        }
    }

    private var timestamp: String {
        let t = entry.startOffset
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%02d:%02d", m, s)
    }

    @ViewBuilder
    private var translationBadge: some View {
        switch entry.translationStatus {
        case .pending:
            Image(systemName: "hourglass")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case .completed:
            EmptyView()
        case .failed:
            Button(String(localized: "Retry"), action: { onRetryTranslation?() })
                .font(.caption2)
                .buttonStyle(.bordered)
                .controlSize(.mini)
        case .notConfigured:
            StatusChip(text: String(localized: "No translation API"), tint: .orange)
        }
    }
}

/// Value type the subtitle list binds to (populated by the coordinator).
struct SubtitleEntryViewModel: Identifiable, Equatable, Sendable {
    let sequenceID: Int
    let startOffset: TimeInterval
    var originalText: String
    var translatedText: String?
    var translationStatus: TranslationStatus

    var id: Int { sequenceID }
}
