import Foundation
import SwiftData

// 随身翻译（interpreter）持久化实体：保存的办事对话与其回合。
//
// 生命周期：工作中的会话以 `status == .draft` 的行存在（草稿，每个
// 账号同时至多一个），每个已完成回合及时落本地；草稿永不进入 outbox
// （CloudSyncService 只在 status 变为 .saved 后入队）。保存 → 进入正式
// 历史与云同步；丢弃 → 连同回合一起删除。音频、模型 prompt、原始模型
// 响应一律不存。
//
// 惯例与仓库其余实体一致：跨实体引用存裸 UUID（conversationID），
// 不用 SwiftData relationship；serverVersion 0 = 从未同步。

/// 一次面对面办事翻译对话。
@Model
final class InterpreterConversation {
    @Attribute(.unique) var id: UUID
    var title: String
    /// 场景 raw value（InterpreterScene.rawValue）。
    var sceneRaw: String
    /// 用户临时背景（可见、可编辑、可清除；不隐式携带到其他会话）。
    var contextNote: String
    /// draft | saved | discarded（草稿永不上传）。
    var statusRaw: String
    var startedAt: Date
    var endedAt: Date?
    var createdAt: Date
    var updatedAt: Date
    /// 0 = 从未同步；accepted push 后单调上调。
    var serverVersion: Int

    init(
        id: UUID = UUID(),
        title: String,
        sceneRaw: String,
        contextNote: String = "",
        statusRaw: String = InterpreterConversationStatus.draft.rawValue,
        startedAt: Date = .now,
        endedAt: Date? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        serverVersion: Int = 0
    ) {
        self.id = id
        self.title = title
        self.sceneRaw = sceneRaw
        self.contextNote = contextNote
        self.statusRaw = statusRaw
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.serverVersion = serverVersion
    }

    var scene: InterpreterScene {
        get { InterpreterScene(rawValue: sceneRaw) ?? .general }
        set { sceneRaw = newValue.rawValue }
    }

    var status: InterpreterConversationStatus {
        get { InterpreterConversationStatus(rawValue: statusRaw) ?? .draft }
        set { statusRaw = newValue.rawValue }
    }
}

/// 一个对话回合：对方说俄语（ru2zh）或用户回复中文（zh2ru）。
@Model
final class InterpreterTurn {
    @Attribute(.unique) var id: UUID
    /// 所属对话（裸 UUID 引用 —— 子行可能先于父行到达）。
    var conversationID: UUID
    /// counterpart | user（InterpreterSpeaker.rawValue）。
    var speakerRaw: String
    /// ru2zh | zh2ru（InterpreterDirection.rawValue）。
    var directionRaw: String
    /// audio | text（InterpreterInputMethod.rawValue）。
    var inputMethodRaw: String
    /// 会话内的追加顺序。
    var sequence: Int
    /// 说话方原话（对方=俄语，用户=中文）。
    var sourceText: String
    /// 普通俄语（无重音；TTS 与搜索用它）。
    var plainRussian: String
    /// 带重音俄语（U+0301 组合重音；仅展示）。校验失败时为空串并显示
    /// "暂未生成重音标注"。
    var stressedRussian: String
    /// 中文翻译（对方回合）或用户中文原文（用户回合）。
    var chineseText: String
    /// 中文回译（zh2ru 回合，供用户核对）。
    var backTranslation: String
    /// InterpreterTurnDetails JSON（结构化详情快照；用户选择保留的
    /// 内容，绝不含 prompt 或原始模型响应）。空串 = 无。可随 turn
    /// 同步 —— 但第十七轮起只允许非来源型结构信息（来源标签走
    /// localSourcesJSON）。
    var detailsJSON: String
    /// [InterpreterLocalSource] JSON —— 文件上下文回合的本地来源
    /// （文件名/页码/documentID/短引文）。设备本地字段：不进 wire、
    /// 不进 outbox、其他设备永远收不到。旧数据由一次性迁移回填。
    /// 空串 = 无本地来源。
    var localSourcesJSON: String
    /// 翻译状态：pending | completed | failed（failed 时原文仍保留）。
    var translationStatusRaw: String
    /// 用户编辑裁决时间戳（同版本合并 newer wins；从未编辑为 nil）。
    var modifiedAt: Date?
    var createdAt: Date
    var updatedAt: Date
    var serverVersion: Int

