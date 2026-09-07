import Foundation

/// Chat prompt construction for the two GGUF translation models, built per
/// the OFFICIAL model cards and each GGUF's embedded chat template (both
/// verified by reading the actual files — the format is byte-exact, not
/// guessed):
///
/// - Hy-MT2 (tencent/Hy-MT2-1.8B, hunyuan-dense): the GGUF embeds the
///   hunyuan jinja template (`<｜hy_begin▁of▁sentence｜>` BOS marker,
///   `<｜hy_User｜>`/`<｜hy_Assistant｜>` turn markers). The llama.cpp C
///   API's template applier only covers a pre-defined template list that
///   does NOT include hunyuan — so the template is rendered by hand here,
///   byte-identical to the embedded one. Instruction per the model card:
///   no system prompt, "Translate the following text into `{target}`…
///   only output the translated result", full language names
///   ("Simplified Chinese").
/// - MiLMMT (xiaomi-research/MiLMMT-46-1B-v1.0, gemma3-1b lineage): the
///   GGUF carries NO chat template (plain concatenation) — the model card
///   documents a plain-text translation prompt with ITS OWN language
///   names ("Russian", "Chinese (Simplified)") and
///   `add_special_tokens=False`, greedy decoding.
///
/// Both builders are pure functions (unit-tested against byte-exact
/// expectations); tokenization flags (no auto-BOS, parse special markers)
/// live in `LlamaContext.complete`.
enum LlamaChatPromptBuilder {
    /// Hy-MT2 translation request in the hunyuan chat format. The model
    /// card documents no multi-turn recipe, so history is NOT included —
    /// one user turn, self-contained.
    static func hyMT2Prompt(source: String, sourceLanguage: String, targetLanguage: String, history: [(source: String, translation: String)]) -> String {
        let target = displayName(for: targetLanguage)
        let sourceText = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return "<｜hy_begin▁of▁sentence｜><｜hy_User｜>"
            + "Translate the following text into \(target). Translate the text as is, without adding any explanation. Only output the translated result without any additional explanation.\n"
            + sourceText
            + "<｜hy_Assistant｜>"
    }

    /// MiLMMT prompt per the model card (verbatim template):
    /// `Translate this from <src> to <tgt>:\n<src>: <sentence>\n<tgt>:`
    /// with the card's exact language names.
    static func milmmtPrompt(source: String, sourceLanguage: String, targetLanguage: String, history: [(source: String, translation: String)]) -> String {
        let sourceName = milmmtLanguageName(sourceLanguage)
        let targetName = milmmtLanguageName(targetLanguage)
        let sourceText = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Translate this from \(sourceName) to \(targetName):\n"
            + "\(sourceName): \(sourceText)\n"
            + "\(targetName):"
    }

    /// Hy-MT2's documented full language names ("Simplified Chinese").
    static func displayName(for languageCode: String) -> String {
        switch languageCode.lowercased() {
        case "zh", "zh-cn", "zh-hans", "chinese": return "Simplified Chinese"
        case "zh-tw", "zh-hant": return "Traditional Chinese"
        case "ru", "russian": return "Russian"
        case "en", "english": return "English"
        default: return languageCode
        }
    }

    /// MiLMMT's card-specified language names ("Chinese (Simplified)").
    static func milmmtLanguageName(_ languageCode: String) -> String {
        switch languageCode.lowercased() {
        case "zh", "zh-cn", "zh-hans", "chinese": return "Chinese (Simplified)"
        case "zh-tw", "zh-hant": return "Chinese (Traditional)"
        case "ru", "russian": return "Russian"
        case "en", "english": return "English"
        default: return languageCode
        }
    }
}
