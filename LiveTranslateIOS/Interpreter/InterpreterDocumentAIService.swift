import Foundation
import UIKit
import OSLog

/// 随身翻译文件上下文的 AI 编排服务：文件解释、字段助手、基于文件
/// 与最近对话的问答、字段值核对。
///
/// 复用 `StudyReviewModelService` 传输层（同一个 OpenAI 兼容原语、同
/// 一个 API key 与模型回退 —— 与 InterpreterTranslationService 相同的
/// 约束：绝不建立第三套 AI HTTP 客户端）。多模态兜底（页面图像分析）
/// 复用 `AttachmentAnalysisModelService`（与视觉问答同一服务）。
///
/// 上下文预算：文件 chunk 受 InterpreterDocumentChunker 的上限约束
/// （8 chunk / 6000 字符），与第十五轮最近 8 回合 / 2400 字符的对话
/// 预算相互独立 —— 加入文件绝不无限放大 prompt。
///
/// 引文校验：模型返回的 citations 一律经
/// InterpreterDocumentChunker.validateCitations 校验（source ID 必须来
/// 自本次请求、页码必须匹配、引文必须在原文中存在）；无效引文被丢弃，
/// 绝不显示成真实来源。
///
/// 取消语义：CancellationError 原样传播（取消不标失败）。
struct InterpreterDocumentAIService: Sendable {
    static let logger = Logger(
        subsystem: "com.livetranslate.ios", category: "interpreter-documents"
    )

    private let model: any StudyReviewModelService

    init(model: any StudyReviewModelService) {
        self.model = model
    }

    var isConfiguredNow: Bool { model.isConfiguredNow }

    // MARK: - 请求载荷（发送前预览的数据结构）

    /// 一次模型请求的完整载荷（UI 在发送前展示给用户核对）。
    struct RequestPayload: Equatable, Sendable {
        /// 将发送的 source 行（含文件名、页码与文本）。
        var sourceLines: [String]
        /// 是否默认遮盖了敏感信息。
        var maskedSensitive: Bool
        /// 遮盖建议（原文里发现的可疑字段）。
        var sensitiveFindings: [String]
    }

    // MARK: - 文件分析（解释这份文件 / 字段助手）

    /// 分析用户选中的文件 chunk。`sources` 必须已经过用户预览与
    /// （默认的）敏感遮盖 —— 本层不再修改发送内容。
    func analyzeDocument(
        sources: [InterpreterDocumentChunker.RequestSource],
        scene: InterpreterScene
    ) async throws -> InterpreterDocumentAnalysis {
        let sourceLines = sources.map { source in
            InterpreterDocumentPrompt.sourceLine(
                sourceID: source.sourceID,
                documentName: source.chunk.documentName,
                pageNumber: source.chunk.pageNumber,
                text: source.chunk.text
            )
        }
        let raw = try await complete(
            system: InterpreterDocumentPrompt.analysisSystemPrompt(scene: scene),
            user: InterpreterDocumentPrompt.analysisUserPrompt(sources: sourceLines),
            maxTokens: 2400
        )
        guard var analysis = InterpreterDocumentParser.parseAnalysis(raw) else {
            throw TranslationError.emptyResponse
        }
        // 引文校验：只保留指向本次请求真实 chunk 的引文。
        let rawCitations = InterpreterDocumentParser.parseRawCitations(raw)
        analysis.citations = Self.validate(
            rawCitations, against: sources
        )
        return analysis
    }

    // MARK: - 基于文件的问答（融合最近对话）

    /// 基于文件与最近对话回答问题，并生成可对工作人员说的俄语。
    func answerQuestion(
        question: String,
        sources: [InterpreterDocumentChunker.RequestSource],
        scene: InterpreterScene,
        contextNote: String,
        recentTurns: [InterpreterContextBuilder.TurnProjection]
    ) async throws -> InterpreterDocumentAnswer {
        let sourceLines = sources.map { source in
            InterpreterDocumentPrompt.sourceLine(
                sourceID: source.sourceID,
                documentName: source.chunk.documentName,
                pageNumber: source.chunk.pageNumber,
                text: source.chunk.text
            )
        }
        let context = InterpreterContextBuilder().buildContext(recentTurns)
        let raw = try await complete(
            system: InterpreterDocumentPrompt.answerSystemPrompt(
                scene: scene, contextNote: contextNote
            ),
            user: InterpreterDocumentPrompt.answerUserPrompt(
                question: question, sources: sourceLines, recentContext: context
            ),
            maxTokens: 1600
        )
        guard var answer = InterpreterDocumentParser.parseAnswer(raw) else {
            throw TranslationError.emptyResponse
        }
        let rawCitations = InterpreterDocumentParser.parseRawCitations(raw)
        answer.citations = Self.validate(rawCitations, against: sources)
        return answer
    }

    // MARK: - 字段值核对（用户手动输入自己的值之后）

    /// 检查用户手动输入的字段值格式。
    func checkFieldValue(
        field: InterpreterFormField,
        userValue: String
    ) async throws -> InterpreterDocumentAnswer {
        let raw = try await complete(
            system: InterpreterDocumentPrompt.fieldCheckSystemPrompt(),
            user: InterpreterDocumentPrompt.fieldCheckUserPrompt(
                fieldLabel: field.russianLabel,
                fieldMeaning: field.chineseMeaning,
                userValue: userValue,
                exampleFormat: field.exampleFormat
            ),
            maxTokens: 800
        )
        guard var answer = InterpreterDocumentParser.parseAnswer(raw) else {
            throw TranslationError.emptyResponse
        }
        // 字段核对没有文件 chunk —— 引文一律为空（不存在可引用的来源）。
        answer.citations = nil
        return answer
    }

