import Foundation
import AVFoundation
import OSLog
import Observation
import UIKit

/// 随身翻译文件上下文的视图模型 —— InterpreterViewModel 的文件域
/// 编排层（保持 InterpreterViewModel 专注音频与对话）。
///
/// 职责：
/// - 文档列表状态（当前会话的本地文档上下文）；
/// - 导入入口（相机 / VisionKit 扫描 / 相册 / Files / 收件箱）；
/// - 提取与 OCR 的进度展示与取消；
/// - 页面选择与发送前预览（含敏感遮盖）；
/// - 与对话融合的 AI 动作（解释文件 / 字段助手 / 按文件提问）——
///   结果作为 InterpreterTurn 落库（用户提交的文字沿既有同步链路）。
///
/// 互斥（第十三/十五轮约束的延伸）：
/// - 收音中不启动相机/扫描/重型提取（先结束当前句或停止收音 ——
///   由 UI 拦截并提示，本模型提供 canStartCapture 判断）；
/// - 打开相机前停止 TTS（与"开始收音前停 TTS"同一协议）；
/// - 提取/OCR 串行执行（extractionTasks 已是每文档一个任务），
///   绝不初始化第二个 ASR 引擎（OCR 与 PDF 渲染不触碰 ASREngineManager）。
@MainActor
@Observable
final class InterpreterDocumentContextModel {
    static let logger = Logger(
        subsystem: "com.livetranslate.ios", category: "interpreter-documents"
    )

    private let environment: AppEnvironment
    private let repository: any ClassroomRepositoryProtocol
    private let documentService: InterpreterDocumentService
    /// 文件上下文模型服务提供者（demo 环境注入 canned）。
    private let aiServiceProvider: @MainActor () -> (any StudyReviewModelService)?
    /// 多模态服务提供者（页面图像兜底；复用视觉问答的同一服务）。
    private let imageServiceProvider: @MainActor () -> (any AttachmentAnalysisModelService)?

    // MARK: - State

    private(set) var documents: [InterpreterDocument] = []
    /// 正在导入的文件数（重复点击导入的防抖）。
    private(set) var isImporting = false
    /// 最近一次导入错误（真实错误类别）。
    var lastImportError: String?

    /// 当前展开/查看的文档。
    var presentedDocumentID: UUID?
    /// 用户选中的发送页面（documentID → page numbers；空 = 全部）。
    var selectedPages: [UUID: Set<Int>] = [:]

    /// 发送前预览状态。
    struct SendPreview: Equatable {
        var sourceLines: [String]
        var maskedSensitive: Bool
        var sensitiveFindings: [String]
        var pendingQuestion: String
        /// 待确认的动作类型。
        var action: PreviewAction
    }

    enum PreviewAction: Equatable, Sendable {
        case analyze          // 解释文件
        case ask              // 按文件提问
        case multimodal       // 页面图像分析（明确确认边界）
    }

    var pendingPreview: SendPreview?
    /// 预览时暂存的（可能已遮盖的）source 集合 —— 确认后才发送。
    private var previewSources: [InterpreterDocumentChunker.RequestSource] = []
    private var previewAction: PreviewAction = .ask

    /// AI 动作进行中（防重复提交）。
    private(set) var isAskingAI = false
    var lastAIError: String?

    init(
        environment: AppEnvironment,
        aiServiceProvider: @escaping @MainActor () -> (any StudyReviewModelService)? = { nil },
        imageServiceProvider: @escaping @MainActor () -> (any AttachmentAnalysisModelService)? = { nil }
    ) {
        self.environment = environment
        self.repository = environment.repository
        self.documentService = InterpreterDocumentService(
            repository: environment.repository,
            fileStore: { InterpreterDocumentStoreShared.store }
        )
        self.aiServiceProvider = aiServiceProvider
        self.imageServiceProvider = imageServiceProvider
    }

    // MARK: - Reload

