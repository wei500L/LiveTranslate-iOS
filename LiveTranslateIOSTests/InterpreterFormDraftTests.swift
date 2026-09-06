import XCTest
import SwiftData
@testable import LiveTranslateIOS

/// 第二十一轮：表单填写草稿的纯逻辑与 sidecar 契约测试（4 个 —— 只
/// 覆盖无法由现有测试覆盖的新核心语义；UI 与既有文档/翻译链路不重
/// 复测试）。
final class InterpreterFormDraftTests: XCTestCase {

    // 1. form-draft sidecar 往返：字段完整保留、坏 JSON → nil、归属
    //    不符 → nil、写入不触碰 SwiftData（绝无 wire/outbox 流量）。
    func testFormDraftSidecarRoundTripAndOwnership() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("form-draft-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InterpreterDocumentStore(root: root)
        let documentID = UUID()

        var draft = InterpreterFormDraft(documentID: documentID)
        draft.fields = [
            InterpreterFormDraftField(
                russianLabel: "Фамилия Имя Отчество",
                chineseMeaning: "姓名",
                pageNumber: 1,
                sourceSnippet: "Фамилия: ______",
                type: .singleLine,
                requirement: .required,
                formatHint: "DD.MM.YYYY",
                options: ["да", "нет"],
                userValue: "Wang Xiaoming",
                userNote: "现场确认用拉丁字母",
                status: .filled
            )
        ]
        try store.writeFormDraft(draft, documentID: documentID)

        let readBack = store.readFormDraft(documentID: documentID)
        XCTAssertEqual(readBack?.fields.count, 1)
        XCTAssertEqual(readBack?.fields.first?.russianLabel, "Фамилия Имя Отчество")
        XCTAssertEqual(readBack?.fields.first?.userValue, "Wang Xiaoming")
        XCTAssertEqual(readBack?.fields.first?.options, ["да", "нет"])
        XCTAssertEqual(readBack?.fields.first?.status, .filled)

        // 坏 JSON → nil（绝不崩溃）。
        let url = store.formDraftURL(documentID: documentID)
        try "{\"broken".data(using: .utf8)?.write(to: url, options: .atomic)
        XCTAssertNil(store.readFormDraft(documentID: documentID))

        // 归属不符（别的 documentID 的草稿）→ 不认领。
        let other = InterpreterFormDraft(documentID: UUID())
        let otherJSON = other.encodedJSON()!
        try otherJSON.data(using: .utf8)?.write(to: url, options: .atomic)
        XCTAssertNil(store.readFormDraft(documentID: documentID))
    }

    // 2. 字段进度与完成核对的纯函数。
    func testProgressAndReviewGroups() {
        let documentID = UUID()
        var draft = InterpreterFormDraft(documentID: documentID)
        draft.fields = [
            // 已填。
            InterpreterFormDraftField(
                russianLabel: "Фамилия", type: .singleLine,
                requirement: .required, userValue: "Wang", status: .filled
            ),
            // 必填未填（进缺失组）。
            InterpreterFormDraftField(
                russianLabel: "Дата рождения", chineseMeaning: "出生日期",
                type: .date,
                requirement: .required, status: .empty
            ),
            // 待确认（有值 + 用户标记）。
            InterpreterFormDraftField(
                russianLabel: "Цель приезда", type: .multiline,
                requirement: .optional,
                userValue: "Учёба в МГУ", status: .needsConfirmation
            ),
            // 不适用（不算未完成）。
            InterpreterFormDraftField(
                russianLabel: "Подпись", type: .signature,
                requirement: .optional, status: .notApplicable
            ),
            // 可选未填（不阻断核对，也不算已填）。
            InterpreterFormDraftField(
                russianLabel: "Телефон", type: .singleLine,
                requirement: .optional, status: .empty
            ),
        ]
        let summary = InterpreterFormDraftProgress.summary(of: draft)
        XCTAssertEqual(summary.total, 5)
        XCTAssertEqual(summary.filled, 1)
        XCTAssertEqual(summary.empty, 2)
        XCTAssertEqual(summary.needsConfirmation, 1)
        XCTAssertEqual(summary.notApplicable, 1)
        XCTAssertEqual(summary.unfinished, 3) // 未填 2 + 待确认 1

        let groups = InterpreterFormDraftProgress.reviewGroups(of: draft)
        XCTAssertEqual(groups.missingRequired.map(\.russianLabel), ["Дата рождения"])
        XCTAssertEqual(groups.needsConfirmation.map(\.russianLabel), ["Цель приезда"])
        XCTAssertEqual(groups.filled.map(\.russianLabel), ["Фамилия"])
        XCTAssertEqual(groups.notApplicable.map(\.russianLabel), ["Подпись"])

        // 搜索：俄文标签 / 中文解释 / 备注。
        XCTAssertTrue(InterpreterFormDraftProgress.matches(
            draft.fields[0], query: "фами"
        ))
        XCTAssertTrue(InterpreterFormDraftProgress.matches(
            draft.fields[1], query: "出生"
        ))
        XCTAssertFalse(InterpreterFormDraftProgress.matches(
            draft.fields[1], query: "ненаходится"
        ))
    }

