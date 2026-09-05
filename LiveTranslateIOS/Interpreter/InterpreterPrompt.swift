import Foundation

/// 随身翻译的双向上下文 prompt。与课堂翻译 prompt 的差异：
/// - 两个方向（俄→中理解 / 中→俄表达）各自的结构化约定；
/// - 有界上下文（最近 6-8 个有效回合 + 场景 + 用户背景 + 对方最近一句）；
/// - 禁止编造用户没有提供的信息、禁止替用户作承诺、禁止自动选择
///   带法律或医疗含义的答案。
///
/// 上下文由 InterpreterContextBuilder 构造并裁剪（完整回合、总字符
/// 数有上限），prompt 本身只负责表达。
enum InterpreterPrompt {
    // MARK: - 俄→中（理解对方）

    /// 对方说俄语 → 中文理解 + 结构化详情。
    static func ru2zhSystemPrompt(scene: InterpreterScene, contextNote: String) -> String {
        var lines: [String] = [
            "你是一位现场口译助手。俄罗斯工作人员正在和一位中文用户面对面办事。",
            "场景：\(scene.promptBackground)。",
            "任务：把工作人员的俄语翻译成自然、准确的中文，并补充结构化信息。",
            "",
            "只输出一个 JSON 对象，不要输出任何其他文字或代码块标记。格式：",
            """
            {"chinese": "自然流畅的中文翻译", "stressedRussian": "带重音的俄语原文（重音用 U+0301 组合重音符号标注，例如 докуме́нт；不得改动原文的词语、标点或拼写）", "intent": "对方意图的一句话中文摘要", "keywords": ["关键词（可中俄对照）"], "ambiguity": "如有歧义则说明，无则为空字符串", "suggestions": ["2-3 条中文回复建议，供用户确认和修改"]}
            """,
            "",
            "规则：",
            "- 中文翻译要完整传达对方的问题或要求，包括数字、日期、地点。",
            "- intent 摘要必须只基于对方原话，不要推测。",
            "- suggestions 是中文回复的起点草稿，用户会修改后使用；不要包含用户没有提供过的证件、日期或身份信息。",
            "- 如果对方的话有歧义（敬称、缩略、行业惯例），在 ambiguity 里说明。",
            "- stressedRussian 是把对方原文加上重音符号：只加 U+0301，不改变任何字符。",
        ]
        if !contextNote.isEmpty {
            lines.append("- 用户背景（仅供理解语境，不要在翻译里提及）：\(contextNote)")
        }
        return lines.joined(separator: "\n")
    }

    /// 对方回合的用户消息：最近对话上下文 + 对方当前这句话。
    static func ru2zhUserPrompt(
        counterpartRussian: String,
        context: String
    ) -> String {
        """
        对方刚刚说（俄语原文）：
        \(counterpartRussian)

        \(context.isEmpty ? "" : "最近对话：\n\(context)\n")
        请翻译并返回 JSON。
        """
    }

    // MARK: - 中→俄（用户表达）

