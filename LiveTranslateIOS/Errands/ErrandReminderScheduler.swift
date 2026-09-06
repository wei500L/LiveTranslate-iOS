import Foundation
import UserNotifications

/// 值类型的通知请求（UNNotificationRequest 无法在测试/demo 中构造 ——
/// 这个值类型让调度器完全可测）。
struct ErrandNotificationRequest: Sendable, Equatable {
    var identifier: String
    var title: String
    var body: String
    var categoryIdentifier: String
    var userInfo: [String: String]
    /// 触发时间（墙钟分量；nil = 不调度，仅记录内容）。
    var fireDateComponents: DateComponents?
    var sound: Bool = true
}

/// 通知中心的抽象 —— 唯一目的是让 ErrandReminderScheduler 可测、demo
/// 可注入 fake（现有三个调度器硬编码 UNUserNotificationCenter.current()
/// 没有注入点；这里生而可测，不建立第二套基础设施 —— 授权模型、
/// category、路由全部复用现有机制）。
@MainActor
protocol ErrandNotificationScheduling: AnyObject {
    /// 当前授权状态（.authorized | .denied | .notDetermined）。
    var authorizationState: UNAuthorizationStatus { get async }
    /// 用户显式动作时请求授权；返回是否可用。
    func requestAuthorization() async -> Bool
    /// 挂起一个请求（同 identifier 幂等覆盖由 remove+add 保证）。
    func add(_ request: ErrandNotificationRequest) async throws
    /// 按精确 identifier 移除待发送请求。
    func removePending(withIdentifiers identifiers: [String])
    /// 全部待发送 identifier（前缀清理用）。
    func pendingIdentifiers() async -> [String]
}

/// 生产实现：薄包装系统通知中心。
@MainActor
final class SystemErrandNotificationCenter: ErrandNotificationScheduling {
    private let center = UNUserNotificationCenter.current()

    var authorizationState: UNAuthorizationStatus {
        get async { await center.notificationSettings().authorizationStatus }
    }

    func requestAuthorization() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default:
            return false
        }
    }

    func add(_ request: ErrandNotificationRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        if request.sound { content.sound = .default }
        content.categoryIdentifier = request.categoryIdentifier
        content.userInfo = request.userInfo
        guard let components = request.fireDateComponents else { return }
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        try await center.add(UNNotificationRequest(
            identifier: request.identifier,
            content: content,
            trigger: trigger
        ))
    }

    func removePending(withIdentifiers identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func pendingIdentifiers() async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier)
    }
}

/// 办事事项本地通知 —— 预约、截止与跟进三类时间各自独立提醒。
/// 完全本地（同 Task/Exam/Class 调度器）：通知状态绝不同步。
///
/// 调度模型：
/// - 一个确认时间的清单项最多一条提醒（identifier 由 case ID + item ID +
///   种类确定 —— 重复保存不产生多条通知）；
/// - enable 总是 remove-then-add（幂等重排；时区/日期/状态变更后重跑即
///   可）；
/// - 授权只在用户显式操作时请求；被拒时事项照常保存，界面显示
///   "提醒未创建"（返回值如实反映）；
/// - 通知内容经 SystemSurfacePrivacy 三档门控；
/// - 不确定日期（dateUncertain）绝不调度 —— 只有用户确认的 dueAt 才
///   成为触发时间；
/// - 过去时间不调度（记住选择但不挂请求 —— 诚实的"已过时不响"）。
@MainActor
final class ErrandReminderScheduler {
    /// 提前量（raw = 分钟；-1 = 不提醒）。
    enum Lead: Int, CaseIterable, Identifiable {
        case off = -1
        case atTime = 0
        case thirty = 30
        case hour = 60
        case threeHours = 180
        case oneDay = 1440
        case threeDays = 4320
        case oneWeek = 10080

        var id: Int { rawValue }

        var displayName: String {
            switch self {
            case .off: return "不提醒"
            case .atTime: return "到点提醒"
            case .thirty: return "提前 30 分钟"
            case .hour: return "提前 1 小时"
            case .threeHours: return "提前 3 小时"
            case .oneDay: return "提前 1 天"
            case .threeDays: return "提前 3 天"
            case .oneWeek: return "提前 1 周"
            }
        }
    }

    /// 提醒种类（appointment | deadline | followUp —— 三种时间语义独立）。
    enum Kind: String, Sendable {
        case appointment
        case deadline
        case followUp

        var displayName: String {
            switch self {
            case .appointment: return "预约"
            case .deadline: return "截止"
            case .followUp: return "跟进"
            }
        }
    }

    // MARK: - Wire constants (shared with NotificationRouter)

    nonisolated static let categoryID = "ERRAND_REMINDER"
    nonisolated static let caseIDUserInfo = "errandCaseID"

    /// 稳定 identifier：errand.<kind>.<caseID>.<itemID>。
    static func notificationID(kind: Kind, caseID: UUID, itemID: UUID) -> String {
        "errand.\(kind.rawValue).\(caseID.uuidString).\(itemID.uuidString)"
    }

    /// 一条已记住的提醒选择（Codable —— 元组不满足 Codable，结构体才
    /// 能落盘）。
    private struct ItemLead: Codable {
        var caseID: String
        var kind: String
        var lead: Int
    }

    private let defaults: UserDefaults
    private let center: any ErrandNotificationScheduling
    /// item UUID string → 选择。Absent = 无提醒。
    private var itemLeads: [String: ItemLead] = [:]

    init(
        defaults: UserDefaults,
        center: (any ErrandNotificationScheduling)? = nil
    ) {
        self.defaults = defaults
        self.center = center ?? SystemErrandNotificationCenter()
        if let data = defaults.data(forKey: Self.storageKey),
           let stored = try? JSONDecoder().decode(
            [String: ItemLead].self, from: data
           ) {
            itemLeads = stored
        }
    }

