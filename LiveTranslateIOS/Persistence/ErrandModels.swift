import Foundation
import SwiftData

// 办事事项（errand case）持久化实体：一件持续办理的现实事务 —— 宿舍
// 登记、银行卡、就诊、签证材料 —— 组织成可执行、可核对、可提醒、可
// 跟进的清单。把第十五轮的随身翻译和第十六轮的文件助手从"单次对话"
// 组织成"完整闭环"。
//
// 生命周期（随身翻译的草稿惯例，放宽为多草稿）：工作中的候选以
// `status == .draft` 的行存在（设备本地，每账号可同时多个 —— 用户可
// 以同时准备几件事），AI/本地规则只创建或更新 draft；用户显式保存
// 后才成为正式同步对象（repository 不再为 draft 行通知 sync，
// CloudSyncService 的 enqueue 守卫是同一扇门上的第二道锁）。
//
// 惯例与仓库其余实体一致：跨实体引用存裸 UUID（caseID /
// conversationID / documentID），不用 SwiftData relationship；
// serverVersion 0 = 从未同步。
//
// 设备本地字段：localSourcesJSON（对话/文件的本地来源链接 —— 文件名、
// 页码、documentID、短引文）绝不进 wire、不进 outbox、其他设备永远收
// 不到（第十七轮边界）。wire 上只有无内容的 hasLocalSources 布尔标志。

/// 一件持续办理的办事事项。
@Model
final class ErrandCase {
    @Attribute(.unique) var id: UUID
    var title: String
    /// 场景 raw value（InterpreterScene.rawValue —— 与随身翻译共用同一
    /// 场景选择器）。
    var sceneRaw: String
    /// draft | preparing | scheduled | waitingForResult | needsFollowUp |
    /// completed | cancelled | archived（客户端管理，服务器只存不解释）。
    var statusRaw: String
    /// 用户确认后的简短目的/摘要（全量期望态，空串清除）。
    var purpose: String
    /// 用户备注。
    var userNote: String
    /// IANA 时区标识（事项各墙钟时间的锚；空串 = 未设置）。
    var timezoneID: String
    /// 地点（允许为空，不能由模型编造）。
    var location: String
    /// 联系方式（允许为空，不能由模型编造）。
    var contact: String
    /// 预计结果时间（waitingForResult 语义 —— 预约/截止/跟进时间在各自
    /// 的 item 上，绝不混在此处）。
    var expectedResultAt: Date?
    /// 用户置顶（首页显示条件之一）。
    var pinned: Bool
    /// 无内容标志：保存设备存在本地来源链接。链接本身（文件名/页码/
    /// 引文/documentID）永不上传。
    var hasLocalSources: Bool
    /// [ErrandLocalSource] JSON —— 设备本地来源链接。不进 wire、不进
    /// outbox、其他设备永远收不到。空串 = 无。
    var localSourcesJSON: String
    var createdAt: Date
    var updatedAt: Date
    /// 0 = 从未同步；accepted push 后单调上调。
    var serverVersion: Int

    init(
        id: UUID = UUID(),
        title: String,
        sceneRaw: String,
        statusRaw: String = ErrandCaseStatus.draft.rawValue,
        purpose: String = "",
        userNote: String = "",
        timezoneID: String = "",
        location: String = "",
        contact: String = "",
        expectedResultAt: Date? = nil,
        pinned: Bool = false,
        hasLocalSources: Bool = false,
        localSourcesJSON: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now,
        serverVersion: Int = 0
    ) {
        self.id = id
        self.title = title
        self.sceneRaw = sceneRaw
        self.statusRaw = statusRaw
        self.purpose = purpose
        self.userNote = userNote
        self.timezoneID = timezoneID
        self.location = location
        self.contact = contact
        self.expectedResultAt = expectedResultAt
        self.pinned = pinned
        self.hasLocalSources = hasLocalSources
        self.localSourcesJSON = localSourcesJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.serverVersion = serverVersion
    }

    var scene: InterpreterScene {
        get { InterpreterScene(rawValue: sceneRaw) ?? .general }
        set { sceneRaw = newValue.rawValue }
    }

    var status: ErrandCaseStatus {
        get { ErrandCaseStatus(rawValue: statusRaw) ?? .draft }
        set { statusRaw = newValue.rawValue }
    }

    /// 解码后的本地来源列表（坏 JSON / 空串 → nil）。
    var localSources: [ErrandLocalSource]? {
        guard !localSourcesJSON.isEmpty else { return nil }
        return try? JSONDecoder().decode(
            [ErrandLocalSource].self, from: Data(localSourcesJSON.utf8)
        )
    }

    /// 保存本地来源（设备本地字段 —— 出站 wire 从不读取它）。
    func storeLocalSources(_ sources: [ErrandLocalSource]) {
        guard let data = try? JSONEncoder().encode(sources) else { return }
        localSourcesJSON = String(data: data, encoding: .utf8) ?? ""
    }
}

