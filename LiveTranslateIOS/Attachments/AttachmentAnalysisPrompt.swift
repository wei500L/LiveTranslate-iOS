import Foundation

/// Prompts for classroom-image understanding. The model must return ONE
/// JSON object with the versioned schema; everything visible belongs to
/// `visibleText`, interpretation belongs to `explanation`, and hedges to
/// `uncertainties` — the three must never be mixed.
enum AttachmentAnalysisPrompt {
    /// Context the analysis may draw on (bounded — never the whole
    /// session).
    struct Context {
        var courseName: String?
        var sessionTitle: String
        var attachmentTitle: String
        var userCaption: String
        /// Nearby transcript lines, already formatted `[n] mm:ss ru` +
        /// `    中文：…` and bounded by the caller.
        var transcriptLines: [String]
        /// The user-anchored entry's text (formatted like transcriptLines).
        var anchoredLines: [String]
        /// Nearby user notes (bounded).
        var noteTexts: [String]
        /// How many numbered transcript entries the model may cite.
        var citationCount: Int
    }

    static func systemPrompt() -> String {
        """
        你是一名课堂资料整理助手，负责分析俄罗斯大学课堂上的板书、课件、手写笔记和教材照片。你的读者是正在俄罗斯学习、中文为母语的学生。

        你会收到一张课堂图片，可能包含：黑板公式、俄语专业术语、程序代码、图表、手写笔记或课件页面。图片质量可能不理想（倾斜、反光、部分遮挡）。

        必须只输出一个 JSON 对象，不要输出任何其他文字、解释或代码块标记。格式：

        {
          "schemaVersion": 1,
          "title": "这张图片的简短标题（中文，≤20字）",
          "visibleText": ["图片中清晰可见的文字，保留原文（俄语/英语/中文），逐条列出"],
          "formulas": ["图片中的数学公式，用 LaTeX 表示"],
          "codeBlocks": ["图片中的代码，保持结构和换行"],
          "keyPoints": ["图片表达的要点（中文）"],
          "explanation": "结合课堂上下文，用中文为学生解释这张图片的内容和意义",
          "uncertainties": ["你无法确认或看不清的内容，如实说明"],
          "transcriptReferences": [1]
        }

        铁律：
        1. visibleText 只放图片中清晰可见的文字，保持原文，不要翻译，不要补全看不清的字符；无法确认的字符用 … 代替并记入 uncertainties。
        2. 公式用 LaTeX；不确定的符号不要猜，记入 uncertainties。
        3. 代码保持原有缩进和换行。
        4. explanation 是你的解释，可以结合转录上下文；它与 visibleText（图片直接可见）必须分开。
        5. transcriptReferences 只能引用用户消息中带 [n] 编号的转录条目；不引用任何编号就返回空数组。不存在或不相关的编号一律不要引用。
        6. 某个字段没有内容就返回空数组或空字符串，不要编造。
        """
    }

    static func userPrompt(context: Context) -> String {
        var lines: [String] = []
        var meta: [String] = []
        if let courseName = context.courseName, !courseName.isEmpty {
            meta.append("课程：\(courseName)")
        }
        meta.append("课堂：\(context.sessionTitle)")
        if !context.attachmentTitle.isEmpty {
            meta.append("图片标题：\(context.attachmentTitle)")
        }
        if !context.userCaption.isEmpty {
            meta.append("学生说明：\(context.userCaption)")
        }
        lines.append(meta.joined(separator: "\n"))
        lines.append("")

        if !context.transcriptLines.isEmpty || !context.anchoredLines.isEmpty {
            lines.append("图片拍摄时附近的课堂转录：")
            lines.append(contentsOf: context.anchoredLines)
            lines.append(contentsOf: context.transcriptLines)
            lines.append("")
            lines.append(
                "transcriptReferences 只能使用上面 \(
                    max(context.citationCount, 0)
                ) 个编号（[1] 到 [\(max(context.citationCount, 1))]）中与图片直接相关的条目。"
            )
            lines.append("")
        } else {
            lines.append("图片拍摄时附近没有可用的课堂转录。transcriptReferences 返回空数组。")
            lines.append("")
        }
        if !context.noteTexts.isEmpty {
            lines.append("学生当时的笔记：")
            for note in context.noteTexts {
                lines.append("- \(note)")
            }
            lines.append("")
        }
        lines.append("请分析这张课堂图片，按系统要求的 JSON 格式输出。")
        return lines.joined(separator: "\n")
    }
}
