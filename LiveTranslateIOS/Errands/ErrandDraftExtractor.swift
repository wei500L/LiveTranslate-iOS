import Foundation

/// 本地确定性规则：从对话回合与文件分析结果生成办事事项候选草稿。
/// AI 不是必要条件 —— 无网络、无模型时同样能整理出可核对的候选。
///
/// 诚实原则：
/// - 只提取来源中明确出现的内容，绝不编造材料、日期、费用或地址；
/// - "通常需要"绝不冒充"明确要求"（关键词只在明确语境命中）；
/// - 每个候选带可解释理由（reason）与来源回合（sourceTurnID）；
/// - 候选的 origin 始终是规则/AI（用户确认前 status = .unconfirmed，
///   绝不自动成为正式清单项）。
enum ErrandDraftExtractor {
    /// 一条候选（材料/动作/问题/费用/预约/截止/跟进）。
    struct Candidate: Identifiable, Equatable, Sendable {
        var id: String { "\(kind.rawValue)|\(title)" }
        var kind: ErrandCaseItemKind
        var title: String
        var detail: String
        /// 日期候选（来自同一来源文本的确定性解析）。
        var date: ErrandDateParser.Candidate?
        var reason: String
        /// 来源回合（本地来源链接用；候选本身只是 UI 态）。
        var sourceTurnID: UUID?
        /// 费用原文（payment 候选）。
        var feeText: String?
    }

    /// 关键词 → 候选类型（中俄双语；只命中"明确要求"语境）。
    private struct KeywordRule {
        var keywords: [String]
        var kind: ErrandCaseItemKind
        /// 标题模板（%@ = 命中行本身）。
        var titleFromLine: Bool
    }

    private static let rules: [KeywordRule] = [
        // 材料：原件/复印件/翻译件/公证件（俄语原文列在前 —— 命中俄语行
        // 时标题保留俄语原文，展示层显示中文类型标签）。
        KeywordRule(
            keywords: ["оригинал", "оригиналы", "原件", "护照原件"],
            kind: .requiredDocument, titleFromLine: true
        ),
        KeywordRule(
            keywords: ["копия", "копии", "копию", "复印件", "打印件"],
            kind: .requiredDocument, titleFromLine: true
        ),
        KeywordRule(
            keywords: ["нотариал", "нотариус", "公证"],
            kind: .requiredDocument, titleFromLine: true
        ),
        KeywordRule(
            keywords: ["перевод документов", "翻译件", "翻译公证"],
            kind: .requiredDocument, titleFromLine: true
        ),
        KeywordRule(
            keywords: ["справка", "справку", "证明", "在读证明"],
            kind: .requiredDocument, titleFromLine: true
        ),
        KeywordRule(
            keywords: ["фото", "фотография", "照片", "证件照"],
            kind: .requiredDocument, titleFromLine: true
        ),
        // 预约/登记。
        KeywordRule(
            keywords: ["записат", "запись", "приём", "прием", "预约", "挂号"],
            kind: .appointment, titleFromLine: true
        ),
        // 截止/期限。
        KeywordRule(
            keywords: ["до пятницы", "срок", "дедлайн", "截止", "期限", "之前交"],
            kind: .deadline, titleFromLine: true
        ),
        // 补交。
        KeywordRule(
            keywords: ["донести", "доплатить", "补交", "补齐"],
            kind: .followUp, titleFromLine: true
        ),
        // 领取。
        KeywordRule(
            keywords: ["получить", "получении", "领取", "取证"],
            kind: .followUp, titleFromLine: true
        ),
        // 等待结果。
        KeywordRule(
            keywords: ["ждать", "готово через", "等待", "等结果"],
            kind: .followUp, titleFromLine: true
        ),
        // 费用。
        KeywordRule(
            keywords: ["оплат", "стоимость", "сумма", "руб", "₽", "付款", "缴费", "费用"],
            kind: .payment, titleFromLine: true
        ),
        // 现场要问的问题（用户明确标记"要问"）。
        KeywordRule(
            keywords: ["спросить", "уточнить", "要问", "请问对方"],
            kind: .question, titleFromLine: true
        ),
        // 办理动作。
        KeywordRule(
            keywords: ["оформит", "подать", "заявлен", "办理", "提交", "申请"],
            kind: .action, titleFromLine: true
        )
    ]

