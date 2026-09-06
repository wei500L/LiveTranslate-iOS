import Foundation
import OSLog

/// 办事事项的 AI 结构化整理 —— 复用 `StudyReviewModelService` 传输层
/// （同一个 OpenAI 兼容原语、同一个 key 与回退链：绝不建立第三套
/// AI 客户端、绝不新增 API Key）。AIRequestDisclosure / AICallScope /
/// AI 活动台账由调用链自动覆盖（传输层记录元数据）。
///
/// 输入预算有界（加入事项绝不放大上传）：
/// - 对话：最近 12 回合、每回合截断至 400 字符、总预算 2400 字符；
/// - 文件：最多 6 个 chunk、每个截断至 900 字符、总预算 3600 字符
///   （低于 InterpreterDocumentChunker 的文件请求上限 —— 整理只做归
///   纳，不做逐行理解）；
/// - 整回合/整 chunk 裁剪，绝不整段历史或整份 OCR。
///
/// 防编造（prompt 硬约束 + 本地丢弃兜底）：
/// - 只总结来源，不补写来源中没有的证件、号码、住址、日期、费用、
///   法律结论或承诺；"通常需要"不冒充"本次明确要求"；
/// - 冲突信息全部进 uncertainties；
/// - 医疗、法律、签证内容只做语言和流程整理，不给保证；
/// - 费用不做汇率换算、不猜币种；
/// - 相对日期保留原文、换算锚点与时区；
/// - 没有明确时间时不建议创建提醒。
///
/// sourceRefs 校验（第十七轮边界的本地执行）：模型引用的对话回合必须
/// 来自本次发送的 turn 列表；文件来源必须通过第十六轮三重校验（source
/// ID 属于本次请求、页码匹配、引文真实存在于发送文本 —— 含遮盖后的
/// 文本）。无效引用被丢弃并记入 uncertainties，绝不展示成可信引用。
struct ErrandAIService: Sendable {
    static let logger = Logger(
        subsystem: "com.livetranslate.ios", category: "errands"
    )

    private let model: any StudyReviewModelService

    init(model: any StudyReviewModelService) {
        self.model = model
    }

    var isConfiguredNow: Bool { model.isConfiguredNow }

    // MARK: - 输入（预算内的来源快照）

    /// 一次整理请求的输入（UI 在发送前展示 disclosure 摘要）。
    struct Input: Equatable, Sendable {
        /// 用户选中的对话回合（已按预算裁剪、可选遮盖后）。
        var turnLines: [String]
        /// 用户选中的文件 chunk（已按预算裁剪、可选遮盖后）。
        var sourceLines: [String]
        /// 用户手动输入的办事背景。
        var userContext: String
        /// 当前日期/时区描述（相对日期换算锚点）。
        var anchorDescription: String
        /// 场景。
        var scene: InterpreterScene
        /// 参与本次请求的 turn ID（sourceRef 校验用）。
        var turnIDs: [UUID]
        /// 参与本次请求的文件来源（sourceRef 三重校验用）。
        var sources: [InterpreterDocumentChunker.RequestSource]
    }

    // MARK: - 结构化输出

    struct Suggestion: Equatable, Sendable {
        var titleSuggestion: String?
        var purposeSummary: String?
        var requiredDocuments: [String] = []
        var actions: [String] = []
        var questionsToAsk: [String] = []
        var appointmentCandidates: [ErrandDateParser.Candidate] = []
        var deadlineCandidates: [ErrandDateParser.Candidate] = []
        var followUpCandidates: [ErrandDateParser.Candidate] = []
        var fees: [String] = []
        var locations: [String] = []
        var contacts: [String] = []
        var uncertainties: [String] = []
        /// 校验通过的来源引用（对话/文件）。
        var validatedTurnRefs: [UUID] = []
        var validatedCitations: [InterpreterCitation] = []
        /// 纯文本降级时的可读建议（结构不可用但保留原文摘要）。
        var plainTextFallback: String?
        /// 详细结构是否可用。
        var detailsAvailable: Bool = true
    }

    // MARK: - 整理

