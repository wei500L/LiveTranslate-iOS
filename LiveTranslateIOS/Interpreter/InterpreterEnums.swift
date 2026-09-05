import Foundation

/// 办事场景：随身翻译面对面的场景选择。场景只影响术语倾向、礼貌
/// 程度、快捷问题与 AI prompt 背景 —— 它绝不硬编码翻译结果。
enum InterpreterScene: String, Codable, CaseIterable, Identifiable, Sendable {
    case general
    case school
    case dorm
    case bank
    case hospital
    case migration
    case telecom
    case post

    var id: String { rawValue }

    /// Wire 值与 Go 服务端 00014 的 allowlist 一致。
    var wireValue: String { rawValue }

    var displayName: String {
        switch self {
        case .general: return "通用"
        case .school: return "学校"
        case .dorm: return "宿舍"
        case .bank: return "银行"
        case .hospital: return "医院/药店"
        case .migration: return "签证/登记"
        case .telecom: return "通信营业厅"
        case .post: return "快递/购物"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "bubble.left.and.bubble.right"
        case .school: return "graduationcap"
        case .dorm: return "house"
        case .bank: return "banknote"
        case .hospital: return "cross.case"
        case .migration: return "checklist"
        case .telecom: return "antenna.radiowaves.left.and.right"
        case .post: return "shippingbox"
        }
    }

    /// AI prompt 中的背景描述（术语倾向与礼貌程度的提示）。
    var promptBackground: String {
        switch self {
        case .general: return "日常办事对话"
        case .school: return "学校外事办公室（教务、签证支持、宿舍分配）"
        case .dorm: return "宿舍管理处（入住、维修、缴费、门禁）"
        case .bank: return "银行（开户、汇款、取款、银行卡）"
        case .hospital: return "医院或药店（挂号、就诊、买药）"
        case .migration: return "移民局/签证登记手续（落地签、居留许可）"
        case .telecom: return "手机通信营业厅（办卡、套餐、缴费）"
        case .post: return "快递、商店和物业（取件、退换、报修）"
        }
    }
}

/// 回合说话方：对方（俄语工作人员）或用户（中文）。
enum InterpreterSpeaker: String, Codable, Sendable {
    case counterpart
    case user

    var displayName: String {
        switch self {
        case .counterpart: return "对方说"
        case .user: return "我的回复"
        }
    }
}

/// 翻译方向：俄→中（对方回合）或中→俄（用户回合）。
enum InterpreterDirection: String, Codable, Sendable {
    case ru2zh
    case zh2ru
}

/// 回合输入方式：本地 ASR 语音或系统键盘/听写文本。
enum InterpreterInputMethod: String, Codable, Sendable {
    case audio
    case text
}

/// 会话生命周期：草稿（本地，永不上传）→ 保存（进入同步）或丢弃。
enum InterpreterConversationStatus: String, Codable, Sendable {
    case draft
    case saved
    case discarded
}

/// 用户回复的语气选择（影响中→俄生成的礼貌层级）。
enum InterpreterTone: String, Codable, CaseIterable, Identifiable, Sendable {
    case polite
    case neutral
    case simple

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .polite: return "礼貌正式"
        case .neutral: return "自然"
        case .simple: return "简单直接"
        }
    }
}
