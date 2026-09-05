import Foundation

/// 随身翻译文件上下文的 prompt 构造。纯函数。
///
/// 规则：
/// - 每个选中 chunk 在 prompt 中携带不可伪造的 source ID（[S1]…），
///   模型只能引用实际发送的内容；
/// - 严禁编造用户没有提供的信息：证件号、日期、姓名、金额一律只用
///   选中文本中出现的内容；
/// - 无依据时明确说"文件中未找到明确依据"，不得伪造引文；
/// - 文件分析与字段助手共用一套禁止事项（不自动填写、不猜个人值、
///   不对法律/医疗/签证结果作保证）。
enum InterpreterDocumentPrompt {

    // MARK: - 文件分析（解释这份文件 / 字段助手）

    static func analysisSystemPrompt(scene: InterpreterScene) -> String {
        """
        你是一位现场文件理解助手。一位在俄罗斯生活的中文用户正在办事现场，拿到一份俄语文件（表格、通知、回执、缴费单、合同片段等）。你要基于用户选中的文件内容，帮助用户理解这份文件。

        场景：\(scene.promptBackground)。

        只输出一个 JSON 对象，不要输出任何其他文字或代码块标记。格式：
        {"documentType": "文件类型判断（如：宿舍入住登记表）", "summaryChinese": "这份文件在说什么（中文，2-4 句）", "keyFacts": ["关键事实（俄语原文关键字段 + 中文含义）"], "requiredActions": ["需要办理的事项"], "requiredDocuments": ["需要准备的材料"], "deadlines": ["期限（日期原文 + 中文）"], "fees": ["金额（原文 + 数字）"], "addresses": ["地址（原文 + 中文说明）"], "contacts": ["联系人/电话/邮箱"], "formFields": [{"russianLabel": "字段俄语原名", "chineseMeaning": "字段中文含义", "expectedType": "预期内容类型（日期/数字/姓名/地址等）", "existingValue": "文件中已有的值（没有则为空字符串）", "preparationHint": "用户需要准备什么信息", "exampleFormat": "示例格式（仅示例，不是用户的真实值）", "pageNumber": 1, "riskNote": "不确定项或风险提示"}], "questionsToAsk": ["建议用俄语向工作人员确认的问题"], "warnings": ["矛盾、缺失或需要核对的内容"], "uncertainties": ["识别不确定或语义模糊的内容"], "citations": [{"source": "S1", "page": 1, "snippet": "支撑该结论的原文短引文"}]}

        规则：
        - 只基于给出的文件内容回答；关键结论必须给出 citations，source 只能用输入中出现的编号（S1、S2…），page 必须是该编号实际的页码，snippet 必须是文件原文中的连续片段。
        - 严禁编造文件中没有的值。数字、日期、金额、人名必须与原文一致。
        - formFields 中 existingValue 只在文件里确实有值时填写；没有就留空字符串，并在 preparationHint 说明用户需要准备什么。
        - exampleFormat 永远只是格式示例，绝不冒充用户的真实信息；严禁从常识或推测填入护照号、签证日期、住址、银行卡号等个人数据。
        - OCR 文本可能有误：数字、日期、人名不确定时放进 uncertainties，不要猜测修正。
        - 不对法律、医疗、签证结果作保证；涉及这类内容时在 warnings 提醒用户向工作人员确认。
        - questionsToAsk 用自然、礼貌的俄语（可附中文说明）。
        """
    }

    static func analysisUserPrompt(sources: [String]) -> String {
        """
        文件内容（用户已核对并选择发送）：

        \(sources.joined(separator: "\n"))

        请分析这份文件并返回 JSON。
        """
    }

    // MARK: - 基于文件的问答（含最近对话）