    // MARK: - 对话回合 → 候选

    /// 从对话回合提取候选（按行扫描；日期候选与关键词候选来自同一回
    /// 合的文本，组合时共享来源）。
    static func candidates(
        fromTurns turns: [(id: UUID, text: String, isCounterpart: Bool)],
        anchor: Date = .now,
        calendar: Calendar = .current
    ) -> [Candidate] {
        var result: [Candidate] = []
        for turn in turns {
            let lines = turn.text
                .components(separatedBy: .newlines)
                .flatMap { $0.components(separatedBy: "。") }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            var turnDates: [ErrandDateParser.Candidate] = []
            for line in lines {
                turnDates.append(
                    contentsOf: ErrandDateParser.candidates(
                        in: line, anchor: anchor, calendar: calendar
                    )
                )
            }
            for line in lines where line.count <= 160 {
                for rule in rules {
                    guard let keyword = rule.keywords.first(where: {
                        line.lowercased().contains($0.lowercased())
                    }) else { continue }
                    // The date candidate closest to this line (same turn).
                    let dateCandidate = ErrandDateParser.candidates(
                        in: line, anchor: anchor, calendar: calendar
                    ).first ?? turnDates.first
                    let kind: ErrandCaseItemKind
                    switch rule.kind {
                    case .deadline: kind = .deadline
                    case .appointment: kind = .appointment
                    case .followUp: kind = .followUp
                    default: kind = rule.kind
                    }
                    result.append(Candidate(
                        kind: kind,
                        title: line,
                        detail: "",
                        date: dateCandidate,
                        reason: "对话中命中关键词「\(keyword)」（\(turn.isCounterpart ? "对方" : "我")的回合）",
                        sourceTurnID: turn.id,
                        feeText: rule.kind == .payment ? line : nil
                    ))
                    break // One kind per line (the first matching rule).
                }
            }
        }
        return deduped(result)
    }

    // MARK: - 文件分析 → 候选（结构化字段直读 —— 文件助手已确认的结果）

    static func candidates(
        fromAnalysis analysis: InterpreterDocumentAnalysis,
        anchor: Date = .now,
        calendar: Calendar = .current
    ) -> [Candidate] {
        var result: [Candidate] = []
        func append(
            _ lines: [String]?, kind: ErrandCaseItemKind, reason: String
        ) {
            guard let lines else { return }
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let date = ErrandDateParser.candidates(
                    in: trimmed, anchor: anchor, calendar: calendar
                ).first
                result.append(Candidate(
                    kind: kind,
                    title: trimmed,
                    detail: "",
                    date: date,
                    reason: reason,
                    sourceTurnID: nil,
                    feeText: kind == .payment ? trimmed : nil
                ))
            }
        }
        append(analysis.requiredDocuments, kind: .requiredDocument,
               reason: "文件分析：需要准备的材料")
        append(analysis.requiredActions, kind: .action,
               reason: "文件分析：需要办理的事项")
        append(analysis.deadlines, kind: .deadline,
               reason: "文件分析：期限")
        append(analysis.fees, kind: .payment,
               reason: "文件分析：费用（原文，未换算）")
        append(analysis.questionsToAsk, kind: .question,
               reason: "文件分析：建议现场询问的问题")
        append(analysis.addresses, kind: .action,
               reason: "文件分析：地址（供核对，未经证实）")
        return deduped(result)
    }

    // MARK: - Helpers

    private static func deduped(_ candidates: [Candidate]) -> [Candidate] {
        var seen: Set<String> = []
        return candidates.filter { seen.insert($0.id).inserted }
    }
}
