import SwiftUI
import WidgetKit

// Live Activity rendering for the learning timer. Shows what is being
// studied, live elapsed time (system-driven from the stretch anchor),
// estimated duration, pause/resume (real commands) and a finish affordance
// that routes into the app (completion writes real data — never from the
// activity itself).

struct StudyLiveActivityView: View {
    let context: ActivityViewContext<StudyActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: context.state.phase == .running ? "timer" : "pause.circle")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(
                        context.state.phase == .running ? WidgetPalette.accent : WidgetPalette.caution
                    )
                    .symbolRenderingMode(.hierarchical)
                VStack(alignment: .leading, spacing: 1) {
                    Text(context.attributes.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                timerText
                    .font(.title3.weight(.bold).monospacedDigit())
                    .frame(maxWidth: 88, alignment: .trailing)
            }
            HStack(spacing: 8) {
                if context.state.estimatedMinutes > 0 {
                    Text("预计 \(context.state.estimatedMinutes) 分钟")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    pauseResumeButton
                    finishButton
                }
            }
        }
        .activityBackgroundTint(Color.black.opacity(0.55))
        .activitySystemActionForegroundColor(Color.white)
    }

    private var subtitle: String {
        var parts: [String] = []
        if !context.attributes.courseName.isEmpty {
            parts.append(context.attributes.courseName)
        }
        parts.append(context.state.phase == .running ? "正在学习" : "学习已暂停")
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var timerText: some View {
        if context.state.phase == .running, let activeSince = context.state.activeSince {
            Text(timerInterval: activeSince...Date.distantFuture, countsDown: false)
        } else {
            Text(WidgetFormat.clockLabel(seconds: context.state.accumulatedSeconds))
        }
    }

    @ViewBuilder
    private var pauseResumeButton: some View {
        if context.state.phase == .running {
            Button(intent: PauseStudyCommandIntent()) {
                Image(systemName: "pause.fill")
                    .font(.body.weight(.semibold))
                    .frame(width: 40, height: 36)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(Text("暂停学习"))
        } else {
            Button(intent: ResumeStudyCommandIntent()) {
                Image(systemName: "play.fill")
                    .font(.body.weight(.semibold))
                    .frame(width: 40, height: 36)
            }
            .buttonStyle(.borderedProminent)
            .tint(WidgetPalette.accent)
            .accessibilityLabel(Text("继续学习"))
        }
    }

    /// Routes into the app — the real completion (minutes folded into the
    /// plan item, status done) happens only there.
    private var finishButton: some View {
        Button(intent: OpenLiveTranslateRouteIntent(destination: .todayStudy)) {
            Image(systemName: "checkmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(WidgetPalette.accent)
                .frame(width: 40, height: 36)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(Text("完成学习"))
    }
}
