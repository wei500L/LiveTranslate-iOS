import Foundation
import OSLog

/// Generation pipeline for study reviews:
///
///     prepare (chunk plan, persisted)
///     → per-chunk extraction (each result persisted on completion)
///     → merge (single call over all chunk extractions)
///     → validate + save (terminal state, sync-pushed)
///
/// Crash/interrupt safety: every stage persists its progress on the review
/// row (`chunkStateJSON`). A relaunch that finds `status == .generating`
/// with no active task is converted by `markInterrupted` into a resumable
/// `partial` state — the UI offers 继续整理 (re-runs pending/failed chunks
/// only) or 重新整理. Progress comes from real pipeline steps, never a
/// timer.
@MainActor
@Observable
final class StudyReviewGenerator {
    private static let logger = Logger(
        subsystem: "com.livetranslate.ios", category: "study-review"
    )

    /// Real pipeline progress for the UI.
    struct Progress: Equatable, Sendable {
        enum Stage: Equatable, Sendable {
            case preparing
            case extracting
            case merging
            case saving
        }

        var stage: Stage
        /// Extracted chunks so far / total chunks (other stages: total = 0).
        var done: Int
        var total: Int

        /// User-facing description without technical vocabulary.
        var label: String {
            switch stage {
            case .preparing:
                return "正在准备课堂内容…"
            case .extracting:
                return total > 1 ? "正在整理第 \(min(done + 1, total))/\(total) 部分…" : "正在整理课堂内容…"
            case .merging:
                return "正在合并课堂内容…"
            case .saving:
                return "正在保存结果…"
            }
        }
    }

    enum GenerationError: LocalizedError, Equatable {
        /// Nothing in the session is worth sending (all entries blank).
        case noContent
        /// The model service is not configured.
        case notConfigured

        var errorDescription: String? {
            switch self {
            case .noContent:
                return "这堂课没有可整理的文字内容。"
            case .notConfigured:
                return "课后整理的模型服务尚未配置。"
            }
        }
    }

    /// Character budget per chunk (Russian + Chinese combined). A typical
    /// 90-minute class lands in 4–10 chunks.
    static let chunkCharBudget = 6_000

    private let repository: any ClassroomRepositoryProtocol
    private let serviceProvider: () -> (any StudyReviewModelService)?
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private(set) var progressBySession: [UUID: Progress] = [:]

    init(
        repository: any ClassroomRepositoryProtocol,
        serviceProvider: @escaping () -> (any StudyReviewModelService)?
    ) {
        self.repository = repository
        self.serviceProvider = serviceProvider
    }

    // MARK: - Task management

    func isActive(_ sessionID: UUID) -> Bool {
        tasks[sessionID] != nil
    }

    func progress(for sessionID: UUID) -> Progress? {
        progressBySession[sessionID]
    }

    func cancel(_ sessionID: UUID) {
        tasks[sessionID]?.cancel()
    }

    // MARK: - Chunk planning (pure, testable)

