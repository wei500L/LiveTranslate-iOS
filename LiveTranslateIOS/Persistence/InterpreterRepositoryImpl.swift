import Foundation
import SwiftData

/// Interpreter (随身翻译) repository methods — the conversation/turn
/// family of `ClassroomRepositoryProtocol`. Implemented as an extension
/// on the concrete class so it shares the model context and the
/// mutationObserver chain (the exam-family convention).
///
/// Draft semantics (the pendingConfirm candidate convention, stricter):
/// draft conversations and their turns NEVER notify the sync observer —
/// the working session is device-local; `saveInterpreterDraft` promotes
/// the whole conversation (and its turns) onto the wire in one go.
/// `discardInterpreterDraft` removes everything outright with zero wire
/// traffic. A user can have at most ONE active draft at a time.
extension TranscriptRepository {

    // MARK: - Draft lifecycle

    var interpreterDraft: InterpreterConversation? {
        let descriptor = FetchDescriptor<InterpreterConversation>()
        let rows = (try? context.fetch(descriptor)) ?? []
        return rows.first { $0.status == .draft }
    }

    func startInterpreterDraft(
        scene: InterpreterScene, contextNote: String
    ) throws -> InterpreterConversation {
        // 一次只允许一个活动中的随身翻译草稿。
        if let existing = interpreterDraft {
            return existing
        }
        let draft = InterpreterConversation(
            title: Self.defaultInterpreterTitle(scene: scene, date: .now),
            sceneRaw: scene.rawValue,
            contextNote: contextNote
        )
        context.insert(draft)
        try context.save()
        // Draft rows never notify sync.
        return draft
    }

    func interpreterDraftTurnCount() throws -> Int? {
        guard let draft = interpreterDraft else { return nil }
        return try interpreterTurns(conversationID: draft.id).count
    }

    /// 默认标题：场景显示名 · M月d日（绝不用 AI 生成标题作为保存前提）。
    static func defaultInterpreterTitle(scene: InterpreterScene, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return "\(scene.displayName) · \(formatter.string(from: date))"
    }