    /// 载入当前会话的文档上下文（进入页面 / 文档变化后）。
    func reload(conversationID: UUID?) {
        guard let conversationID else {
            documents = []
            return
        }
        documents = (try? repository.interpreterDocuments(conversationID: conversationID)) ?? []
    }

    var readyDocumentCount: Int {
        documents.filter { $0.status == .ready || $0.status == .partiallyExtracted }.count
    }

    var hasContext: Bool { !documents.isEmpty }

    func document(with id: UUID) -> InterpreterDocument? {
        documents.first { $0.id == id }
    }

    func extractionProgress(for documentID: UUID) -> InterpreterDocumentService.Progress? {
        documentService.progress(for: documentID)
    }

    // MARK: - 导入互斥判断

    /// 收音/转写中不允许启动相机或扫描（音频优先 —— 先结束当前句或
    /// 停止收音）。查看文件与手动输入不受此限。
    func canStartCapture(isListening: Bool) -> Bool {
        !isListening
    }

    // MARK: - 导入：相机

    /// 相机拍摄的单张图片（CameraCaptureSheet 复用课堂的封装）。
    func importCapturedImage(
        _ data: Data, conversationID: UUID
    ) async {
        await importData(
            data, fileName: "拍摄照片.jpg", conversationID: conversationID,
            source: .camera, utTypeIdentifier: "public.jpeg"
        )
    }

    // MARK: - 导入：扫描（VisionKit）

    /// VisionKit 文档扫描返回的多页图片 → 合成单份本地 PDF。
    /// 扫描器取消（空页集）不创建任何文档（返回 nil）。
    func importScannedPages(
        _ pageDatas: [Data], conversationID: UUID
    ) async {
        guard !pageDatas.isEmpty else { return } // 取消：无空文档
        guard let pdfData = InterpreterDocumentService.makePDFData(from: pageDatas) else {
            lastImportError = "扫描结果无法保存"
            return
        }
        let fileName = "扫描文档-\(Self.timestamp()).pdf"
        await importData(
            pdfData, fileName: fileName, conversationID: conversationID,
            source: .scan, utTypeIdentifier: "com.adobe.pdf"
        )
    }

    // MARK: - 导入：相册

    /// PhotosPicker 选择的图片（逐张导入为独立单页文档）。
    func importPickedPhotos(
        _ datas: [Data], conversationID: UUID
    ) async {
        for (index, data) in datas.enumerated() {
            await importData(
                data,
                fileName: "相册图片-\(Self.timestamp())-\(index + 1).jpg",
                conversationID: conversationID,
                source: .photos,
                utTypeIdentifier: "public.jpeg"
            )
        }
    }

    // MARK: - 导入：Files

    /// Files 导入（安全作用域 URL 在有效期内立即复制）。
    func importFileURL(
        _ url: URL, conversationID: UUID
    ) async {
        await performImport(conversationID: conversationID, source: .files) {
            try await self.documentService.importFile(
                at: url, conversationID: conversationID, source: .files
            )
        }
    }

    // MARK: - 导入：智能收件箱

    /// 从智能收件箱复制已接收的文件（通过 Store API 取 payload 并
    /// 立即复制进 Interpreter 自己的受控生命周期 —— 不保存对 inbox
    /// 临时路径的引用；收件箱删除不破坏已复制的文档）。
    func importInboxItem(
        payloadURL: URL, fileName: String, conversationID: UUID
    ) async {
        await performImport(conversationID: conversationID, source: .inbox) {
            try await self.documentService.importFile(
                at: payloadURL, conversationID: conversationID, source: .inbox
            )
        }
    }

    // MARK: - 导入核心

    private func importData(
        _ data: Data, fileName: String, conversationID: UUID,
        source: InterpreterDocumentSource, utTypeIdentifier: String?
    ) async {
        await performImport(conversationID: conversationID, source: source) {
            try await self.documentService.importData(
                data, fileName: fileName, conversationID: conversationID,
                source: source, utTypeIdentifier: utTypeIdentifier
            )
        }
    }