    private static let storageKey = "errand.reminderState"

    private func persist() {
        if let data = try? JSONEncoder().encode(itemLeads) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    /// 记住一个选择（无可用确认时间/提前量已过时 —— 请求不挂）。
    private func remember(
        item: ErrandCaseItem, kind: Kind, lead: Lead
    ) {
        itemLeads[item.id.uuidString] = ItemLead(
            caseID: item.caseID.uuidString,
            kind: kind.rawValue,
            lead: lead.rawValue
        )
        persist()
    }

    // MARK: - Authorization (user-initiated only)

    var isAuthorized: Bool {
        get async {
            switch await center.authorizationState {
            case .authorized, .provisional, .ephemeral: return true
            default: return false
            }
        }
    }

    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool {
        await center.requestAuthorization()
    }

    // MARK: - Arming

    func lead(itemID: UUID) -> Lead {
        guard let stored = itemLeads[itemID.uuidString] else { return .off }
        return Lead(rawValue: stored.lead) ?? .off
    }

    func armedKind(itemID: UUID) -> Kind? {
        itemLeads[itemID.uuidString].flatMap { Kind(rawValue: $0.kind) }
    }
    /// 挂上（或重排）一个清单项的提醒。返回 false 当且仅当授权被拒
    /// （诚实结果 —— 界面显示"提醒未创建"）。
    @discardableResult
    func enable(
        item: ErrandCaseItem, caseTitle: String, kind: Kind, lead: Lead
    ) async -> Bool {
        guard lead != .off else {
            disable(itemID: item.id)
            return true
        }
        // 只有用户确认的时间才能成为触发点；不确定日期绝不调度。
        guard let dueAt = item.dueAt, !item.dateUncertain else {
            remember(item: item, kind: kind, lead: lead)
            return true
        }
        let fireDate = dueAt.addingTimeInterval(-TimeInterval(lead.rawValue) * 60)
        guard fireDate > .now else {
            // 提前量已过：记住选择但不调度（过去时间永不触发）。
            remember(item: item, kind: kind, lead: lead)
            return true
        }
        guard await requestAuthorizationIfNeeded() else { return false }
        remember(item: item, kind: kind, lead: lead)

        let identifier = Self.notificationID(kind: kind, caseID: item.caseID, itemID: item.id)
        center.removePending(withIdentifiers: [identifier])
        let request = ErrandNotificationRequest(
            identifier: identifier,
            title: "\(kind.displayName)提醒",
            body: Self.notificationBody(
                caseTitle: caseTitle, itemTitle: item.title
            ),
            categoryIdentifier: Self.categoryID,
            userInfo: [Self.caseIDUserInfo: item.caseID.uuidString],
            fireDateComponents: Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: fireDate
            )
        )
        try? await center.add(request)
        return true
    }

    /// 取消并忘掉一个清单项的提醒。
    func disable(itemID: UUID) {
        itemLeads[itemID.uuidString] = nil
        persist()
        Task { [weak self] in
            await self?.removeIdentifiers { $0.contains(".\(itemID.uuidString)") }
        }
    }

    /// 取消一个事项的全部提醒并忘掉其选择（事项删除/完成/取消 ——
    /// identifier 与状态里都带着事项标记，可完整清理）。
    func cancelCase(caseID: UUID) {
        let marker = ".\(caseID.uuidString)."
        let stateMarker = caseID.uuidString
        itemLeads = itemLeads.filter { _, value in value.caseID != stateMarker }
        persist()
        Task { [weak self] in
            await self?.removeIdentifiers { $0.contains(marker) }
        }
    }

    /// 清空全部（账号切换/删除 —— 调用方负责重建新账号状态）。
    func cancelAll() {
        itemLeads = [:]
        persist()
        Task { [weak self] in
            await self?.removeIdentifiers { _ in true }
        }
    }

    /// 按谓词移除待发送请求（identifier 全量拉取后过滤 —— UNUserNotification
    /// Center 只支持精确 identifier 移除）。
    private func removeIdentifiers(_ matches: (String) -> Bool) async {
        let pending = await center.pendingIdentifiers()
        let targets = pending.filter(matches)
        guard !targets.isEmpty else { return }
        center.removePending(withIdentifiers: targets)
    }

    /// 清理 itemLeads 中已不存在的 item（事项被删时行已删 —— 由
    /// refreshAll 重建；这里只做通知请求侧的诚实清理）。
    func pruneMissingItems(liveItemIDs: Set<UUID>) {
        let removed = itemLeads.keys.filter {
            UUID(uuidString: $0).map { !liveItemIDs.contains($0) } ?? true
        }
        guard !removed.isEmpty else { return }
        for key in removed { itemLeads[key] = nil }
        persist()
    }

    // MARK: - Privacy-gated content (SystemSurfacePrivacy 三档)

    /// 通知正文：完整 = 事项标题 + 清单项；仅标题 = 事项标题 + 通用状态；
    /// 仅状态 = "有一项办事事项需要处理"（医院/签证/材料细节绝不出现）。
    static func notificationBody(caseTitle: String, itemTitle: String) -> String {
        switch SettingsStore.shared.systemSurfacePrivacy {
        case .showFullContent:
            var body = caseTitle
            if !itemTitle.isEmpty { body += " · \(itemTitle)" }
            return body
        case .showTitlesOnly:
            return caseTitle.isEmpty ? "有一项办事事项需要处理" : caseTitle
        case .hideSensitiveContent:
            return "有一项办事事项需要处理"
        }
    }
}
