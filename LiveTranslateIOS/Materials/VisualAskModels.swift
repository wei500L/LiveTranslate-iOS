import Foundation

/// The loosely-structured answer of a visual Q&A turn. Parsing is
/// deliberately tolerant — a model that answers in plain text still
/// produces a usable `VisualAnswer` (the text rides `answer` verbatim);
/// a broken field never discards the whole answer.
struct VisualAnswer: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    /// The main answer text (always present — plain-text answers land
    /// here verbatim).
    var answer: String = ""
    /// Step-by-step explanation (optional).
    var steps: [String]?
    /// References to the evidence images (validated against the turn's
    /// evidence list at parse time — a fabricated 图片 99 never survives).
    var citations: [VisualAnswerCitation]?
    /// Text the model read off the images.
    var visibleText: [String]?
    /// Formulas in LaTeX (kept as-is; copyable).
    var formulas: [String]?
    /// Explicitly uncertain content.
    var uncertainties: [String]?
    /// Suggested follow-ups/actions (plain strings — the UI offers them
    /// as one-tap follow-up questions, never as auto-executed commands).
    var suggestedActions: [String]?
    /// True when the model returned plain text (no parsable JSON).
    var isPlainText: Bool = false

    var hasStructuredExtras: Bool {
        !(steps ?? []).isEmpty || !(formulas ?? []).isEmpty
            || !(visibleText ?? []).isEmpty || !(uncertainties ?? []).isEmpty
            || !(citations ?? []).isEmpty || !(suggestedActions ?? []).isEmpty
    }

    /// Searchable text: answer + formulas + visible text (question text
    /// lives on the user message).
    var searchableText: String {
        var parts = [answer]
        parts += formulas ?? []
        parts += visibleText ?? []
        return parts.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    func encodedJSON() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ json: String) -> VisualAnswer? {
        guard !json.isEmpty, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(VisualAnswer.self, from: data)
    }
}

/// One image citation inside a visual answer: the 1-based 图片 number the
/// model referenced (stored 0-based as `evidenceIndex` after
/// validation), plus an optional page number the model claims.
struct VisualAnswerCitation: Codable, Sendable, Equatable, Identifiable {
    var id = UUID()
    /// 0-based index into the message's evidence list.
    var evidenceIndex: Int = 0
    /// Page number the model claims (display hint only; the chip jumps
    /// via the evidence's own stable reference).
    var pageNumber: Int?
    var snippet: String = ""

    enum CodingKeys: String, CodingKey {
        case evidenceIndex, pageNumber, snippet
    }

    init(evidenceIndex: Int, pageNumber: Int? = nil, snippet: String = "") {
        self.evidenceIndex = evidenceIndex
        self.pageNumber = pageNumber
        self.snippet = snippet
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        evidenceIndex = try c.decodeIfPresent(Int.self, forKey: .evidenceIndex) ?? 0
        pageNumber = try c.decodeIfPresent(Int.self, forKey: .pageNumber)
        snippet = try c.decodeIfPresent(String.self, forKey: .snippet) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(evidenceIndex, forKey: .evidenceIndex)
        try c.encodeIfPresent(pageNumber, forKey: .pageNumber)
        try c.encode(snippet, forKey: .snippet)
    }
}

/// Tolerant parser for visual answers. Handles JSON code fences, plain
/// JSON, missing fields, array/string confusion, and plain-text replies.
/// Degradation rules: a plain-text reply stays a valid answer; citations
/// pointing outside the evidence list are dropped; a citation failure
/// never discards the answer.
enum VisualAnswerParser {
    static let maxArrayItems = 60
    static let maxItemLength = 6_000
    static let maxAnswerLength = 12_000

    static func parse(text: String, evidenceCount: Int) -> VisualAnswer {
        var result = VisualAnswer()
        let payload = AttachmentAnalysisParser.jsonPayload(from: text)

        var object: [String: Any]? = nil
        if let payload {
            object = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any]
        }

