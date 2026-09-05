import XCTest
import SwiftData
import CryptoKit
@testable import LiveTranslateIOS

/// 随身翻译现场文件（第十六轮）的纯逻辑测试：chunk 稳定性、citation
/// 校验、敏感遮盖、结构化解析宽容降级、文档状态机与文件生命周期、
/// 本地文档不进 outbox/wire。
final class InterpreterDocumentTests: XCTestCase {

    // MARK: - Chunker

    func testChunksAreDeterministicAndStable() {
        let text = "Фамилия Имя Отчество\nДата вселения: 01.09.2026\n\nПаспорт: копия"
        let first = InterpreterDocumentChunker.chunks(
            documentID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            documentName: "登记表",
            pageNumber: 1,
            text: text
        )
        let second = InterpreterDocumentChunker.chunks(
            documentID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            documentName: "登记表",
            pageNumber: 1,
            text: text
        )
        XCTAssertEqual(first.map(\.id), second.map(\.id), "同一文本的 chunk ID 必须稳定")
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?.pageNumber, 1)
        XCTAssertEqual(first.first?.blockIndex, 1)
        // 空白行被丢弃；原文保持。
        XCTAssertTrue(first.first!.text.contains("Фамилия Имя Отчество"))
        XCTAssertFalse(first.first!.text.contains("\n\n"))
    }

    func testDifferentPagesAndBlocksGiveDifferentIDs() {
        let documentID = UUID()
        XCTAssertNotEqual(
            InterpreterDocumentChunker.deterministicChunkID(documentID: documentID, pageNumber: 1, blockIndex: 1),
            InterpreterDocumentChunker.deterministicChunkID(documentID: documentID, pageNumber: 2, blockIndex: 1)
        )
        XCTAssertNotEqual(
            InterpreterDocumentChunker.deterministicChunkID(documentID: documentID, pageNumber: 1, blockIndex: 1),
            InterpreterDocumentChunker.deterministicChunkID(documentID: documentID, pageNumber: 1, blockIndex: 2)
        )
        // 不同文档的同一页/块也不同。
        XCTAssertNotEqual(
            InterpreterDocumentChunker.deterministicChunkID(documentID: documentID, pageNumber: 1, blockIndex: 1),
            InterpreterDocumentChunker.deterministicChunkID(documentID: UUID(), pageNumber: 1, blockIndex: 1)
        )
    }

    func testSelectionRespectsUserPagesAndBudget() {
        let documentID = UUID()
        // 20 个 chunk 分布在 3 页。
        var chunks: [InterpreterDocumentChunker.Chunk] = []
        for page in 1...3 {
            for block in 1...7 {
                chunks.append(InterpreterDocumentChunker.Chunk(
                    id: UUID(), documentID: documentID, documentName: "d",
                    pageNumber: page, blockIndex: block,
                    text: String(repeating: "слово\(block) ", count: 30),
                    contentHash: ""
                ))
            }
        }
        // 用户只选了第 2 页。
        let selected = InterpreterDocumentChunker.selectChunks(.init(
            chunks: chunks, selectedPages: [2], question: ""
        ))
        XCTAssertFalse(selected.isEmpty)
        XCTAssertTrue(selected.allSatisfy { $0.pageNumber == 2 }, "用户选择优先")
        XCTAssertLessThanOrEqual(selected.count, InterpreterDocumentChunker.maxChunksPerRequest)
        let total = selected.reduce(0) { $0 + $1.text.count }
        XCTAssertLessThanOrEqual(total, InterpreterDocumentChunker.maxContextCharacters)
    }

    func testSelectionTruncatesByWholeChunksOnly() {
        let documentID = UUID()
        let chunks = (1...20).map { index in
            InterpreterDocumentChunker.Chunk(
                id: UUID(), documentID: documentID, documentName: "d",
                pageNumber: 1, blockIndex: index,
                text: String(repeating: "текст ", count: 100),
                contentHash: ""
            )
        }
        let selected = InterpreterDocumentChunker.selectChunks(.init(
            chunks: chunks, selectedPages: [], question: ""
        ))
        // 选择数量受限；每个 chunk 完整（绝无半句）。
        XCTAssertLessThanOrEqual(selected.count, InterpreterDocumentChunker.maxChunksPerRequest)
        for chunk in selected {
            XCTAssertFalse(chunk.text.hasSuffix("тек"), "chunk 不得被截断半句")
        }
    }

    // MARK: - Citation 校验

    private func makeSources() -> [InterpreterDocumentChunker.RequestSource] {
        let documentID = UUID()
        let chunks = InterpreterDocumentChunker.chunks(
            documentID: documentID, documentName: "登记表", pageNumber: 3,
            text: "Фамилия Имя Отчество\nДата вселения: 01.09.2026\nПаспорт: копия"
        )
        return InterpreterDocumentChunker.requestSources(for: chunks)
    }

    func testValidCitationSurvives() {
        let sources = makeSources()
        let validated = InterpreterDocumentChunker.validateCitations(
            [InterpreterDocumentChunker.ReturnedCitation(
                sourceID: "S1", pageNumber: 3, snippet: "Дата вселения: 01.09.2026"
            )],
            against: sources
        )
        XCTAssertEqual(validated.count, 1)
        XCTAssertEqual(validated.first?.documentName, "登记表")
        XCTAssertEqual(validated.first?.pageNumber, 3)
    }

    func testFabricatedSourceIDIsDropped() {
        let sources = makeSources()
        let validated = InterpreterDocumentChunker.validateCitations(
            [InterpreterDocumentChunker.ReturnedCitation(
                sourceID: "S9", pageNumber: 3, snippet: "Дата"
            )],
            against: sources
        )
        XCTAssertTrue(validated.isEmpty, "不存在的 source ID 必须丢弃")
    }

    func testWrongPageNumberIsDropped() {
        let sources = makeSources()
        let validated = InterpreterDocumentChunker.validateCitations(
            [InterpreterDocumentChunker.ReturnedCitation(
                sourceID: "S1", pageNumber: 99, snippet: "Дата"
            )],
            against: sources
        )
        XCTAssertTrue(validated.isEmpty, "页码不匹配必须丢弃")
    }

    func testFabricatedSnippetIsDropped() {
        let sources = makeSources()
        let validated = InterpreterDocumentChunker.validateCitations(
            [InterpreterDocumentChunker.ReturnedCitation(
                sourceID: "S1", pageNumber: 3, snippet: "这句话不在文件中"
            )],
            against: sources
        )
        XCTAssertTrue(validated.isEmpty, "引文必须在原文中存在")
    }

    func testWhitespaceNormalizedSnippetSurvives() {
        let sources = makeSources()
        // 模型重排了空白 —— 安全规范化后仍应匹配。
        let validated = InterpreterDocumentChunker.validateCitations(
            [InterpreterDocumentChunker.ReturnedCitation(
                sourceID: "S1", pageNumber: 3, snippet: "Дата  вселения: 01.09.2026"
            )],
            against: sources
        )
        XCTAssertEqual(validated.count, 1)
    }

    // MARK: - 敏感遮盖

    func testDetectsAndMasksPassport() {
        let text = "Паспорт: 1234 567890, дата выдачи 01.09.2026"
        let (masked, matches) = InterpreterSensitiveMasker.masked(text)
        XCTAssertEqual(matches.filter { $0.kind == .passport }.count, 1)
        XCTAssertTrue(masked.contains("×"))
        XCTAssertFalse(masked.contains("1234 567890"), "护照号必须被遮盖")
    }

    func testDetectsEmailAndPhone() {
        let text = "Почта: student@example.com, тел: +7 916 123 45 67"
        let (masked, matches) = InterpreterSensitiveMasker.masked(text)
        XCTAssertTrue(matches.contains { $0.kind == .email })
        XCTAssertTrue(matches.contains { $0.kind == .phone })
        XCTAssertFalse(masked.contains("student@example.com"))
        XCTAssertFalse(masked.contains("+7 916 123 45 67"))
    }

    func testNormalTextUnmasked() {
        let text = "Дата вселения: 01.09.2026, комната 412"
        let (masked, matches) = InterpreterSensitiveMasker.masked(text)
        XCTAssertTrue(matches.isEmpty)
        XCTAssertEqual(masked, text)
    }

    // MARK: - 结构化解析宽容降级

    func testParseAnalysisWithFencesAndProse() {
        let raw = """
        好的，以下是分析：
        ```json
        {"documentType": "宿舍登记表", "summaryChinese": "需要填写并提交复印件。", "keyFacts": ["Паспорт 护照"]}
        ```
        希望有帮助。
        """
        let analysis = InterpreterDocumentParser.parseAnalysis(raw)
        XCTAssertNotNil(analysis)
        XCTAssertEqual(analysis?.documentType, "宿舍登记表")
        XCTAssertEqual(analysis?.detailsAvailable, true)
    }

    func testParseAnalysisPlainTextFallsBack() {
        let raw = "这份文件是一份宿舍入住登记表。"
        let analysis = InterpreterDocumentParser.parseAnalysis(raw)
        XCTAssertEqual(analysis?.summaryChinese, raw)
        XCTAssertEqual(analysis?.detailsAvailable, false, "纯文本回退必须诚实说明结构不可用")
    }

    func testParseAnswerValidatesStress() {
        // 重音校验：改词（паспорт → паспортх）→ 丢弃重音版。
        let raw = """
        {"answerChinese": "需要填表。", "suggestedRussian": "Скажите, пожалуйста?", "stressedRussian": "Скажи́те, пожа́луйста?", "backTranslation": "请说？"}
        """
        let answer = InterpreterDocumentParser.parseAnswer(raw)
        XCTAssertEqual(answer?.answerChinese, "需要填表。")
        XCTAssertEqual(answer?.stressedRussian, "Скажи́те, пожа́луйста?", "正确重音必须保留")
        // 改词版本必须被丢弃。
        let bad = """
        {"answerChinese": "需要填表。", "suggestedRussian": "Скажите, пожалуйста?", "stressedRussian": "Скажите, пожалуйстах?", "backTranslation": ""}
        """
        let badAnswer = InterpreterDocumentParser.parseAnswer(bad)
        XCTAssertNil(badAnswer?.stressedRussian, "改词的重音版本必须丢弃")
        XCTAssertEqual(badAnswer?.suggestedRussian, "Скажите, пожалуйста?")
    }

    func testParseAnswerPlainTextFallsBack() {
        let answer = InterpreterDocumentParser.parseAnswer("直接回答。")
        XCTAssertEqual(answer?.answerChinese, "直接回答。")
        XCTAssertEqual(answer?.detailsAvailable, false)
    }

    // MARK: - 提取结果 sidecar 编解码

    func testExtractionSidecarRoundTripAndDecodeTolerance() {
        let extraction = InterpreterDocumentExtraction(pages: [
            InterpreterDocumentPageText(
                pageNumber: 2, extractedText: "page two",
                ocrText: "", ocrConfidence: 0.8, ocrStatusRaw: InterpreterPageOCRStatus.none.rawValue
            ),
            InterpreterDocumentPageText(
                pageNumber: 1, extractedText: "", ocrText: "страница",
                ocrConfidence: 0.4, ocrStatusRaw: InterpreterPageOCRStatus.done.rawValue
            )
        ])
        let json = extraction.encodedJSON()!
        let decoded = InterpreterDocumentExtraction.decode(json)!
        // 页码升序（构造即排序）。
        XCTAssertEqual(decoded.pages.map(\.pageNumber), [1, 2])
        // 坏 JSON → nil（绝不崩溃）。
        XCTAssertNil(InterpreterDocumentExtraction.decode("{broken"))
        XCTAssertNil(InterpreterDocumentExtraction.decode(""))
    }

    func testEffectiveTextPrefersTextLayer() {
        let page = InterpreterDocumentPageText(
            pageNumber: 1, extractedText: "текст-слой", ocrText: "OCR"
        )
        XCTAssertEqual(page.effectiveText, "текст-слой")
        let scanned = InterpreterDocumentPageText(pageNumber: 1, extractedText: "", ocrText: "OCR")
        XCTAssertEqual(scanned.effectiveText, "OCR")
    }

    // MARK: - 分句（不半句截断）

    func testSplitSentencesNeverCutsMidSentence() {
        let long = String(repeating: "Слово. ", count: 30)
        let sentences = InterpreterDocumentChunker.splitSentences(long)
        XCTAssertGreaterThanOrEqual(sentences.count, 1)
        for sentence in sentences {
            XCTAssertFalse(sentence.isEmpty)
            // 每段以句界结尾或为整体（绝无半句）。
            XCTAssertTrue(
                sentence.hasSuffix(".") || sentence.hasSuffix(" ") || sentences.count == 1
            )
        }
    }

    // MARK: - 导出选项（文件来源默认不包含）

    func testExportDefaultsExcludeDocumentSources() {
        let conversation = InterpreterExporter.ConversationExport(
            title: "宿舍办理", scene: .dorm, startedAt: .now,
            turns: [
                InterpreterExporter.TurnExport(
                    speaker: .user, direction: .zh2ru, sourceText: "请解释文件",
                    plainRussian: "Скажите", stressedRussian: "", chineseText: "请解释文件",
                    backTranslation: "", createdAt: .now,
                    details: InterpreterTurnDetails(
                        intentSummary: "宿舍登记表",
                        keywords: ["登记表 · 第1页"]
                    )
                )
            ]
        )
        let defaultText = InterpreterExporter.markdown(conversation)
        XCTAssertFalse(defaultText.contains("登记表 · 第1页"), "默认导出不包含文件来源")
        let withSources = InterpreterExporter.markdown(
            conversation,
            options: .init(includeDocumentSources: true)
        )
        XCTAssertTrue(withSources.contains("登记表 · 第1页"))
        XCTAssertTrue(withSources.contains("来源文件仅保存在原设备"))
        // 绝不导出内部 UUID、模型名、API 地址。
        XCTAssertFalse(withSources.contains("api"))
        XCTAssertFalse(withSources.contains("http"))
    }
}

