import XCTest
import SwiftData
@testable import LiveTranslateIOS

/// 第十七轮 citation 同步边界测试：details 绝不携带文件来源标签；
/// 一次性迁移、出站清洗、入站清洗与本地来源的设备本地性。
final class InterpreterCitationBoundaryTests: XCTestCase {

    // MARK: - Sanitizer（纯逻辑）

    func testSanitizerStripsCitationLabelsOnly() throws {
        let dirty = """
        {"intentSummary":"文件分析","keywords":["Сумма: 15000₽","护照_扫描.pdf · 第1页","签证复印件.jpg · 第 2 页"],"detailsAvailable":true}
        """
        let cleaned = InterpreterDetailsSanitizer.sanitizedDetailsJSON(dirty)
        let details = try XCTUnwrap(JSONDecoder().decode(
            InterpreterTurnDetails.self, from: Data(cleaned.utf8)
        ))
        XCTAssertEqual(details.keywords, ["Сумма: 15000₽"], "只移除来源标签,保留普通关键词")
        XCTAssertEqual(details.hasLocalSources, true)
        XCTAssertFalse(cleaned.contains("护照_扫描.pdf"))
        XCTAssertFalse(cleaned.contains("签证复印件.jpg"))
    }

    func testSanitizerKeepsCleanDetailsByteIdentical() {
        let clean = """
        {"intentSummary":"开户","keywords":["паспорт 护照"],"hasLocalSources":true,"detailsAvailable":true}
        """
        XCTAssertEqual(
            InterpreterDetailsSanitizer.sanitizedDetailsJSON(clean), clean,
            "已清洗的 details 不得被再次改写(幂等)"
        )
        // 无关键词的 details 同样原样通过。
        let noKeywords = "{\"intentSummary\":\"问路\"}"
        XCTAssertEqual(
            InterpreterDetailsSanitizer.sanitizedDetailsJSON(noKeywords), noKeywords
        )
        // 坏 JSON 原样返回(语法判断是调用方的事 —— 这里只做内容防御)。
        let broken = "not-json{{"
        XCTAssertEqual(InterpreterDetailsSanitizer.sanitizedDetailsJSON(broken), broken)
    }

    func testCitationLabelPattern() {
        XCTAssertTrue(InterpreterDetailsSanitizer.isCitationLabel("登记表.pdf · 第1页"))
        XCTAssertTrue(InterpreterDetailsSanitizer.isCitationLabel("扫描文档-20260905 · 第12页"))
        XCTAssertTrue(InterpreterDetailsSanitizer.isCitationLabel("x · 第 3 页"))
        XCTAssertFalse(InterpreterDetailsSanitizer.isCitationLabel("高等数学 · 第三章"))
        XCTAssertFalse(InterpreterDetailsSanitizer.isCitationLabel("паспорт 护照"))
        XCTAssertFalse(InterpreterDetailsSanitizer.isCitationLabel("来源文件仅保存在原设备"))
    }

    // MARK: - 出站 payload(绝不上传来源标签)

    @MainActor
    func testOutboundPayloadSanitizesLegacyDirtyTurn() throws {
        let dirtyDetails = InterpreterTurnDetails(
            intentSummary: "文件分析",
            keywords: ["Сумма: 15000₽", "护照_扫描.pdf · 第1页"]
        )
        let turn = InterpreterTurn(
            conversationID: UUID(),
            speakerRaw: "counterpart",
            directionRaw: "ru2zh",
            inputMethodRaw: "text",
            sequence: 1,
            sourceText: "原文",
            chineseText: "翻译",
            detailsJSON: {
                let data = try! JSONEncoder().encode(dirtyDetails)
                return String(data: data, encoding: .utf8) ?? ""
            }()
        )
        let payload = CloudSyncService.payload(for: turn)
        let detailsJSON = try XCTUnwrap(payload.turnDetails)
        XCTAssertFalse(
            detailsJSON.contains("护照_扫描.pdf"),
            "出站 wire 绝不携带文件名"
        )
        let details = try XCTUnwrap(JSONDecoder().decode(
            InterpreterTurnDetails.self, from: Data(detailsJSON.utf8)
        ))
        XCTAssertEqual(details.keywords, ["Сумма: 15000₽"])
        XCTAssertEqual(details.hasLocalSources, true)
    }

    @MainActor
    func testOutboundPayloadNeverCarriesLocalSources() throws {
        // localSourcesJSON 是设备本地字段 —— payload(for:) 从不读取它。
        let turn = InterpreterTurn(
            conversationID: UUID(),
            speakerRaw: "counterpart",
            directionRaw: "ru2zh",
            inputMethodRaw: "text",
            sequence: 1,
            sourceText: "原文",
            chineseText: "翻译"
        )
        turn.storeLocalSources([InterpreterLocalSource(
            documentID: UUID(), documentName: "护照_扫描.pdf",
            pageNumber: 1, snippet: "Паспорт РФ 4509 123456"
        )])
        let payload = CloudSyncService.payload(for: turn)
        let encoded = try JSONEncoder().encode(payload)
        let wire = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertFalse(wire.contains("护照_扫描.pdf"))
        XCTAssertFalse(wire.contains("Паспорт РФ"))
    }

    // MARK: - 一次性迁移 + 入站清洗(仓库层)

