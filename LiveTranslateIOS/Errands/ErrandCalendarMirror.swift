import Foundation
import EventKit

/// 办事事项日历镜像的事件存储抽象 —— 让镜像完全可测、demo 可注入
/// fake（ExamCalendarService 硬编码 EKEventStore 没有注入点；这里是
/// 同一 write-only 模式的第二个消费者，不建立第二套基础设施 —— 权限
/// 请求链、NSCalendarsWriteOnlyAccessUsageDescription、账号域
/// UserDefaults 镜像表、精确 id 查找全部沿用 ExamCalendarService 的
/// 既有语义）。
@MainActor
protocol ErrandEventStoring: AnyObject {
    /// 当前授权状态。
    var authorizationStatus: EKAuthorizationStatus { get }
    /// 请求 write-only 授权（仅用户显式动作；返回是否可用）。
    func requestWriteOnlyAccess() async -> Bool
    /// 用户可写的日历（nil = 未授权）。
    func writableCalendars() -> [ErrandCalendarInfo]
    /// 按 identifier 精确查找（绝不范围扫描用户的日历）。
    func event(identifier: String) -> ErrandEventInfo?
    /// 保存（新建或原地更新 —— 幂等）；失败如实返回 false。
    func save(
        title: String, location: String, notes: String,
        start: Date, duration: TimeInterval,
        calendarIdentifier: String, existingIdentifier: String?
    ) -> String?
    /// 删除事件（外部已删除时如实返回 false —— 调用方清掉本地映射）。
    func remove(identifier: String) -> Bool
}

/// 日历/事件的值类型（EKCalendar/EKEvent 无法在测试中构造）。
struct ErrandCalendarInfo: Identifiable, Equatable {
    var id: String
    var title: String
}

struct ErrandEventInfo: Equatable {
    var identifier: String
    var title: String
    var location: String
    var notes: String
    var startDate: Date
    var endDate: Date
}

/// 生产实现：包装系统 EKEventStore（write-only —— 绝不读取用户的
/// 日历内容，只按精确 identifier 查找自己创建的事件）。
@MainActor
final class SystemErrandEventStore: ErrandEventStoring {
    private let store = EKEventStore()

    var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    func requestWriteOnlyAccess() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .authorized, .writeOnly:
            return true
        case .notDetermined:
            if #available(iOS 17.0, *) {
                return (try? await store.requestWriteOnlyAccessToEvents()) ?? false
            }
            return false
        default:
            return false
        }
    }

    func writableCalendars() -> [ErrandCalendarInfo] {
        guard authorizationStatus == .authorized || authorizationStatus == .writeOnly else {
            return []
        }
        return store.calendars(for: .event)
            .filter { !$0.isImmutable }
            .map { ErrandCalendarInfo(id: $0.calendarIdentifier, title: $0.title) }
    }

    func event(identifier: String) -> ErrandEventInfo? {
        guard let event = store.event(withIdentifier: identifier) else { return nil }
        return ErrandEventInfo(
            identifier: event.eventIdentifier ?? "",
            title: event.title ?? "",
            location: event.location ?? "",
            notes: event.notes ?? "",
            startDate: event.startDate,
            endDate: event.endDate
        )
    }

    func save(
        title: String, location: String, notes: String,
        start: Date, duration: TimeInterval,
        calendarIdentifier: String, existingIdentifier: String?
    ) -> String? {
        guard authorizationStatus == .authorized || authorizationStatus == .writeOnly else {
            return nil
        }
        let event: EKEvent
        if let existingIdentifier,
           let fetched = store.event(withIdentifier: existingIdentifier) {
            // Update in place — never a duplicate (idempotent re-tap).
            event = fetched
        } else {
            guard let calendar = store.calendar(
                withIdentifier: calendarIdentifier
            ) else { return nil }
            event = EKEvent(eventStore: store)
            event.calendar = calendar
        }
        event.title = title
        event.location = location.isEmpty ? nil : location
        event.notes = notes.isEmpty ? nil : notes
        event.startDate = start
        event.endDate = start.addingTimeInterval(max(duration, 15 * 60))
        do {
            try store.save(event, span: .thisEvent)
            return event.eventIdentifier
        } catch {
            return nil
        }
    }

    func remove(identifier: String) -> Bool {
        guard let event = store.event(withIdentifier: identifier) else { return false }
        do {
            try store.remove(event, span: .thisEvent)
            return true
        } catch {
            return false
        }
    }
}