    func saveInterpreterDraft(title: String?) throws {
        guard let draft = interpreterDraft else { return }
        let turns = try interpreterTurns(conversationID: draft.id)
        // 空会话自动清理：不创建历史垃圾，也不上云。
        guard !turns.isEmpty else {
            try discardInterpreterDraft()
            return
        }
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.title = title
        }
        draft.status = .saved
        draft.endedAt = .now
        draft.updatedAt = .now
        try context.save()
        // The conversation AND its turns ride the wire for the first time.
        mutationObserver?.interpreterConversationSaved(draft)
        for turn in turns {
            mutationObserver?.interpreterTurnCreated(turn)
        }
    }

    func discardInterpreterDraft() throws {
        guard let draft = interpreterDraft else { return }
        let turns = try interpreterTurns(conversationID: draft.id)
        for turn in turns {
            context.delete(turn)
        }
        // The draft's local document context goes with the draft (the
        // user explicitly abandons the working session).
        try? deleteInterpreterDocuments(
            conversationID: draft.id, store: InterpreterDocumentStoreShared.store
        )
        context.delete(draft)
        try context.save()
        // Draft deletes produce no wire traffic (nothing was uploaded).
    }

    // MARK: - Turns

    func interpreterTurns(conversationID: UUID) throws -> [InterpreterTurn] {
        let descriptor = FetchDescriptor<InterpreterTurn>(
            predicate: #Predicate { $0.conversationID == conversationID }
        )
        return try context.fetch(descriptor).sorted { $0.sequence < $1.sequence }
    }

    func interpreterConversation(id: UUID) -> InterpreterConversation? {
        let descriptor = FetchDescriptor<InterpreterConversation>(
            predicate: #Predicate { $0.id == id }
        )
        return (try? context.fetch(descriptor))?.first
    }

    private func nextInterpreterSequence(conversationID: UUID) -> Int {
        let turns = (try? interpreterTurns(conversationID: conversationID)) ?? []
        return (turns.map(\.sequence).max() ?? 0) + 1
    }

    /// 对方回合：俄语原文立即落本地（翻译 pending）。草稿回合不通知 sync。
    func addInterpreterCounterpartTurn(
        conversationID: UUID, russian: String, inputMethod: InterpreterInputMethod
    ) throws -> InterpreterTurn {
        let turn = InterpreterTurn(
            conversationID: conversationID,
            speakerRaw: InterpreterSpeaker.counterpart.rawValue,
            directionRaw: InterpreterDirection.ru2zh.rawValue,
            inputMethodRaw: inputMethod.rawValue,
            sequence: nextInterpreterSequence(conversationID: conversationID),
            sourceText: russian,
            plainRussian: russian
        )
        context.insert(turn)
        try context.save()
        if turnBelongsToSavedConversation(turn) {
            mutationObserver?.interpreterTurnCreated(turn)
        }
        return turn
    }

    /// 用户回合：中文先落本地（俄语翻译 pending）。草稿回合不通知 sync。
    func addInterpreterUserTurn(
        conversationID: UUID, chinese: String, inputMethod: InterpreterInputMethod
    ) throws -> InterpreterTurn {
        let turn = InterpreterTurn(
            conversationID: conversationID,
            speakerRaw: InterpreterSpeaker.user.rawValue,
            directionRaw: InterpreterDirection.zh2ru.rawValue,
            inputMethodRaw: inputMethod.rawValue,
            sequence: nextInterpreterSequence(conversationID: conversationID),
            sourceText: chinese,
            chineseText: chinese
        )
        context.insert(turn)
        try context.save()
        if turnBelongsToSavedConversation(turn) {
            mutationObserver?.interpreterTurnCreated(turn)
        }
        return turn
    }

    /// 翻译完成：写入结构化结果。重音已在上游通过
    /// RussianStressValidator 校验（失败传 nil，界面显示"暂未生成重音标注"）。
    func completeInterpreterTurnTranslation(
        _ turn: InterpreterTurn,
        chinese: String?, russian: String?, stressedRussian: String?,
        backTranslation: String?, details: InterpreterTurnDetails?
    ) throws {
        if let chinese { turn.chineseText = chinese }
        if let russian { turn.plainRussian = russian }
        if let stressedRussian { turn.stressedRussian = stressedRussian }
        if let backTranslation { turn.backTranslation = backTranslation }
        if let details { turn.storeDetails(details) }
        turn.translationStatusRaw = InterpreterTurnTranslationStatus.completed.rawValue
        turn.updatedAt = .now
        try context.save()
        if turnBelongsToSavedConversation(turn) {
            mutationObserver?.interpreterTurnUpdated(turn)
        }
    }

    /// 翻译失败：原文保留，状态标记（用户可逐条重试）。
    func failInterpreterTurnTranslation(_ turn: InterpreterTurn) throws {
        turn.translationStatusRaw = InterpreterTurnTranslationStatus.failed.rawValue
        turn.updatedAt = .now
        try context.save()
        if turnBelongsToSavedConversation(turn) {
            mutationObserver?.interpreterTurnUpdated(turn)
        }
    }

    /// 用户编辑原文：stamp modifiedAt（同版本合并 newer wins 的裁决基准）。
    func updateInterpreterTurnSource(_ turn: InterpreterTurn, text: String) throws {
        turn.sourceText = text
        turn.modifiedAt = .now
        turn.updatedAt = .now
        try context.save()
        if turnBelongsToSavedConversation(turn) {
            mutationObserver?.interpreterTurnUpdated(turn)
        }
    }

    func deleteInterpreterTurn(_ turn: InterpreterTurn) throws {
        let saved = turnBelongsToSavedConversation(turn)
        context.delete(turn)
        try context.save()
        if saved {
            mutationObserver?.interpreterTurnDeleted(id: turn.id)
        }
    }

    // MARK: - Saved history

    func savedInterpreterConversations() throws -> [InterpreterConversation] {
        let descriptor = FetchDescriptor<InterpreterConversation>()
        return try context.fetch(descriptor)
            .filter { $0.status == .saved }
            .sorted { ($0.startedAt) > ($1.startedAt) }
    }

    func interpreterConversations(matching query: String) throws -> [InterpreterConversation] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let lowered = trimmed.lowercased()
        return ((try? savedInterpreterConversations()) ?? []).filter { conversation in
            if conversation.title.lowercased().contains(lowered) { return true }
            if conversation.scene.displayName.lowercased().contains(lowered) { return true }
            let turns = (try? interpreterTurns(conversationID: conversation.id)) ?? []
            return turns.contains { turn in
                turn.sourceText.lowercased().contains(lowered)
                    || turn.chineseText.lowercased().contains(lowered)
                    || turn.plainRussian.lowercased().contains(lowered)
            }
        }
    }

    func renameInterpreterConversation(
        _ conversation: InterpreterConversation, to title: String
    ) throws {
        conversation.title = title
        conversation.updatedAt = .now
        try context.save()
        if conversation.status == .saved {
            mutationObserver?.interpreterConversationUpdated(conversation)
        }
    }

    func updateInterpreterConversationMeta(
        _ conversation: InterpreterConversation, contextNote: String
    ) throws {
        conversation.contextNote = contextNote
        conversation.updatedAt = .now
        try context.save()
        if conversation.status == .saved {
            mutationObserver?.interpreterConversationUpdated(conversation)
        }
    }

    func deleteInterpreterConversation(_ conversation: InterpreterConversation) throws {
        let id = conversation.id
        let turns = (try? interpreterTurns(conversationID: id)) ?? []
        for turn in turns {
            context.delete(turn)
        }
        context.delete(conversation)
        try context.save()
        // The conversation's LOCAL document context is reaped after the
        // row is gone (never resurrected by a late task — rows delete
        // first, so a late file write becomes an orphan the store-level
        // cleanup reaps).
        try? deleteInterpreterDocuments(
            conversationID: id, store: InterpreterDocumentStoreShared.store
        )
        if conversation.status == .saved {
            mutationObserver?.interpreterConversationDeleted(id: id)
        }
    }

    // MARK: - Remote apply (pull)

    func applyRemoteInterpreterConversation(
        record: SyncServerRecordDTO, serverVersion: Int
    ) throws {
        guard let recordID = record.id else { return }
        let descriptor = FetchDescriptor<InterpreterConversation>(
            predicate: #Predicate { $0.id == recordID }
        )
        let existing = try context.fetch(descriptor).first
        if let existing, existing.serverVersion >= serverVersion { return }

        let conversation: InterpreterConversation
        if let existing {
            conversation = existing
        } else {
            conversation = InterpreterConversation(
                id: recordID,
                title: "",
                sceneRaw: InterpreterScene.general.rawValue
            )
            context.insert(conversation)
        }
        if let title = record.title { conversation.title = title }
        if let scene = record.interpreterScene,
           let parsed = InterpreterScene(rawValue: scene) {
            conversation.sceneRaw = parsed.rawValue
        }
        if let contextNote = record.interpreterContextNote {
            conversation.contextNote = contextNote
        }
        if let status = record.interpreterStatus,
           let parsed = InterpreterConversationStatus(rawValue: status) {
            conversation.statusRaw = parsed.rawValue
        }
        if let startedAt = record.interpreterStartedAt {
            conversation.startedAt = startedAt
        }
        conversation.endedAt = record.interpreterEndedAt
        conversation.serverVersion = serverVersion
        conversation.updatedAt = .now
        try context.save()
    }

    func applyRemoteInterpreterTurn(
        record: SyncServerRecordDTO, serverVersion: Int
    ) throws {
        guard let recordID = record.id,
              let conversationID = record.conversationId else { return }
        // Turn rows may arrive before their conversation (the wire
        // convention) — ensure the parent exists as a shell.
        if interpreterConversation(id: conversationID) == nil {
            let shell = InterpreterConversation(
                id: conversationID, title: "", sceneRaw: InterpreterScene.general.rawValue
            )
            context.insert(shell)
        }
        let descriptor = FetchDescriptor<InterpreterTurn>(
            predicate: #Predicate { $0.id == recordID }
        )
        let existing = try context.fetch(descriptor).first
        if let existing, existing.serverVersion >= serverVersion { return }

        let turn: InterpreterTurn
        if let existing {
            turn = existing
        } else {
            turn = InterpreterTurn(
                id: recordID,
                conversationID: conversationID,
                speakerRaw: InterpreterSpeaker.counterpart.rawValue,
                directionRaw: InterpreterDirection.ru2zh.rawValue,
                inputMethodRaw: InterpreterInputMethod.audio.rawValue,
                sequence: record.turnSequence ?? 0,
                sourceText: ""
            )
            context.insert(turn)
        }
        turn.conversationID = conversationID
        if let speaker = record.turnSpeaker,
           let parsed = InterpreterSpeaker(rawValue: speaker) {
            turn.speakerRaw = parsed.rawValue
        }
        if let direction = record.turnDirection,
           let parsed = InterpreterDirection(rawValue: direction) {
            turn.directionRaw = parsed.rawValue
        }
        if let method = record.turnInputMethod,
           let parsed = InterpreterInputMethod(rawValue: method) {
            turn.inputMethodRaw = parsed.rawValue
        }
        if let sequence = record.turnSequence { turn.sequence = sequence }
        if let source = record.turnSourceText { turn.sourceText = source }
        if let plain = record.turnPlainRussian { turn.plainRussian = plain }
        if let stressed = record.turnStressedRussian { turn.stressedRussian = stressed }
        if let chinese = record.turnChineseText { turn.chineseText = chinese }
        if let back = record.turnBackTranslation { turn.backTranslation = back }
        if let details = record.turnDetails { turn.detailsJSON = details }
        turn.modifiedAt = record.turnModifiedAt
        turn.translationStatusRaw = InterpreterTurnTranslationStatus.completed.rawValue
        turn.serverVersion = serverVersion
        turn.updatedAt = .now
        try context.save()
    }

    func deleteInterpreterConversationByID(_ id: UUID) throws {
        guard let conversation = interpreterConversation(id: id) else { return }
        // 幂等：直接删除（本地不存墓碑，delete-wins 在 push 冲突分支执行）。
        try deleteInterpreterConversation(conversation)
    }

    func deleteInterpreterTurnByID(_ id: UUID) throws {
        let descriptor = FetchDescriptor<InterpreterTurn>(
            predicate: #Predicate { $0.id == id }
        )
        guard let turn = try context.fetch(descriptor).first else { return }
        try deleteInterpreterTurn(turn)
    }

    // MARK: - Helpers

    private func turnBelongsToSavedConversation(_ turn: InterpreterTurn) -> Bool {
        interpreterConversation(id: turn.conversationID)?.status == .saved
    }
}