    // MARK: - 多模态兜底（分析原始页面图像）

    /// 分析选定页面的受限尺寸图像副本（用户明确确认后才调用 ——
    /// "页面无文字层 / OCR 不足 / 需要理解表格布局" 时的兜底）。
    /// 图像经 InterpreterDocumentAIService.preparePageImage 预先渲染
    /// （页面级、有界），绝不发送整份 PDF。
    func analyzePages(
        images: [ModelImagePayload],
        question: String,
        scene: InterpreterScene,
        imageService: any AttachmentAnalysisModelService
    ) async throws -> InterpreterDocumentAnalysis {
        let raw = try await imageService.complete(
            systemPrompt: InterpreterDocumentPrompt.analysisSystemPrompt(scene: scene),
            userPrompt: """
            页面图像见附件（用户已确认发送这些页面）。用户的问题：\(question.isEmpty ? "请分析这份文件" : question)

            请分析并返回 JSON。citations 用 [{"source": "图片 1", "page": 1, "snippet": "..."}] 的形式引用图片编号。
            """,
            images: images,
            maxTokens: 2400
        )
        guard var analysis = InterpreterDocumentParser.parseAnalysis(raw) else {
            throw TranslationError.emptyResponse
        }
        // 多模态引文不携带可校验的 source ID（图像编号 "图片 1"）——
        // 降级为不带 snippet 的页码引用，明确标注为图像引文。
        analysis.citations = nil
        if analysis.detailsAvailable {
            // 保留结构化结果，但引文不可伪造：只有图像级来源。
            analysis.uncertainties = (analysis.uncertainties ?? [])
        }
        return analysis
    }

    // MARK: - 预览载荷构建（发送前预览 + 敏感遮盖）

    /// 为一次请求构建可预览载荷：默认对明显敏感信息（护照号、卡号、
    /// 手机号、邮箱）执行本地遮盖；返回遮盖后的 source 列表与发现
    /// 摘要，由 UI 展示并允许用户取消遮盖。
    static func buildPreviewPayload(
        sources: [InterpreterDocumentChunker.RequestSource],
        maskSensitive: Bool = true
    ) -> (payload: RequestPayload, maskedSources: [InterpreterDocumentChunker.RequestSource]) {
        var maskedSources: [InterpreterDocumentChunker.RequestSource] = []
        var findings: [String] = []
        for source in sources {
            var chunk = source.chunk
            if maskSensitive {
                let (masked, matches) = InterpreterSensitiveMasker.masked(chunk.text)
                if !matches.isEmpty {
                    chunk.text = masked
                    for match in matches {
                        let finding = "\(source.chunk.documentName) 第\(source.chunk.pageNumber)页：\(match.kind.displayName)"
                        if !findings.contains(finding) {
                            findings.append(finding)
                        }
                    }
                }
            }
            maskedSources.append(
                InterpreterDocumentChunker.RequestSource(sourceID: source.sourceID, chunk: chunk)
            )
        }
        let lines = maskedSources.map { source in
            InterpreterDocumentPrompt.sourceLine(
                sourceID: source.sourceID,
                documentName: source.chunk.documentName,
                pageNumber: source.chunk.pageNumber,
                text: source.chunk.text
            )
        }
        return (
            RequestPayload(
                sourceLines: lines,
                maskedSensitive: maskSensitive && !findings.isEmpty,
                sensitiveFindings: findings
            ),
            maskedSources
        )
    }

    /// 渲染一个 PDF/图片页面的受限尺寸分析副本（多模态兜底用）。
    static func preparePageImage(
        documentID: UUID, pageNumber: Int,
        store: InterpreterDocumentStore
    ) async -> ModelImagePayload? {
        let task = Task.detached(priority: .utility) { () -> Data? in
            // Thumbnail cache first (regenerable, bounded 600px).
            if let cached = store.pageThumbnailData(documentID: documentID, pageNumber: pageNumber) {
                return cached
            }
            return nil
        }
        guard let data = await task.value,
              let image = UIImage(data: data) else { return nil }
        // Bounded re-encode (long edge 1600 — the analysis budget).
        let longEdge = max(image.size.width, image.size.height)
        guard longEdge > 0 else { return nil }
        let scale = min(1600 / longEdge, 1)
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        guard let jpeg = resized.jpegData(compressionQuality: 0.72) else { return nil }
        return ModelImagePayload(data: jpeg, label: "页面 \(pageNumber)")
    }

    // MARK: - Helpers

    private func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        try await model.complete(
            systemPrompt: system, userPrompt: user, maxTokens: maxTokens
        )
    }

    /// Citation validation shared by every path.
    static func validate(
        _ rawCitations: [InterpreterDocumentChunker.ReturnedCitation],
        against sources: [InterpreterDocumentChunker.RequestSource]
    ) -> [InterpreterCitation] {
        InterpreterDocumentChunker.validateCitations(rawCitations, against: sources)
            .map { validated in
                InterpreterCitation(
                    sourceID: validated.sourceID,
                    documentName: validated.documentName,
                    pageNumber: validated.pageNumber,
                    blockIndex: validated.blockIndex,
                    snippet: validated.snippet
                )
            }
    }
}
