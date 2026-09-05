import Foundation

/// 结构化翻译详情：模型按约定 JSON 返回的补充字段。所有字段允许
/// 缺失 —— 解析器必须容忍部分字段缺失、字符串/数组混用与纯文本
/// 响应（解析失败时绝不丢弃可读翻译）。
struct InterpreterTurnDetails: Codable, Equatable, Sendable {
    /// 对方意图摘要（ru2zh 方向）。
    var intentSummary: String?
    /// 关键词（双语对照，模型自由文本行）。
    var keywords: [String]?
    /// 可能存在的歧义说明。
    var ambiguity: String?
    /// 可选中文回复建议（ru2zh：2-3 条，只预填输入框）。
    var suggestedReplies: [String]?
    /// 更礼貌的备选俄语表达（zh2ru）。
    var politeAlternative: String?
    /// 更简单直接的备选俄语表达（zh2ru）。
    var simpleAlternative: String?
    /// 不确定项 / 使用提示。
    var uncertainties: [String]?
    /// 详细解释是否可用（纯文本回退时为 false，界面诚实说明）。
    var detailsAvailable: Bool = true

    enum CodingKeys: String, CodingKey {
        case intentSummary
        case keywords
        case ambiguity
        case suggestedReplies
        case politeAlternative
        case simpleAlternative
        case uncertainties
        case detailsAvailable
    }

    /// 空详情（纯文本回退时使用 —— 显示普通翻译，说明详细解释不可用）。
    static let plainTextFallback = InterpreterTurnDetails(detailsAvailable: false)
}

/// 随身翻译的翻译结果：可读翻译（永远保留）+ 结构化详情（可缺失）。
struct InterpreterTranslationResult: Equatable, Sendable {
    /// 主要可读文本（ru2zh = 中文翻译；zh2ru = 自然俄语）。
    var mainText: String
    /// 带重音俄语（校验通过时才非 nil）。
    var stressedRussian: String?
    /// 中文回译（zh2ru 方向）。
    var backTranslation: String?
    /// 结构化详情。
    var details: InterpreterTurnDetails
    /// 是否来自纯文本响应（非结构化 JSON）。
    var isPlainTextResponse: Bool
}

// MARK: - 俄语重音校验

/// 俄语重音标注校验：带重音版本使用 Unicode combining acute accent
/// (U+0301)。校验规则：
/// 1. 去掉所有 U+0301 后，与普通俄语在 Unicode 规范化后一致；
/// 2. 重音版本不得修改词语、数字、标点或姓名；
/// 3. 校验不通过 → 丢弃重音版本，保留普通俄语（显示"暂未生成重音标注"）；
/// 4. `ё` 不应被错误替换为 `е`（е vs ё 差异导致校验失败）。
enum RussianStressValidator {
    /// 组合重音符号 U+0301。
    static let combiningAcute = "\u{0301}"

    /// 去掉所有 combining acute（TTS 朗读必须用这个普通俄语）。
    static func stripStress(_ text: String) -> String {
        text.replacingOccurrences(of: combiningAcute, with: "")
    }

    /// 校验带重音版本与普通版本的一致性。通过返回 true。
    /// - 规则 1：去重音后 NFC 规范化必须与普通版本 NFC 规范化一致
    ///   （重音符号只能叠加，不能改变基础字符）。
    static func isValid(stressed: String, plain: String) -> Bool {
        let stripped = stripStress(stressed)
        let a = stripped.precomposedStringWithCanonicalMapping
        let b = plain.precomposedStringWithCanonicalMapping
        return a == b
    }

    /// 校验并择优：通过返回带重音版本，不通过返回 nil（调用方保留
    /// 普通俄语并显示"暂未生成重音标注"）。
    static func validated(stressed: String?, plain: String) -> String? {
        guard let stressed, !stressed.isEmpty else { return nil }
        // 重音版本不得为空壳（与普通版本相同则没有重音可言）。
        guard stressed != plain else { return nil }
        return isValid(stressed: stressed, plain: plain) ? stressed : nil
    }
}