// MARK: - Repository / 生命周期测试

@MainActor
final class InterpreterDocumentRepositoryTests: XCTestCase {
    private var container: ModelContainer!
    private var repository: TranscriptRepository!
    private var store: InterpreterDocumentStore!
    private var recorder = MutationRecorder()

    override func setUp() async throws {
        let schema = Schema([
            InterpreterConversation.self, InterpreterTurn.self,
            InterpreterDocument.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
        repository = TranscriptRepository(
            container: container,
            databaseURL: URL(fileURLWithPath: "/dev/null/nonexistent.sqlite")
        )
        store = InterpreterDocumentStore(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("interp-doc-tests-\(UUID().uuidString)", isDirectory: true)
        )
        recorder = MutationRecorder()
        repository.mutationObserver = recorder
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: store.root)
    }

    private func makeDraft() throws -> InterpreterConversation {
        try repository.startInterpreterDraft(scene: .dorm, contextNote: "")
    }

    private func importDocument(
        into conversationID: UUID, text: String
    ) throws -> InterpreterDocument {
        let documentID = UUID()
        let outcome = try store.importData(
            text.data(using: .utf8)!, documentID: documentID, fileExtension: "txt"
        )
        return try repository.addInterpreterDocument(
            InterpreterDocumentDraft(
                conversationID: conversationID,
                source: .files,
                originalFileName: "通知.txt",
                format: .text,
                mimeType: "text/plain",
                fileSize: outcome.fileSize,
                contentHash: outcome.contentHash,
                originalRelativePath: outcome.relativePath
            )
        )
    }

    func testDocumentRowsNeverNotifySync() throws {
        let draft = try makeDraft()
        _ = try importDocument(into: draft.id, text: "Заселение 01.09.2026")
        // 设备本地实体：零 wire 流量。
        XCTAssertTrue(recorder.conversationSaved.isEmpty)
        XCTAssertTrue(recorder.turnCreated.isEmpty)
        // 查询正常。
        let documents = try repository.interpreterDocuments(conversationID: draft.id)
        XCTAssertEqual(documents.count, 1)
    }

    func testDuplicateHashDetectionWithinConversation() throws {
        let draft = try makeDraft()
        _ = try importDocument(into: draft.id, text: "одинаковый текст")
        let duplicates = try repository.interpreterDocuments(
            conversationID: draft.id, contentHash: {
                let data = "одинаковый текст".data(using: .utf8)!
                return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }()
        )
        XCTAssertEqual(duplicates.count, 1, "同会话内 SHA-256 相同应能查出")
    }

    func testDiscardDraftRemovesDocumentsAndFiles() throws {
        let draft = try makeDraft()
        let document = try importDocument(into: draft.id, text: "текст")
        XCTAssertTrue(store.originalExists(
            documentID: document.id, fileExtension: "txt"
        ))
        try repository.discardInterpreterDraft()
        let documents = try repository.interpreterDocuments(conversationID: draft.id)
        XCTAssertTrue(documents.isEmpty, "丢弃草稿必须清理文档行")
        XCTAssertFalse(store.originalExists(
            documentID: document.id, fileExtension: "txt"
        ), "丢弃草稿必须清理文档文件")
    }

    func testDeleteConversationReapsDocumentFiles() throws {
        let draft = try makeDraft()
        _ = try importDocument(into: draft.id, text: "текст")
        _ = try repository.addInterpreterUserTurn(
            conversationID: draft.id, chinese: "问题", inputMethod: .text
        )
        try repository.saveInterpreterDraft(title: nil)
        let saved = try repository.savedInterpreterConversations()
        XCTAssertEqual(saved.count, 1)
        try repository.deleteInterpreterConversation(saved[0])
        let documents = try repository.interpreterDocuments(conversationID: saved[0].id)
        XCTAssertTrue(documents.isEmpty)
    }

    func testDropOriginalsKeepsExtractionSidecar() throws {
        let draft = try makeDraft()
        let document = try importDocument(into: draft.id, text: "текст")
        try store.writeExtraction(
            InterpreterDocumentExtraction(
                pages: [InterpreterDocumentPageText(pageNumber: 1, extractedText: "текст")]
            ),
            documentID: document.id
        )
        try repository.dropInterpreterDocumentOriginals(
            conversationID: draft.id, store: store
        )
        XCTAssertFalse(store.originalExists(
            documentID: document.id, fileExtension: "txt"
        ), "原始文件被删除")
        XCTAssertNotNil(store.readExtraction(documentID: document.id), "提取 sidecar 保留")
        // 行保留且 keepOriginalFile 翻 false。
        let documents = try repository.interpreterDocuments(conversationID: draft.id)
        XCTAssertEqual(documents.count, 1)
        XCTAssertFalse(documents[0].keepOriginalFile)
    }

    func testReconcileInterruptedImportingBecomesFailed() throws {
        let draft = try makeDraft()
        let document = try repository.addInterpreterDocument(
            InterpreterDocumentDraft(
                conversationID: draft.id, source: .files,
                originalFileName: "x.pdf", format: .pdf,
                mimeType: "application/pdf",
                status: .importing
            )
        )
        repository.reconcileInterpreterDocuments(store: store)
        XCTAssertEqual(document.status, .failed, "导入中断回滚为可重试失败")
        XCTAssertEqual(document.statusRaw, InterpreterDocumentStatus.failed.rawValue)
    }

    func testReconcileInterruptedExtractingBecomesImported() throws {
        let draft = try makeDraft()
        let document = try importDocument(into: draft.id, text: "текст")
        document.statusRaw = InterpreterDocumentStatus.extracting.rawValue
        repository.reconcileInterpreterDocuments(store: store)
        XCTAssertEqual(document.status, .imported, "提取中断回滚到已导入（可重新提取）")
    }

    func testReconcileMissingFileFlipsToFailed() throws {
        let draft = try makeDraft()
        let document = try importDocument(into: draft.id, text: "текст")
        // 文件被外部删除。
        try FileManager.default.removeItem(
            at: store.originalURL(documentID: document.id, fileExtension: "txt")
        )
        repository.reconcileInterpreterDocuments(store: store)
        XCTAssertEqual(document.status, .failed, "文件缺失必须诚实显示失败")
        XCTAssertTrue(document.errorSummary.contains("不存在"))
    }

    func testStorePathContainment() throws {
        let draft = try makeDraft()
        let document = try importDocument(into: draft.id, text: "текст")
        // 正常相对路径可解析。
        XCTAssertNotNil(store.originalURL(forRelativePath: document.originalRelativePath))
        // 越界路径（路径穿越）被拒绝。
        XCTAssertNil(store.originalURL(forRelativePath: "../escape.txt"))
        XCTAssertNil(store.originalURL(forRelativePath: ""))
    }

    func testRemoveOrphansKeepsLiveDocuments() throws {
        let draft = try makeDraft()
        let document = try importDocument(into: draft.id, text: "текст")
        // 写入一个没有行的目录（孤儿）。
        let orphanID = UUID()
        try FileManager.default.createDirectory(
            at: store.directory(for: orphanID),
            withIntermediateDirectories: true
        )
        store.removeOrphans(liveIDs: [document.id])
        XCTAssertTrue(store.originalExists(documentID: document.id, fileExtension: "txt"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.directory(for: orphanID).path
        ))
    }

    func testServiceMergesPages() {
        let existing = [
            InterpreterDocumentPageText(pageNumber: 1, extractedText: "one"),
            InterpreterDocumentPageText(pageNumber: 2, extractedText: "two"),
        ]
        let updated = [
            InterpreterDocumentPageText(pageNumber: 2, ocrText: "два"),
        ]
        let merged = InterpreterDocumentService.mergePages(existing: existing, updated: updated)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.first { $0.pageNumber == 2 }?.ocrText, "два")
        XCTAssertEqual(merged.first { $0.pageNumber == 2 }?.extractedText, "two", "OCR 不覆盖文字层")
    }
}