    private func performImport(
        conversationID: UUID, source: InterpreterDocumentSource,
        _ operation: () async throws -> InterpreterDocument
    ) async {
        guard !isImporting else { return } // 重复点击防抖
        isImporting = true
        lastImportError = nil
        defer { isImporting = false }
        do {
            _ = try await operation()
            reload(conversationID: conversationID)
        } catch is CancellationError {
            // 取消不标失败。
        } catch let error as InterpreterDocumentService.ImportError {
            if error == .duplicateInConversation {
                // 同会话内 SHA-256 相同：诚实提示（用户可选择仍要导入）。
                lastImportError = "本次对话中已有相同文件；如需再次使用请先删除原文件"
            } else {
                lastImportError = error.errorDescription
            }
        } catch {
            lastImportError = error.localizedDescription
        }
    }

    // MARK: - 文档操作

    func deleteDocument(
        _ document: InterpreterDocument, conversationID: UUID?
    ) {
        // OCR 进行中删除：取消任务再删（状态由任务字典清理）。
        documentService.cancel(document.id)
        do {
            try repository.deleteInterpreterDocument(
                document, store: InterpreterDocumentStoreShared.store
            )
        } catch {
            Self.logger.error("delete document failed: \(error)")
        }
        reload(conversationID: conversationID)
    }

    func retryExtraction(_ document: InterpreterDocument) {
        documentService.startExtraction(document: document)
    }

    func runOCR(document: InterpreterDocument, pages: [Int] = []) {
        documentService.runOCR(document: document, pages: pages)
    }

    func cancelExtraction(_ document: InterpreterDocument) {
        documentService.cancel(document.id)
    }

    func setAllowsModelUse(_ document: InterpreterDocument, _ allows: Bool) {
        try? repository.updateInterpreterDocumentPreferences(
            document, allowsModelUse: allows, keepOriginalFile: nil
        )
    }

    /// 读取文档的提取结果（OCR 文本切换显示用）。
    func extraction(for document: InterpreterDocument) -> InterpreterDocumentExtraction? {
        InterpreterDocumentStoreShared.store?.readExtraction(documentID: document.id)
    }

    /// 失败页列表（部分提取语义）。
    func failedPages(for document: InterpreterDocument) -> [Int] {
        guard let extraction = extraction(for: document) else { return [] }
        return extraction.pages
            .filter { $0.ocrStatusRaw == InterpreterPageOCRStatus.failed.rawValue }
            .map(\.pageNumber)
    }

    /// 低置信度页（< 0.5 的 OCR 平均置信度）。
    func lowConfidencePages(for document: InterpreterDocument) -> [Int] {
        guard let extraction = extraction(for: document) else { return [] }
        return extraction.pages
            .filter { $0.ocrConfidence >= 0 && $0.ocrConfidence < 0.5 }
            .map(\.pageNumber)
    }

    // MARK: - 选择与构建 source

    /// 当前选中（或全部可用）chunk 的构建：用户选择优先，当前查看页
    /// 优先，词法匹配补充 —— 上限由 InterpreterDocumentChunker 执行。
    func availableChunks(
        for document: InterpreterDocument, question: String = ""
    ) -> [InterpreterDocumentChunker.Chunk] {
        guard document.allowsModelUse else { return [] }
        guard let extraction = extraction(for: document) else { return [] }
        let pages = selectedPages[document.id] ?? Set(extraction.pages.map(\.pageNumber))
        var chunks: [InterpreterDocumentChunker.Chunk] = []
        for page in extraction.pages where pages.contains(page.pageNumber) {
            chunks.append(contentsOf: InterpreterDocumentChunker.chunks(
                documentID: document.id,
                documentName: (document.originalFileName as NSString).deletingPathExtension,
                pageNumber: page.pageNumber,
                text: page.effectiveText
            ))
        }
        return chunks
    }

    /// 组装一次 AI 请求的 source 集（所有就绪文档的选中 chunk，受限额）。
    func requestSources(question: String) -> [InterpreterDocumentChunker.RequestSource] {
        let candidates = readyDocuments.flatMap { document in
            availableChunks(for: document, question: question)
        }
        let selected = InterpreterDocumentChunker.selectChunks(
            .init(
                chunks: candidates,
                selectedPages: Set(selectedPages.values.flatMap { $0 }),
                question: question
            )
        )
        return InterpreterDocumentChunker.requestSources(for: selected)
    }

