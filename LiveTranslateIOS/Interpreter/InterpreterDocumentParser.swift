import Foundation

/// 结构化文件分析 / 办事问答的模型与宽容解析。
///
/// 解析规则沿用 InterpreterResponseParser 的五件套：剥代码栅栏、
/// 容忍前后散文、字段缺失、字符串/数组混用（FlexList）、纯文本
/// 降级（主结果保留，明确"详细结构不可用"）。jsonPayload 复用
/// AttachmentAnalysisParser.jsonPayload —— 全仓共享原语（本轮把
/// Interpreter 的私有实现收敛到同一份语义）。

// MARK: - 文件分析结果（解释这份文件）

/// 一份现场文件的结构化理解。所有字段可缺失。
struct InterpreterDocumentAnalysis: Codable, Equatable, Sendable {
    /// 文件类型判断（如"宿舍登记表""缴费通知"）。
    var documentType: String?
    /// 中文摘要。
    var summaryChinese: String?
    /// 关键事实（双语自由文本行）。
    var keyFacts: [String]?
    /// 需要办理的事项。
    var requiredActions: [String]?
    /// 需要准备的材料。
    var requiredDocuments: [String]?
    /// 期限。
    var deadlines: [String]?
    /// 费用。
    var fees: [String]?
    /// 地址。
    var addresses: [String]?
    /// 联系人。
    var contacts: [String]?
    /// 表格字段解释（字段助手）。
    var formFields: [InterpreterFormField]?
    /// 建议向工作人员提出的问题（俄语）。
    var questionsToAsk: [String]?
    /// 警告（矛盾、缺失、需要核对的）。
    var warnings: [String]?
    /// 不确定项。
    var uncertainties: [String]?
    /// 校验后的引文。
    var citations: [InterpreterCitation]?
    /// 详细结构是否可用（纯文本回退 false）。
    var detailsAvailable: Bool = true

    enum CodingKeys: String, CodingKey {
        case documentType, summaryChinese, keyFacts, requiredActions
        case requiredDocuments, deadlines, fees, addresses, contacts
        case formFields, questionsToAsk, warnings, uncertainties
        case citations, detailsAvailable
    }

    /// 宽容解码：逐字段 decodeIfPresent（合成的 init(from:) 会要求
    /// 非可选字段全部在 JSON 里 —— detailsAvailable 缺失时整个解码
    /// 失败，这违反"部分字段缺失"的解析姿态）。
    init(
        documentType: String? = nil,
        summaryChinese: String? = nil,
        keyFacts: [String]? = nil,
        requiredActions: [String]? = nil,
        requiredDocuments: [String]? = nil,
        deadlines: [String]? = nil,
        fees: [String]? = nil,
        addresses: [String]? = nil,
        contacts: [String]? = nil,
        formFields: [InterpreterFormField]? = nil,
        questionsToAsk: [String]? = nil,
        warnings: [String]? = nil,
        uncertainties: [String]? = nil,
        citations: [InterpreterCitation]? = nil,
        detailsAvailable: Bool = true
    ) {
        self.documentType = documentType
        self.summaryChinese = summaryChinese
        self.keyFacts = keyFacts
        self.requiredActions = requiredActions
        self.requiredDocuments = requiredDocuments
        self.deadlines = deadlines
        self.fees = fees
        self.addresses = addresses
        self.contacts = contacts
        self.formFields = formFields
        self.questionsToAsk = questionsToAsk
        self.warnings = warnings
        self.uncertainties = uncertainties
        self.citations = citations
        self.detailsAvailable = detailsAvailable
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        documentType = try container.decodeIfPresent(String.self, forKey: .documentType)
        summaryChinese = try container.decodeIfPresent(String.self, forKey: .summaryChinese)
        keyFacts = try container.decodeIfPresent([String].self, forKey: .keyFacts)
        requiredActions = try container.decodeIfPresent([String].self, forKey: .requiredActions)
        requiredDocuments = try container.decodeIfPresent([String].self, forKey: .requiredDocuments)
        deadlines = try container.decodeIfPresent([String].self, forKey: .deadlines)
        fees = try container.decodeIfPresent([String].self, forKey: .fees)
        addresses = try container.decodeIfPresent([String].self, forKey: .addresses)
        contacts = try container.decodeIfPresent([String].self, forKey: .contacts)
        formFields = try container.decodeIfPresent([InterpreterFormField].self, forKey: .formFields)
        questionsToAsk = try container.decodeIfPresent([String].self, forKey: .questionsToAsk)
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings)
        uncertainties = try container.decodeIfPresent([String].self, forKey: .uncertainties)
        citations = try container.decodeIfPresent([InterpreterCitation].self, forKey: .citations)
        detailsAvailable = try container.decodeIfPresent(Bool.self, forKey: .detailsAvailable) ?? true
    }

    static let plainTextFallback = InterpreterDocumentAnalysis(
        summaryChinese: nil, detailsAvailable: false
    )
}

