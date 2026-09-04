import SwiftUI
import WidgetKit

// Live Activity rendering for the classroom. The lock screen answers
// "是否仍在记录、翻译是否正常、已记录多久"; Dynamic Island stays minimal —
// status icon, system-driven timer, and in the expanded region the
// controls. No model names, no waveforms, no full transcripts; the single
// latest Chinese line shows only when the user's privacy choice allows
// (the app already filtered it into the content state).

struct ClassroomLiveActivityView: View {
    let context: ActivityViewContext<ClassroomSessionActivityAttributes>

    var body: some View {
        lockScreenView
    }

    // MARK: Lock screen / banner

    private var lockScreenView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                statusIcon
                VStack(alignment: .leading, spacing: 1) {
                    Text(titleText)
                        .font(.headline)
                        .lineLimit(1)
                    Text(statusLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                timerText
                    .font(.title3.weight(.bold).monospacedDigit())
                    .frame(maxWidth: 88, alignment: .trailing)
            }

            // One restrained Chinese line, only when the app included it.
            if !context.state.latestChinese.isEmpty {
                Text(context.state.latestChinese)
                    .font(.subheadline)
                    .lineLimit(2, reservesSpace: false)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                healthLabel
                Spacer()
                // Controls: pause/resume act through the command queue on
                // the real coordinator; end opens the app's existing
                // confirmation dialog (never destroys on its own).
                HStack(spacing: 6) {
                    pauseResumeButton
                    endButton
                }
            }
        }
        .activityBackgroundTint(Color.black.opacity(0.55))
        .activitySystemActionForegroundColor(Color.white)
    }

    private var statusIcon: some View {
        let pair = WidgetStatus.classroom(context.state.phase)
        return Image(systemName: pair.symbol)
            .font(.body.weight(.semibold))
            .foregroundStyle(context.state.phase == .recording ? WidgetPalette.accent : .white)
            .symbolRenderingMode(.hierarchical)
    }

    private var titleText: String {
        context.attributes.title
    }

    private var statusLabel: String {
        var parts = [WidgetStatus.classroom(context.state.phase).label]
        if context.state.phase == .recording {
            parts.append(context.state.isTranscribing ? "转录正常" : "转录已中断")
            parts.append(context.state.translation.label)
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var timerText: some View {
        if context.state.phase == .paused || context.state.phase == .ended
            || context.state.phase == .failed {
            Text(WidgetFormat.clockLabel(seconds: context.state.accumulatedSeconds))
        } else if let activeSince = context.state.activeSince {
            // System-driven live count while the classroom records.
            Text(timerInterval: activeSince..., countsDown: false)
        } else {
            Text(WidgetFormat.clockLabel(seconds: context.state.accumulatedSeconds))
        }
    }

    /// Micro-health: local transcription + translation, symbol + text
    /// (never color alone).
    private var healthLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: context.state.isTranscribing ? "waveform" : "waveform.slash")
                .font(.caption2)
            Text(context.state.translation.label)
                .font(.caption2)
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var pauseResumeButton: some View {
        if context.state.phase == .recording {
            Button(intent: PauseClassroomCommandIntent()) {
                Image(systemName: "pause.fill")
                    .font(.body.weight(.semibold))
                    .frame(width: 40, height: 36)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(Text("暂停课堂"))
        } else if context.state.phase == .paused {
            Button(intent: ResumeClassroomCommandIntent()) {
                Image(systemName: "play.fill")
                    .font(.body.weight(.semibold))
                    .frame(width: 40, height: 36)
            }
            .buttonStyle(.borderedProminent)
            .tint(WidgetPalette.accent)
            .accessibilityLabel(Text("继续课堂"))
        }
    }

    private var endButton: some View {
        Button(intent: OpenLiveTranslateRouteIntent(destination: .endClassroomConfirmation)) {
            Image(systemName: "stop.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color(red: 1.0, green: 0.42, blue: 0.42))
                .frame(width: 40, height: 36)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(Text("结束课堂"))
    }
}
