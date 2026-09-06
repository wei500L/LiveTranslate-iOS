import Foundation

/// 俄语表单逐项填写（第二十一轮）的纯值类型。
///
/// 一份表单 = 一份本机填写草稿（form-draft.json sidecar，由
/// InterpreterDocumentStore 落盘）。字段清单的来源按优先级合并：
/// 1. 第十六轮 AI 文件分析的 formFields（中文解释、类型建议）；
/// 2. OCR / 文字层中可识别的标签（冒号行启发式，仅建议）；
/// 3. 用户手动新增或修正。
///
/// 全部内容只保存在当前设备：不进 outbox、不进 SwiftData observer、
/// 不进 Spotlight / Widget / Live Activity、不上传服务器。用户主动把
/// 字段问题或自由文本发起翻译后，该文字沿既有 InterpreterTurn 链路
/// 同步 —— 那是唯一且明确的云端边界。
///
/// 本功能是填写助手，不是自动填表机器人：不写回 PDF、不自动提交、
/// 不生成签名；用户最终在纸质或官方电子表单中亲自填写。

// MARK: - 字段类型

/// 字段的预期输入类型（AI 建议或用户手动选择；unknown 兜底）。
enum InterpreterFormFieldType: String, Codable, Sendable, CaseIterable, Identifiable {
    case singleLine       // 单行文字（姓名、证件号、地址…）
    case multiline        // 多行说明（来访目的、情况说明…）
    case date             // 日期
    case number           // 数字或金额
    case singleChoice     // 单选/下拉候选
    case multipleChoice   // 多选/复选框
    case signature        // 签名位置（只解释要求，不提供绘制能力）
    case unknown          // 未知类型（宽容兜底）

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .singleLine: return "单行文字"
        case .multiline: return "多行说明"
        case .date: return "日期"
        case .number: return "数字/金额"
        case .singleChoice: return "单选"
        case .multipleChoice: return "多选"
        case .signature: return "签名位置"
        case .unknown: return "未知类型"
        }
    }

    /// 签名位置只解释"这里需要签名/日期"，不提供输入。
    var acceptsUserValue: Bool {
        self != .signature
    }

    /// 从 AI 分析的 expectedType 自由文本（或俄语关键词）启发映射。
    /// 无法判断时返回 unknown —— 绝不丢弃字段。
    static func fromHint(_ hint: String?) -> InterpreterFormFieldType {
        guard let hint, !hint.isEmpty else { return .unknown }
        let lowered = hint.lowercased()
        func contains(_ needles: [String]) -> Bool {
            needles.contains { lowered.contains($0) }
        }
        if contains(["签名", "签字", "подпись", "signature", "签署"]) { return .signature }
        if contains(["日期", "时间", "дата", "date", "出生"]) { return .date }
        if contains(["多行", "说明", "描述", "备注", "multiline", "описание", "цель"]) { return .multiline }
        if contains(["数字", "金额", "费用", "数量", "число", "сумма", "amount", "number", "количество"]) { return .number }
        if contains(["多选", "复选", "勾选", "checkbox"]) { return .multipleChoice }
        if contains(["单选", "选择", "下拉", "radio", "select", "выбор", "вариант"]) { return .singleChoice }
        return .unknown
    }
}

/// 字段填写状态（四态，不只用颜色区分 —— UI 带文字标签）。
enum InterpreterFormFieldStatus: String, Codable, Sendable {
    case empty             // 未填
    case filled            // 已填
    case needsConfirmation // 待确认（用户标记或翻译后待核对）
    case notApplicable     // 不适用

    var displayName: String {
        switch self {
        case .empty: return "未填"
        case .filled: return "已填"
        case .needsConfirmation: return "待确认"
        case .notApplicable: return "不适用"
        }
    }
}

/// 必填性（AI 建议或用户设定；unknown 兜底 —— 只是提示，不阻止保存）。
enum InterpreterFormFieldRequirement: String, Codable, Sendable {
    case required
    case optional
    case unknown

    var displayName: String {
        switch self {
        case .required: return "必填"
        case .optional: return "可选"
        case .unknown: return "必填未知"
        }
    }
}

// MARK: - 草稿字段

