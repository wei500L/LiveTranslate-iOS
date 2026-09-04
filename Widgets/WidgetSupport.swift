import Foundation
import SwiftUI
import WidgetKit

// Widget-side formatting helpers. Lock screen and home screen widgets
// follow SYSTEM reading conventions (SF Symbols, plain layouts, auto-
// updating time text) rather than shrinking app cards. Status is never
// color-only — every state pairs an icon or label.

// MARK: - Time

/// Relative countdown text ("3小时后") from now to a date — computed at
/// render time; between reloads the system's auto-updating Text covers it.
enum WidgetFormat {
    static func relativeLabel(to date: Date, from now: Date = .now) -> String {
        let interval = date.timeIntervalSince(now)
        if interval <= 0 { return "进行中" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        if let text = formatter.string(from: interval) {
            return "\(text)后"
        }
        return "即将开始"
    }

    /// Lock-screen next-class label mirroring the app's semantics.
    static func nextClassStateLabel(
        start: Date, end: Date, isCancelled: Bool, isTimeChanged: Bool,
        now: Date = .now
    ) -> String {
        if isCancelled { return "已停课" }
        if isTimeChanged { return "调课" }
        if now < start { return relativeLabel(to: start, from: now) }
        if now < end { return "正在上课" }
        return "已结束"
    }

    static func examCountdown(days: Int) -> String {
        switch days {
        case ..<0: return "已结束"
        case 0: return "今天"
        case 1: return "明天"
        default: return "还有 \(days) 天"
        }
    }

    static func clockLabel(seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    static func timeOfDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }
}

// MARK: - Palette

/// Restrained widget palette: system-driven containers with a single
/// accent. Readable in light, dark, tinted and accented lock-screen
/// contexts; important information is always text + symbol, never color
/// alone.
enum WidgetPalette {
    static let accent = Color(red: 0.30, green: 0.78, blue: 0.47)
    static let caution = Color(red: 0.95, green: 0.69, blue: 0.23)
    static let primaryText = Color.primary
    static let secondaryText = Color.secondary
}

// MARK: - Status symbols

/// Icon + label pairs for states (never color-only).
enum WidgetStatus {
    static func classroom(_ phase: LiveClassroomPhase) -> (symbol: String, label: String) {
        switch phase {
        case .recording: return ("waveform", "正在记录")
        case .paused: return ("pause.circle", "已暂停")
        case .finalizing: return ("hourglass", "正在保存课堂")
        case .ended: return ("checkmark.circle", "已保存")
        case .failed: return ("exclamationmark.triangle", "已中断 · 点击查看")
        }
    }

    static func study(_ phase: LiveStudyPhase) -> (symbol: String, label: String) {
        switch phase {
        case .running: return ("timer", "正在学习")
        case .paused: return ("pause.circle", "学习已暂停")
        }
    }
}