    func organize(_ input: Input) async throws -> Suggestion {
        let raw = try await AICallScope.with(
            AICallContext(
                feature: .errandOrganizing,
                textCategory: .mixed,
                masked: input.turnLines.contains(where: { $0.contains("▪") })
                    || input.sourceLines.contains(where: { $0.contains("▪") })
            )
        ) {
            try await model.complete(
                systemPrompt: Self.systemPrompt(scene: input.scene),
                userPrompt: Self.userPrompt(input),
                maxTokens: 2200
            )
        }
        return Self.parse(raw, input: input)
    }

    // MARK: - Prompt

    static func systemPrompt(scene: InterpreterScene) -> String {
        """
        你是一位帮助中国留学生在俄罗斯办理日常事务的助理。用户会给你一段\
        办事对话（俄语/中文）和/或文件摘录，以及他们写下的办事背景。

        场景：\(scene.promptBackground)。

        请把内容整理成一份 JSON 办事草稿。规则（必须遵守）：
        1. 只总结来源中明确出现的信息。绝不补写来源中没有的证件、号码、\
        住址、日期、费用、法律结论或承诺。宁可留空，不可编造。
        2. "通常需要"的材料与"对方明确要求"的材料必须区分：前者只能进 \
        uncertainties（用"通常需要，请核实"开头），后者才进 requiredDocuments。
        3. 相互冲突或模糊的信息（两个不同日期、两种不同金额）全部进 \
        uncertainties，不要自行取舍。
        4. 医疗、法律、签证内容只做语言和流程整理，不给出任何保证或\
        法律意见。
        5. 费用只保留原文表述，不做汇率换算，不猜测币种。
        6. 日期保留原文写法（如 "до пятницы"），dateText 字段放原文；\
        不要把相对日期算成具体日期（用户端会换算并要求确认）。
        7. 没有明确时间时，不要建议创建提醒或日历。
        8. 引用来源时用 sourceRefs：对话引用 {"turn": "T3"}（T 后数字是\
        对话行的编号），文件引用 {"source": "S1", "page": 2, "snippet":\
        "原文片段"}。只引用真实存在于输入中的编号和片段。
        9. 用中文输出整理结果（保留俄语原文短语在括号中，便于现场核对）。

        JSON 字段：titleSuggestion（8 字内标题）、purposeSummary（一句话\
        目的）、requiredDocuments[]、actions[]、questionsToAsk[]（俄语+\
        中文）、appointmentCandidates[]、deadlineCandidates[]、\
        followUpCandidates[]、fees[]、locations[]、contacts[]、\
        uncertainties[]、sourceRefs[]。时间候选对象含 dateText（原文）、\
        meaning（中文含义）、isRelative（是否相对日期）、uncertain（是否\
        仍有歧义）。只输出 JSON。
        """
    }

    static func userPrompt(_ input: Input) -> String {
        var lines: [String] = []
        if !input.turnLines.isEmpty {
            lines.append("【对话记录】")
            lines.append(contentsOf: input.turnLines)
        }
        if !input.sourceLines.isEmpty {
            lines.append("【文件摘录】")
            lines.append(contentsOf: input.sourceLines)
        }
        if !input.userContext.isEmpty {
            lines.append("【用户背景】")
            lines.append(input.userContext)
        }
        lines.append("【当前时间】\(input.anchorDescription)")
        return lines.joined(separator: "\n")
    }

    // MARK: - 输入构建（预算裁剪 + 遮盖）

