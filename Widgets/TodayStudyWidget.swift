import SwiftUI
import WidgetKit

// 今日学习 widget — plan progress (done / total), the next item and its
// estimated minutes, the running learning timer, plus the inbox count as
// auxiliary info. Empty data is honestly empty ("今天暂无安排") — the
// widget never invents recommended tasks. Timeline: reload at the next
// midnight; live elapsed derives from the running-stretch anchor.

// MARK: - Entry

struct TodayStudyEntry: TimelineEntry {
    let date: Date
    let today: WidgetTodayStudy?
    let study: WidgetStudyActivity?
    let inboxPendingCount: Int
    let scopeActive: Bool
}

// MARK: - Provider

struct TodayStudyProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayStudyEntry {
        TodayStudyEntry(date: .now, today: nil, study: nil, inboxPendingCount: 0, scopeActive: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayStudyEntry) -> Void) {
        completion(current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayStudyEntry>) -> Void) {
        // "Today" flips at midnight — reload then. Between reloads the
        // running timer text updates itself from the stretch anchor.
        let entry = current()
        if let midnight = Calendar.current.nextDate(
            after: entry.date, matching: DateComponents(hour: 0, minute: 0),
            matchingPolicy: .nextTime
        ) {
            completion(Timeline(entries: [entry], policy: .after(midnight)))
        } else {
            completion(Timeline(entries: [entry], policy: .atEnd))
        }
    }

    private func current() -> TodayStudyEntry {
        let store = SystemSnapshotStore()
        let scope = SystemScope.currentScopeKey(defaults: SystemSnapshotStore.defaults)
        let snapshot = store.load(activeScopeKey: scope)
        return TodayStudyEntry(
            date: .now,
            today: snapshot?.today,
            study: snapshot?.study,
            inboxPendingCount: snapshot?.inboxPendingCount ?? 0,
            scopeActive: snapshot != nil
        )
    }
}

// MARK: - Widget

struct TodayStudyWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TodayStudyWidget", provider: TodayStudyProvider()) { entry in
            TodayStudyView(entry: entry)
                .widgetBackground()
        }
        .configurationDisplayName("今日学习")
        .description("今日计划完成进度、下一项内容与学习计时。")
        .supportedFamilies([
            .systemSmall, .systemMedium,
            .accessoryInline, .accessoryRectangular
        ])
    }
}

// MARK: - Views

struct TodayStudyView: View {
    @Environment(\.widgetFamily) private var widgetFamily
    let entry: TodayStudyEntry

    var body: some View {
        if !entry.scopeActive {
            unavailable("切换账号后打开 App 更新")
        } else if let study = entry.study {
            runningStudy(study)
        } else if let today = entry.today, today.planTotal > 0 {
            planContent(today)
        } else {
            unavailable("今天暂无安排")
        }
    }

    // MARK: Running timer (front and center while studying)