/// 事项清单中的一行：材料、动作、问题、付款、预约、截止或跟进。
@Model
final class ErrandCaseItem {
    @Attribute(.unique) var id: UUID
    /// 所属事项（裸 UUID 引用 —— 子行可能先于父行到达）。
    var caseID: UUID
    var title: String
    /// requiredDocument | action | question | payment | appointment |
    /// deadline | followUp（ErrandCaseItemKind.rawValue）。
    var kindRaw: String
    /// unconfirmed | pending | done | skipped。
    var statusRaw: String
    /// 清单内排序。
    var sequence: Int
    /// 可选说明（材料说明如 原件/复印件/翻译件/公证件）。
    var detail: String
    /// 用户确认后的时间（绝对时刻；nil = 未确认时间）。只有用户明确
    /// 确认后才持久化为可提醒时间。
    var dueAt: Date?
    /// 日期原文（如"周五之前"/"до пятницы"），保留原样。
    var dateText: String
    /// 是否为相对日期换算（锚点 = 来源时间 + 用户当前时区）。
    var dateIsRelative: Bool
    /// 换算后是否仍有歧义（歧义项绝不能自动调度提醒）。
    var dateUncertain: Bool
    /// manual | ai（ai = 用户确认过的 AI 候选 —— 模型绝不直接写行）。
    var originRaw: String
    /// 用户是否已确认（AI 候选逐项勾选后置位；粘滞 —— 迟到重放不取消）。
    var confirmed: Bool
    /// 费用原始文本（仅来源明确或用户填写时保存）。
    var feeText: String
    /// 费用数值（可选；不做汇率换算，不猜币种）。
    var feeAmount: Double?
    /// 币种（如 RUB；空串 = 未设置）。
    var feeCurrency: String
    /// 用户编辑裁决时间戳（同版本合并 newer wins；从未编辑为 nil）。
    var modifiedAt: Date?
    /// 完成时间（done 时打点）。
    var completedAt: Date?
    var createdAt: Date
    var updatedAt: Date
    var serverVersion: Int

    init(
        id: UUID = UUID(),
        caseID: UUID,
        title: String,
        kindRaw: String,
        statusRaw: String = ErrandCaseItemStatus.pending.rawValue,
        sequence: Int = 0,
        detail: String = "",
        dueAt: Date? = nil,
        dateText: String = "",
        dateIsRelative: Bool = false,
        dateUncertain: Bool = false,
        originRaw: String = ErrandCaseItemOrigin.manual.rawValue,
        confirmed: Bool = true,
        feeText: String = "",
        feeAmount: Double? = nil,
        feeCurrency: String = "",
        modifiedAt: Date? = nil,
        completedAt: Date? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        serverVersion: Int = 0
    ) {
        self.id = id
        self.caseID = caseID
        self.title = title
        self.kindRaw = kindRaw
        self.statusRaw = statusRaw
        self.sequence = sequence
        self.detail = detail
        self.dueAt = dueAt
        self.dateText = dateText
        self.dateIsRelative = dateIsRelative
        self.dateUncertain = dateUncertain
        self.originRaw = originRaw
        self.confirmed = confirmed
        self.feeText = feeText
        self.feeAmount = feeAmount
        self.feeCurrency = feeCurrency
        self.modifiedAt = modifiedAt
        self.completedAt = completedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.serverVersion = serverVersion
    }

    var kind: ErrandCaseItemKind {
        get { ErrandCaseItemKind(rawValue: kindRaw) ?? .action }
        set { kindRaw = newValue.rawValue }
    }

