import Foundation
import OSLog

/// Orchestrates multimodal analysis of session attachments. One generator
/// per profile (owned by AppEnvironment), same lifetime pattern as
/// StudyReviewGenerator: it owns in-flight tasks keyed by attachment id,
/// reports REAL progress states (no fake percentages), and survives view
/// churn.
///
/// Semantics:
///   - Sequential per-session batches (a class worth of photos is a few
///     requests, not a parallel storm);
///   - each image is an independent unit — one failure never aborts the
///     batch, and retry re-runs only the failed images;
///   - cancellation stops at the next image boundary and leaves already
///     completed results on the rows;
///   - an orphaned `analyzing` row (app killed) is reconciled back to a
///     restorable state at the next launch;
///   - the two user-facing modes are `imageOnly` (仅理解图片) and
///     `withClassContext` (结合课堂讲解整理) — no tokens, windows or
///     model jargon surface in the UI.
@MainActor
@Observable
final class AttachmentAnalysisGenerator {
    static let logger = Logger(subsystem: "com.livetranslate.ios", category: "attachment-analysis")

    /// How the model is asked to treat classroom context.
    enum Mode: String, Sendable, CaseIterable, Identifiable {
        case imageOnly
        case withClassContext

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .imageOnly: return String(localized: "仅理解图片")
            case .withClassContext: return String(localized: "结合课堂讲解")
            }
        }

        var explanation: String {
            switch self {
            case .imageOnly:
                return String(localized: "只分析图片本身的内容")
            case .withClassContext:
                return String(localized: "结合拍摄时附近的转录与笔记一起理解")
            }
        }
    }

    /// Real per-attachment progress states surfaced to the UI.
    enum ProgressState: Equatable, Sendable {
        case waiting       // queued in the current batch
        case analyzing
        case completed
        case partial
        case failed(String)
        case cancelled
    }

    private let repository: any ClassroomRepositoryProtocol
    private let fileStore: () -> AttachmentFileStore?
    private let serviceProvider: () -> (any AttachmentAnalysisModelService)?
    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Batch-level progress (attachmentID → latest state).
    private(set) var progressByID: [UUID: ProgressState] = [:]

    init(
        repository: any ClassroomRepositoryProtocol,
        fileStore: @escaping () -> AttachmentFileStore?,
        serviceProvider: @escaping () -> (any AttachmentAnalysisModelService)?
    ) {
        self.repository = repository
        self.fileStore = fileStore
        self.serviceProvider = serviceProvider
    }

    var isAnalyzing: Bool { !tasks.isEmpty }

    // MARK: - Public API

    /// Analyzes a batch of attachments sequentially. Each image is an
    /// independent unit: failures isolate, retry covers only failed ones,
    /// and cancellation stops at the next image boundary.
    func analyze(
        _ attachments: [SessionAttachment], mode: Mode,
        context: @escaping AttachmentAnalysisContextProvider
    ) {
        let ids = attachments.map(\.id)
        guard !ids.isEmpty else { return }
        // One task per batch entry — a shared batch task would let one
        // slow image block retry of a failed sibling.
        for attachment in attachments {
            guard tasks[attachment.id] == nil else { continue }
            progressByID[attachment.id] = .waiting
            let id = attachment.id
            tasks[id] = Task { [weak self] in
                await self?.runOne(
                    attachmentID: id, mode: mode, context: context
                )
                self?.tasks[id] = nil
            }
        }
    }

    /// Cancels the in-flight analyses of the given attachments (or all
    /// when nil). Completed results stay on their rows.
    func cancel(attachmentIDs: [UUID]? = nil) {
        let target = attachmentIDs ?? Array(tasks.keys)
        for id in target {
            tasks[id]?.cancel()
        }
    }

    /// Launch-time reconciliation: a row left in `analyzing` by an app
    /// kill becomes `pending` again — analysis can simply be restarted
    /// (idempotent, no fake progress states persist).
    func reconcileInterruptedAnalyses() {
        guard let all = try? repository.allAttachments() else { return }
        for attachment in all where attachment.analysisStatus == .analyzing {
            if let result = AttachmentAnalysisResult.decode(attachment.analysisJSON) {
                // Has a previous result underneath — keep it, mark partial
                // (the interrupted run never completed over it).
                try? repository.updateAttachmentAnalysisProgress(attachment, status: .partial)
            } else {
                try? repository.updateAttachmentAnalysisProgress(attachment, status: .pending)
            }
        }
    }

    // MARK: - One image

    private func runOne(
        attachmentID: UUID, mode: Mode, context: AttachmentAnalysisContextProvider
    ) async {
        guard !Task.isCancelled else {
            progressByID[attachmentID] = .cancelled
            return
        }
        let attachment: SessionAttachment?
        do {
            attachment = try repository.attachment(id: attachmentID)
        } catch {
            attachment = nil
        }
        guard let attachment else {
            progressByID[attachmentID] = .failed(String(localized: "附件不存在"))
            return
        }
        guard let service = serviceProvider(), service.isConfiguredNow else {
            try? repository.failAttachmentAnalysis(attachment)
            progressByID[attachmentID] = .failed(String(localized: "图片理解模型未配置"))
            return
        }
        guard let store = fileStore(),
              let imageData = store.analysisData(
                  for: attachment.id, sessionID: attachment.sessionID
              ) else {
            try? repository.failAttachmentAnalysis(attachment)
            progressByID[attachmentID] = .failed(String(localized: "本地图片文件缺失"))
            return
        }

        progressByID[attachmentID] = .analyzing
        // Device-local progress marker (never synced; reconciled at launch).
        try? repository.updateAttachmentAnalysisProgress(attachment, status: .analyzing)

        do {
            let promptContext = context(
                attachment, mode == .withClassContext
            )
            let promptContextString = promptContext.promptContext
            let raw = try await AICallScope.with(
                AICallContext(feature: .attachmentAnalysis, textCategory: .transcript)
            ) {
                try await service.complete(
                    systemPrompt: AttachmentAnalysisPrompt.systemPrompt(),
                    userPrompt: AttachmentAnalysisPrompt.userPrompt(context: promptContextString),
                    imageData: imageData,
                    imageMIME: "image/jpeg",
                    maxTokens: 2_400
                )
            }
            if Task.isCancelled {
                progressByID[attachmentID] = .cancelled
                return
            }
            let result = try AttachmentAnalysisParser.parse(
                text: raw, citationIDs: promptContext.citationIDs
            )
            // A result that only carries an explanation (no visible
            // content, no formulas, no code, no points) is a degraded
            // parse — partial, not completed.
            let hasCore = !(result.visibleText ?? []).isEmpty
                || !(result.formulas ?? []).isEmpty
                || !(result.codeBlocks ?? []).isEmpty
                || !(result.keyPoints ?? []).isEmpty
            let status: AttachmentAnalysisStatus = hasCore ? .completed : .partial
            try repository.completeAttachmentAnalysis(
                attachment, result: result, status: status
            )
            progressByID[attachmentID] = (status == .completed) ? .completed : .partial
        } catch is CancellationError {
            // Leave the previous result (if any); back to a restorable state.
            if AttachmentAnalysisResult.decode(attachment.analysisJSON) != nil {
                try? repository.updateAttachmentAnalysisProgress(attachment, status: .partial)
            } else {
                try? repository.updateAttachmentAnalysisProgress(attachment, status: .pending)
            }
            progressByID[attachmentID] = .cancelled
        } catch {
            Self.logger.error("attachment analysis failed: \(String(describing: error), privacy: .public)")
            try? repository.failAttachmentAnalysis(attachment)
            let message = (error as? LocalizedError)?.errorDescription
                ?? String(localized: "分析失败")
            progressByID[attachmentID] = .failed(message)
        }
    }
}

/// Supplies the (bounded) classroom context for one attachment's analysis.
/// Built on the main actor by the caller (the repository is main-actor);
/// returns both the prompt context and the citation id map.
typealias AttachmentAnalysisContextProvider =
    @MainActor (SessionAttachment, _ includeClassContext: Bool)
        -> AttachmentAnalysisPromptContextBundle

struct AttachmentAnalysisPromptContextBundle: Sendable {
    var promptContext: AttachmentAnalysisPrompt.Context
    /// Global 1-based citation numbers → real entry ids (parser validates
    /// against this).
    var citationIDs: [UUID]
}