    init(
        id: UUID = UUID(),
        conversationID: UUID,
        speakerRaw: String,
        directionRaw: String,
        inputMethodRaw: String,
        sequence: Int,
        sourceText: String,
        plainRussian: String = "",
        stressedRussian: String = "",
        chineseText: String = "",
        backTranslation: String = "",
        detailsJSON: String = "",
        localSourcesJSON: String = "",
        translationStatusRaw: String = "pending",
        modifiedAt: Date? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        serverVersion: Int = 0
    ) {
        self.id = id
        self.conversationID = conversationID
        self.speakerRaw = speakerRaw
        self.directionRaw = directionRaw
        self.inputMethodRaw = inputMethodRaw
        self.sequence = sequence
        self.sourceText = sourceText
        self.plainRussian = plainRussian
        self.stressedRussian = stressedRussian
        self.chineseText = chineseText
        self.backTranslation = backTranslation
        self.detailsJSON = detailsJSON
        self.localSourcesJSON = localSourcesJSON
        self.translationStatusRaw = translationStatusRaw
        self.modifiedAt = modifiedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.serverVersion = serverVersion
    }

    var speaker: InterpreterSpeaker {
        get { InterpreterSpeaker(rawValue: speakerRaw) ?? .counterpart }
        set { speakerRaw = newValue.rawValue }
    }

    var direction: InterpreterDirection {
        get { InterpreterDirection(rawValue: directionRaw) ?? .ru2zh }
        set { directionRaw = newValue.rawValue }
    }

    var inputMethod: InterpreterInputMethod {
        get { InterpreterInputMethod(rawValue: inputMethodRaw) ?? .audio }
        set { inputMethodRaw = newValue.rawValue }
    }

    /// 解码后的结构化详情（坏 JSON → 纯文本回退，绝不崩溃）。
    var details: InterpreterTurnDetails? {
        guard !detailsJSON.isEmpty else { return nil }
        return try? JSONDecoder().decode(InterpreterTurnDetails.self, from: Data(detailsJSON.utf8))
    }

    /// 翻译状态（沿用课堂 EntryPhase 的词汇）。
    var translationCompleted: Bool { translationStatusRaw == "completed" }
    var translationFailed: Bool { translationStatusRaw == "failed" }

    /// 保存详情（编码失败时丢弃 —— 主翻译文本永远已在行上）。
    func storeDetails(_ details: InterpreterTurnDetails) {
        guard let data = try? JSONEncoder().encode(details) else { return }
        detailsJSON = String(data: data, encoding: .utf8) ?? ""
    }

    /// 解码后的本地来源列表（坏 JSON / 空串 → nil）。
    var localSources: [InterpreterLocalSource]? {
        guard !localSourcesJSON.isEmpty else { return nil }
        return try? JSONDecoder().decode(
            [InterpreterLocalSource].self, from: Data(localSourcesJSON.utf8)
        )
    }

    /// 保存本地来源（设备本地字段 —— 出站 wire 从不读取它）。
    func storeLocalSources(_ sources: [InterpreterLocalSource]) {
        guard let data = try? JSONEncoder().encode(sources) else { return }
        localSourcesJSON = String(data: data, encoding: .utf8) ?? ""
    }
}

/// 回合翻译状态（本地状态机；不上传原始模型响应，只有终态入 wire）。
enum InterpreterTurnTranslationStatus: String, Codable, Sendable {
    case pending
    case completed
    case failed
}
