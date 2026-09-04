import SwiftUI

/// The learning-timer card (学习计时) — embedded in the review center's
/// 今天 page while an activity runs. Elapsed time comes from timestamps
/// (the tracker), refreshed by a 1-minute display tick — never a
/// per-second task. 暂停/继续/完成/放弃 are all real state transitions;
/// an abandoned run is never disguised as completed.
struct StudyActivityCard: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var tickDate = Date()
    @State private var timer: Timer?

    var body: some View {
        if let activity = environment.studyActivityTracker.currentActivity {
            VStack(alignment: .leading, spacing: LTSpacing.s) {
                HStack(spacing: LTSpacing.m) {
                    Image(systemName: environment.studyActivityTracker.isPaused
                        ? "pause.circle.fill" : "timer")
                        .font(.title2)
                        .foregroundStyle(environment.studyActivityTracker.isPaused
                            ? LTColors.warning : LTColors.accentGreen)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(environment.studyActivityTracker.isPaused ? "学习已暂停" : "正在学习")
                            .font(LTTypography.cardTitle)
                            .foregroundStyle(LTColors.textPrimary)
                        Text(activityTitle(activity))
                            .font(LTTypography.caption)
                            .foregroundStyle(LTColors.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(elapsedText)
                        .font(.system(.title3, design: .rounded).weight(.bold).monospacedDigit())
                        .foregroundStyle(LTColors.textPrimary)
                }
                HStack(spacing: LTSpacing.s) {
                    if environment.studyActivityTracker.isPaused {
                        Button {
                            environment.studyActivityTracker.resume()
                        } label: {
                            Label("继续", systemImage: "play.fill")
                                .font(.footnote.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .buttonStyle(LTPrimaryButtonStyle())
                    } else {
                        Button {
                            environment.studyActivityTracker.pause()
                        } label: {
                            Label("暂停", systemImage: "pause.fill")
                                .font(.footnote.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .buttonStyle(LTSecondaryButtonStyle())
                    }
                    Button {
                        environment.studyActivityTracker.complete()
                        LTHaptics.success()
                    } label: {
                        Label("完成", systemImage: "checkmark")
                            .font(.footnote.weight(.semibold))
                            .frame(minWidth: 76, minHeight: 36)
                    }
                    .buttonStyle(LTPrimaryButtonStyle())
                    Button {
                        environment.studyActivityTracker.abandon()
                    } label: {
                        Text("放弃")
                            .font(.footnote)
                            .foregroundStyle(LTColors.textTertiary)
                            .frame(minWidth: 56, minHeight: 36)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("放弃本次学习"))
                }
            }
            .padding(LTSpacing.l)
            .ltCard()
            .onAppear { startTimer() }
            .onDisappear {
                timer?.invalidate()
                timer = nil
                // A checkpoint when the card leaves: background time
                // folds into the row so the synced duration stays honest.
                environment.studyActivityTracker.checkpoint()
            }
        }
    }

    private var elapsedText: String {
        // Reads through the tracker on every display tick (the tick
        // forces re-render via tickDate).
        _ = tickDate
        let seconds = environment.studyActivityTracker.elapsedSeconds
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func activityTitle(_ activity: StudyActivity) -> String {
        if let itemID = activity.planItemID,
           let item = try? environment.repository.studyPlanItem(id: itemID) {
            return item.title
        }
        if let examID = activity.examID,
           let exam = try? environment.repository.exam(id: examID) {
            return exam.title
        }
        return "自主学习"
    }

    /// Minute-level display refresh (timestamps stay the source of
    /// truth; this only re-renders the label).
    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in
                tickDate = .now
                environment.studyActivityTracker.checkpoint()
            }
        }
    }
}
