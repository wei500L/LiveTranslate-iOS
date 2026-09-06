import Foundation
import OSLog
import Observation
import SwiftData

/// 表单填写草稿的编排模型（第二十一轮）—— 草稿逻辑与 SwiftUI 展示
/// 分离的薄层：
/// - 读 / 建一份文档唯一的 form-draft.json sidecar；
/// - 字段操作（值、状态、备注、排序、增、改、合并、删）后落盘；
/// - AI formFields 与 OCR 冒号行标签只在**创建草稿时**合并一次 —— 之
///   后草稿是唯一事实来源（用户可修正识别错误）；
/// - 自由文本"翻译为俄语"复用 InterpreterTranslationService（绝不建立
///   第二套翻译服务）：先披露、返回后用户确认，普通俄语（无 U+0301
///   重音）才写入正式值；
/// - 现场询问上下文交给 InterpreterViewModel（UI-only），本模型不碰对
///   话与 turn。
///
/// 所有写入只触碰本机 sidecar —— 不经 repository、不通知 observer、
/// 不进 outbox。
@MainActor
@Observable
final class InterpreterFormDraftModel {
    static let logger = Logger(
        subsystem: "com.livetranslate.ios", category: "interpreter-form-draft"
    )

    let document: InterpreterDocument
    private let store: InterpreterDocumentStore?

    /// 当前草稿（private(set)：外部只读；测试经 replaceDraftForTesting
    /// 注入，生产写路径全部经本模型的方法）。
    private(set) var draft: InterpreterFormDraft
    /// 草稿读取失败（坏 JSON / 归属不符）时的真实状态（nil = 正常）。
    private(set) var loadError: String?

    /// 最近一次写盘错误（诚实展示，可重试 —— 草稿在内存中继续编辑）。
    private(set) var lastWriteError: String?

    init(document: InterpreterDocument, store: InterpreterDocumentStore?) {
        self.document = document
        self.store = store
        if let store, let existing = store.readFormDraft(documentID: document.id) {
            draft = existing
        } else if let store, store.formDraftExists(documentID: document.id) {
            // sidecar 存在但读不回：诚实提示，不静默重建覆盖。
            loadError = "填写草稿无法读取（可能已损坏）。可以重新创建清单；原草稿文件在重新保存时会被覆盖。"
            draft = InterpreterFormDraft(documentID: document.id)
        } else {
            draft = InterpreterFormDraft(documentID: document.id)
        }
    }

    // MARK: - 派生状态

    var documentName: String { document.originalFileName }

    var progress: InterpreterFormDraftProgress.Summary {
        InterpreterFormDraftProgress.summary(of: draft)
    }

    var fieldCount: Int { draft.fields.count }

    func field(with id: UUID) -> InterpreterFormDraftField? {
        draft.fields.first { $0.id == id }
    }

    func field(at index: Int) -> InterpreterFormDraftField? {
        guard draft.fields.indices.contains(index) else { return nil }
        return draft.fields[index]
    }

    func index(of id: UUID) -> Int? {
        draft.fields.firstIndex { $0.id == id }
    }

    // MARK: - 建立清单（AI formFields + OCR 标签，一次性合并）

    /// 用文档当前 AI 分析与提取文字建立字段清单（草稿为空时）。
    /// 返回建立的字段数（0 = 无可识别来源，用户仍可手动新增）。
    @discardableResult
    func populateFromSources(extraction: InterpreterDocumentExtraction?) -> Int {
        guard draft.fields.isEmpty else { return 0 }
        let analysisFields = document.analysis?.formFields ?? []
        let pages = extraction?.pages ?? []
        let fields = analysisFields.isEmpty && pages.isEmpty
            ? []
            : InterpreterFormFieldSourceMerge.merged(
                analysisFields: analysisFields, pages: pages
            )
        guard !fields.isEmpty else { return 0 }
        draft.fields = fields
        draft.modifiedAt = .now
        persist()
        return fields.count
    }

    /// 草稿是否已有内容（入口按钮文案区分"逐项填写" vs "创建填写清单"）。
    var hasFields: Bool { !draft.fields.isEmpty }

    // MARK: - 字段值与状态

    /// 用户输入值（原样保存 —— 绝不自动翻译、改大小写/空格/标点）。
    /// "必填"只是提示：不阻止保存真实值，也不虚构默认值。
    func setValue(fieldID: UUID, value: String) {
        mutate(fieldID: fieldID) { field in
            field.userValue = value
            field.status = InterpreterFormDraftField.effectiveStatus(field: field)
            if value.isEmpty { field.chineseSourceText = "" }
        }
    }

    func setNote(fieldID: UUID, note: String) {
        mutate(fieldID: fieldID) { $0.userNote = note }
    }

    /// 翻译结果写入（用户明确确认后调用）：正式表单值永远用普通俄语
    /// （无 U+0301 重音），原中文保留在 chineseSourceText 供核对。
    func applyTranslatedValue(fieldID: UUID, russian: String, chinese: String) {
        let plain = RussianStressValidator.stripStress(russian)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else { return }
        mutate(fieldID: fieldID) { field in
            field.chineseSourceText = chinese
            field.userValue = plain
            field.status = .needsConfirmation // 翻译值默认待确认 —— 用户核对后才算已填
        }
    }

    /// 现场问到的回答"使用为当前值"（用户确认写入）。
    func applyHeardValue(fieldID: UUID, value: String) {
        setValue(fieldID: fieldID, value: value)
    }

    func markNeedsConfirmation(fieldID: UUID) {
        mutate(fieldID: fieldID) { field in
            guard !field.userValue.isEmpty else { return }
            field.status = .needsConfirmation
        }
    }

