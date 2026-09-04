import SwiftUI
import WidgetKit

// 下一堂课 widget — the pre-class layer on the home screen and lock
// screen. Data comes ONLY from the app-maintained App Group snapshot (the
// extension never recomputes occurrences). Tap routes to the occurrence
// through the app's controlled start chain — never a direct microphone
// start. Timeline entries land on the class start / end, midnight, and
// reload .atEnd; between reloads the countdown uses the system's
// auto-updating text.

// MARK: - Entry

struct NextClassEntry: TimelineEntry {
    let date: Date
    /// The snapshot payload at generation time (nil = nothing scheduled /
    /// stale scope).
    let next: WidgetNextClass?
    let scopeActive: Bool
    /// After the class ends without a refresh, the widget stops claiming
    /// knowledge and invites a look in the app.
    let isStale: Bool
}

// MARK: - Provider

struct NextClassProvider: TimelineProvider {
    func placeholder(in context: Context) -> NextClassEntry {
        NextClassEntry(date: .now, next: nil, scopeActive: true, isStale: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (NextClassEntry) -> Void) {
        completion(current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextClassEntry>) -> Void) {
        let entry = current()
        var entries = [entry]
        if let next = entry.next {
            let start = next.start
            let end = next.end
            // State transitions the label rides on.
            if start > entry.date { entries.append(entry.at(start)) }
            if end > entry.date { entries.append(entry.at(end, stale: true)) }
            // Label refresh at the next midnight.
            if let midnight = Calendar.current.nextDate(
                after: entry.date, matching: DateComponents(hour: 0, minute: 0),
                matchingPolicy: .nextTime
            ), midnight > entry.date {
                entries.append(entry.at(midnight))
            }
            entries.sort { $0.date < $1.date }
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }


    private func current() -> NextClassEntry {
        let store = SystemSnapshotStore()
        let scope = SystemScope.currentScopeKey(defaults: SystemSnapshotStore.defaults)
        let snapshot = store.load(activeScopeKey: scope)
        return NextClassEntry(
            date: .now,
            next: snapshot?.nextClass,
            scopeActive: snapshot != nil,
            isStale: false
        )
    }
}

private extension NextClassEntry {
    func at(_ date: Date, stale: Bool = false) -> NextClassEntry {
        NextClassEntry(date: date, next: next, scopeActive: scopeActive, isStale: stale)
    }
}

// MARK: - Widget

struct NextClassWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NextClassWidget", provider: NextClassProvider()) { entry in
            NextClassView(entry: entry)
                .widgetBackground()
        }
        .configurationDisplayName("下一堂课")
        .description("距离下一堂课的时间、地点与状态。")
        .supportedFamilies([
            .systemSmall, .systemMedium,
            .accessoryCircular, .accessoryInline, .accessoryRectangular
        ])
    }
}

// MARK: - Views

struct NextClassView: View {
    @Environment(\.widgetFamily) private var widgetFamily
    let entry: NextClassEntry

    var body: some View {
        if !entry.scopeActive {
            unavailableView("切换账号后打开 App 更新")
        } else if let next = entry.next {
            content(next)
        } else {
            unavailableView("今天暂无安排")
        }
    }

    @ViewBuilder
    private func content(_ next: WidgetNextClass) -> some View {
        switch widgetFamily {
        case .accessoryInline:
            // Inline is a single text line (no button rendering): the
            // default tap opens the app.
            HStack(spacing: 4) {
                Image(systemName: "calendar")
                Text("\(next.courseName) · \(stateLabel(next))")
            }
        default:
            // The whole surface is the tap target: route into the app's
            // next-class card (the controlled start chain lives there).
            Button(intent: OpenLiveTranslateRouteIntent(destination: .nextClass)) {
                switch widgetFamily {
                case .accessoryCircular:
                    VStack(spacing: 1) {
                        Image(systemName: "calendar")
                            .font(.headline)
                        Text(WidgetFormat.relativeLabel(to: next.start, from: entry.date))
                            .font(.caption2)
                            .minimumScaleFactor(0.6)
                    }
                case .accessoryRectangular:
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Image(systemName: "calendar")
                            Text(next.courseName)
                        }
                        .font(.headline)
                        Text(stateLabel(next))
                            .font(.caption)
                        if !next.location.isEmpty {
                            Text(next.location)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                case .systemMedium:
                    mediumContent(next)
                default:
                    smallContent(next)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func stateLabel(_ next: WidgetNextClass) -> String {
        if entry.isStale { return "已结束 · 打开 App 查看" }
        return WidgetFormat.nextClassStateLabel(
            start: next.start, end: next.end,
            isCancelled: next.isCancelled, isTimeChanged: next.isTimeChanged,
            now: entry.date
        )
    }

    private func smallContent(_ next: WidgetNextClass) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "calendar")
                    .foregroundStyle(WidgetPalette.accent)
                Spacer()
                // Auto-updating countdown between reloads.
                Text(next.start, style: .relative)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 80, alignment: .trailing)
            }
            .font(.caption)
            Text(next.courseName)
                .font(.headline)
                .lineLimit(2)
            VStack(alignment: .leading, spacing: 2) {
                Text(stateLabel(next))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(next.isCancelled ? WidgetPalette.caution : WidgetPalette.accent)
                Label(
                    "\(WidgetFormat.timeOfDay(next.start)) · \(next.location.isEmpty ? "地点未定" : next.location)",
                    systemImage: "mappin.and.ellipse"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func mediumContent(_ next: WidgetNextClass) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                        .foregroundStyle(WidgetPalette.accent)
                    Text("下一堂课")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(next.courseName)
                    .font(.headline)
                    .lineLimit(1)
                Text(stateLabel(next))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(next.isCancelled ? WidgetPalette.caution : WidgetPalette.accent)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text(next.start, style: .time)
                    .font(.title3.weight(.semibold).monospacedDigit())
                Text(WidgetFormat.shortDate(next.start))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label(next.location.isEmpty ? "地点未定" : next.location, systemImage: "mappin.and.ellipse")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func unavailableView(_ message: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: "calendar.badge.exclamationmark")
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

// MARK: - Background compatibility

extension View {
    /// iOS 17 widget background (the extension's deployment target): an
    /// explicit (empty) container background keeps home-screen padding
    /// valid on every system appearance.
    @ViewBuilder
    func widgetBackground() -> some View {
        containerBackground(for: .widget) { Color.clear }
    }
}
