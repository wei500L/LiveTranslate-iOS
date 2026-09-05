import Foundation
import OSLog

/// 随身翻译的双向上下文翻译服务。
///
/// 复用 `StudyReviewModelService` 作为传输层（同一个 OpenAI 兼容
/// HTTP 原语、同一个 API key 与模型回退体系 —— 绝不建立第三套 AI
/// HTTP 客户端，也不增加第二个 API Key）。本层只负责：
/// - 组装双向（ru2zh / zh2ru）的 system + user prompt（InterpreterPrompt）；
/// - 调用一次非流式 completion（结构化输出靠 prompt 约定 + 宽容解析）；
/// - 用 InterpreterResponseParser 解析（纯文本响应降级为可读翻译）；
/// - 校验俄语重音（失败保留普通俄语，不阻塞翻译）。
///
/// 取消语义：CancellationError 原样传播 —— 调用方决定如何记录状态
/// （取消的请求绝不标成失败）。
struct InterpreterTranslationService: Sendable {
    static let logger = Logger(subsystem: "com.livetranslate.ios", category: "interpreter")

    private let model: any StudyReviewModelService

    init(model: any StudyReviewModelService) {
        self.model = model
    }

    var isConfiguredNow: Bool { model.isConfiguredNow }

    // MARK: - 俄→中（理解对方）

    /// 翻译对方的一句话俄语。翻译失败时调用方保留俄语原文。
    func translateCounterpart(
        russian: String,
        scene: InterpreterScene,
        contextNote: String,
        recentTurns: [InterpreterContextBuilder.TurnProjection]
    ) async throws -> InterpreterTranslationResult {
        let contextBuilder = InterpreterContextBuilder()
        let context = contextBuilder.buildContext(recentTurns)
        let raw = try await complete(
            system: InterpreterPrompt.ru2zhSystemPrompt(scene: scene, contextNote: contextNote),
            user: InterpreterPrompt.ru2zhUserPrompt(
                counterpartRussian: russian, context: context
            )
        )
        guard let result = InterpreterResponseParser.parseRu2Zh(raw) else {
            // 空响应按 empty 处理（上游标记失败可重试）。
            throw TranslationError.emptyResponse
        }
        return result
    }

    // MARK: - 中→俄（用户表达）

    /// 结合上下文把用户中文生成自然俄语。
    func translateUser(
        chinese: String,
        scene: InterpreterScene,
        contextNote: String,
        tone: InterpreterTone,
        recentTurns: [InterpreterContextBuilder.TurnProjection]
    ) async throws -> InterpreterTranslationResult {
        let contextBuilder = InterpreterContextBuilder()
        let context = contextBuilder.buildContext(recentTurns)
        let raw = try await complete(
            system: InterpreterPrompt.zh2ruSystemPrompt(
                scene: scene, contextNote: contextNote, tone: tone
            ),
            user: InterpreterPrompt.zh2ruUserPrompt(
                userChinese: chinese, context: context
            )
        )
        guard let result = InterpreterResponseParser.parseZh2Ru(raw) else {
            throw TranslationError.emptyResponse
        }
        return result
    }

    // MARK: - Transport

    private func complete(system: String, user: String) async throws -> String {
        try await AICallScope.with(
            AICallContext(feature: .interpreterReply, textCategory: .userInput)
        ) {
            try await model.complete(
                systemPrompt: system, userPrompt: user, maxTokens: 1024
            )
        }
    }
}