/// 草稿中的一个字段（Codable 纯值；宽容解码 —— 单字段结构不完整不
/// 丢弃整份清单）。
struct InterpreterFormDraftField: Codable, Equatable, Identifiable, Sendable {
    /// 稳定的本机 field ID（草稿内持久；创建时生成，排序/编辑不变）。
    var id: UUID
    /// 俄文字段原文（表单中的原标签）。
    var russianLabel: String
    /// 中文解释。
    var chineseMeaning: String
    /// 来源页码（1-based；nil = 未定位到原表位置）。
    var pageNumber: Int?
    /// 可选的来源短引文（OCR/文字层中该字段的原文行）。
    var sourceSnippet: String?
    /// 字段类型。
    var type: InterpreterFormFieldType
    /// 必填/可选/未知。
    var requirement: InterpreterFormFieldRequirement
    /// 格式提示（如 DD.MM.YYYY；永远只是建议）。
    var formatHint: String?
    /// 候选项（俄文选项，可带中文解释；AI 建议或用户输入）。
    var options: [String]
    /// 用户输入的值（原样保存 —— 绝不自动翻译姓名/证件号等原样字段）。
    var userValue: String
    /// 自由文本翻译为俄语前的原中文（翻译后保留供核对；空 = 无）。
    var chineseSourceText: String
    /// 用户备注（现场问到的答案等）。
    var userNote: String
    /// 状态。
    var status: InterpreterFormFieldStatus
    var modifiedAt: Date

    init(
        id: UUID = UUID(),
        russianLabel: String,
        chineseMeaning: String = "",
        pageNumber: Int? = nil,
        sourceSnippet: String? = nil,
        type: InterpreterFormFieldType = .unknown,
        requirement: InterpreterFormFieldRequirement = .unknown,
        formatHint: String? = nil,
        options: [String] = [],
        userValue: String = "",
        chineseSourceText: String = "",
        userNote: String = "",
        status: InterpreterFormFieldStatus = .empty,
        modifiedAt: Date = .now
    ) {
        self.id = id
        self.russianLabel = russianLabel
        self.chineseMeaning = chineseMeaning
        self.pageNumber = pageNumber
        self.sourceSnippet = sourceSnippet
        self.type = type
        self.requirement = requirement
        self.formatHint = formatHint
        self.options = options
        self.userValue = userValue
        self.chineseSourceText = chineseSourceText
        self.userNote = userNote
        self.status = status
        self.modifiedAt = modifiedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, russianLabel, chineseMeaning, pageNumber, sourceSnippet
        case type, requirement, formatHint, options
        case userValue, chineseSourceText, userNote, status, modifiedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // id 缺失/无效 → 生成新 ID（字段仍保留，不丢弃）。
        if let raw = try container.decodeIfPresent(String.self, forKey: .id),
           let parsed = UUID(uuidString: raw) {
            id = parsed
        } else {
            id = UUID()
        }
        russianLabel = (try container.decodeIfPresent(String.self, forKey: .russianLabel) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        chineseMeaning = try container.decodeIfPresent(String.self, forKey: .chineseMeaning) ?? ""
        pageNumber = try container.decodeIfPresent(Int.self, forKey: .pageNumber)
        sourceSnippet = try container.decodeIfPresent(String.self, forKey: .sourceSnippet)
        type = try container.decodeIfPresent(InterpreterFormFieldType.self, forKey: .type) ?? .unknown
        requirement = try container.decodeIfPresent(InterpreterFormFieldRequirement.self, forKey: .requirement) ?? .unknown
        formatHint = try container.decodeIfPresent(String.self, forKey: .formatHint)
        options = try container.decodeIfPresent([String].self, forKey: .options) ?? []
        userValue = try container.decodeIfPresent(String.self, forKey: .userValue) ?? ""
        chineseSourceText = try container.decodeIfPresent(String.self, forKey: .chineseSourceText) ?? ""
        userNote = try container.decodeIfPresent(String.self, forKey: .userNote) ?? ""
        status = try container.decodeIfPresent(InterpreterFormFieldStatus.self, forKey: .status) ?? .empty
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? .now
    }

    /// 有效状态：空白标签的字段对用户无意义（用户可手动删除 —— 这里
    /// 只在加载时丢弃完全空白的条目）。
    var isMeaningful: Bool { !russianLabel.isEmpty }

    /// 值状态派生：清空值 → empty；有值 → filled；needsConfirmation 与
    /// notApplicable 是用户显式标记（待确认需要值才有意义；不适用保持
    /// 不适用）。
    static func effectiveStatus(field: InterpreterFormDraftField) -> InterpreterFormFieldStatus {
        switch field.status {
        case .notApplicable:
            return .notApplicable
        case .needsConfirmation:
            return field.userValue.isEmpty ? .empty : .needsConfirmation
        case .empty, .filled:
            return field.userValue.isEmpty ? .empty : .filled
        }
    }
}

// MARK: - 草稿

/// 一份表单的本机填写草稿（sidecar JSON —— 设备本地，绝不进 wire）。
struct InterpreterFormDraft: Codable, Equatable, Sendable {
    /// 草稿格式版本（当前 "1"；未知版本宽容解码）。
    var version: String
    /// 所属 document ID（与 sidecar 所在目录一致；加载时校验）。
    var documentID: UUID
    /// 字段（按原表顺序；用户可拖动调整）。
    var fields: [InterpreterFormDraftField]
    /// 完成核对时间（nil = 未核对；完成后仍可继续编辑）。
    var checkedAt: Date?
    var modifiedAt: Date