    // 3. 翻译值写入必须经确认路径（applyTranslatedValue 只被确认
    //    sheet 调用）：普通俄语无 U+0301 重音、原中文保留、状态待确认。
    @MainActor
    func testTranslatedValueIsPlainAndNeedsConfirmation() {
        let documentID = UUID()
        var draft = InterpreterFormDraft(documentID: documentID)
        let field = InterpreterFormDraftField(
            russianLabel: "Цель приезда", type: .multiline
        )
        draft.fields = [field]
        let model = InterpreterFormDraftModel(
            document: InterpreterDocument(
                conversationID: UUID(),
                sourceRaw: InterpreterDocumentSource.scan.rawValue,
                originalFileName: "demo.pdf",
                formatRaw: InterpreterDocumentFormat.pdf.rawValue,
                mimeType: "application/pdf"
            ),
            store: nil // 无 store：写盘报错但内存语义照常。
        )
        model.replaceDraftForTesting(draft)
        // 模型返回带重音的俄语 —— 写入前必须剥离（正式表单值无重音）。
        model.applyTranslatedValue(
            fieldID: field.id,
            russian: "Уче́ба в МГУ́",
            chinese: "我在莫斯科国立大学学习"
        )
        let updated = model.field(with: field.id)
        XCTAssertEqual(updated?.userValue, "Учёба в МГУ")
        XCTAssertFalse(updated?.userValue.contains(RussianStressValidator.combiningAcute) ?? true)
        XCTAssertEqual(updated?.chineseSourceText, "我在莫斯科国立大学学习")
        XCTAssertEqual(updated?.status, .needsConfirmation)
    }

    // 4. 从字段进入对话再返回时定位同一 field ID（UI-only 上下文：
    //    beginFieldAsk 建立定位、consumeFormReturn 一次性消费）。
    @MainActor
    func testFieldAskReturnLocatesSameField() {
        let viewModel = InterpreterViewModel(environment: AppEnvironment())
        let documentID = UUID()
        let fieldID = UUID()
        let context = InterpreterFormFieldAskContext(
            documentID: documentID, fieldID: fieldID,
            russianLabel: "Регистрация по месту пребывания",
            chineseMeaning: "居住登记"
        )
        viewModel.beginFieldAsk(context, prefilledQuestion: "这个字段应该填写什么？")
        XCTAssertEqual(viewModel.fieldAskContext?.fieldID, fieldID)
        XCTAssertEqual(viewModel.fieldAskContext?.chipLabel, "当前字段：Регистрация по месту пребывания")
        // 预填只填输入框（不自动发送）。
        XCTAssertEqual(viewModel.replyDraft, "这个字段应该填写什么？")
        // 一次性消费：第一次返回定位、第二次 nil。
        let ref = viewModel.consumeFormReturn()
        XCTAssertEqual(ref?.documentID, documentID)
        XCTAssertEqual(ref?.fieldID, fieldID)
        XCTAssertNil(viewModel.consumeFormReturn())
        // 结束询问清空上下文。
        viewModel.endFieldAsk()
        XCTAssertNil(viewModel.fieldAskContext)
    }
}

