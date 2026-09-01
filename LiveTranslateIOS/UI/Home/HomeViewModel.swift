import SwiftUI
import AVFoundation

/// View model for the home screen. Aggregates the real readiness signals
/// (mic permission, installed language resources, translation config,
/// network) and SwiftData-derived study statistics.
@MainActor
@Observable
final class HomeViewModel {
    struct ReadinessItem: Identifiable, Equatable {
        enum State: Equatable {
            case ok
            case warning
            case unavailable
        }

        let id: String
        let title: String
        let detail: String
        let state: State
        /// Tapping this row routes somewhere (e.g. missing resources →
        /// model management).
        let action: ReadinessAction?
    }

    enum ReadinessAction {
        case modelManagement
        /// Deep link into the system Settings app when mic is denied.
        case systemSettings
    }

    struct SessionSummary: Identifiable {
        let id: UUID
        let title: String
        let startTime: Date
        let duration: TimeInterval
        let entryCount: Int
        let abnormalTermination: Bool
        let hasFailedTranslations: Bool

        init(session: ClassroomSession, failedEntries: Bool) {
            self.id = session.id
            self.title = session.title
            self.startTime = session.startTime
            self.duration = session.duration
            self.entryCount = session.entryCount
            self.abnormalTermination = session.abnormalTermination
            self.hasFailedTranslations = failedEntries
        }
    }

    private var environment: AppEnvironment?

    var isLoaded = false
    var recentSessions: [SessionSummary] = []
    var micAuthorized = false
    var preferredBackendInstalled = false
    var anyBackendInstalled = false
    /// [oldest … today], minutes of classroom time per day.
    var dailyMinutes: [Double] = []
    var todayTotalSeconds: TimeInterval = 0
    var weekSessionCount = 0

    // MARK: - Lifecycle

    func attach(_ environment: AppEnvironment) {
        self.environment = environment
    }

    func reload() async {
        guard let environment else { return }

        // Permission state (not granted yet = still requestable, so
        // "denied" is the only red state).
        let permission = AVAudioApplication.shared.recordPermission
        micAuthorized = permission == .granted

        // Language resources: whichever backend the user prefers, plus the
        // "anything installed" signal for the degraded banner.
        async let coreML = environment.engineManager.isInstalled(.coreMLFP16)
        async let sherpa = environment.engineManager.isInstalled(.sherpaONNXInt8)
        let (coreMLInstalled, sherpaInstalled) = await (coreML, sherpa)
        anyBackendInstalled = coreMLInstalled || sherpaInstalled
        preferredBackendInstalled = environment.settings.preferredBackend == .coreMLFP16
            ? coreMLInstalled
            : sherpaInstalled

        // Recent classrooms (real SwiftData reads).
        let sessions = (try? environment.repository.sessions(matching: "")) ?? []
        recentSessions = sessions.prefix(3).map { session in
            let entries = (try? environment.repository.entries(for: session)) ?? []
            let failed = entries.contains { $0.status == .failed || $0.status == .notConfigured }
            return SessionSummary(session: session, failedEntries: failed)
        }

        // Study statistics: last 7 days (today last).
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        dailyMinutes = (1...7).map { offset in
            let day = calendar.date(byAdding: .day, value: -7 + offset, to: today)!
            let next = calendar.date(byAdding: .day, value: 1, to: day)!
            let total = sessions
                .filter { $0.startTime >= day && $0.startTime < next }
                .reduce(0.0) { $0 + max($1.duration, 0) }
            return total / 60
        }
        todayTotalSeconds = sessions
            .filter { $0.startTime >= today }
            .reduce(0.0) { $0 + max($1.duration, 0) }
        weekSessionCount = sessions.filter { $0.startTime >= today.addingTimeInterval(-7 * 86_400) }.count

        isLoaded = true
    }

    // MARK: - Derived

    /// Whether the classroom can start right now with everything green.
    var isFullyReady: Bool {
        micAuthorized && preferredBackendInstalled && translationConfigured
    }

    /// Translation service is configured when base URL + model are set
    /// (local servers such as Ollama need no API key, so the key is not
    /// part of readiness). Same rule as `SettingsStore.isTranslationConfigured`.
    var translationConfigured: Bool {
        environment?.settings.isTranslationConfigured ?? false
    }

    var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        switch hour {
        case 5..<11: return "早上好"
        case 11..<13: return "中午好"
        case 13..<18: return "下午好"
        case 18..<23: return "晚上好"
        default: return "夜深了"
        }
    }

    var greetingSubtitle: String {
        let weekday = Calendar.current.component(.weekday, from: .now)
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        return "今天是\(names[weekday - 1])，祝听课顺利"
    }

    /// Readiness rows bound to real state.
    var readinessItems: [ReadinessItem] {
        guard let environment else { return [] }
        var items: [ReadinessItem] = []

        items.append(ReadinessItem(
            id: "mic",
            title: "麦克风权限",
            detail: micAuthorized ? "已授权" : "未授权，无法采集课堂声音",
            state: micAuthorized ? .ok : .unavailable,
            action: micAuthorized ? nil : .systemSettings
        ))

        items.append(ReadinessItem(
            id: "direction",
            title: "翻译方向",
            detail: "俄语 → 简体中文",
            state: .ok,
            action: nil
        ))

        let resourcesDetail: String
        let resourcesState: ReadinessItem.State
        if preferredBackendInstalled {
            resourcesDetail = "本地模式 · 转写可用"
            resourcesState = .ok
        } else if anyBackendInstalled {
            resourcesDetail = "当前偏好模式未安装，可前往语言资源管理切换"
            resourcesState = .warning
        } else {
            resourcesDetail = "语言资源未准备好，需要先下载"
            resourcesState = .unavailable
        }
        items.append(ReadinessItem(
            id: "resources",
            title: "本地转写",
            detail: resourcesDetail,
            state: resourcesState,
            action: .modelManagement
        ))

        items.append(ReadinessItem(
            id: "autosave",
            title: "自动保存",
            detail: "俄语原文识别后立即保存到本地",
            state: .ok,
            action: nil
        ))

        let translationDetail: String
        if translationConfigured {
            translationDetail = environment.coordinator.isNetworkAvailable
                ? "云端翻译 · 已连接"
                : "云端翻译 · 当前无网络"
            items.append(ReadinessItem(
                id: "translation",
                title: "翻译服务",
                detail: translationDetail,
                state: environment.coordinator.isNetworkAvailable ? .ok : .warning,
                action: nil
            ))
        } else {
            items.append(ReadinessItem(
                id: "translation",
                title: "翻译服务",
                detail: "未配置 · 课堂仅显示俄语原文",
                state: .warning,
                action: nil
            ))
        }

        return items
    }

    var maxDailyMinutes: Double {
        max(dailyMinutes.max() ?? 0, 30)
    }

    /// Short weekday labels (一…日) for the last 7 days, oldest → today.
    var dailyLabels: [String] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let names = ["日", "一", "二", "三", "四", "五", "六"]
        return (1...7).map { offset in
            let day = calendar.date(byAdding: .day, value: -7 + offset, to: today)!
            return names[calendar.component(.weekday, from: day) - 1]
        }
    }

    /// True while a classroom is running but the full-screen live view is
    /// collapsed (user tapped 收起).
    var hasOngoingSession: Bool {
        environment?.coordinator.isRunning ?? false
    }
}