    static let currentVersion = "1"
    static let fileName = "form-draft.json"

    init(
        version: String = InterpreterFormDraft.currentVersion,
        documentID: UUID,
        fields: [InterpreterFormDraftField] = [],
        checkedAt: Date? = nil,
        modifiedAt: Date = .now
    ) {
        self.version = version
        self.documentID = documentID
        self.fields = fields
        self.checkedAt = checkedAt
        self.modifiedAt = modifiedAt
    }

    enum CodingKeys: String, CodingKey {
        case version, documentID, fields, checkedAt, modifiedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? Self.currentVersion
        documentID = try container.decodeIfPresent(UUID.self, forKey: .documentID) ?? UUID()
        fields = (try container.decodeIfPresent([InterpreterFormDraftField].self, forKey: .fields) ?? [])
            .filter(\.isMeaningful)
        checkedAt = try container.decodeIfPresent(Date.self, forKey: .checkedAt)
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? .now
    }

    /// 解码容错：坏 JSON → nil（绝不崩溃；UI 提示"草稿无法读取，可
    /// 重新创建"）。
    static func decode(_ json: String, documentID: UUID) -> InterpreterFormDraft? {
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(InterpreterFormDraft.self, from: data) else { return nil }
        // 归属校验：documentID 不一致（文件被移动/复制）→ 不认领。
        guard decoded.documentID == documentID else { return nil }
        return decoded
    }

    func encodedJSON() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - 进度与核对（纯函数）

/// 草稿进度与完成核对的纯函数（可测；View 不自行统计）。
enum InterpreterFormDraftProgress {

    struct Summary: Equatable, Sendable {
        var total: Int
        var filled: Int
        var empty: Int
        var needsConfirmation: Int
        var notApplicable: Int
        /// 未完成 = 未填 + 待确认（不适用不算未完成）。
        var unfinished: Int

        var checked: Bool { filled + notApplicable > 0 && unfinished == 0 }
    }

    static func summary(of draft: InterpreterFormDraft) -> Summary {
        var filled = 0, empty = 0, needsConfirmation = 0, notApplicable = 0
        for field in draft.fields {
            switch InterpreterFormDraftField.effectiveStatus(field: field) {
            case .filled: filled += 1
            case .empty: empty += 1
            case .needsConfirmation: needsConfirmation += 1
            case .notApplicable: notApplicable += 1
            }
        }
        let total = draft.fields.count
        return Summary(
            total: total,
            filled: filled,
            empty: empty,
            needsConfirmation: needsConfirmation,
            notApplicable: notApplicable,
            unfinished: empty + needsConfirmation
        )
    }

    /// 完成前核对分组（按原表顺序保留字段顺序）。
    struct ReviewGroups: Equatable, Sendable {
        /// 尚未填写的必填项。
        var missingRequired: [InterpreterFormDraftField]
        /// 标记为待确认的字段。
        var needsConfirmation: [InterpreterFormDraftField]
        /// 已填写字段（及其值）。
        var filled: [InterpreterFormDraftField]
        /// 不适用字段。
        var notApplicable: [InterpreterFormDraftField]
    }

    static func reviewGroups(of draft: InterpreterFormDraft) -> ReviewGroups {
        var missing: [InterpreterFormDraftField] = []
        var confirm: [InterpreterFormDraftField] = []
        var filled: [InterpreterFormDraftField] = []
        var na: [InterpreterFormDraftField] = []
        for field in draft.fields {
            switch InterpreterFormDraftField.effectiveStatus(field: field) {
            case .filled:
                filled.append(field)
            case .empty:
                if field.requirement == .required { missing.append(field) }
                // 可选未填不阻断核对，但也不放进"已填"。
            case .needsConfirmation:
                confirm.append(field)
            case .notApplicable:
                na.append(field)
            }
        }
        return ReviewGroups(
            missingRequired: missing,
            needsConfirmation: confirm,
            filled: filled,
            notApplicable: na
        )
    }

