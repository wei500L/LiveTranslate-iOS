import SwiftUI
import WidgetKit

// The widget extension's single bundle: three restrained home/lock
// widgets plus the two Live Activity renderers. The app intents the
// widgets use live in WidgetIntents.swift; the App Shortcuts (Siri) live
// in the main app target (AppShortcuts.swift).

@main
struct LiveTranslateWidgetBundle: WidgetBundle {
    var body: some Widget {
        NextClassWidget()
        TodayStudyWidget()
        NextExamWidget()
        ClassroomLiveActivityWidget()
        StudyLiveActivityWidget()
        if #available(iOS 18.0, *) {
            OpenClassroomControl()
            CaptureBlackboardControl()
            TodayStudyControl()
        }
    }
}

// MARK: - Live Activity widgets

struct ClassroomLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ClassroomSessionActivityAttributes.self) { context in
            ClassroomLiveActivityView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Image(systemName: WidgetStatus.classroom(context.state.phase).symbol)
                            .foregroundStyle(
                                context.state.phase == .recording
                                    ? WidgetPalette.accent : .white
                            )
                            .symbolRenderingMode(.hierarchical)
                        Text(WidgetStatus.classroom(context.state.phase).label)
                            .font(.caption2)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.title)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                        if !context.state.latestChinese.isEmpty {
                            Text(context.state.latestChinese)
                                .font(.caption2)
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.phase == .paused {
                        Text(WidgetFormat.clockLabel(seconds: context.state.accumulatedSeconds))
                            .font(.caption2.weight(.semibold).monospacedDigit())
                    } else if let activeSince = context.state.activeSince {
                        Text(timerInterval: activeSince..., countsDown: false)
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .frame(maxWidth: 60)
                    } else {
                        Text(WidgetFormat.clockLabel(seconds: context.state.accumulatedSeconds))
                            .font(.caption2.weight(.semibold).monospacedDigit())
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 10) {
                        Button(intent: OpenLiveTranslateRouteIntent(destination: .currentClassroom)) {
                            Label("返回课堂", systemImage: "chevron.left.arrowtriangle.right")
                                .font(.caption2)
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                        if context.state.phase == .recording {
                            Button(intent: PauseClassroomCommandIntent()) {
                                Image(systemName: "pause.fill")
                            }
                            .buttonStyle(.bordered)
                            .accessibilityLabel(Text("暂停课堂"))
                        } else if context.state.phase == .paused {
                            Button(intent: ResumeClassroomCommandIntent()) {
                                Image(systemName: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(WidgetPalette.accent)
                            .accessibilityLabel(Text("继续课堂"))
                        }
                        Button(intent: OpenLiveTranslateRouteIntent(destination: .endClassroomConfirmation)) {
                            Image(systemName: "stop.fill")
                                .foregroundStyle(Color(red: 1.0, green: 0.42, blue: 0.42))
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel(Text("结束课堂"))
                    }
                }
            } compactLeading: {
                // Recording state — the symbol changes with the phase, so
                // paused is never color-only.
                Image(systemName: WidgetStatus.classroom(context.state.phase).symbol)
                    .foregroundStyle(
                        context.state.phase == .recording ? WidgetPalette.accent : .white
                    )
                    .symbolRenderingMode(.hierarchical)
            } compactTrailing: {
                // System-driven time text (no per-second updates pushed).
                if context.state.phase == .paused {
                    Text(WidgetFormat.clockLabel(seconds: context.state.accumulatedSeconds))
                        .monospacedDigit()
                } else if let activeSince = context.state.activeSince {
                    Text(timerInterval: activeSince..., countsDown: false)
                        .monospacedDigit()
                        .frame(maxWidth: 48)
                } else {
                    Text(WidgetFormat.clockLabel(seconds: context.state.accumulatedSeconds))
                        .monospacedDigit()
                }
            } minimal: {
                Image(systemName: WidgetStatus.classroom(context.state.phase).symbol)
                    .foregroundStyle(
                        context.state.phase == .recording ? WidgetPalette.accent : .white
                    )
                    .symbolRenderingMode(.hierarchical)
            }
        }
    }
}

struct StudyLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: StudyActivityAttributes.self) { context in
            StudyLiveActivityView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.phase == .running ? "timer" : "pause.circle")
                        .foregroundStyle(
                            context.state.phase == .running
                                ? WidgetPalette.accent : WidgetPalette.caution
                        )
                        .symbolRenderingMode(.hierarchical)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.title)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                        if !context.attributes.courseName.isEmpty {
                            Text(context.attributes.courseName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.phase == .running, let activeSince = context.state.activeSince {
                        Text(timerInterval: activeSince..., countsDown: false)
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .frame(maxWidth: 60)
                    } else {
                        Text(WidgetFormat.clockLabel(seconds: context.state.accumulatedSeconds))
                            .font(.caption2.weight(.semibold).monospacedDigit())
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 10) {
                        Button(intent: OpenLiveTranslateRouteIntent(destination: .todayStudy)) {
                            Label("去学习", systemImage: "chevron.left.arrowtriangle.right")
                                .font(.caption2)
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                        if context.state.phase == .running {
                            Button(intent: PauseStudyCommandIntent()) {
                                Image(systemName: "pause.fill")
                            }
                            .buttonStyle(.bordered)
                            .accessibilityLabel(Text("暂停学习"))
                        } else {
                            Button(intent: ResumeStudyCommandIntent()) {
                                Image(systemName: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(WidgetPalette.accent)
                            .accessibilityLabel(Text("继续学习"))
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.phase == .running ? "timer" : "pause.circle")
                    .foregroundStyle(
                        context.state.phase == .running ? WidgetPalette.accent : .white
                    )
                    .symbolRenderingMode(.hierarchical)
            } compactTrailing: {
                if context.state.phase == .running, let activeSince = context.state.activeSince {
                    Text(timerInterval: activeSince..., countsDown: false)
                        .monospacedDigit()
                        .frame(maxWidth: 48)
                } else {
                    Text(WidgetFormat.clockLabel(seconds: context.state.accumulatedSeconds))
                        .monospacedDigit()
                }
            } minimal: {
                Image(systemName: context.state.phase == .running ? "timer" : "pause.circle")
                    .foregroundStyle(
                        context.state.phase == .running ? WidgetPalette.accent : .white
                    )
                    .symbolRenderingMode(.hierarchical)
            }
        }
    }
}