    /// Greedy chunk plan over the entries that carry usable text: whole
    /// entries only (never mid-sentence), adjacent entries stay together,
    /// an oversized entry becomes its own chunk. Citation numbers are
    /// global (1-based index into `citationIDs`).
    static func chunkPlan(entries: [TranscriptEntry], charBudget: Int = chunkCharBudget) -> StudyChunkState {
        let usable = entries.filter { entry in
            !entry.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !(entry.translatedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        var state = StudyChunkState()
        state.citationIDs = usable.map(\.id)

        var current: [UUID] = []
        var currentChars = 0
        var firstCitation = 1
        var index = 0
        for (position, entry) in usable.enumerated() {
            let russian = entry.originalText
            let chinese = entry.translatedText ?? ""
            let cost = russian.count + chinese.count
            if !current.isEmpty && currentChars + cost > charBudget {
                state.chunks.append(.init(
                    index: index, entryIDs: current, firstCitation: firstCitation, status: .pending
                ))
                index += 1
                firstCitation = position + 1
                current = []
                currentChars = 0
            }
            current.append(entry.id)
            currentChars += cost
        }
        if !current.isEmpty {
            state.chunks.append(.init(
                index: index, entryIDs: current, firstCitation: firstCitation, status: .pending
            ))
        }
        return state
    }

    // MARK: - Generation

    /// Starts (or resumes) generation for one session. `resume == true`
    /// keeps the existing chunk plan and re-runs only pending/failed
    /// chunks, then merges. The user's additions from the current content
    /// always survive a regeneration.
    func generate(
        session: ClassroomSession,
        context: StudyReviewPrompt.ClassContext,
        notes: [String],
        entries: [TranscriptEntry],
        resume: Bool
    ) {
        let sessionID = session.id
        guard tasks[sessionID] == nil else { return }
        progressBySession[sessionID] = Progress(stage: .preparing, done: 0, total: 0)
        tasks[sessionID] = Task { [weak self] in
            await self?.run(
                session: session, context: context, notes: notes, entries: entries, resume: resume
            )
            // run() clears the session's progress on every exit path.
            self?.tasks[sessionID] = nil
        }
    }

    private func run(
        session: ClassroomSession,
        context: StudyReviewPrompt.ClassContext,
        notes: [String],
        entries: [TranscriptEntry],
        resume: Bool
    ) async {
        let sessionID = session.id
        do {
            guard let service = serviceProvider(), service.isConfiguredNow else {
                throw GenerationError.notConfigured
            }
            let review = try prepareReview(
                session: session, entries: entries, resume: resume
            )
            guard var chunkState = StudyChunkState.decode(review.chunkStateJSON),
                  !chunkState.chunks.isEmpty else {
                throw GenerationError.noContent
            }

            // ---- Chunk extraction --------------------------------------
            progressBySession[sessionID] = Progress(
                stage: .extracting, done: chunkState.doneCount, total: chunkState.chunks.count
            )
            let entriesByID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for chunkIndex in chunkState.chunks.indices {
                guard chunkState.chunks[chunkIndex].status != .done else { continue }
                let chunk = chunkState.chunks[chunkIndex]
                let materials: [StudyReviewPrompt.EntryMaterial] = chunk.entryIDs.enumerated().compactMap { offset, entryID in
                    guard let entry = entriesByID[entryID] else { return nil }
                    return StudyReviewPrompt.EntryMaterial(
                        citation: chunk.firstCitation + offset,
                        timestamp: TranscriptExporter.mmss(entry.startOffset),
                        russian: entry.originalText,
                        chinese: entry.translatedText
                    )
                }
                let userPrompt = StudyReviewPrompt.extractionUserPrompt(
                    context: context, entries: materials, notes: notes
                )
                do {
                    let raw = try await service.complete(
                        systemPrompt: StudyReviewPrompt.extractionSystemPrompt(),
                        userPrompt: userPrompt,
                        maxTokens: 2_400
                    )
                    let normalized = try StudyReviewParser.normalizeExtraction(raw)
                    chunkState.chunks[chunkIndex].extractionJSON = normalized
                    chunkState.chunks[chunkIndex].status = .done
                } catch is CancellationError {
                    // Leave the chunk pending so a resume re-runs it.
                    try? persistProgress(review, chunkState: chunkState, terminal: nil)
                    try? repository.markStudyReviewInterrupted(review)
                    progressBySession[sessionID] = nil
                    Self.logger.info("review generation cancelled (session=\(sessionID.uuidString, privacy: .public))")
                    return
                } catch {
                    // A failed chunk never aborts the whole run — the
                    // others keep going and the user can retry this one.
                    chunkState.chunks[chunkIndex].status = .failed
                    chunkState.chunks[chunkIndex].extractionJSON = nil
                    Self.logger.error(
                        "chunk \(chunk.index) extraction failed: \(String(describing: error), privacy: .public)"
                    )
                }
                progressBySession[sessionID] = Progress(
                    stage: .extracting, done: chunkState.doneCount, total: chunkState.chunks.count
                )
                try? persistProgress(review, chunkState: chunkState, terminal: nil)
            }

            guard !Task.isCancelled else { return }

            let failedChunks = chunkState.chunks.filter { $0.status == .failed }
            if !failedChunks.isEmpty {
                // Partial: keep every completed chunk, mark the state so
                // the UI offers 继续整理 (retry the failed chunks).
                try? persistProgress(
                    review, chunkState: chunkState, terminal: .partial
                )
                progressBySession[sessionID] = nil
                return
            }

            // ---- Merge ---------------------------------------------------
            progressBySession[sessionID] = Progress(
                stage: .merging, done: chunkState.chunks.count, total: chunkState.chunks.count
            )
            let extractions = chunkState.chunks.compactMap(\.extractionJSON)
            let mergePrompt = StudyReviewPrompt.mergeUserPrompt(
                context: context, chunkExtractions: extractions, notes: notes
            )
            let mergedRaw: String
            do {
                mergedRaw = try await service.complete(
                    systemPrompt: StudyReviewPrompt.mergeSystemPrompt(),
                    userPrompt: mergePrompt,
                    maxTokens: 4_096
                )
            } catch is CancellationError {
                try? persistProgress(review, chunkState: chunkState, terminal: .partial)
                try? repository.markStudyReviewInterrupted(review)
                progressBySession[sessionID] = nil
                return
            }
            var content = try StudyReviewParser.parse(text: mergedRaw, citationIDs: chunkState.citationIDs)
            // The user's own additions always survive a regeneration.
            if let old = StudyReviewContent.decode(review.contentJSON), !old.userNotes.isEmpty {
                content.userNotes = old.userNotes
            }

            // ---- Save ----------------------------------------------------
            progressBySession[sessionID] = Progress(
                stage: .saving, done: chunkState.chunks.count, total: chunkState.chunks.count
            )
            try repository.completeStudyReviewGeneration(
                review,
                content: content,
                model: serviceModelName(service),
                sourceUpdatedAt: session.updatedAt
            )
            progressBySession[sessionID] = nil
            Self.logger.info("review generation completed (session=\(sessionID.uuidString, privacy: .public))")
        } catch {
            // Fatal pipeline error. Keep whatever chunk progress exists in
            // a RESUMABLE state (partial) — only a run with no progress at
            // all becomes failed.
            if let review = try? repository.studyReview(forSessionID: sessionID) {
                let hasProgress = StudyChunkState.decode(review.chunkStateJSON)?.hasAnyProgress ?? false
                if hasProgress {
                    try? repository.updateStudyReviewProgress(
                        review, chunkStateJSON: review.chunkStateJSON, terminal: .partial
                    )
                } else {
                    try? repository.failStudyReviewGeneration(review)
                }
            }
            progressBySession[sessionID] = nil
            Self.logger.error(
                "review generation failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    // MARK: - Stage helpers

    /// Fetches or creates the review row; on a fresh run writes a new
    /// chunk plan, on resume keeps the persisted one.
    private func prepareReview(
        session: ClassroomSession, entries: [TranscriptEntry], resume: Bool
    ) throws -> StudyReview {
        let review = try repository.ensureStudyReview(forSessionID: session.id)
        if !resume {
            let plan = Self.chunkPlan(entries: entries)
            guard !plan.chunks.isEmpty else {
                throw GenerationError.noContent
            }
            try repository.beginStudyReviewGeneration(review, chunkState: plan)
        } else if StudyChunkState.decode(review.chunkStateJSON)?.hasAnyProgress != true {
            // Nothing to resume from — start over with a fresh plan.
            let plan = Self.chunkPlan(entries: entries)
            guard !plan.chunks.isEmpty else {
                throw GenerationError.noContent
            }
            try repository.beginStudyReviewGeneration(review, chunkState: plan)
        }
        return review
    }

    /// Persists chunk progress; `terminal != nil` also writes the review
    /// status (partial/failed). Intermediate writes never touch the sync
    /// observer — generation progress is device-local.
    private func persistProgress(
        _ review: StudyReview, chunkState: StudyChunkState, terminal: StudyReviewStatus?
    ) throws {
        guard let json = chunkState.encodedString() else { return }
        try repository.updateStudyReviewProgress(review, chunkStateJSON: json, terminal: terminal)
    }

    private func serviceModelName(_ service: any StudyReviewModelService) -> String {
        // The concrete config carries the model name; the protocol only
        // exposes behavior, so this is display-only best effort.
        (service as? OpenAICompatibleStudyService)?.config.model ?? ""
    }
}
