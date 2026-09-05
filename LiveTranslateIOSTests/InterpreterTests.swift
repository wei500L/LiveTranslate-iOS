import XCTest
import SwiftData
@testable import LiveTranslateIOS

final class InterpreterTests: XCTestCase {
    // MARK: - 俄语重音校验

    func testStressValidatorAcceptsCorrectStress() {
        XCTAssertTrue(RussianStressValidator.isValid(
            stressed: "докуме́нт",
            plain: "документ"
        ))
        XCTAssertTrue(RussianStressValidator.isValid(
            stressed: "общежи́тие",
            plain: "общежитие"
        ))
    }

    func testStressValidatorRejectsChangedCharacters() {
        // 重音版本不得修改词语 —— е 被换成了 ё 之外的字.
        XCTAssertFalse(RussianStressValidator.isValid(
            stressed: "документх",
            plain: "документ"
        ))
        // 标点被改动.
        XCTAssertFalse(RussianStressValidator.isValid(
            stressed: "документ!",
            plain: "документ?"
        ))
    }

    func testStressValidatorRejectsEYoSubstitution() {
        // ё 不应被替换：е́ 和 ё 是不同的字符。
        XCTAssertFalse(RussianStressValidator.isValid(
            stressed: "ёлка",
            plain: "е́лка"
        ))
    }

    func testStripStress() {
        XCTAssertEqual(
            RussianStressValidator.stripStress("докуме́нт"),
            "документ"
        )
        XCTAssertEqual(
            RussianStressValidator.stripStress("без重音"),
            "без重音"
        )
    }

    func testValidatedReturnsNilForIdenticalOrInvalid() {
        // 与普通版本相同（没有重音可言）。
        XCTAssertNil(RussianStressValidator.validated(
            stressed: "документ", plain: "документ"
        ))
        // 校验失败 → nil（调用方保留普通俄语）。
        XCTAssertNil(RussianStressValidator.validated(
            stressed: "другой", plain: "документ"
        ))
        // 空。
        XCTAssertNil(RussianStressValidator.validated(stressed: nil, plain: "документ"))
    }

    // MARK: - 解析器（zh2ru）