        if let object {
            result.answer = clampString(object["answer"] as? String, limit: maxAnswerLength)
                ?? clampString(object["text"] as? String, limit: maxAnswerLength)
                ?? ""
            result.steps = clampArray(object["steps"])
            result.visibleText = clampArray(object["visibleText"])
            result.formulas = clampArray(object["formulas"])
            result.uncertainties = clampArray(object["uncertainties"])
            result.suggestedActions = clampArray(object["suggestedActions"])
            result.citations = parseCitations(object["citations"], evidenceCount: evidenceCount)
            if result.answer.isEmpty {
                // No answer field but structured extras exist: assemble a
                // readable answer from them instead of dropping them.
                if let steps = result.steps, !steps.isEmpty {
                    result.answer = steps.joined(separator: "\n")
                } else if let visible = result.visibleText, !visible.isEmpty {
                    result.answer = visible.joined(separator: "\n")
                }
            }
            if result.answer.isEmpty {
                // The object parsed but carried nothing usable: keep the
                // raw text as a plain answer (never an empty bubble).
                result.answer = String(text.prefix(maxAnswerLength))
                result.isPlainText = true
                result.steps = nil
                result.visibleText = nil
            }
        } else {
            // Plain text reply — a valid answer, just unstructured.
            result.answer = String(text.prefix(maxAnswerLength))
            result.isPlainText = true
        }
        return result
    }

    /// Validates each citation against the turn's evidence list; invalid
    /// or fabricated image numbers are dropped (never rendered, never
    /// saved).
    private static func parseCitations(_ raw: Any?, evidenceCount: Int) -> [VisualAnswerCitation]? {
        guard evidenceCount > 0 else { return nil }
        var list: [[String: Any]] = []
        if let array = raw as? [[String: Any]] {
            list = array
        } else if let object = raw as? [String: Any] {
            list = [object]
        } else if let string = raw as? String {
            list = [["evidence": string]]
        }
        guard !list.isEmpty else { return nil }
        var citations: [VisualAnswerCitation] = []
        for item in list.prefix(maxArrayItems) {
            // Accept both 1-based "evidence"/"image" numbers and explicit
            // 0-based indexes; normalize to 0-based.
            let number: Int?
            if let n = item["evidence"] as? Int { number = n }
            else if let n = item["image"] as? Int { number = n }
            else if let n = item["evidenceIndex"] as? Int { number = n + 1 }
            else if let s = item["evidence"] as? String, let n = Int(s.trimmingCharacters(in: .whitespaces)) { number = n }
            else { number = nil }
            guard let n = number, n >= 1, n <= evidenceCount else { continue }
            let page = item["page"] as? Int ?? item["pageNumber"] as? Int
            let snippet = clampString(item["snippet"] as? String, limit: 300) ?? ""
            citations.append(VisualAnswerCitation(evidenceIndex: n - 1, pageNumber: page, snippet: snippet))
        }
        return citations.isEmpty ? nil : citations
    }

    /// String-or-single-string-array coercion with clamping.
    private static func clampArray(_ raw: Any?) -> [String]? {
        var items: [String] = []
        if let array = raw as? [Any] {
            for element in array.prefix(maxArrayItems) {
                if let s = element as? String { items.append(String(s.prefix(maxItemLength))) }
                else if let n = element as? NSNumber { items.append(n.stringValue) }
            }
        } else if let s = raw as? String {
            items.append(String(s.prefix(maxItemLength)))
        }
        return items.isEmpty ? nil : items
    }

    private static func clampString(_ raw: String?, limit: Int) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return String(raw.prefix(limit))
    }
}

/// Prompt construction for visual Q&A. Pure functions. The assistant
/// grounds every factual claim in the numbered evidence images and (when
/// retrieval ran) the numbered text sources [n]; citations must use the
/// real 图片 numbers; formulas stay LaTeX; uncertainty is stated
/// explicitly.
enum VisualAskPrompt {
    /// One numbered text source (retrieval hit) in the prompt.
    struct SourceLine: Sendable, Equatable {
        var number: Int
        var label: String
        var text: String
    }

    /// One existing per-image text layer (OCR / structured analysis) the
    /// turn carries as context.
    struct ImageContextLine: Sendable, Equatable {
        var imageNumber: Int
        var title: String
        var text: String
    }

    static func systemPrompt() -> String {
        """
        你是课程学习助手。用户是在俄罗斯大学留学的中国学生，会给你若干张带编号的课堂或资料图片（图片 1、图片 2…），可能还有带编号 [n] 的检索材料片段（课堂转录、笔记、资料页、图片理解等）。请回答用户关于这些图片的问题。

        要求：
        - 用中文回答；图片或资料里的俄语原文要保留俄语并给出中文含义。
        - 回答必须是单个 JSON 对象，不要添加多余文字，格式：
        {"answer": "...", "steps": ["..."], "citations": [{"evidence": 1, "page": 2, "snippet": "..."}], "visibleText": ["..."], "formulas": ["..."], "uncertainties": ["..."], "suggestedActions": ["..."]}
        - answer 是主要回答；steps 是推导或步骤（可选）；citations 引用图片编号（evidence 从 1 开始，只能用实际给出的图片编号）；visibleText 是你在图片里读到的文字；formulas 用 LaTeX 保留公式原文；uncertainties 写明看不清或不确定的内容；suggestedActions 是建议的后续问题或行动（每条一句话）。
        - 引用检索材料时在 answer 里用 [n] 标注，只能使用输入中出现的编号。
        - 如果图片不清晰或信息不足，必须在 uncertainties 里说明，不要编造。
        """
    }

    static func userPrompt(
        question: String,
        imageCount: Int,
        imageContext: [ImageContextLine] = [],
        sources: [SourceLine] = [],
        history: [CourseAssistantPrompt.HistoryTurn] = []
    ) -> String {
        var lines: [String] = []
        if imageCount > 1 {
            lines.append("随消息附上 \(imageCount) 张图片，按 图片 1 到 图片 \(imageCount) 的顺序排列；回答中引用时请使用这些编号。")
        } else if imageCount == 1 {
            lines.append("随消息附上 1 张图片（图片 1）。")
        }
        if !imageContext.isEmpty {
            lines.append("")
            lines.append("这些图片已有的本机识别内容（可能有误，仅供参考）：")
            for context in imageContext {
                lines.append("图片 \(context.imageNumber) · \(context.title)：\(context.text)")
            }
        }
        if !sources.isEmpty {
            lines.append("")
            lines.append("检索到的材料片段：")
            for source in sources {
                lines.append("[\(source.number)] \(source.label)")
                lines.append("    " + source.text.replacingOccurrences(of: "\n", with: "\n    "))
            }
        }
        if !history.isEmpty {
            lines.append("")
            lines.append("此前对话（仅供理解指代，不必复述）：")
            for turn in history {
                lines.append("\(turn.isUser ? "学生" : "助手")：\(turn.text)")
            }
        }
        lines.append("")
        lines.append("学生的问题：\(question)")
        return lines.joined(separator: "\n")
    }
}