    /// 构建预算内的输入。对话 12 回合 / 每回合 400 字符 / 共 2400；文件
    /// 6 chunk / 每 chunk 900 字符 / 共 3600（低于文件请求链自身的上限）。
    static func buildInput(
        turns: [(id: UUID, text: String, isCounterpart: Bool)],
        sources: [InterpreterDocumentChunker.RequestSource],
        userContext: String,
        scene: InterpreterScene,
        now: Date = .now,
        timezone: TimeZone = .current,
        maskSensitive: Bool = true
    ) -> (input: Input, disclosure: AIRequestDisclosure, findings: [String]) {
        // 对话：最近 12 回合，逐回合截断，总量封顶。
        let recent = turns.suffix(12)
        var turnLines: [String] = []
        var turnIDs: [UUID] = []
        var turnBudget = 2400
        for (index, turn) in recent.enumerated() {
            var text = String(turn.text.prefix(400))
            if maskSensitive {
                let (masked, matches) = InterpreterSensitiveMasker.masked(text)
                text = masked
                _ = matches
            }
            let line = "T\(index + 1) \(turn.isCounterpart ? "对方" : "我")：\(text)"
            guard turnBudget > 0 else { break }
            let clipped = String(line.prefix(turnBudget))
            turnBudget -= clipped.count
            turnLines.append(clipped)
            turnIDs.append(turn.id)
        }

        // 文件：最多 6 chunk，逐 chunk 截断，总量封顶（遮盖在来源选择层
        // 已做过 —— 这里对直接传入的文本再兜底一次）。
        var sourceLines: [String] = []
        var sentSources: [InterpreterDocumentChunker.RequestSource] = []
        var sourceBudget = 3600
        for source in sources.prefix(6) {
            let line = InterpreterDocumentPrompt.sourceLine(
                sourceID: source.sourceID,
                documentName: source.chunk.documentName,
                pageNumber: source.chunk.pageNumber,
                text: String(source.chunk.text.prefix(900))
            )
            guard sourceBudget > 0 else { break }
            let clipped = String(line.prefix(sourceBudget))
            sourceBudget -= clipped.count
            sourceLines.append(clipped)
            sentSources.append(source)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 EEEE HH:mm"
        formatter.timeZone = timezone
        let anchor = formatter.string(from: now)
            + "（时区 \(timezone.identifier)，相对日期以此为锚）"

        let characterCount = (turnLines + sourceLines)
            .map(\.count).reduce(0, +) + userContext.count
        let disclosure = AIRequestDisclosure(
            feature: .errandOrganizing,
            host: nil,
            textCategory: .mixed,
            characterCount: characterCount,
            imageCount: 0,
            masked: maskSensitive,
            userTriggered: true
        )
        return (
            Input(
                turnLines: turnLines,
                sourceLines: sourceLines,
                userContext: userContext,
                anchorDescription: anchor,
                scene: scene,
                turnIDs: turnIDs,
                sources: sentSources
            ),
            disclosure,
            []
        )
    }

    // MARK: - 宽容解析

    /// 解析模型输出：剥代码栅栏、容忍散文包裹、字段缺失、数组/字符串
    /// 混用；纯文本降级保留可读建议但绝不伪造结构化成功。
    static func parse(_ raw: String, input: Input) -> Suggestion {
        var suggestion = Suggestion()
        guard let payload = AttachmentAnalysisParser.jsonPayload(from: raw),
              let data = payload.data(using: .utf8)
        else {
            // 纯文本降级：保留原文作为可读建议（detailsAvailable=false）。
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            suggestion.plainTextFallback = String(trimmed.prefix(600))
            suggestion.detailsAvailable = false
            if !trimmed.isEmpty {
                suggestion.uncertainties.append("模型未返回结构化结果，已保留原文摘要 —— 请人工核对")
            }
            return suggestion
        }

        struct WirePayload: Decodable {
            var titleSuggestion: String?
            var purposeSummary: String?
            var requiredDocuments: FlexList?
            var actions: FlexList?
            var questionsToAsk: FlexList?
            var appointmentCandidates: [WireTimeCandidate]?
            var deadlineCandidates: [WireTimeCandidate]?
            var followUpCandidates: [WireTimeCandidate]?
            var fees: FlexList?
            var locations: FlexList?
            var contacts: FlexList?
            var uncertainties: FlexList?
            var sourceRefs: [WireSourceRef]?
        }
        struct WireTimeCandidate: Decodable {
            var dateText: String?
            var meaning: String?
            var isRelative: Bool?
            var uncertain: Bool?
        }
        struct WireSourceRef: Decodable {
            var turn: String?
            var source: String?
            var page: Int?
            var snippet: String?
        }
        struct FlexList: Decodable {
            var values: [String]
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let single = try? container.decode(String.self) {
                    values = [single]
                } else if let list = try? container.decode([String].self) {
                    values = list
                } else {
                    values = []
                }
            }
        }

        guard let wire = try? JSONDecoder().decode(WirePayload.self, from: data) else {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            suggestion.plainTextFallback = String(trimmed.prefix(600))
            suggestion.detailsAvailable = false
            suggestion.uncertainties.append("结构化结果解析失败，已保留原文 —— 请人工核对")
            return suggestion
        }

        func lines(_ list: FlexList?) -> [String] {
            (list?.values ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        suggestion.titleSuggestion = nonEmpty(wire.titleSuggestion)
        suggestion.purposeSummary = nonEmpty(wire.purposeSummary)
        suggestion.requiredDocuments = lines(wire.requiredDocuments)
        suggestion.actions = lines(wire.actions)
        suggestion.questionsToAsk = lines(wire.questionsToAsk)
        suggestion.fees = lines(wire.fees)
        suggestion.locations = lines(wire.locations)
        suggestion.contacts = lines(wire.contacts)
        suggestion.uncertainties = lines(wire.uncertainties)

        // 时间候选：原文保留 + 本地确定性换算（模型不换算，本地换算后
        // 仍需用户确认）。
        func convert(_ wireCandidates: [WireTimeCandidate]?) -> [ErrandDateParser.Candidate] {
            (wireCandidates ?? []).compactMap { candidate in
                guard let dateText = nonEmpty(candidate.dateText) else { return nil }
                let local = ErrandDateParser.candidates(in: dateText).first
                return ErrandDateParser.Candidate(
                    rawText: dateText,
                    resolved: local?.resolved,
                    isRelative: candidate.isRelative ?? local?.isRelative ?? false,
                    uncertain: candidate.uncertain ?? local?.uncertain ?? true,
                    hasTime: local?.hasTime ?? false,
                    reason: candidate.meaning.map { "AI 整理：\($0)" } ?? "AI 整理的时间候选"
                )
            }
        }
        suggestion.appointmentCandidates = convert(wire.appointmentCandidates)
        suggestion.deadlineCandidates = convert(wire.deadlineCandidates)
        suggestion.followUpCandidates = convert(wire.followUpCandidates)

        // sourceRefs 校验：对话引用必须属于本次发送的 turn；文件引用经
        // 第十六轮三重校验。无效引用丢弃并进入 uncertainties（"来源无法
        // 核对"），绝不展示成可信引用。
        var invalid = 0
        var validatedTurns: [UUID] = []
        var wireCitations: [InterpreterDocumentChunker.ReturnedCitation] = []
        for ref in wire.sourceRefs ?? [] {
            if let turnRef = nonEmpty(ref.turn) {
                // "T3" → 本次输入第 3 行。
                let digits = turnRef.filter(\.isNumber)
                if let index = Int(digits), index >= 1, index <= input.turnIDs.count {
                    validatedTurns.append(input.turnIDs[index - 1])
                    continue
                }
                invalid += 1
                continue
            }
            if let sourceRef = nonEmpty(ref.source) {
                wireCitations.append(InterpreterDocumentChunker.ReturnedCitation(
                    sourceID: sourceRef,
                    pageNumber: ref.page,
                    snippet: ref.snippet ?? ""
                ))
                continue
            }
            invalid += 1
        }
        let validated = InterpreterDocumentChunker.validateCitations(
            wireCitations, against: input.sources
        )
        invalid += wireCitations.count - validated.count
        suggestion.validatedTurnRefs = validatedTurns
        suggestion.validatedCitations = validated.map {
            InterpreterCitation(
                sourceID: $0.sourceID,
                documentName: $0.documentName,
                pageNumber: $0.pageNumber,
                blockIndex: $0.blockIndex,
                snippet: $0.snippet
            )
        }
        if invalid > 0 {
            suggestion.uncertainties.append(
                "有 \(invalid) 条来源引用无法核对，已丢弃（不展示为可信来源）"
            )
        }
        return suggestion
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
