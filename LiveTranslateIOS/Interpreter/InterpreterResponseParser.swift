import Foundation

/// 随身翻译结构化响应解析器。模型按 prompt 约定返回 JSON，但解析器
/// 必须容忍（现有仓库的 5 份解析器惯例的收敛建模）：
/// - Markdown 代码栅栏（```/```json）；
/// - 前后夹杂散文的最外层 `{...}`；
/// - 部分字段缺失；
/// - 字符串/数组混用（单字符串当单元素数组）；
/// - 纯文本响应（降级为可读翻译 + 诚实说明详细解释不可用）。
///
/// 解析失败时绝不丢弃可读翻译。
enum InterpreterResponseParser {
    /// 解析 zh2ru（用户中文 → 俄语）方向的结构化响应。
    /// 纯文本响应 → mainText = 原文文本，isPlainTextResponse = true。
    static func parseZh2Ru(_ raw: String) -> InterpreterTranslationResult? {
        guard let payload = jsonPayload(from: raw),
              let decoded = try? JSONDecoder().decode(Zh2RuPayload.self, from: Data(payload.utf8))
        else {
            // 纯文本回退：不丢弃可读翻译。
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return InterpreterTranslationResult(
                mainText: text,
                stressedRussian: nil,
                backTranslation: nil,
                details: .plainTextFallback,
                isPlainTextResponse: true
            )
        }

        let russian = decoded.russian?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !russian.isEmpty else { return nil }

        var details = InterpreterTurnDetails(detailsAvailable: true)
        details.politeAlternative = nonEmpty(decoded.politeAlternative)
        details.simpleAlternative = nonEmpty(decoded.simpleAlternative)
        details.keywords = stringList(decoded.keywords)
        details.uncertainties = stringList(decoded.uncertainties)

        return InterpreterTranslationResult(
            mainText: russian,
            stressedRussian: RussianStressValidator.validated(
                stressed: decoded.stressedRussian, plain: russian
            ),
            backTranslation: nonEmpty(decoded.backTranslation),
            details: details,
            isPlainTextResponse: false
        )
    }

    /// 解析 ru2zh（对方俄语 → 中文）方向的结构化响应。
    static func parseRu2Zh(_ raw: String) -> InterpreterTranslationResult? {
        guard let payload = jsonPayload(from: raw),
              let decoded = try? JSONDecoder().decode(Ru2ZhPayload.self, from: Data(payload.utf8))
        else {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return InterpreterTranslationResult(
                mainText: text,
                stressedRussian: nil,
                backTranslation: nil,
                details: .plainTextFallback,
                isPlainTextResponse: true
            )
        }

        let chinese = decoded.chinese?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !chinese.isEmpty else { return nil }

        var details = InterpreterTurnDetails(detailsAvailable: true)
        details.intentSummary = nonEmpty(decoded.intent)
        details.keywords = stringList(decoded.keywords)
        details.ambiguity = nonEmpty(decoded.ambiguity)
        details.suggestedReplies = stringList(decoded.suggestions)

        var stressed: String?
        if let s = decoded.stressedRussian {
            // 重音校验以对方原文为基准（重音版不得改动原文词语）。
            let plainSource = RussianStressValidator.stripStress(s)
            stressed = RussianStressValidator.validated(stressed: s, plain: plainSource)
        }

        return InterpreterTranslationResult(
            mainText: chinese,
            stressedRussian: stressed,
            backTranslation: nil,
            details: details,
            isPlainTextResponse: false
        )
    }

    // MARK: - 载荷结构

    /// 宽容解码：所有字段 optional，逐字段容忍。
    private struct Zh2RuPayload: Codable {
        var russian: String?
        var stressedRussian: String?
        var backTranslation: String?
        var keywords: FlexList?
        var politeAlternative: String?
        var simpleAlternative: String?
        var uncertainties: FlexList?
    }

    private struct Ru2ZhPayload: Codable {
        var chinese: String?
        var stressedRussian: String?
        var intent: String?
        var keywords: FlexList?
        var ambiguity: String?
        var suggestions: FlexList?
    }

    /// 字符串/数组混用容忍：单字符串 → 单元素数组。
    private struct FlexList: Codable {
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

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(values)
        }
    }

    // MARK: - 辅助

    /// 剥 Markdown 代码栅栏 + 取最外层大括号（容忍前后散文）。
    /// 仓库惯例的收敛建模（StudyReviewParser.jsonPayload 语义）。
    static func jsonPayload(from text: String) -> String? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 剥围栏：```json ... ``` / ``` ... ```
        if s.hasPrefix("```") {
            // 丢弃第一行（``` 或 ```json）。
            if let firstNewline = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: firstNewline)...])
            } else {
                return nil
            }
            // 剥尾栅栏。
            if let fenceRange = s.range(of: "```", options: .backwards) {
                s = String(s[..<fenceRange.lowerBound])
            }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 取最外层大括号（容忍前后散文）。
        guard let start = s.firstIndex(of: "{"),
              let end = s.lastIndex(of: "}"),
              start < end else { return nil }
        return String(s[start...end])
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stringList(_ l: FlexList?) -> [String]? {
        guard let l, !l.values.isEmpty else { return nil }
        let trimmed = l.values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return trimmed.isEmpty ? nil : trimmed
    }
}