    var status: ErrandCaseItemStatus {
        get { ErrandCaseItemStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    var origin: ErrandCaseItemOrigin {
        get { ErrandCaseItemOrigin(rawValue: originRaw) ?? .manual }
        set { originRaw = newValue.rawValue }
    }
}

// MARK: - 状态机

/// 事项生命周期。draft 是设备本地草稿（永不入 outbox）；scheduled 仅在
/// 用户确认预约后进入（识别到日期绝不自动进入）；completed 不自动删除
/// 历史，可归档；归档后可显式重开（历史保留）。
enum ErrandCaseStatus: String, Codable, Sendable, CaseIterable {
    case draft
    case preparing
    case scheduled
    case waitingForResult
    case needsFollowUp
    case completed
    case cancelled
    case archived

    var displayName: String {
        switch self {
        case .draft: return "草稿"
        case .preparing: return "准备材料"
        case .scheduled: return "已预约"
        case .waitingForResult: return "等待结果"
        case .needsFollowUp: return "需要跟进"
        case .completed: return "已完成"
        case .cancelled: return "已取消"
        case .archived: return "已归档"
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .cancelled, .archived: return true
        case .draft, .preparing, .scheduled, .waitingForResult, .needsFollowUp:
            return false
        }
    }

    var isFormal: Bool { self != .draft }

    /// 受约束的转换（UI 与 repository 双重执行；不合法转换直接拒绝）。
    /// 规则：draft 只能由用户保存升为正式态；正式活动态之间可由用户
    /// 显式切换；任何活动态可完成/取消；完成/取消可归档；归档可显式
    /// 重开为准备中。terminal 态之间除归档外不可互转。
    func canTransition(to next: ErrandCaseStatus) -> Bool {
        switch (self, next) {
        case (.draft, _):
            // 保存：用户确认后进入任一正式态（通常是 preparing/scheduled）。
            return next.isFormal
        case (_, .draft):
            // 正式事项绝不退回草稿。
            return false
        case (.archived, .preparing):
            return true
        case (.completed, .archived), (.cancelled, .archived):
            return true
        case (.completed, _), (.cancelled, _), (.archived, _):
            return false
        default:
            // preparing/scheduled/waitingForResult/needsFollowUp 之间的
            // 显式切换 + 完成/取消。
            return true
        }
    }
}

// MARK: - 清单项

/// 清单项类型。预约、截止、后续跟进是三种不同的时间语义，绝不能混成
/// 一个 dueDate 语义 —— 它们只是共享"带确认时间"的行结构。
enum ErrandCaseItemKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case requiredDocument
    case action
    case question
    case payment
    case appointment
    case deadline
    case followUp

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .requiredDocument: return "材料"
        case .action: return "动作"
        case .question: return "要问的问题"
        case .payment: return "费用"
        case .appointment: return "预约"
        case .deadline: return "截止"
        case .followUp: return "跟进"
        }
    }

    var symbol: String {
        switch self {
        case .requiredDocument: return "doc.text"
        case .action: return "figure.walk"
        case .question: return "questionmark.bubble"
        case .payment: return "banknote"
        case .appointment: return "calendar.badge.clock"
        case .deadline: return "flag.checkered"
        case .followUp: return "arrow.clockwise.circle"
        }
    }

    /// 该类型的行是否承载一个可确认的时间语义（预约/截止/跟进）。
    var carriesTime: Bool {
        switch self {
        case .appointment, .deadline, .followUp: return true
        default: return false
        }
    }
}

/// 清单项状态。unconfirmed 是 AI/规则候选的初始态（设备本地，不入同步
/// —— 与 StudyTask pendingConfirm 惯例一致：候选不确认不上船）。
enum ErrandCaseItemStatus: String, Codable, Sendable {
    case unconfirmed
    case pending
    case done
    case skipped

    var displayName: String {
        switch self {
        case .unconfirmed: return "待确认"
        case .pending: return "待处理"
        case .done: return "已完成"
        case .skipped: return "已跳过"
        }
    }
}

/// 清单项来源：手动或 AI 建议（AI 候选必须经用户逐项确认）。
enum ErrandCaseItemOrigin: String, Codable, Sendable {
    case manual
    case ai

    var displayName: String {
        switch self {
        case .manual: return "手动"
        case .ai: return "AI 建议"
        }
    }
}

// MARK: - 设备本地来源链接

/// 事项与随身翻译对话/现场文件的本地来源链接。多对多：一个来源可被
/// 多个事项引用（每个事项存自己的链接记录）；删除事项不删原对话/原
/// 文件；删除原文件后事项仍可用已确认的结构化内容，本地来源如实显示
/// "原文件已从本机删除"。
///
/// 设备本地字段（第十七轮边界）：文件名、页码、documentID、短引文绝
/// 不进 wire —— 出站 payload(for:) 从不读取 localSourcesJSON。
struct ErrandLocalSource: Codable, Sendable, Equatable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case conversation
        case document
    }

    var id: UUID = UUID()
    var kind: Kind
    /// kind == .conversation 时的对话 id。
    var conversationID: UUID?
    /// kind == .document 时的现场文件 id。
    var documentID: UUID?
    /// 设备本地的文件显示名（仅本机展示；绝不进 wire）。
    var documentName: String
    /// 页码（document 来源可选）。
    var pageNumber: Int?
    /// 短引文（经第十六轮三重校验后保留；绝不进 wire）。
    var snippet: String
    /// 加入时间（列表排序）。
    var addedAt: Date = .now

    init(
        kind: Kind,
        conversationID: UUID? = nil,
        documentID: UUID? = nil,
        documentName: String = "",
        pageNumber: Int? = nil,
        snippet: String = "",
        addedAt: Date = .now
    ) {
        self.kind = kind
        self.conversationID = conversationID
        self.documentID = documentID
        self.documentName = documentName
        self.pageNumber = pageNumber
        self.snippet = snippet
        self.addedAt = addedAt
    }

    /// 幂等键：同一对话或同一文件（+页）重复加入同一事项时判定重复。
    var dedupKey: String {
        switch kind {
        case .conversation:
            return "c:\(conversationID?.uuidString ?? "")"
        case .document:
            return "d:\(documentID?.uuidString ?? "")#\(pageNumber ?? 0)"
        }
    }
}