    /// 用户核对翻译值后确认无误 → 已填。
    func confirmFilled(fieldID: UUID) {
        mutate(fieldID: fieldID) { field in
            guard !field.userValue.isEmpty else { return }
            field.status = .filled
        }
    }

    func markNotApplicable(fieldID: UUID, notApplicable: Bool) {
        mutate(fieldID: fieldID) { field in
            if notApplicable {
                field.status = .notApplicable
            } else {
                field.status = InterpreterFormDraftField.effectiveStatus(field: field)
            }
        }
    }

    // MARK: - 字段结构操作

    /// 拖动排序（总览 List onMove）。
    func move(from offsets: IndexSet, to destination: Int) {
        draft.fields.move(fromOffsets: offsets, toOffset: destination)
        draft.modifiedAt = .now
        persist()
    }

    /// 上移一位（菜单路径 —— 修正识别错误的字段顺序）。
    func moveUp(fieldID: UUID) {
        guard let index = index(of: fieldID), index > 0 else { return }
        draft.fields.swapAt(index, index - 1)
        draft.modifiedAt = .now
        persist()
    }

    /// 下移一位（菜单路径）。
    func moveDown(fieldID: UUID) {
        guard let index = index(of: fieldID), index + 1 < draft.fields.count else { return }
        draft.fields.swapAt(index, index + 1)
        draft.modifiedAt = .now
        persist()
    }

    /// 手动新增字段（不依赖 AI 成功）。
    @discardableResult
    func addField(
        russianLabel: String, chineseMeaning: String = "",
        pageNumber: Int? = nil, type: InterpreterFormFieldType = .unknown,
        requirement: InterpreterFormFieldRequirement = .unknown,
        formatHint: String? = nil, options: [String] = []
    ) -> UUID? {
        let label = russianLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return nil }
        let field = InterpreterFormDraftField(
            russianLabel: label, chineseMeaning: chineseMeaning,
            pageNumber: pageNumber, type: type, requirement: requirement,
            formatHint: formatHint, options: options
        )
        draft.fields.append(field)
        draft.modifiedAt = .now
        persist()
        return field.id
    }

    /// 编辑字段信息（识别错误的修正：标签、解释、类型、必填、格式、
    /// 选项、页码）。
    func updateField(_ updated: InterpreterFormDraftField) {
        guard let index = index(of: updated.id) else { return }
        var field = updated
        field.modifiedAt = .now
        draft.fields[index] = field
        draft.modifiedAt = .now
        persist()
    }

    /// 合并两个字段（识别重复）：标签与解释取第一个；值/状态取非空的
    /// 那一侧；第二个被删除。
    func mergeFields(primaryID: UUID, intoSecondaryID: UUID) {
        guard var primary = field(with: primaryID),
              let secondaryIndex = index(of: intoSecondaryID) else { return }
        let secondary = draft.fields[secondaryIndex]
        if primary.chineseMeaning.isEmpty { primary.chineseMeaning = secondary.chineseMeaning }
        if primary.userValue.isEmpty {
            primary.userValue = secondary.userValue
            primary.chineseSourceText = secondary.chineseSourceText
        }
        if primary.userNote.isEmpty { primary.userNote = secondary.userNote }
        if primary.formatHint == nil { primary.formatHint = secondary.formatHint }
        if primary.pageNumber == nil { primary.pageNumber = secondary.pageNumber }
        if primary.sourceSnippet == nil { primary.sourceSnippet = secondary.sourceSnippet }
        if primary.options.isEmpty { primary.options = secondary.options }
        primary.status = InterpreterFormDraftField.effectiveStatus(field: primary)
        primary.modifiedAt = .now
        draft.fields[secondaryIndex] = primary
        let primaryIndex = index(of: primaryID)
        if let primaryIndex, primaryIndex != secondaryIndex {
            draft.fields.remove(at: primaryIndex)
        }
        draft.modifiedAt = .now
        persist()
    }

    func deleteField(fieldID: UUID) {
        draft.fields.removeAll { $0.id == fieldID }
        draft.modifiedAt = .now
        persist()
    }

    // MARK: - 完成核对

    var reviewGroups: InterpreterFormDraftProgress.ReviewGroups {
        InterpreterFormDraftProgress.reviewGroups(of: draft)
    }

    /// 完成核对：只标记"本机清单已核对"，不代表官方表单已填写/签署/
    /// 提交。完成后仍可继续编辑（再次修改不清除核对标记 —— 清单继续
    /// 有效）。
    func markChecked() {
        draft.checkedAt = .now
        draft.modifiedAt = .now
        persist()
    }

    var isChecked: Bool { draft.checkedAt != nil }

    // MARK: - 持久化

    private func mutate(fieldID: UUID, _ transform: (inout InterpreterFormDraftField) -> Void) {
        guard let index = index(of: fieldID) else { return }
        var field = draft.fields[index]
        transform(&field)
        field.modifiedAt = .now
        draft.fields[index] = field
        draft.modifiedAt = .now
        persist()
    }

    /// 测试注入（XCTest target）：替换整个草稿。生产代码不调用 ——
    /// 写路径全部经本模型的方法（每次写入原子落盘）。
    func replaceDraftForTesting(_ replacement: InterpreterFormDraft) {
        draft = replacement
    }

    private func persist() {
        guard let store else {
            lastWriteError = "无法访问本机文件存储"
            return
        }
        do {
            try store.writeFormDraft(draft, documentID: document.id)
            lastWriteError = nil
        } catch {
            Self.logger.error("write form draft failed: \(error)")
            lastWriteError = "草稿保存失败（内容仍在编辑中，可重试）"
        }
    }
}