    @MainActor
    private func makeRepository() throws -> (TranscriptRepository, MutationRecorder) {
        let schema = Schema([
            InterpreterConversation.self, InterpreterTurn.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let repository = TranscriptRepository(
            container: container,
            databaseURL: URL(fileURLWithPath: "/dev/null/nonexistent.sqlite")
        )
        let recorder = MutationRecorder()
        repository.mutationObserver = recorder
        return (repository, recorder)
    }

    /// 旧数据形态:details.keywords 混有来源标签与普通关键词。
    private func legacyDirtyDetails() -> String {
        let details = InterpreterTurnDetails(
            intentSummary: "文件分析",
            keywords: ["Сумма: 15000₽", "护照_扫描.pdf · 第1页", "登记表.pdf · 第2页"]
        )
        let data = try! JSONEncoder().encode(details)
        return String(data: data, encoding: .utf8) ?? ""
    }

    @MainActor
    func testMigrationMovesLabelsToLocalAndNotifiesSync() throws {
        let (repository, recorder) = try makeRepository()
        let draft = try repository.startInterpreterDraft(scene: .migration, contextNote: "")
        let turn = try repository.addInterpreterCounterpartTurn(
            conversationID: draft.id, russian: "Подайте заявление", inputMethod: .text
        )
        turn.detailsJSON = legacyDirtyDetails()
        try repository.saveInterpreterDraft(title: nil)
        recorder.turnUpdated.removeAll() // save 的通知不算迁移的

        let migrated = try repository.migrateInterpreterCitationDetails()
        XCTAssertEqual(migrated, 1)

        // 标签进入本地来源;details 只剩非来源信息 + 标记。
        let localSources = try XCTUnwrap(turn.localSources)
        XCTAssertEqual(localSources.count, 2)
        XCTAssertEqual(
            Set(localSources.map(\.documentName)),
            ["登记表.pdf", "护照_扫描.pdf"],
            "两个来源标签都迁入(顺序无关)"
        )
        XCTAssertEqual(localSources.first?.pageNumber, 1)
        XCTAssertNil(localSources.first?.documentID, "迁移条目没有 documentID —— 如实缺省,不伪造")
        let details = try XCTUnwrap(turn.details)
        XCTAssertEqual(details.keywords, ["Сумма: 15000₽"])
        XCTAssertEqual(details.hasLocalSources, true)

        // 已保存会话的被改写回合通知 sync(清洗值随正常 turn 更新上船)。
        XCTAssertEqual(recorder.turnUpdated, [turn.id])

        // 幂等:再跑一遍是 no-op,不再通知。
        let again = try repository.migrateInterpreterCitationDetails()
        XCTAssertEqual(again, 0)
        XCTAssertEqual(recorder.turnUpdated, [turn.id])
    }

    @MainActor
    func testMigrationLeavesDraftTurnsLocalOnly() throws {
        let (repository, recorder) = try makeRepository()
        let draft = try repository.startInterpreterDraft(scene: .general, contextNote: "")
        let turn = try repository.addInterpreterCounterpartTurn(
            conversationID: draft.id, russian: "Привет", inputMethod: .text
        )
        turn.detailsJSON = legacyDirtyDetails()

        let migrated = try repository.migrateInterpreterCitationDetails()
        XCTAssertEqual(migrated, 1)
        XCTAssertEqual(turn.localSources?.count, 2)
        // 草稿回合不上 wire —— 迁移不为其产生通知。
        XCTAssertTrue(recorder.turnUpdated.isEmpty)
    }

    @MainActor
    func testInboundRemoteApplySanitizesAndKeepsLocalSources() throws {
        let (repository, _) = try makeRepository()
        let conversationID = UUID()
        let turnID = UUID()

        // 本机已有该回合:本地来源存在,details 是清洗后的形态。
        let existing = InterpreterTurn(
            id: turnID,
            conversationID: conversationID,
            speakerRaw: "counterpart",
            directionRaw: "ru2zh",
            inputMethodRaw: "text",
            sequence: 1,
            sourceText: "原文"
        )
        existing.storeLocalSources([InterpreterLocalSource(
            documentID: UUID(), documentName: "护照_扫描.pdf",
            pageNumber: 1, snippet: "短引文"
        )])
        var cleaned = InterpreterTurnDetails(intentSummary: "文件分析")
        cleaned.keywords = ["Сумма: 15000₽"]
        cleaned.hasLocalSources = true
        existing.storeDetails(cleaned)
        repository.context.insert(existing)

        // 远端推来旧客户端的脏 details(serverVersion 更新)。
        let remoteRecord = SyncServerRecordDTO(
            id: turnID,
            conversationId: conversationID,
            turnSpeaker: "counterpart",
            turnDirection: "ru2zh",
            turnInputMethod: "text",
            turnSequence: 1,
            turnSourceText: "原文(远端)",
            turnDetails: legacyDirtyDetails(),
            turnModifiedAt: nil
        )
        try repository.applyRemoteInterpreterTurn(record: remoteRecord, serverVersion: 5)

        // details 被清洗;本地来源绝不被远端覆盖。
        let details = try XCTUnwrap(existing.details)
        XCTAssertEqual(details.keywords, ["Сумма: 15000₽"], "入站脏 details 必须被清洗")
        XCTAssertEqual(details.hasLocalSources, true)
        XCTAssertEqual(existing.localSources?.count, 1, "本地来源是设备本地字段,远端不可覆盖")
        XCTAssertEqual(existing.localSources?.first?.documentName, "护照_扫描.pdf")
    }
}