/// 办事事项预约的可选日历镜像 —— 完全复用 ExamCalendarService 的克制
/// write-only 模式：
/// - LiveTranslate 库是唯一事实源：系统日历只是用户显式要求时的一次性
///   镜像；
/// - 授权只在用户点"加入日历"时请求（write-only —— 绝不读取用户日历）；
/// - eventIdentifier 与写入状态只存设备本地（账号域 UserDefaults），
///   绝不同步；另一台设备拉到事项后显示"尚未添加到此设备日历"，
///   绝不自动创建；
/// - 同一 appointment 重复点击幂等（原地更新，不重复建事件）；
/// - 用户在日历里删了事件 → 如实清除本地映射，绝不背后重建；
/// - 写入失败如实返回 false（绝不显示成功）；
/// - 日历标题遵守系统界面隐私策略（仅状态档用通用标题，不带事项
///   标题/地点/材料细节）。
@MainActor
final class ErrandCalendarMirror {
    static let shared = ErrandCalendarMirror()

    private var defaultsBound: UserDefaults
    private let store: any ErrandEventStoring

    init(
        defaults: UserDefaults = .standard,
        store: (any ErrandEventStoring)? = nil
    ) {
        self.defaultsBound = defaults
        self.store = store ?? SystemErrandEventStore()
    }

    /// Rebinds to the account-scoped defaults store (profile switch).
    /// Mirror state is per-device; rebinding drops the old account's
    /// bindings（旧账号的 EK 事件留在用户日历里直到用户在系统侧删除 ——
    /// 绝不删除另一个账号的数据）。
    func configure(defaults: UserDefaults) {
        defaultsBound = defaults
    }

    private let mirrorKey = "calendar.errandMirrors"

    /// item UUID string → EK event identifier。
    private func mirrorTable() -> [String: String] {
        guard let data = defaultsBound.data(forKey: mirrorKey),
              let table = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return table
    }

    private func saveMirrorTable(_ table: [String: String]) {
        if let data = try? JSONEncoder().encode(table) {
            defaultsBound.set(data, forKey: mirrorKey)
        }
    }

    // MARK: - Calendars

    /// 用户可写的日历（授权后）。
    func writableCalendars() async -> [ErrandCalendarInfo] {
        _ = await requestAccessIfNeeded()
        return store.writableCalendars()
    }

    @discardableResult
    func requestAccessIfNeeded() async -> Bool {
        switch store.authorizationStatus {
        case .authorized, .writeOnly:
            return true
        default:
            return await store.requestWriteOnlyAccess()
        }
    }

    // MARK: - Mirroring

    /// 该预约是否已有本机镜像（另一台设备永远 false —— 映射不同步）。
    func hasMirroredAppointment(itemID: UUID) -> Bool {
        mirrorTable()[itemID.uuidString] != nil
    }

    /// 镜像的标题：完整/仅标题档用事项名，仅状态档用通用词（地点与
    /// 材料细节绝不进仅状态档的日历）。
    static func eventTitle(
        caseTitle: String, itemTitle: String
    ) -> String {
        switch SettingsStore.shared.systemSurfacePrivacy {
        case .showFullContent, .showTitlesOnly:
            var title = "办事：\(caseTitle)"
            if !itemTitle.isEmpty { title += " · \(itemTitle)" }
            return title
        case .hideSensitiveContent:
            return "办事事项"
        }
    }

    /// 加入（或原地更新）一个已确认预约的日历事件。返回 false 当且仅
    /// 当授权被拒或写入失败（如实结果）。
    @discardableResult
    func mirror(
        item: ErrandCaseItem, caseTitle: String,
        location: String, note: String, calendar: ErrandCalendarInfo
    ) async -> Bool {
        guard await requestAccessIfNeeded() else { return false }
        // 只有用户确认的时间才能进日历。
        guard let start = item.dueAt, !item.dateUncertain else { return false }
        var table = mirrorTable()
        let existing = table[item.id.uuidString]
        guard let identifier = store.save(
            title: Self.eventTitle(caseTitle: caseTitle, itemTitle: item.title),
            location: location,
            notes: note,
            start: start,
            duration: 60 * 60,
            calendarIdentifier: calendar.id,
            existingIdentifier: existing
        ) else { return false }
        table[item.id.uuidString] = identifier
        saveMirrorTable(table)
        return true
    }

    /// 移除镜像（预约删除/用户要求停止镜像）。事件已被用户在系统侧
    /// 删除时如实清掉本地映射（remove 返回 false = 已不存在）。
    func removeMirroredAppointment(itemID: UUID) {
        var table = mirrorTable()
        guard let eventID = table[itemID.uuidString] else { return }
        _ = store.remove(identifier: eventID)
        table[itemID.uuidString] = nil
        saveMirrorTable(table)
    }

    /// 清掉事件已不存在系统侧的映射（用户在日历里删了 —— 如实反映）。
    func pruneStaleMirrors() {
        var table = mirrorTable()
        let stale = table.filter { store.event(identifier: $0.value) == nil }
        guard !stale.isEmpty else { return }
        for key in stale.keys { table[key] = nil }
        saveMirrorTable(table)
    }

    /// 清空全部映射（账号切换/删除 —— 不删用户日历里的事件本身，
    /// 只放弃本机的跟踪）。
    func clearAll() {
        saveMirrorTable([:])
    }
}