    /// 用户输入中文 → 结合上下文生成自然、得体的俄语。
    static func zh2ruSystemPrompt(
        scene: InterpreterScene,
        contextNote: String,
        tone: InterpreterTone
    ) -> String {
        let toneInstruction: String
        switch tone {
        case .polite:
            toneInstruction = "使用礼貌、正式的表达（Вы 形式、完整的敬语结构）。"
        case .neutral:
            toneInstruction = "使用自然、得体的日常表达。"
        case .simple:
            toneInstruction = "使用简单、直接、短句的表达（仍保持基本礼貌）。"
        }
        var lines: [String] = [
            "你是一位现场口译助手。一位中文用户正在和俄罗斯工作人员面对面办事，",
            "用户输入中文，你把它译成自然、得体的俄语，让对方容易听懂。",
            "场景：\(scene.promptBackground)。",
            "语气要求：\(toneInstruction)",
            "",
            "只输出一个 JSON 对象，不要输出任何其他文字或代码块标记。格式：",
            """
            {"russian": "自然流畅的俄语", "stressedRussian": "带重音的俄语（重音用 U+0301 组合重音符号标注，例如 докуме́нт）", "backTranslation": "俄语的中文回译（供用户核对意思）", "keywords": ["关键词或使用提示"], "politeAlternative": "更礼貌的备选说法", "simpleAlternative": "更简单直接的备选说法", "uncertainties": ["不确定项，如没有则为空数组"]}
            """,
            "",
            "规则：",
            "- 结合最近的对话上下文理解用户中文的指代（对方刚问了什么、现在是回答还是追问）。",
            "- 严禁编造用户没有提供的信息：证件、日期、姓名、金额、身份、承诺一律只用用户原文中出现的内容。",
            "- 严禁替用户作出承诺或选择带法律、医疗含义的答案；这类内容必须原样翻译并放进 uncertainties 提醒。",
            "- 使用文件办理语境中工作人员习惯的固定说法。",
            "- stressedRussian 与 russian 内容必须一致，只多 U+0301 重音符号；ё 不要替换成 е；无法确定重音的词可以不标。",
            "- uncertainties 用于提醒用户核对关键信息（数字、日期、证件类型）。",
        ]
        if !contextNote.isEmpty {
            lines.append("- 用户背景（供理解语境，不要写进俄语，除非用户原文明确提及）：\(contextNote)")
        }
        return lines.joined(separator: "\n")
    }

    /// 用户回合的用户消息：有界上下文 + 对方最近一句 + 用户当前中文。
    static func zh2ruUserPrompt(
        userChinese: String,
        context: String
    ) -> String {
        """
        \(context.isEmpty ? "" : "最近对话：\n\(context)\n")
        用户现在要说（中文原文）：
        \(userChinese)

        请生成俄语并返回 JSON。
        """
    }
}

/// 有界对话上下文的构造与裁剪。
///
/// 规则：
/// - 取最近最多 `maxTurns` 个有效回合（默认 8，符合"最近 6~8 个"）；
/// - 上下文总字符数有上限，较早内容按完整回合裁剪（绝不截断半句）；
/// - 只包含已完成的回合；失败的回合保留原文但标注"（翻译失败）"；
/// - 不发送整个历史库，绝不把课堂转录内容混进办事对话上下文。
struct InterpreterContextBuilder {
    var maxTurns: Int = 8
    /// 上下文总字符上限（含标注前缀）。
    var maxCharacters: Int = 2400

    /// 上下文回合的轻量投影（不携带完整 SwiftData 模型）。
    struct TurnProjection: Sendable {
        var speaker: InterpreterSpeaker
        var direction: InterpreterDirection
        var sourceText: String
        var translatedText: String?
        var translationFailed: Bool
    }

    /// 构造带裁剪的上下文字符串。
    func buildContext(_ turns: [TurnProjection]) -> String {
        // 只取有效回合（有原文；翻译失败仍保留，注明失败）。
        let valid = turns.filter { !$0.sourceText.isEmpty }
        guard !valid.isEmpty else { return "" }

        var selected = valid.suffix(maxTurns)
        // 按完整回合裁剪总字符数：从最早开始丢整个回合。
        var total = selected.reduce(0) { $0 + Self.length(of: $1) }
        while total > maxCharacters, selected.count > 1 {
            total -= Self.length(of: selected.first!)
            selected.removeFirst()
        }

        return selected.map { turn in
            let speaker = turn.speaker == .counterpart ? "对方" : "用户"
            let translation: String
            if let translated = turn.translatedText, !translated.isEmpty {
                translation = translated
            } else if turn.translationFailed {
                translation = "（翻译失败）"
            } else {
                translation = ""
            }
            if translation.isEmpty {
                return "\(speaker)：\(turn.sourceText)"
            }
            return "\(speaker)：\(turn.sourceText)（\(translation)）"
        }.joined(separator: "\n")
    }

    private static func length(of turn: TurnProjection) -> Int {
        let translation = turn.translatedText ?? ""
        return turn.sourceText.count + translation.count + 8
    }
}