/// 一个表格字段的解释（字段助手）。只提供理解和建议 —— 绝不自动
/// 填写、绝不从账号或历史对话猜个人真实值。
struct InterpreterFormField: Codable, Equatable, Sendable {
    /// 俄语原字段名（文件中的原文）。
    var russianLabel: String
    /// 中文含义。
    var chineseMeaning: String
    /// 预期内容类型（如"日期""数字""姓名""地址"）。
    var expectedType: String?
    /// 文件中已有的值（确实存在时；不存在为空）。
    var existingValue: String?
    /// 用户需要准备的信息（提示，不是替用户编造的值）。
    var preparationHint: String?
    /// 示例格式（明确标注是示例）。
    var exampleFormat: String?
    /// 来源页码。
    var pageNumber: Int?
    /// 不确定项或风险提示。
    var riskNote: String?

    enum CodingKeys: String, CodingKey {
        case russianLabel, chineseMeaning, expectedType, existingValue
        case preparationHint, exampleFormat, pageNumber, riskNote
    }

    init(
        russianLabel: String,
        chineseMeaning: String,
        expectedType: String? = nil,
        existingValue: String? = nil,
        preparationHint: String? = nil,
        exampleFormat: String? = nil,
        pageNumber: Int? = nil,
        riskNote: String? = nil
    ) {
        self.russianLabel = russianLabel
        self.chineseMeaning = chineseMeaning
        self.expectedType = expectedType
        self.existingValue = existingValue
        self.preparationHint = preparationHint
        self.exampleFormat = exampleFormat
        self.pageNumber = pageNumber
        self.riskNote = riskNote
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        russianLabel = try container.decodeIfPresent(String.self, forKey: .russianLabel) ?? ""
        chineseMeaning = try container.decodeIfPresent(String.self, forKey: .chineseMeaning) ?? ""
        expectedType = try container.decodeIfPresent(String.self, forKey: .expectedType)
        existingValue = try container.decodeIfPresent(String.self, forKey: .existingValue)
        preparationHint = try container.decodeIfPresent(String.self, forKey: .preparationHint)
        exampleFormat = try container.decodeIfPresent(String.self, forKey: .exampleFormat)
        pageNumber = try container.decodeIfPresent(Int.self, forKey: .pageNumber)
        riskNote = try container.decodeIfPresent(String.self, forKey: .riskNote)
    }
}

// MARK: - 问答结果（基于文件与最近对话）

/// 基于文件上下文与最近对话的办事问答结果。
struct InterpreterDocumentAnswer: Codable, Equatable, Sendable {
    /// 中文回答。
    var answerChinese: String
    /// 建议的俄语表达。
    var suggestedRussian: String?
    /// 带重音俄语（校验通过时非空）。
    var stressedRussian: String?
    /// 中文回译。
    var backTranslation: String?
    /// 更礼貌的备选。
    var politeAlternative: String?
    /// 更简单的备选。
    var simpleAlternative: String?
    /// 校验后的引文。
    var citations: [InterpreterCitation]?
    /// 不确定项。
    var uncertainties: [String]?
    /// 详细结构是否可用。
    var detailsAvailable: Bool = true

    enum CodingKeys: String, CodingKey {
        case answerChinese, suggestedRussian, stressedRussian
        case backTranslation, politeAlternative, simpleAlternative
        case citations, uncertainties, detailsAvailable
    }

    init(
        answerChinese: String,
        suggestedRussian: String? = nil,
        stressedRussian: String? = nil,
        backTranslation: String? = nil,
        politeAlternative: String? = nil,
        simpleAlternative: String? = nil,
        citations: [InterpreterCitation]? = nil,
        uncertainties: [String]? = nil,
        detailsAvailable: Bool = true
    ) {
        self.answerChinese = answerChinese
        self.suggestedRussian = suggestedRussian
        self.stressedRussian = stressedRussian
        self.backTranslation = backTranslation
        self.politeAlternative = politeAlternative
        self.simpleAlternative = simpleAlternative
        self.citations = citations
        self.uncertainties = uncertainties
        self.detailsAvailable = detailsAvailable
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        answerChinese = try container.decodeIfPresent(String.self, forKey: .answerChinese) ?? ""
        suggestedRussian = try container.decodeIfPresent(String.self, forKey: .suggestedRussian)
        stressedRussian = try container.decodeIfPresent(String.self, forKey: .stressedRussian)
        backTranslation = try container.decodeIfPresent(String.self, forKey: .backTranslation)
        politeAlternative = try container.decodeIfPresent(String.self, forKey: .politeAlternative)
        simpleAlternative = try container.decodeIfPresent(String.self, forKey: .simpleAlternative)
        citations = try container.decodeIfPresent([InterpreterCitation].self, forKey: .citations)
        uncertainties = try container.decodeIfPresent([String].self, forKey: .uncertainties)
        detailsAvailable = try container.decodeIfPresent(Bool.self, forKey: .detailsAvailable) ?? true
    }
}

