import Foundation

/// The classroom translation system prompt, inherited verbatim in behavior
/// from the reference project's `translator.py` DEFAULT_PROMPT.
enum ClassroomTranslationPrompt {
    /// Placeholder-bearing template. `{source_lang}`, `{target_lang}` and
    /// `{context}` are substituted at request time.
    static let template = """
你是俄语课堂的实时翻译助手。请将课堂中的{source_lang}内容翻译成{target_lang}。
场景：学校或大学课堂，内容可能包括教师讲解、学生提问、课堂讨论、例句、术语、板书和作业要求。
规则：
- 只输出一条准确、自然的{target_lang}译文，不要解释、分析、前缀、引号或多个候选。
- 保持教师讲解或学生发言的逻辑、语气、否定、条件、因果、时间和指代关系，不擅自补充未说内容。
- 课程术语、人名、地名、书名、课程名、缩写、数字、公式和符号使用目标语言通行表达；没有把握时保留原文，不要臆造。
- 结合课堂语境和近期上下文纠正俄语 ASR 的错词、同音词和断句；无法确定时忠实翻译，不要编造。
- 可适度压缩口语重复和填充词，但不要省略定义、例子、数字、公式、作业要求或关键限定。
- 保持适合实时字幕的简洁长度；原句未完时翻译当前可确定的内容，不添加说明。
近期课堂上下文：
{context}
"""

    static let languageDisplay: [String: String] = [
        "en": "English", "ja": "Japanese", "zh": "Chinese", "zh-CN": "Simplified Chinese",
        "ko": "Korean", "fr": "French", "de": "German", "es": "Spanish", "ru": "Russian",
        "pt": "Portuguese", "it": "Italian", "uk": "Ukrainian",
    ]

    static func displayLanguage(_ code: String) -> String {
        languageDisplay[code] ?? code
    }

    /// Build the final system prompt with context lines embedded.
    /// - Parameters:
    ///   - source: source language code, e.g. "ru".
    ///   - target: target language code, e.g. "zh-CN".
    ///   - history: recent (source, translation) pairs, oldest first.
    static func build(
        source: String,
        target: String,
        history: [(source: String, translation: String)]
    ) -> String {
        var contextLines: [String] = []
        for pair in history {
            contextLines.append("Source: \(pair.source)")
            contextLines.append("Translation: \(pair.translation)")
            contextLines.append("")
        }
        let context = contextLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let src = displayLanguage(source)
        let tgt = displayLanguage(target)
        return template
            .replacingOccurrences(of: "{source_lang}", with: src)
            .replacingOccurrences(of: "{target_lang}", with: tgt)
            .replacingOccurrences(of: "{context}", with: context)
    }
}

/// Provider shapes that disable thinking/reasoning modes. Thinking left on
/// burns the whole max_tokens budget on reasoning and yields an empty
/// completion — the reference project documented this as issue #38.
enum ThinkingStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    case auto, deepseek, qwen, vllm, openai, off

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return String(localized: "Auto-detect")
        case .deepseek: return "DeepSeek / GLM (nested thinking)"
        case .qwen: return "Qwen / DashScope (enable_thinking)"
        case .vllm: return "vLLM / SGLang (chat template)"
        case .openai: return "OpenAI / Grok (reasoning_effort)"
        case .off: return String(localized: "Off (no parameter)")
        }
    }

    static let nestedThinkingModels = ["deepseek", "glm"]
    static let nestedThinkingEndpoints = ["deepseek", "volces", "api.z.ai", "bigmodel"]
    static let paramlessEndpoints = ["api.openai.com", "api.x.ai", "api.anthropic.com"]

    /// Resolve "auto" from the endpoint and model id.
    static func resolve(_ style: ThinkingStyle, apiBase: String, model: String) -> ThinkingStyle {
        guard style == .auto else { return style }
        let endpoint = apiBase.lowercased()
        let modelID = model.lowercased()
        if nestedThinkingModels.contains(where: { modelID.contains($0) })
            || nestedThinkingEndpoints.contains(where: { endpoint.contains($0) }) {
            return .deepseek
        }
        if paramlessEndpoints.contains(where: { endpoint.contains($0) }) {
            return .off
        }
        return .qwen
    }

    /// Request-body fragment that disables thinking for this style.
    var disableBody: [String: Any] {
        switch self {
        case .deepseek: return ["thinking": ["type": "disabled"]]
        case .qwen: return ["enable_thinking": false]
        case .vllm: return ["chat_template_kwargs": ["enable_thinking": false]]
        case .openai: return ["reasoning_effort": "none"]
        case .auto, .off: return [:]
        }
    }
}
