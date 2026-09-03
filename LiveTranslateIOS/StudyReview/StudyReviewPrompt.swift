import Foundation

/// Prompt construction for study-review generation. Pure functions — the
/// generator feeds them real transcript data and the same strings are
/// deterministic for tests. Prompts are Chinese (the review language) and
/// keep the Russian originals for terminology.
enum StudyReviewPrompt {
    /// Entry material for one prompt (already filtered and bounded).
    struct EntryMaterial: Sendable, Equatable {
        /// Global citation number shown to the model ([n]).
        var citation: Int
        var timestamp: String
        var russian: String
        /// nil / empty when the translation is missing or failed.
        var chinese: String?
    }

    /// Class-level context woven into every prompt.
    struct ClassContext: Sendable, Equatable {
        var sessionTitle: String = ""
        var courseName: String = ""
        var teacherName: String = ""

        var contextLine: String {
            var parts: [String] = []
            if !courseName.isEmpty { parts.append(courseName) }
            if !sessionTitle.isEmpty { parts.append(sessionTitle) }
            if !teacherName.isEmpty { parts.append("教师：\(teacherName)") }
            return parts.joined(separator: " · ")
        }
    }

    // MARK: - Chunk extraction

    static func extractionSystemPrompt() -> String {
        """
        你是课堂学习助手。用户是在俄罗斯大学留学的中国学生，刚上完一堂用俄语授课的课程。你会收到这堂课转录文本的一部分（每条带 [编号]、时间、俄语原文与中文翻译），可能还有学生的课堂笔记。请从这部分内容中提取学习材料。

        要求：
        - 只输出一个 JSON 对象，不要输出任何其他文字或代码块标记。
        - topic：这一部分的主题（一句话，若内容太杂可概括）。
        - keyPoints：这部分真正重要的概念、公式、定义、方法或结论；不要把每句话都列成重点。
        - terms：本部分出现的学科专业术语（俄语原词 + 中文含义 + 简短解释）；不要收录普通高频词汇。
        - assignments：只收录老师明确布置的任务（作业、阅读、截止日期、下节课准备、需提交材料）。没有明确证据时返回空数组，绝不要猜测。
        - uncertainties：转录明显不完整、翻译可疑、上下文不足或含义不确定、值得学生回看原文确认的内容。
        - 每条内容用 cites 标注其来源转录编号，只能使用本次输入中出现的编号；无法确定来源时用空数组。

        JSON 格式：
        {"topic": "…", "keyPoints": [{"text": "…", "cites": [1]}], "terms": [{"russian": "…", "chinese": "…", "explanation": "…", "cites": [2]}], "assignments": [{"text": "…", "cites": [3]}], "uncertainties": [{"text": "…", "cites": [4]}]}
        """
    }

    static func extractionUserPrompt(
        context: ClassContext,
        entries: [EntryMaterial],
        notes: [String]
    ) -> String {
        var lines: [String] = []
        let contextLine = context.contextLine
        if !contextLine.isEmpty {
            lines.append("课堂：\(contextLine)")
            lines.append("")
        }
        lines.append("转录内容：")
        for entry in entries {
            lines.append("[\(entry.citation)] \(entry.timestamp) \(entry.russian)")
            if let chinese = entry.chinese, !chinese.isEmpty {
                lines.append("    中文：\(chinese)")
            }
        }
        if !notes.isEmpty {
            lines.append("")
            lines.append("学生课堂笔记（参考，不必逐条处理）：")
            for note in notes {
                lines.append("- \(note)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Merge

    static func mergeSystemPrompt() -> String {
        """
        你是课堂学习助手。以下输入是对一堂课分段提取的结果（JSON 对象数组，每段对应课堂的一部分）。请把它们合并为一份完整的课后复习整理。

        要求：
        - 只输出一个 JSON 对象，不要输出任何其他文字或代码块标记。
        - topic：用一句话概括本堂课的主题。
        - summary：面向复习的中文摘要（约 200～400 字），概括本堂课讲了什么、按什么脉络展开、最重要的结论；写成连贯的段落，不要罗列条目。
        - outline：层级提纲（最多三层），按授课逻辑组织；每个节点有 title，可附 detail（关键解释、示例、结论）；保留来源编号。
        - keyPoints：合并并去重各段的重点；保留全课最重要的内容，不要超过 15 条。
        - terms：合并去重各段术语；保留专业术语。
        - assignments：合并各段识别到的明确任务；若所有段落都没有明确任务，返回空数组。
        - uncertainties：合并值得回看原文确认的内容，不要超过 10 条。
        - cites 只能使用输入中出现的转录编号。

        JSON 格式：
        {"topic": "…", "summary": "…", "outline": [{"title": "…", "detail": "…", "cites": [1], "children": []}], "keyPoints": [{"text": "…", "cites": [2]}], "terms": [{"russian": "…", "chinese": "…", "explanation": "…", "cites": [3]}], "assignments": [{"text": "…", "cites": [4]}], "uncertainties": [{"text": "…", "cites": [5]}]}
        """
    }

    static func mergeUserPrompt(
        context: ClassContext,
        chunkExtractions: [String],
        notes: [String]
    ) -> String {
        var lines: [String] = []
        let contextLine = context.contextLine
        if !contextLine.isEmpty {
            lines.append("课堂：\(contextLine)")
            lines.append("")
        }
        lines.append("分段提取结果（按课堂时间顺序）：")
        for (index, extraction) in chunkExtractions.enumerated() {
            lines.append("—— 第 \(index + 1) 部分 ——")
            lines.append(extraction)
        }
        if !notes.isEmpty {
            lines.append("")
            lines.append("学生课堂笔记（供理解上下文，不要求纳入输出）：")
            for note in notes {
                lines.append("- \(note)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