/// 一条经过校验的引文（来源文件 + 页码 + 短引文）。只有通过
/// InterpreterDocumentChunker.validateCitations 的引文才会出现在
/// 这里 —— 未校验的模型引文绝不落库、绝不渲染。
struct InterpreterCitation: Codable, Equatable, Sendable {
    /// 请求内 source ID（"S1"…）。
    var sourceID: String
    /// 文件名（显示用）。
    var documentName: String
    /// 页码。
    var pageNumber: Int
    /// 块序。
    var blockIndex: Int
    /// 短引文（≤300 字符）。
    var snippet: String

    var displayLabel: String {
        "\(documentName) · 第\(pageNumber)页"
    }
}

// MARK: - 宽容解析

enum InterpreterDocumentParser {
    /// 解析文件分析响应。纯文本响应 → summaryChinese = 原文，
    /// detailsAvailable = false（可读主结果保留，结构不可用诚实说明）。
    static func parseAnalysis(_ raw: String) -> InterpreterDocumentAnalysis? {
        guard let payload = AttachmentAnalysisParser.jsonPayload(from: raw),
              let data = payload.data(using: .utf8) else {
            return plainFallback(raw)
        }
        guard let decoded = try? JSONDecoder().decode(
            InterpreterDocumentAnalysis.self, from: data
        ) else {
            return plainFallback(raw)
        }
        var result = decoded
        // 主结果空 → 整体视为不可用（不伪造成功）。
        if (decoded.summaryChinese ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           (decoded.documentType ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           decoded.keyFacts?.isEmpty != false {
            return plainFallback(raw)
        }
        result.detailsAvailable = true
        return result
    }

    /// 解析问答响应。重音校验复用 RussianStressValidator。
    static func parseAnswer(_ raw: String) -> InterpreterDocumentAnswer? {
        guard let payload = AttachmentAnalysisParser.jsonPayload(from: raw),
              let data = payload.data(using: .utf8),
              var decoded = try? JSONDecoder().decode(
                  InterpreterDocumentAnswer.self, from: data
              ) else {
            // 纯文本回退：可读回答保留，详细结构不可用。
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return InterpreterDocumentAnswer(
                answerChinese: text, detailsAvailable: false
            )
        }
        let answer = decoded.answerChinese.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return nil }
        decoded.answerChinese = answer
        // 重音校验（第十五轮规则：改词改标点 → 丢弃重音版，保留普通俄语）。
        if let russian = decoded.suggestedRussian, !russian.isEmpty {
            decoded.stressedRussian = RussianStressValidator.validated(
                stressed: decoded.stressedRussian, plain: russian
            )
        } else {
            decoded.stressedRussian = nil
        }
        decoded.detailsAvailable = true
        return decoded
    }

    /// 解析模型返回的引文列表（校验前的原始形态）。
    static func parseRawCitations(_ raw: String) -> [InterpreterDocumentChunker.ReturnedCitation] {
        guard let payload = AttachmentAnalysisParser.jsonPayload(from: raw),
              let object = (try? JSONSerialization.jsonObject(with: Data(payload.utf8)))
                  as? [String: Any],
              let citations = object["citations"] as? [[String: Any]] else { return [] }
        return citations.prefix(12).compactMap { item in
            guard let source = item["source"] as? String ?? item["sourceID"] as? String
            else { return nil }
            let page = item["page"] as? Int ?? item["pageNumber"] as? Int
            let snippet = (item["snippet"] as? String ?? "").prefix(300)
            return InterpreterDocumentChunker.ReturnedCitation(
                sourceID: source, pageNumber: page, snippet: String(snippet)
            )
        }
    }

    private static func plainFallback(_ raw: String) -> InterpreterDocumentAnalysis? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return InterpreterDocumentAnalysis(
            summaryChinese: text, detailsAvailable: false
        )
    }
}
