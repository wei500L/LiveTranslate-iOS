import Foundation
import OSLog

/// AI-assisted card generation from USER-SELECTED classroom material.
///
/// Scope contract: only the items the user explicitly ticked travel to
/// the model — never a whole two-hour transcript. The request is one
/// non-streaming chat completion on the study-review model service; the
/// response is parsed tolerantly with hard limits; nothing becomes a
/// real card before the user reviewed the preview and pressed 保存.
enum LearningCardGenerator {
    static let logger = Logger(subsystem: "com.livetranslate.ios", category: "learning-cards")

    /// One selectable input item (a key point, a term, an uncertainty, an
    /// image formula) with the source refs the generated card inherits.
    struct InputItem: Identifiable, Equatable {
        var id = UUID()
        /// Display + prompt text of the item.
        var text: String
        /// Optional label shown in the picker ("重点"/"术语"/"板书"…).
        var label: String
        var source: LearningSourceRef
    }

    /// One card candidate parsed from the model output (preview-only —
    /// NOT a StudyCard until the user saves it).
    struct GeneratedCard: Identifiable, Equatable {
        var id = UUID()
        var front: String
        var back: String
        var type: StudyCardType
        /// 1-based index into the input items (0 = none/out of range).
        var sourceIndex: Int
    }

    enum Limits {
        static let maxCards = 12
        static let maxFrontLength = 300
        static let maxBackLength = 800
        static let maxInputItems = 40
        static let maxInputLength = 1200
    }

    // MARK: Prompt

    static func systemPrompt() -> String {
        """
        你是一名帮助中国学生复习俄罗斯大学课程的助教。用户会给出课堂材料条目，\
        请根据这些条目制作少量高质量的学习卡片（用于间隔复习）。

        要求：
        - 只输出一个 JSON 对象，不要输出任何解释、前言或 Markdown 代码块标记；
        - 卡片数量在 3–8 张之间，宁少而精，不要凑数；
        - 每张卡片正面是一个明确的问题、俄语词或概念名，背面是简短答案或解释；
        - 俄语内容保持原文，中文解释自然、准确；
        - type 从这些值里选：ru2zh（俄译中）、zh2ru（中译俄）、qa（问答）、\
        concept（概念）、formula（公式）、code（代码）；
        - sourceIndex 填该卡片依据的条目编号（1 开始），不确定就填 1。

        输出格式：
        {"cards":[{"front":"","back":"","type":"qa","sourceIndex":1}]}
        """
    }

    static func userPrompt(items: [InputItem]) -> String {
        let lines = items.prefix(Limits.maxInputItems).enumerated().map { index, item in
            let trimmed = String(item.text.prefix(Limits.maxInputLength))
            return "[\(index + 1)]（\(item.label)）\(trimmed)"
        }
        return "课堂材料条目：\n" + lines.joined(separator: "\n")
            + "\n\n请为这些条目制作学习卡片。"
    }

    // MARK: Parse

    /// Tolerant parse: fence stripping, outermost-brace extraction,
    /// per-card validation with partial results kept. A response that is
    /// entirely unparseable returns nil (the UI shows a real failure —
    /// no fabricated cards, ever).
    static func parse(_ response: String) -> [GeneratedCard]? {
        guard let payload = jsonPayload(from: response),
              let data = payload.data(using: .utf8),
              let raw = try? JSONDecoder().decode(RawResponse.self, from: data) else {
            return nil
        }
        var cards: [GeneratedCard] = []
        for rawCard in raw.cards.prefix(Limits.maxCards) {
            let front = rawCard.front.trimmingCharacters(in: .whitespacesAndNewlines)
            let back = rawCard.back.trimmingCharacters(in: .whitespacesAndNewlines)
            // Blank faces, narration text and overlong fields are dropped
            // silently — partial results are still useful.
            guard !front.isEmpty, !back.isEmpty else { continue }
            guard front.count <= Limits.maxFrontLength, back.count <= Limits.maxBackLength else { continue }
            // The model's explanatory text sometimes masquerades as a
            // card; a >6-line "front" is narration, not a card face.
            guard front.numberOfLines <= 3 else { continue }
            let type = StudyCardType(rawValue: rawCard.type) ?? .qa
            let index = rawCard.sourceIndex >= 1 ? rawCard.sourceIndex : 1
            cards.append(GeneratedCard(front: front, back: back, type: type, sourceIndex: index))
        }
        return cards
    }

    /// Extracts the outermost JSON object from a model response
    /// (tolerates ``` fences and surrounding prose).
    static func jsonPayload(from text: String) -> String? {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("```") {
            candidate = candidate
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let start = candidate.firstIndex(of: "{"),
              let end = candidate.lastIndex(of: "}"), start < end else { return nil }
        return String(candidate[start...end])
    }

    private struct RawResponse: Decodable {
        var cards: [RawCard]

        enum CodingKeys: String, CodingKey {
            case cards
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            cards = try c.decodeIfPresent([RawCard].self, forKey: .cards) ?? []
        }
    }

    private struct RawCard: Decodable {
        var front: String
        var back: String
        var type: String
        var sourceIndex: Int

        enum CodingKeys: String, CodingKey {
            case front, back, type, sourceIndex
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            front = try c.decodeIfPresent(String.self, forKey: .front) ?? ""
            back = try c.decodeIfPresent(String.self, forKey: .back) ?? ""
            type = try c.decodeIfPresent(String.self, forKey: .type) ?? "qa"
            sourceIndex = try c.decodeIfPresent(Int.self, forKey: .sourceIndex) ?? 1
        }
    }
}

private extension String {
    var numberOfLines: Int {
        components(separatedBy: .newlines).count
    }
}