    private var readyDocuments: [InterpreterDocument] {
        documents.filter {
            $0.allowsModelUse
                && ($0.status == .ready || $0.status == .partiallyExtracted)
        }
    }

    // MARK: - 发送前预览（隐私闸门）

    /// 打开发送前预览（默认遮盖敏感信息；用户可查看遮盖后文本并
    /// 选择发送未遮盖内容）。
    func buildPreview(
        question: String, action: PreviewAction
    ) -> Bool {
        let sources = requestSources(question: question)
        guard !sources.isEmpty else {
            lastAIError = "没有可发送的文件内容（先完成文字提取并允许模型使用）"
            return false
        }
        let (payload, masked) = InterpreterDocumentAIService.buildPreviewPayload(
            sources: sources, maskSensitive: true
        )
        previewSources = masked
        previewAction = action
        pendingPreview = SendPreview(
            sourceLines: payload.sourceLines,
            maskedSensitive: payload.maskedSensitive,
            sensitiveFindings: payload.sensitiveFindings,
            pendingQuestion: question,
            action: action
        )
        return true
    }

    /// 用户在预览中选择发送未遮盖内容。
    func useUnmaskedSources(question: String) {
        let sources = requestSources(question: question)
        previewSources = InterpreterDocumentChunker.requestSources(
            for: sources.map(\.chunk)
        )
        if pendingPreview != nil {
            let lines = previewSources.map { source in
                InterpreterDocumentPrompt.sourceLine(
                    sourceID: source.sourceID,
                    documentName: source.chunk.documentName,
                    pageNumber: source.chunk.pageNumber,
                    text: source.chunk.text
                )
            }
            pendingPreview?.sourceLines = lines
            pendingPreview?.maskedSensitive = false
            pendingPreview?.sensitiveFindings = []
        }
    }

    func cancelPreview() {
        pendingPreview = nil
        previewSources = []
    }

    /// 用户在预览中取消了某些 source 行（完整 chunk 为单位）—— 从
    /// 待发送集合中剔除。
    func excludeSources(_ sourceIDs: Set<String>) {
        previewSources = previewSources.filter { !sourceIDs.contains($0.sourceID) }
    }

    // MARK: - 多模态兜底（页面图像分析）

    /// 为多模态分析准备选定页面的受限尺寸副本。
    func prepareMultimodalImages(
        documents: [InterpreterDocument]
    ) async -> [ModelImagePayload] {
        var images: [ModelImagePayload] = []
        for document in documents {
            let pages = selectedPages[document.id] ?? []
            for page in pages.sorted() {
                if let image = await InterpreterDocumentAIService.preparePageImage(
                    documentID: document.id, pageNumber: page,
                    store: InterpreterDocumentStoreShared.store
                        ?? InterpreterDocumentStore(accountID: nil)
                ) {
                    images.append(image)
                }
            }
        }
        return Array(images.prefix(4)) // VisualAskImagePipeline 预算惯例
    }

    // MARK: - AI 动作（确认后执行 —— 结果沿 turn 链路）

    var currentPreviewSources: [InterpreterDocumentChunker.RequestSource] {
        previewSources
    }

    var currentPreviewAction: PreviewAction {
        previewAction
    }

    func resolveAIService() -> (any StudyReviewModelService)? {
        if let injected = aiServiceProvider(), injected != nil {
            return injected
        }
        return environment.studyServiceBoxForInterpreter?.get()
    }

    func resolveImageService() -> (any AttachmentAnalysisModelService)? {
        imageServiceProvider()
    }

    func setAsking(_ asking: Bool) {
        isAskingAI = asking
    }

    func clearAIError() {
        lastAIError = nil
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMdd-HHmm"
        return formatter.string(from: .now)
    }
}