    func testParseZh2RuFullJSON() {
        let raw = """
        {"russian": "У меня есть только оригинал.", "stressedRussian": "У меня есть то́лько оригина́л.", "backTranslation": "我只有原件。", "keywords": ["оригинал 原件"], "politeAlternative": "Не могли бы вы подсказать?", "simpleAlternative": "Где копия?", "uncertainties": ["确认证件类型"]}
        """
        let result = InterpreterResponseParser.parseZh2Ru(raw)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.mainText, "У меня есть только оригинал.")
        XCTAssertEqual(result?.stressedRussian, "У меня есть то́лько оригина́л.")
        XCTAssertEqual(result?.backTranslation, "我只有原件。")
        XCTAssertEqual(result?.details.keywords?.count, 1)
        XCTAssertEqual(result?.details.politeAlternative, "Не могли бы вы подсказать?")
        XCTAssertEqual(result?.isPlainTextResponse, false)
    }

    func testParseZh2RuToleratesFencesAndProse() {
        let raw = """
        好的，以下是翻译：
        ```json
        {"russian": "Можно сделать копию здесь?", "stressedRussian": "Мо́жно сде́лать ко́пию здесь?"}
        ```
        希望对你有帮助。
        """
        let result = InterpreterResponseParser.parseZh2Ru(raw)
        XCTAssertEqual(result?.mainText, "Можно сделать копию здесь?")
        XCTAssertEqual(result?.stressedRussian, "Мо́жно сде́лать ко́пию здесь?")
    }

    func testParseZh2RuPartialFields() {
        let raw = """
        {"russian": "Хорошо."}
        """
        let result = InterpreterResponseParser.parseZh2Ru(raw)
        XCTAssertEqual(result?.mainText, "Хорошо.")
        XCTAssertNil(result?.stressedRussian)
        XCTAssertNil(result?.backTranslation)
        XCTAssertNil(result?.details.keywords)
    }

    func testParseZh2RuStringInsteadOfArray() {
        // 字符串/数组混用：单字符串 → 单元素数组。
        let raw = """
        {"russian": "Хорошо.", "keywords": "оригинал 原件"}
        """
        let result = InterpreterResponseParser.parseZh2Ru(raw)
        XCTAssertEqual(result?.details.keywords, ["оригинал 原件"])
    }

    func testParseZh2RuPlainTextFallback() {
        // 纯文本响应：不丢弃可读翻译，诚实说明详细解释不可用。
        let raw = "Можно сделать копию здесь?"
        let result = InterpreterResponseParser.parseZh2Ru(raw)
        XCTAssertEqual(result?.mainText, "Можно сделать копию здесь?")
        XCTAssertEqual(result?.isPlainTextResponse, true)
        XCTAssertEqual(result?.details.detailsAvailable, false)
    }

    func testParseZh2RuInvalidStressDiscarded() {
        // 重音校验不通过 → 丢弃重音版本，保留普通俄语。
        let raw = """
        {"russian": "документ", "stressedRussian": "совсем другой текст"}
        """
        let result = InterpreterResponseParser.parseZh2Ru(raw)
        XCTAssertEqual(result?.mainText, "документ")
        XCTAssertNil(result?.stressedRussian)
    }

    // MARK: - 解析器（ru2zh）

    func testParseRu2ZhFullJSON() {
        let raw = """
        {"chinese": "您有护照复印件吗？", "stressedRussian": "У вас есть ко́пия па́спорта?", "intent": "询问材料", "keywords": ["паспорт 护照"], "ambiguity": "", "suggestions": ["我只有原件，可以在这里复印吗？", "我明天带来复印件"]}
        """
        let result = InterpreterResponseParser.parseRu2Zh(raw)
        XCTAssertEqual(result?.mainText, "您有护照复印件吗？")
        XCTAssertEqual(result?.stressedRussian, "У вас есть ко́пия па́спорта?")
        XCTAssertEqual(result?.details.intentSummary, "询问材料")
        XCTAssertEqual(result?.details.suggestedReplies?.count, 2)
    }

    func testParseRu2ZhPlainTextFallback() {
        let raw = "您有护照复印件吗？"
        let result = InterpreterResponseParser.parseRu2Zh(raw)
        XCTAssertEqual(result?.mainText, "您有护照复印件吗？")
        XCTAssertEqual(result?.isPlainTextResponse, true)
    }

    // MARK: - jsonPayload 容忍度

    func testJsonPayloadFenceStripping() {
        XCTAssertEqual(
            InterpreterResponseParser.jsonPayload(from: "```json\n{\"a\":1}\n```"),
            "{\"a\":1}"
        )
        XCTAssertEqual(
            InterpreterResponseParser.jsonPayload(from: "```\n{\"a\":1}\n```"),
            "{\"a\":1}"
        )
    }

    func testJsonPayloadProseTolerance() {
        XCTAssertEqual(
            InterpreterResponseParser.jsonPayload(from: "前言 {\"a\":1} 后记"),
            "{\"a\":1}"
        )
        // 无 JSON → nil。
        XCTAssertNil(InterpreterResponseParser.jsonPayload(from: "纯文本没有大括号"))
    }

    // MARK: - 上下文构建与裁剪

    private func projection(
        _ speaker: InterpreterSpeaker, source: String, translation: String?
    ) -> InterpreterContextBuilder.TurnProjection {
        InterpreterContextBuilder.TurnProjection(
            speaker: speaker,
            direction: speaker == .counterpart ? .ru2zh : .zh2ru,
            sourceText: source,
            translatedText: translation,
            translationFailed: false
        )
    }

    func testContextBuilderBoundedTurns() {
        var turns: [InterpreterContextBuilder.TurnProjection] = []
        for index in 0..<20 {
            turns.append(projection(
                .counterpart,
                source: "Строка \(index)",
                translation: "第 \(index) 句"
            ))
        }
        let builder = InterpreterContextBuilder(maxTurns: 8, maxCharacters: 10_000)
        let context = builder.buildContext(turns)
        // 只包含最近 8 个回合。
        XCTAssertTrue(context.contains("Строка 19"))
        XCTAssertTrue(context.contains("Строка 12"))
        XCTAssertFalse(context.contains("Строка 11"))
        XCTAssertFalse(context.contains("Строка 0"))
    }

    func testContextBuilderTrimsWholeTurnsByCharacters() {
        var turns: [InterpreterContextBuilder.TurnProjection] = []
        for index in 0..<10 {
            turns.append(projection(
                .counterpart,
                source: String(repeating: "长", count: 100) + "\(index)",
                translation: nil
            ))
        }
        // 极小字符上限：只能容纳约 1 个回合（按完整回合裁剪）。
        let builder = InterpreterContextBuilder(maxTurns: 10, maxCharacters: 150)
        let context = builder.buildContext(turns)
        XCTAssertTrue(context.contains("9"))
        XCTAssertFalse(context.contains("8"))
    }

    func testContextBuilderMarksFailedTranslation() {
        let turns = [
            InterpreterContextBuilder.TurnProjection(
                speaker: .counterpart, direction: .ru2zh,
                sourceText: "Привет", translatedText: nil, translationFailed: true
            )
        ]
        let context = InterpreterContextBuilder().buildContext(turns)
        XCTAssertTrue(context.contains("（翻译失败）"))
    }

    func testContextBuilderEmpty() {
        XCTAssertEqual(InterpreterContextBuilder().buildContext([]), "")
    }

    // MARK: - InterpreterTurnDetails 编解码

    func testTurnDetailsCodableRoundTrip() throws {
        let details = InterpreterTurnDetails(
            intentSummary: "询问材料",
            keywords: ["паспорт 护照"],
            ambiguity: nil,
            suggestedReplies: ["我明天带来"],
            politeAlternative: "…",
            simpleAlternative: nil,
            uncertainties: ["确认证件类型"],
            detailsAvailable: true
        )
        let data = try JSONEncoder().encode(details)
        let decoded = try JSONDecoder().decode(InterpreterTurnDetails.self, from: data)
        XCTAssertEqual(decoded, details)
    }

    // MARK: - DTO wire 形状

    func testInterpreterTurnPayloadWireShape() throws {
        let encoder = JSONEncoder()
        let payload = SyncPushPayloadDTO(
            conversationId: UUID(),
            turnSpeaker: "counterpart",
            turnDirection: "ru2zh",
            turnInputMethod: "audio",
            turnSequence: 3,
            turnSourceText: "У вас есть копия?",
            turnPlainRussian: "У вас есть копия?",
            turnStressedRussian: "У вас есть ко́пия?",
            turnChineseText: "您有护照复印件吗？",
            turnDetails: "{\"keywords\":[]}",
            turnModifiedAt: Date(timeIntervalSince1970: 1_000_000)
        )
        let data = try encoder.encode(payload)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        // Wire 键名与 Go 服务端 00014 一致。
        XCTAssertEqual(object["conversationId"] as? String, payload.conversationId?.uuidString)
        XCTAssertEqual(object["turnSpeaker"] as? String, "counterpart")
        XCTAssertEqual(object["turnDirection"] as? String, "ru2zh")
        XCTAssertEqual(object["turnSequence"] as? Int, 3)
        XCTAssertEqual(object["turnSourceText"] as? String, "У вас есть копия?")
        XCTAssertEqual(object["turnChineseText"] as? String, "您有护照复印件吗？")
    }

    func testInterpreterEntityWireNames() {
        XCTAssertEqual(
            SyncEntityType.interpreterConversation.rawValue, "interpreter_conversation"
        )
        XCTAssertEqual(SyncEntityType.interpreterTurn.rawValue, "interpreter_turn")
    }

    func testServerRecordDecodesInterpreterConversation() throws {
        // Go wire 记录形状（interpreterXxx 键）的解码容忍度。日期与
        // SyncAPIClient 同策略（RFC 3339，支持小数秒）。
        let json = """
        {"entityType": "interpreter_conversation", "id": "00000000-0000-0000-0000-000000000001",
         "title": "宿舍办理 · 9月5日", "interpreterScene": "dorm",
         "interpreterContextNote": "我是莫斯科国立大学留学生",
         "interpreterStatus": "saved",
         "interpreterStartedAt": "2026-09-05T10:00:00Z",
         "serverVersion": 3, "deleted": false}
        """
        let record = try Self.decoder.decode(
            SyncServerRecordDTO.self, from: Data(json.utf8)
        )
        XCTAssertEqual(record.title, "宿舍办理 · 9月5日")
        XCTAssertEqual(record.interpreterScene, "dorm")
        XCTAssertEqual(record.interpreterContextNote, "我是莫斯科国立大学留学生")
        XCTAssertEqual(record.interpreterStatus, "saved")
        XCTAssertEqual(record.serverVersion, 3)
        XCTAssertEqual(record.deleted, false)
    }

    func testServerRecordDecodesInterpreterTurn() throws {
        let json = """
        {"entityType": "interpreter_turn", "id": "00000000-0000-0000-0000-000000000002",
         "conversationId": "00000000-0000-0000-0000-000000000001",
         "turnSpeaker": "user", "turnDirection": "zh2ru", "turnInputMethod": "text",
         "turnSequence": 2, "turnSourceText": "我只有原件，可以在这里复印吗？",
         "turnPlainRussian": "У меня есть только оригинал.",
         "turnStressedRussian": "У меня есть то́лько оригина́л.",
         "turnChineseText": "我只有原件，可以在这里复印吗？",
         "turnBackTranslation": "我只有原件。",
         "turnDetails": "{\\"keywords\\":[\\"оригинал 原件\\"]}",
         "turnModifiedAt": "2026-09-05T10:01:00Z",
         "serverVersion": 1, "deleted": false}
        """
        let record = try Self.decoder.decode(
            SyncServerRecordDTO.self, from: Data(json.utf8)
        )
        XCTAssertEqual(record.turnSpeaker, "user")
        XCTAssertEqual(record.turnDirection, "zh2ru")
        XCTAssertEqual(record.turnSequence, 2)
        XCTAssertEqual(record.turnStressedRussian, "У меня есть то́лько оригина́л.")
        XCTAssertEqual(record.turnDetails, "{\"keywords\":[\"оригинал 原件\"]}")
    }

    /// 与 SyncAPIClient 相同的 RFC 3339 日期解码策略（测试用）。
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = SyncAPIClient.parseServerDate(raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unparseable server date: \(raw)"
            )
        }
        return decoder
    }()
}