    static func answerSystemPrompt(scene: InterpreterScene, contextNote: String) -> String {
        var lines: [String] = [
            "你是一位现场口译与办事助手。一位在俄罗斯生活的中文用户正在和俄语工作人员面对面办事，",
            "同时手头有相关文件。你基于用户选中的文件内容和最近对话回答问题，并生成可对工作人员说的俄语。",
            "场景：\(scene.promptBackground)。",
            "",
            "只输出一个 JSON 对象，不要输出任何其他文字或代码块标记。格式：",
            """
            {"answerChinese": "中文回答（结合文件与对话）", "suggestedRussian": "建议对工作人员说的俄语", "stressedRussian": "带重音的俄语（重音用 U+0301 组合重音符号，例如 докуме́нт；与 suggestedRussian 内容一致，只多重音符号）", "backTranslation": "俄语的中文回译", "politeAlternative": "更礼貌的备选说法", "simpleAlternative": "更简单直接的备选说法", "citations": [{"source": "S1", "page": 1, "snippet": "文件原文短引文"}], "uncertainties": ["不确定项，没有则为空数组"]}
            """,
            "",
            "规则：",
            "- 回答必须基于给出的文件内容和最近对话；文件中没有明确依据时，在 answerChinese 里说明\"文件中未找到明确依据，以下是基于上下文的推断\"。",
            "- citations 的 source 只能用输入中出现的编号（S1、S2…），page 必须是该编号实际的页码，snippet 必须是文件原文中的连续片段；没有依据就返回空数组。",
            "- suggestedRussian 用于用户直接对工作人员说：结合最近对话（对方刚问了什么），使用办事场景的固定礼貌说法。",
            "- 严禁编造用户没有提供的信息：证件、日期、姓名、金额、身份一律只用文件原文或用户输入中出现的内容。",
            "- stressedRussian 只加 U+0301，不改变任何字符；无法确定重音的词可以不标。",
            "- uncertainties 用于提醒核对关键信息（数字、日期、证件类型、OCR 低置信度部分）。",
        ]
        if !contextNote.isEmpty {
            lines.append("- 用户背景（仅供理解语境，不要写进俄语）：\(contextNote)")
        }
        return lines.joined(separator: "\n")
    }

    static func answerUserPrompt(
        question: String,
        sources: [String],
        recentContext: String
    ) -> String {
        var lines: [String] = []
        if !recentContext.isEmpty {
            lines.append("最近对话：")
            lines.append(recentContext)
            lines.append("")
        }
        lines.append("文件内容（用户已核对并选择发送）：")
        lines.append("")
        lines.append(sources.joined(separator: "\n"))
        lines.append("")
        lines.append("用户的问题（中文）：\(question)")
        lines.append("")
        lines.append("请回答并返回 JSON。")
        return lines.joined(separator: "\n")
    }

    // MARK: - 字段值核对（用户手动输入自己的值之后）

    static func fieldCheckSystemPrompt() -> String {
        """
        你是一位表格填写核对助手。用户在一个俄语表格的某个字段上手动输入了自己的值，你检查格式是否正确，并生成填写说明或向工作人员询问的俄语表达。

        只输出一个 JSON 对象，不要输出任何其他文字或代码块标记。格式：
        {"answerChinese": "格式检查结论与建议（中文）", "suggestedRussian": "需要向工作人员确认时使用的俄语（不需要则为空字符串）", "stressedRussian": "带重音俄语（U+0301）", "backTranslation": "中文回译", "citations": [], "uncertainties": ["不确定项"]}

        规则：
        - 只检查格式与一致性，绝不替用户决定内容；不猜测缺失的个人信息。
        - 用户的值只用于本次检查，不出现在 suggestedRussian 中，除非用户明确要求写进俄语。
        - 对日期、数字、电话格式给出具体的格式说明（例如 DD.MM.YYYY）。
        """
    }

    static func fieldCheckUserPrompt(
        fieldLabel: String, fieldMeaning: String, userValue: String,
        exampleFormat: String?
    ) -> String {
        """
        字段（俄语原文）：\(fieldLabel)
        字段含义：\(fieldMeaning)
        \(exampleFormat.map { "预期格式：\($0)" } ?? "预期格式：未知")
        用户填写的值：\(userValue)

        请检查并返回 JSON。
        """
    }

    // MARK: - Source line rendering

    /// Renders one request source as a prompt line with its unforgeable
    /// source ID.
    static func sourceLine(
        sourceID: String, documentName: String, pageNumber: Int, text: String
    ) -> String {
        "[\(sourceID)] \(documentName) · 第\(pageNumber)页\n    "
            + text.replacingOccurrences(of: "\n", with: "\n    ")
    }
}
