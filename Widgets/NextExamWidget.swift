import SwiftUI
import WidgetKit

// 下一场考试 widget — countdown to the nearest scheduled exam, with its
// course and the current plan progress as auxiliary lines (the combined
// status the spec allows). Lock-screen accessory families stay minimal
// (one countdown line). Tap routes to ExamDetailView through the app.

// MARK: - Entry

struct NextExamEntry: TimelineEntry {
    let date: Date
    let exam: WidgetNextExam?
    let today: WidgetTodayStudy?
    let scopeActive: Bool
}

// MARK: - Provider

struct NextExamProvider: TimelineProvider {
    func placeholder(in context: Context) -> NextExamEntry {
        NextExamEntry(date: .now, exam: nil, today: nil, scopeActive: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (NextExamEntry) -> Void) {
        completion(current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextExamEntry>) -> Void) {
        let entry = current()
        // The day-countdown changes at midnight; reload then.
        if let midnight = Calendar.current.nextDate(
            after: entry.date, matching: DateComponents(hour: 0, minute: 0),
            matchingPolicy: .nextTime
        ) {
            completion(Timeline(entries: [entry], policy: .after(midnight)))
        } else {
            completion(Timeline(entries: [entry], policy: .atEnd))
        }
    }

    private func current() -> NextExamEntry {
        let store = SystemSnapshotStore()
        let scope = SystemScope.currentScopeKey(defaults: SystemSnapshotStore.defaults)
        let snapshot = store.load(activeScopeKey: scope)
        return NextExamEntry(
            date: .now,
            exam: snapshot?.nextExam,
            today: snapshot?.today,
            scopeActive: snapshot != nil
        )
    }
}

// MARK: - Widget

struct NextExamWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NextExamWidget", provider: NextExamProvider()) { entry in
            NextExamView(entry: entry)
                .widgetBackground()
        }
        .configurationDisplayName("下一场考试")
        .description("考试倒计时与今日计划进度。")
        .supportedFamilies([
            .systemSmall, .systemMedium,
            .accessoryCircular, .accessoryInline, .accessoryRectangular
        ])
    }
}

// MARK: - Views

struct NextExamView: View {
    @Environment(\.widgetFamily) private var widgetFamily
    let entry: NextExamEntry

    var body: some View {
        if !entry.scopeActive {
            unavailable("切换账号后打开 App 更新")
        } else if let exam = entry.exam {
            content(exam)
        } else {
            unavailable("近期没有考试安排")
        }
    }

    @ViewBuilder
    private func content(_ exam: WidgetNextExam) -> some View {
        switch widgetFamily {
        case .accessoryInline:
            // Inline is text-only; the default tap opens the app.
            HStack(spacing: 4) {
                Image(systemName: "graduationcap.fill")
                Text("\(exam.title) · \(WidgetFormat.examCountdown(days: exam.daysUntil))")
            }
        default:
            Button(intent: OpenEntityRouteIntent(kind: .exam, id: exam.examID)) {
                switch widgetFamily {
                case .accessoryCircular:
                    VStack(spacing: 1) {
                        Image(systemName: "graduationcap.fill")
                            .font(.headline)
                        Text(WidgetFormat.examCountdown(days: exam.daysUntil))
                            .font(.caption2)
                            .minimumScaleFactor(0.6)
                    }
                case .accessoryRectangular:
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Image(systemName: "graduationcap.fill")
                            Text(exam.title)
                        }
                        .font(.headline)
                        Text(WidgetFormat.examCountdown(days: exam.daysUntil))
                            .font(.caption)
                        if !exam.courseName.isEmpty {
                            Text(exam.courseName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                case .systemMedium:
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            Image(systemName: "graduationcap.fill")
                                .foregroundStyle(WidgetPalette.accent)
                            Text("下一场考试")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(exam.title)
                            .font(.headline)
                            .lineLimit(1)
                        if !exam.courseName.isEmpty {
                            Text(exam.courseName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("\(max(exam.daysUntil, 0))")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .minimumScaleFactor(0.5)
                        Text("天")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let today = entry.today, today.planTotal > 0 {
                            Text("今日计划 \(today.planDone)/\(today.planTotal)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            default:
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "graduationcap.fill")
                            .foregroundStyle(WidgetPalette.accent)
                        Spacer()
                        Text(WidgetFormat.examCountdown(days: exam.daysUntil))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(WidgetPalette.accent)
                    }
                    .font(.caption)
                    Text(exam.title)
                        .font(.headline)
                        .lineLimit(2)
                    if !exam.courseName.isEmpty {
                        Text(exam.courseName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(WidgetFormat.shortDate(exam.examDate))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                }
            }
            .buttonStyle(.plain)
        }
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