// MARK: - Repository draft lifecycle (草稿永不通知 sync)

/// Records every mutation notification — proves draft rows never notify
/// the sync observer while save promotes the whole conversation at once.
/// Records mutation-observer calls (interpreter family). Internal so the
/// document-context tests can reuse the same double.
final class MutationRecorder: TranscriptMutationObserving {
    var conversationSaved: [UUID] = []
    var conversationUpdated: [UUID] = []
    var conversationDeleted: [UUID] = []
    var turnCreated: [UUID] = []
    var turnUpdated: [UUID] = []
    var turnDeleted: [UUID] = []

    func interpreterConversationSaved(_ conversation: InterpreterConversation) {
        conversationSaved.append(conversation.id)
    }
    func interpreterConversationUpdated(_ conversation: InterpreterConversation) {
        conversationUpdated.append(conversation.id)
    }
    func interpreterConversationDeleted(id: UUID) {
        conversationDeleted.append(id)
    }
    func interpreterTurnCreated(_ turn: InterpreterTurn) {
        turnCreated.append(turn.id)
    }
    func interpreterTurnUpdated(_ turn: InterpreterTurn) {
        turnUpdated.append(turn.id)
    }
    func interpreterTurnDeleted(id: UUID) {
        turnDeleted.append(id)
    }
}