    /// 搜索匹配：俄文标签、中文解释与用户备注（大小写不敏感）。
    static func matches(_ field: InterpreterFormDraftField, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let lowered = trimmed.lowercased()
        return field.russianLabel.lowercased().contains(lowered)
            || field.chineseMeaning.lowercased().contains(lowered)
            || field.userNote.lowercased().contains(lowered)
    }
}

// MARK: - 字段来源合并（纯函数）

/// 草稿初始化时的字段来源合并（纯函数）：
/// 1. AI formFields 优先（带中文解释）；
/// 2. OCR / 文字层的冒号行启发式标签补充（去重后仅作建议字段）；
/// 3. 用户手动新增发生在草稿建立之后（草稿是唯一事实来源）。
enum InterpreterFormFieldSourceMerge {

    /// AI 分析字段 → 草稿字段。existingValue 是文件中已有的值 —— 不是
    /// 用户亲自输入或确认的值，绝不直接写进 userValue（用户值必须以
    /// "亲自输入或明确确认"为前提）；作为来源引文展示供核对。
    static func fields(fromAnalysis analysis: [InterpreterFormField]) -> [InterpreterFormDraftField] {
        analysis.compactMap { field in
            let label = field.russianLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { return nil }
            let existing = field.existingValue?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return InterpreterFormDraftField(
                russianLabel: label,
                chineseMeaning: field.chineseMeaning,
                pageNumber: field.pageNumber,
                sourceSnippet: existing.isEmpty ? nil : "文件中已有值：\(existing)",
                type: InterpreterFormFieldType.fromHint(field.expectedType),
                requirement: .unknown,
                formatHint: field.exampleFormat,
                options: []
            )
        }
    }

    /// 页面文字中的候选标签（冒号行启发式 —— 只建议，用户可删改）：
    /// 短行、以 ":" 或 "：" 结尾或中含冒号、且不是纯数字。
    static func candidateLabels(pages: [InterpreterDocumentPageText]) -> [String] {
        var labels: [String] = []
        for page in pages {
            for line in page.effectiveText.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, trimmed.count <= 80 else { continue }
                // 去掉行尾下划线/空白占位（表单留白）。
                let cleaned = trimmed
                    .replacingOccurrences(of: "_", with: "")
                    .trimmingCharacters(in: .whitespaces)
                guard cleaned.contains(":") || cleaned.contains("：") else { continue }
                let label = cleaned
                    .components(separatedBy: CharacterSet(charactersIn: ":："))
                    .first?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                guard !label.isEmpty, label.count >= 2, !label.allSatisfy({ $0.isNumber }) else { continue }
                if !labels.contains(label) {
                    labels.append(label)
                }
            }
        }
        return labels
    }

    /// 合并：AI 字段在前（原序），启发式标签补在后（去重 vs AI 标签）。
    static func merged(
        analysisFields: [InterpreterFormField],
        pages: [InterpreterDocumentPageText]
    ) -> [InterpreterFormDraftField] {
        var fields = fields(fromAnalysis: analysisFields)
        let existing = Set(fields.map { $0.russianLabel.lowercased() })
        let candidates = candidateLabels(pages: pages)
        var appended = 0
        for label in candidates {
            guard !existing.contains(label.lowercased()) else { continue }
            // 启发式候选量上限：一份表单的字段清单不失控。
            if appended >= 40 { break }
            fields.append(InterpreterFormDraftField(
                russianLabel: label,
                chineseMeaning: "",
                type: .unknown,
                requirement: .unknown
            ))
            appended += 1
        }
        return fields
    }
}

// MARK: - 询问工作人员上下文（UI-only）

/// 字段询问上下文：带着当前字段进入柜台对话的内存状态 —— 绝不入库、
/// 不进 outbox、不写进任何 turn wire；只驱动上下文条的字段 chip 与
/// 返回定位。
struct InterpreterFormFieldAskContext: Equatable, Sendable {
    var documentID: UUID
    var fieldID: UUID
    var russianLabel: String
    var chineseMeaning: String

    /// chip 文案（"当前字段：…"）。
    var chipLabel: String {
        let label = russianLabel.isEmpty ? chineseMeaning : russianLabel
        return "当前字段：\(label)"
    }
}

/// 从填写页进入对话再返回时的定位引用（UI-only，一次性消费）。
struct InterpreterFormFieldRef: Equatable, Sendable {
    var documentID: UUID
    var fieldID: UUID
}
