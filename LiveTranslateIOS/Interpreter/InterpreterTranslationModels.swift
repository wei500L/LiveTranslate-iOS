import Foundation

/// 结构化翻译详情：模型按约定 JSON 返回的补充字段。所有字段允许
/// 缺失 —— 解析器必须容忍部分字段缺失、字符串/数组混用与纯文本
/// 响应（解析失败时绝不丢弃可读翻译）。
///
/// 同步边界（第十七轮）：details 会随 turn 上传到自建服务器。它只
/// 允许携带非来源型结构信息 —— 文件名、页码、本地 documentID 与
/// 引文 snippet 绝不进入 details；文件上下文的来源信息以无内容的
/// `hasLocalSources` 标记表达，真实标签只存本机
/// （InterpreterTurn.localSourcesJSON）。
struct InterpreterTurnDetails: Codable, Equatable, Sendable {
    /// 对方意图摘要（ru2zh 方向）。
    var intentSummary: String?
    /// 关键词（双语对照，模型自由文本行；不含文件来源标签）。
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
    /// 该回合引用了本地文件来源，但来源标签只保存在原设备 —— 其他
    /// 设备看到 true 时显示"来源文件仅保存在原设备"，绝不渲染假
    /// 链接。无内容，只表达"有来源"这一事实。
    var hasLocalSources: Bool?

    enum CodingKeys: String, CodingKey {
        case intentSummary
        case keywords
        case ambiguity
        case suggestedReplies
        case politeAlternative
        case simpleAlternative
        case uncertainties
        case detailsAvailable
        case hasLocalSources
    }

    /// 空详情（纯文本回退时使用 —— 显示普通翻译，说明详细解释不可用）。
    static let plainTextFallback = InterpreterTurnDetails(detailsAvailable: false)
}

/// 一条只保存在本机的文件来源引用（随身翻译文件上下文回合）。
/// 由校验通过的 citation 生成：snippet 是模型引用的原文短引文
/// （≤300 字符，与实际发送给模型的那份文本一致 —— 默认遮盖后的），
/// documentName 是本机文件名。绝不进入 details / outbox / 服务器；
/// 存储在 InterpreterTurn.localSourcesJSON（设备本地字段）。
struct InterpreterLocalSource: Codable, Equatable, Sendable {
    /// 来源文件的本机行 ID（第十七轮之前生成的迁移条目没有 —— 只
    /// 有显示用的名称与页码）。
    var documentID: UUID?
    var documentName: String
    var pageNumber: Int
    /// ≤300 字符的短引文（发送给模型的那份文本里的连续片段）。
    var snippet: String

    var displayLabel: String {
        "\(documentName) · 第\(pageNumber)页"
    }
}

/// 出站/入站 details 的防御性清洗：把旧版本塞进 keywords 的文件
/// 来源标签（"文件名 · 第N页" 形态）移出可同步 details，改为无内容
/// 的 hasLocalSources 标记。真实标签从不经过这里 —— 它们本来就不
/// 应该在 details 里；这个清洗是给历史数据和旧客户端的兜底。
enum InterpreterDetailsSanitizer {
    /// "文件名 · 第N页" 的识别模式 —— 与 Chunker 的 label 生成保持
    /// 一致（空格差异容忍："第 1 页" 与 "第1页" 都匹配）。
    static func isCitationLabel(_ keyword: String) -> Bool {
        let pattern = "^.+ · 第\\s*[0-9]+\\s*页$"
        return keyword.range(of: pattern, options: .regularExpression) != nil
    }

    /// 清洗一段 details JSON：返回清洗后的 JSON 字符串；无可清洗
    /// 内容时原样返回（幂等 —— 已清洗的输入不会被再次改写）。
    /// 无效 JSON 原样返回（调用方决定是否拒绝 —— 这里不做语法
    /// 判断，只做内容防御）。
    static func sanitizedDetailsJSON(_ json: String) -> String {
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              var details = try? JSONDecoder().decode(
                  InterpreterTurnDetails.self, from: data
              )
        else { return json }
        guard let keywords = details.keywords,
              keywords.contains(where: isCitationLabel)
        else {
            // 无来源标签：hasLocalSources 保持不变（可能是别的设备
            // 写入的真实标记）。
            return json
        }
        let remaining = keywords.filter { !isCitationLabel($0) }
        details.keywords = remaining.isEmpty ? nil : remaining
        // 已有显式 false 之外的情况：既然移除了标签，就一定存在本地
        // 来源 —— 标记为 true（其他设备显示"来源仅保存在原设备"）。
        if details.hasLocalSources != true {
            details.hasLocalSources = true
        }
        guard let encoded = try? JSONEncoder().encode(details),
              let out = String(data: encoded, encoding: .utf8)
        else { return json }
        return out
    }
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