@MainActor
final class InterpreterRepositoryTests: XCTestCase {
    private var container: ModelContainer!
    private var repository: TranscriptRepository!
    private var recorder = MutationRecorder()

    override func setUp() async throws {
        let schema = Schema([
            InterpreterConversation.self, InterpreterTurn.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
        repository = TranscriptRepository(
            container: container,
            databaseURL: URL(fileURLWithPath: "/dev/null/nonexistent.sqlite")
        )
        recorder = MutationRecorder()
        repository.mutationObserver = recorder
    }

    func testDraftLifecycleNeverNotifiesSync() throws {
        // 草稿建立 + 两个回合 + 翻译完成 —— 全程零通知。
        let draft = try repository.startInterpreterDraft(
            scene: .dorm, contextNote: "我是莫斯科国立大学留学生"
        )
        XCTAssertEqual(draft.status, .draft)
        // 默认标题：场景显示名 + " · " + M月d日（本地生成，非 AI）。
        XCTAssertTrue(draft.title.hasPrefix("宿舍 · "))
        XCTAssertFalse(draft.title.dropFirst(4).isEmpty)

        let turn1 = try repository.addInterpreterCounterpartTurn(
            conversationID: draft.id,
            russian: "У вас есть копия паспорта?",
            inputMethod: .audio
        )
        XCTAssertEqual(turn1.translationStatusRaw, "pending")

        try repository.completeInterpreterTurnTranslation(
            turn1,
            chinese: "您有护照复印件吗？",
            russian: nil,
            stressedRussian: "У вас есть ко́пия па́спорта?",
            backTranslation: nil,
            details: InterpreterTurnDetails(intentSummary: "询问材料")
        )

        XCTAssertTrue(recorder.conversationSaved.isEmpty)
        XCTAssertTrue(recorder.turnCreated.isEmpty)
        XCTAssertTrue(recorder.turnUpdated.isEmpty)

        // 保存：conversation + 两个状态一次性通知。
        try repository.saveInterpreterDraft(title: "宿舍办理 · 9月5日")
        XCTAssertEqual(recorder.conversationSaved, [draft.id])
        XCTAssertEqual(recorder.turnCreated, [turn1.id])
        XCTAssertEqual(draft.status, .saved)
        XCTAssertNotNil(draft.endedAt)

        // 保存后的回合编辑/删除会通知（delete-wins）。
        let turn2 = try repository.addInterpreterUserTurn(
            conversationID: draft.id, chinese: "我只有原件", inputMethod: .text
        )
        XCTAssertEqual(recorder.turnCreated, [turn1.id, turn2.id])
        try repository.deleteInterpreterTurn(turn2)
        XCTAssertEqual(recorder.turnDeleted, [turn2.id])
    }

    func testEmptyDraftIsCleanedOnSave() throws {
        // 空会话自动清理，不创建历史垃圾，也不上云。
        let draft = try repository.startInterpreterDraft(scene: .bank, contextNote: "")
        try repository.saveInterpreterDraft(title: nil)
        XCTAssertNil(repository.interpreterDraft)
        XCTAssertTrue(recorder.conversationSaved.isEmpty)
        let saved = try repository.savedInterpreterConversations()
        XCTAssertTrue(saved.isEmpty)
    }

    func testDiscardRemovesDraftAndTurns() throws {
        let draft = try repository.startInterpreterDraft(scene: .general, contextNote: "")
        _ = try repository.addInterpreterCounterpartTurn(
            conversationID: draft.id, russian: "Привет", inputMethod: .audio
        )
        try repository.discardInterpreterDraft()
        XCTAssertNil(repository.interpreterDraft)
        XCTAssertTrue(try repository.interpreterTurns(conversationID: draft.id).isEmpty)
        XCTAssertTrue(try repository.savedInterpreterConversations().isEmpty)
        // 丢弃产生零 wire 流量。
        XCTAssertTrue(recorder.conversationDeleted.isEmpty)
        XCTAssertTrue(recorder.turnDeleted.isEmpty)
    }

    func testSingleActiveDraftInvariant() throws {
        let first = try repository.startInterpreterDraft(scene: .dorm, contextNote: "")
        // 已有活动草稿时再次 start 返回同一个。
        let second = try repository.startInterpreterDraft(scene: .bank, contextNote: "")
        XCTAssertEqual(first.id, second.id)
    }

    func testFailedTranslationKeepsSource() throws {
        let draft = try repository.startInterpreterDraft(scene: .general, contextNote: "")
        let turn = try repository.addInterpreterCounterpartTurn(
            conversationID: draft.id, russian: "Как дела?", inputMethod: .audio
        )
        try repository.failInterpreterTurnTranslation(turn)
        XCTAssertEqual(turn.translationStatusRaw, "failed")
        XCTAssertEqual(turn.sourceText, "Как дела?")
        XCTAssertEqual(turn.plainRussian, "Как дела?")
    }

    func testUpdateTurnSourceStampsModifiedAt() throws {
        let draft = try repository.startInterpreterDraft(scene: .general, contextNote: "")
        let turn = try repository.addInterpreterUserTurn(
            conversationID: draft.id, chinese: "我只有原件", inputMethod: .text
        )
        XCTAssertNil(turn.modifiedAt)
        try repository.updateInterpreterTurnSource(turn, text: "我只有护照原件")
        XCTAssertEqual(turn.sourceText, "我只有护照原件")
        XCTAssertNotNil(turn.modifiedAt)
    }

    func testSearchMatchesTurnTexts() throws {
        let draft = try repository.startInterpreterDraft(scene: .dorm, contextNote: "")
        _ = try repository.addInterpreterCounterpartTurn(
            conversationID: draft.id, russian: "общежитие", inputMethod: .audio
        )
        _ = try repository.addInterpreterUserTurn(
            conversationID: draft.id, chinese: "我需要办理入住", inputMethod: .text
        )
        try repository.saveInterpreterDraft(title: nil)

        XCTAssertEqual(try repository.interpreterConversations(matching: "入住").count, 1)
        XCTAssertEqual(try repository.interpreterConversations(matching: "общежитие").count, 1)
        XCTAssertEqual(try repository.interpreterConversations(matching: "不存在").count, 0)
    }

    func testTurnDetailsRoundTrip() throws {
        let draft = try repository.startInterpreterDraft(scene: .general, contextNote: "")
        let turn = try repository.addInterpreterCounterpartTurn(
            conversationID: draft.id, russian: "Привет", inputMethod: .audio
        )
        let details = InterpreterTurnDetails(
            intentSummary: "打招呼",
            keywords: ["привет 你好"]
        )
        try repository.completeInterpreterTurnTranslation(
            turn, chinese: "你好", russian: nil,
            stressedRussian: nil, backTranslation: nil, details: details
        )
        XCTAssertEqual(turn.details?.intentSummary, "打招呼")
        XCTAssertEqual(turn.details?.keywords, ["привет 你好"])
    }
}