    @ViewBuilder
    private func runningStudy(_ study: WidgetStudyActivity) -> some View {
        switch widgetFamily {
        case .accessoryInline:
            // Inline is text-only (no button rendering): the default tap
            // opens the app.
            HStack(spacing: 4) {
                Image(systemName: study.isPaused ? "pause.circle" : "timer")
                Text("\(study.title) · \(elapsedText(study))")
            }
        default:
            Button(intent: OpenLiveTranslateRouteIntent(destination: .todayStudy)) {
                switch widgetFamily {
                case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: study.isPaused ? "pause.circle" : "timer")
                        Text(study.isPaused ? "学习已暂停" : "正在学习")
                    }
                    .font(.headline)
                    Text(study.title)
                        .font(.caption)
                        .lineLimit(1)
                    Text(elapsedText(study))
                        .font(.caption2.monospacedDigit())
                }
            case .systemMedium:
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            Image(systemName: study.isPaused ? "pause.circle" : "timer")
                                .foregroundStyle(study.isPaused ? WidgetPalette.caution : WidgetPalette.accent)
                            Text(study.isPaused ? "学习已暂停" : "正在学习")
                        }
                        .font(.caption)
                        Text(study.title)
                            .font(.headline)
                            .lineLimit(1)
                        if !study.courseName.isEmpty {
                            Text(study.courseName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(timerText(study))
                            .font(.title2.weight(.bold).monospacedDigit())
                            .minimumScaleFactor(0.6)
                        if study.estimatedMinutes > 0 {
                            Text("预计 \(study.estimatedMinutes) 分钟")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            default:
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: study.isPaused ? "pause.circle" : "timer")
                            .foregroundStyle(study.isPaused ? WidgetPalette.caution : WidgetPalette.accent)
                        Spacer()
                        Text(timerText(study))
                            .font(.headline.monospacedDigit())
                            .minimumScaleFactor(0.6)
                    }
                    .font(.caption)
                    Text(study.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                    if study.estimatedMinutes > 0 {
                        Text("预计 \(study.estimatedMinutes) 分钟")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                }
            }
            .buttonStyle(.plain)
        }
    }

    /// Live elapsed: system-driven timer while running; static folded
    /// seconds while paused (timestamps stay the source of truth).
    @ViewBuilder
    private func timerText(_ study: WidgetStudyActivity) -> some View {
        if !study.isPaused, let activeSince = study.activeSince {
            Text(timerInterval: activeSince..., countsDown: false)
        } else {
            Text(WidgetFormat.clockLabel(seconds: study.accumulatedSeconds))
        }
    }

    private func elapsedText(_ study: WidgetStudyActivity) -> String {
        WidgetFormat.clockLabel(seconds: study.accumulatedSeconds)
    }

    // MARK: Plan progress

    @ViewBuilder
    private func planContent(_ today: WidgetTodayStudy) -> some View {
        switch widgetFamily {
        case .accessoryInline:
            // Inline is text-only; the default tap opens the app.
            HStack(spacing: 4) {
                Image(systemName: "checklist")
                Text("今日计划 \(today.planDone)/\(today.planTotal)")
            }
        default:
            Button(intent: OpenLiveTranslateRouteIntent(destination: .todayStudy)) {
                switch widgetFamily {
                case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "checklist")
                        Text("今日学习")
                    }
                    .font(.headline)
                    Text("\(today.planDone)/\(today.planTotal) 项完成")
                        .font(.caption)
                    if !today.nextItemTitle.isEmpty {
                        Text(today.nextItemTitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            case .systemMedium:
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            Image(systemName: "checklist")
                                .foregroundStyle(WidgetPalette.accent)
                            Text("今日学习")
                        }
                        .font(.caption)
                        if today.nextItemTitle.isEmpty {
                            Text("今日计划已完成")
                                .font(.headline)
                        } else {
                            Text(today.nextItemTitle)
                                .font(.headline)
                                .lineLimit(1)
                            if today.nextItemEstimatedMinutes > 0 {
                                Text("预计 \(today.nextItemEstimatedMinutes) 分钟")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer()
                    VStack(spacing: 4) {
                        progressText(today)
                    }
                }
            default:
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "checklist")
                            .foregroundStyle(WidgetPalette.accent)
                        Spacer()
                        progressText(today)
                    }
                    .font(.caption)
                    if today.nextItemTitle.isEmpty {
                        Text("今日计划已完成")
                            .font(.headline)
                    } else {
                        Text(today.nextItemTitle)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(2)
                    }
                }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func progressText(_ today: WidgetTodayStudy) -> some View {
        Text("\(today.planDone)/\(today.planTotal)")
            .font(.headline.monospacedDigit())
            .foregroundStyle(today.planDone >= today.planTotal && today.planTotal > 0
                              ? WidgetPalette.accent : WidgetPalette.primaryText)
    }

    private func unavailable(_ message: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: "graduationcap")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
