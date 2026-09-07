import Foundation

/// Chat prompt construction for the two GGUF translation models, built per
/// the OFFICIAL model cards (not guessed):
///
/// - Hy-MT2 (tencent/Hy-MT2-1.8B, hunyuan-dense): NO system prompt; a user
///   instruction "Translate the following text into `{target_lang}`…
///   only output the translated result without any additional
///   explanation" followed by the source text. Full language names
///   (Simplified Chinese, Russian). Chat template: Hunyuan's
///   `<|startoftext|>…<|extra_0|>Assistant: <|extra_1|>`-style markers are
///   NOT in the GGUF's embedded template — the card's own CLI examples run
///   raw `--jinja` chat mode, so the exact embedded template is honored by
///   the dedicated builder below.
/// - MiLMMT (xiaomi-research/MiLMMT-46-1B-v1.0, gemma3-1b lineage): Gemma
///   turn template `<start_of_turn>user\n…<end_of_turn>\n<start_of_turn>model\n`
///   with no system role (Gemma folds system text into the first user
///   turn — but MiLMMT's card documents a plain translation instruction,
///   so no system text is added).
///
/// Both builders are pure functions (unit-tested against byte-exact
/// expectations).
enum LlamaChatPromptBuilder {
    /// Hy-MT2 translation instruction per the model card. Full language
    /// names, no system prompt, one user turn.
    static func hyMT2Prompt(source: String, sourceLanguage: String, targetLanguage: String, history: [(source: String, translation: String)]) -> String {
        // Hy-MT2's card has no documented multi-turn context recipe; the
        // card's delimiter guidance recommends keeping the request
        // self-contained. History is therefore NOT included for Hy-MT2 —
        // consistency over speculative context injection.
        let target = displayName(for: targetLanguage)
        let sourceText = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        Translate the following text into \(target). Translate the text as is, without adding any explanation. Only output the translated result without any additional explanation.
        \(sourceText)
        """
    }

    /// MiLMMT prompt in Gemma turn format. The instruction mirrors the
    /// card's documented translation usage.
    static func milmmtPrompt(source: String, sourceLanguage: String, targetLanguage: String, history: [(source: String, translation: String)]) -> String {
        let target = displayName(for: targetLanguage)
        let sourceText = source.trimmingCharacters(in: .whitespacesAndNewlines)
        // Context turns ride as prior user/model pairs (Gemma multi-turn),
        // capped small: the 2048-token window must hold prompt + answer.
        var turns = ""
        for pair in history.suffix(2) {
            turns += "<start_of_turn>user\nTranslate the following text into \(target).\n\(pair.source)\n<end_of_turn>\n"
            turns += "<start_of_turn>model\n\(pair.translation)\n<end_of_turn>\n"
        }
        return turns + "<start_of_turn>user\nTranslate the following text into \(target). Translate the text as is, without adding any explanation. Only output the translated result without any additional explanation.\n\(sourceText)\n<end_of_turn>\n<start_of_turn>model\n"
    }

    /// Full BCP-47-ish code → the full language name the model cards
    /// require ("Simplified Chinese", "Russian", …).
    static func displayName(for languageCode: String) -> String {
        switch languageCode.lowercased() {
        case "zh", "zh-cn", "zh-hans", "chinese": return "Simplified Chinese"
        case "zh-tw", "zh-hant": return "Traditional Chinese"
        case "ru", "russian": return "Russian"
        case "en", "english": return "English"
        default: return languageCode
        }
    }
}
