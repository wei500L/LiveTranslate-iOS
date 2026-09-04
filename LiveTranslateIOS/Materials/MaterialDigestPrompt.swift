import Foundation

/// Prompt construction for material-digest (导读) generation. Pure
/// functions — the generator feeds real page data and the same strings
/// are deterministic for tests. Prompts are Chinese (the reading
/// language); Russian originals are kept for terminology. Every item
/// must cite the PAGE NUMBER it came from — the citation contract is
/// `materialID + pageNumber`, stable and jump-back-able.
enum MaterialDigestPrompt {
    /// One page's material for the prompt.
    struct PageMaterial: Sendable, Equatable {
        var pageNumber: Int
        /// Effective text (text layer, else OCR) — never both.
        var text: String
        /// True when the page is a scanned image the multimodal pass
        /// described (the merge sees its observation).
        var isImagePage: Bool
    }

    /// Material-level context woven into every prompt.
    struct MaterialContext: Sendable, Equatable {
        var materialTitle: String = ""
        var courseName: String = ""
        var kindName: String = ""
        var pageCount: Int = 0

        var contextLine: String {
            var parts: [String] = []
            if !courseName.isEmpty { parts.append(courseName) }
            if !materialTitle.isEmpty { parts.append(materialTitle) }
            if !kindName.isEmpty { parts.append("类型：\(kindName)") }
            if pageCount > 0 { parts.append("共 \(pageCount) 页") }
            return parts.joined(separator: " · ")
        }
    }

    // MARK: - Chunk extraction

    static func extractionSystemPrompt() -> String {
        """
        你是课程资料阅读助手。用户是在俄罗斯大学留学的中国学生，正在阅读一份课程资料（讲义、习题、实验指导或阅读材料），可能是俄语原文。你会收到这份资料的一部分页面（每页带页码和文字内容；俄语资料保留原文）。请从这部分页面中提取导读材料。

        要求：
        - 只输出一个 JSON 对象，不要输出任何其他文字或代码块标记。
        - topic：这部分内容的主题（一句话）。
        - keyPoints：这部分真正重要的概念、定义、方法或结论；不要把每段都列成重点。
        - terms：本部分出现的学科专业术语（俄语原词 + 中文含义 + 简短解释）；不要收录普通高频词汇。
        - formulas：本部分出现的公式和符号（用文字或 LaTeX 描述其含义）；没有公式返回空数组。
        - examples：本部分的例题、习题或实验步骤（概括其做法，不必抄题）。
        - assignments：资料中明确写出的作业、练习要求或截止日期；没有明确证据时返回空数组，绝不要猜测。
        - uncertainties：页面文字明显残缺、 OCR 可疑、含义不确定或值得学生回看原页确认的内容。
        - 每条内容用 pages 标注其来源页码；只能使用本次输入中出现的页码；无法确定来源时用空数组。

        JSON 格式：
        {"topic": "…", "keyPoints": [{"text": "…", "pages": [1]}], "terms": [{"russian": "…", "chinese": "…", "explanation": "…", "pages": [2]}], "formulas": [{"text": "…", "detail": "…", "pages": [3]}], "examples": [{"text": "…", "pages": [4]}], "assignments": [{"text": "…", "pages": [5]}], "uncertainties": [{"text": "…", "pages": [6]}]}
        """
    }

    static func extractionUserPrompt(
        context: MaterialContext, pages: [PageMaterial]
    ) -> String {
        var lines: [String] = []
        let contextLine = context.contextLine
        if !contextLine.isEmpty {
            lines.append("资料：\(contextLine)")
            lines.append("")
        }
        lines.append("页面内容：")
        for page in pages {
            let body = page.text.isEmpty
                ? "（本页无可提取文字，可能是扫描图片）"
                : page.text
            lines.append("—— 第 \(page.pageNumber) 页 ——")
            lines.append(body)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Scanned-page image description (multimodal, bounded)

    static func imagePageSystemPrompt() -> String {
        """
        你是资料页面识别助手。这张图片是一份课程资料中的一页（扫描件、板书或图表）。请用中文描述这一页的内容，供后续汇总使用。

        要求：
        - 只输出一个 JSON 对象，不要输出任何其他文字或代码块标记。
        - text：这一页包含的内容描述（可见文字的忠实转写、公式、图表结构、标题层级）；可见的俄语文字保留原文并尽量给出中文含义。
        - uncertainties：无法辨认或不确定的部分；辨认清晰时返回空数组。

        JSON 格式：
        {"text": "…", "uncertainties": ["…"]}
        """
    }

    static func imagePageUserPrompt(pageNumber: Int) -> String {
        "这是资料的第 \(pageNumber) 页。"
    }

    // MARK: - Merge

    static func mergeSystemPrompt() -> String {
        """
        你是课程资料阅读助手。以下输入是对一份资料分段提取的结果（JSON 对象数组，每段对应若干页），可能还有若干扫描页的图片识别结果。请把它们合并为一份完整的资料导读。

        要求：
        - 只输出一个 JSON 对象，不要输出任何其他文字或代码块标记。
        - overview：面向阅读的中文概述（约 150～300 字）：这份资料讲什么、按什么结构组织、适合在什么阶段阅读。
        - outline：资料的层级目录（最多三层），按资料自身结构组织；每个节点有 title，可附 detail。
        - keyPoints：合并去重各段的重点；不要超过 15 条。
        - terms：合并去重各段的俄语术语，保留专业术语。
        - formulas：合并各段的公式与符号说明。
        - examples：合并各段的例题或实验步骤。
        - assignments：资料中明确写出的作业、练习或截止要求；所有部分都没有明确证据时返回空数组。
        - prerequisites：阅读这份资料之前需要先掌握的知识（来自资料自身的提示或内容的明显依赖）。
        - recommendedPages：最值得优先阅读的页码（不超过 10 个）。
        - uncertainties：合并值得回看原页确认的内容，不要超过 10 条。
        - 每条内容用 pages 标注其来源页码；只能使用输入中出现的页码；无法确定来源时用空数组。

        JSON 格式：
        {"overview": "…", "outline": [{"title": "…", "detail": "…", "pages": [1]}], "keyPoints": [{"text": "…", "pages": [2]}], "terms": [{"russian": "…", "chinese": "…", "explanation": "…", "pages": [3]}], "formulas": [{"text": "…", "detail": "…", "pages": [4]}], "examples": [{"text": "…", "pages": [5]}], "assignments": [{"text": "…", "pages": [6]}], "prerequisites": ["…"], "recommendedPages": [1, 2], "uncertainties": [{"text": "…", "pages": [7]}]}
        """
    }

    static func mergeUserPrompt(
        context: MaterialContext,
        chunkExtractions: [String],
        imagePageObservations: [(pageNumber: Int, json: String)]
    ) -> String {
        var lines: [String] = []
        let contextLine = context.contextLine
        if !contextLine.isEmpty {
            lines.append("资料：\(contextLine)")
            lines.append("")
        }
        lines.append("分段提取结果（按页码顺序）：")
        for (index, extraction) in chunkExtractions.enumerated() {
            lines.append("—— 第 \(index + 1) 部分 ——")
            lines.append(extraction)
        }
        if !imagePageObservations.isEmpty {
            lines.append("")
            lines.append("扫描页图片识别结果：")
            for observation in imagePageObservations {
                lines.append("—— 第 \(observation.pageNumber) 页 ——")
                lines.append(observation.json)
            }
        }
        return lines.joined(separator: "\n")
    }
}
