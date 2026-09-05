import CryptoKit
import Foundation
import OSLog

/// Chunk-level generation progress persisted on the material row
/// (`digestChunkStateJSON` — device-local, never synced), so an
/// interrupted digest run resumes exactly where it stopped.
struct MaterialDigestChunkState: Codable, Sendable, Equatable {
    struct Chunk: Codable, Sendable, Equatable {
        enum Status: String, Codable, Sendable {
            case pending, done, failed
        }

        var index: Int
        /// Page numbers of this chunk (whole pages only).
        var pageNumbers: [Int] = []
        var status: Status = .pending
        /// The model's chunk extraction (as returned, pages still raw
        /// numbers) — fed verbatim into the merge prompt.
        var extractionJSON: String?
    }

    /// SHA-256 of the effective page text at planning time (staleness:
    /// 资料内容已更新，可重新整理 is detected against this).
    var sourceHash: String = ""
    var chunks: [Chunk] = []

    var doneCount: Int { chunks.filter { $0.status == .done }.count }
    var hasAnyProgress: Bool { doneCount > 0 }

    static func decode(_ json: String) -> MaterialDigestChunkState? {
        guard !json.isEmpty, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MaterialDigestChunkState.self, from: data)
    }

    func encodedString() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Generation pipeline for material digests (导读):
///
///     plan chunks over pages (whole pages, char budget — persisted)
///     → per-chunk extraction over EFFECTIVE page text (each result
///       persisted on completion)
///     → scanned pages without text: bounded multimodal descriptions
///       (only when an image model is configured; never for text pages)
///     → merge (single call over all chunk extractions)
///     → validate pages + save (terminal state, sync-pushed)
///
/// The OLD digest survives until the new one succeeds — regeneration
/// never blanks content at the start. A failed chunk never aborts the
/// run (partial is resumable); cancellation leaves a resumable state.
/// The source hash recorded at planning time drives the honest
/// 资料内容已更新，可重新整理 hint (never an automatic re-run).
@MainActor
@Observable
final class MaterialDigestGenerator {
    private static let logger = Logger(
        subsystem: "com.livetranslate.ios", category: "material-digest"
    )

    /// Real pipeline progress for the UI.
    struct Progress: Equatable, Sendable {
        enum Stage: Equatable, Sendable {
            case preparing
            case extracting
            case describing   // 扫描页图片识别
            case merging
            case saving
        }

        var stage: Stage
        var done: Int
        var total: Int

        var label: String {
            switch stage {
            case .preparing:
                return "正在准备资料内容…"
            case .extracting:
                return total > 1
                    ? "正在整理第 \(min(done + 1, total))/\(total) 部分…"
                    : "正在整理资料内容…"
            case .describing:
                return "正在识别扫描页 \(done + 1)/\(total)…"
            case .merging:
                return "正在汇总资料导读…"
            case .saving:
                return "正在保存导读…"
            }
        }
    }

    enum GenerationError: LocalizedError, Equatable {
        case noContent
        case notConfigured

        var errorDescription: String? {
            switch self {
            case .noContent:
                return "这份资料还没有可整理的文字内容。"
            case .notConfigured:
                return "资料导读的模型服务尚未配置。"
            }
        }
    }

    /// Character budget per chunk (effective page text). A typical
    /// 40-page handout lands in 3–8 chunks.
    static let chunkCharBudget = 6_000
    /// Upper bound of scanned pages sent to the multimodal service per
    /// digest run (bounded cost; the rest stay honestly uncertain).
    static let imagePageBudget = 6

    private let repository: any ClassroomRepositoryProtocol
    private let textServiceProvider: () -> (any StudyReviewModelService)?
    private let imageServiceProvider: () -> (any AttachmentAnalysisModelService)?
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private(set) var progressByMaterial: [UUID: Progress] = [:]

    init(
        repository: any ClassroomRepositoryProtocol,
        textServiceProvider: @escaping () -> (any StudyReviewModelService)?,
        imageServiceProvider: @escaping () -> (any AttachmentAnalysisModelService)?
    ) {
        self.repository = repository
        self.textServiceProvider = textServiceProvider
        self.imageServiceProvider = imageServiceProvider
    }

    // MARK: - Task management

    func isActive(_ materialID: UUID) -> Bool {
        tasks[materialID] != nil
    }

    func progress(for materialID: UUID) -> Progress? {
        progressByMaterial[materialID]
    }

    func cancel(_ materialID: UUID) {
        tasks[materialID]?.cancel()
    }

    /// Launch-time reconciliation: an orphaned `analyzing` row becomes a
    /// resumable `partial` state (the UI offers 继续整理).
    func reconcileInterrupted() {
        guard let materials = try? repository.materials(courseID: nil) else { return }
        for material in materials where material.digestStatus == .analyzing {
            try? repository.markMaterialDigestInterrupted(material)
        }
    }

    // MARK: - Chunk planning (pure, testable)

    /// Greedy chunk plan over pages that carry usable text: whole pages
    /// only, adjacent pages stay together, an oversized page becomes its
    /// own chunk. The plan also records the source hash so a later edit
    /// of the material is detectable.
    static func chunkPlan(
        pages: [(pageNumber: Int, text: String)], sourceHash: String,
        charBudget: Int = chunkCharBudget
    ) -> MaterialDigestChunkState {
        var state = MaterialDigestChunkState()
        state.sourceHash = sourceHash
        let usable = pages.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        var current: [Int] = []
        var currentChars = 0
        var index = 0
        for page in usable {
            let cost = page.text.count
            if !current.isEmpty && currentChars + cost > charBudget {
                state.chunks.append(.init(index: index, pageNumbers: current, status: .pending))
                index += 1
                current = []
                currentChars = 0
            }
            current.append(page.pageNumber)
            currentChars += cost
        }
        if !current.isEmpty {
            state.chunks.append(.init(index: index, pageNumbers: current, status: .pending))
        }
        return state
    }

    // MARK: - Generation

    /// Starts (or resumes) digest generation for one material. `resume`
    /// keeps the existing chunk plan and re-runs only pending/failed
    /// chunks.
    func generate(material: CourseMaterial, resume: Bool) {
        let materialID = material.id
        guard tasks[materialID] == nil else { return }
        progressByMaterial[materialID] = Progress(stage: .preparing, done: 0, total: 0)
        tasks[materialID] = Task { [weak self] in
            await self?.run(materialID: materialID, resume: resume)
            self?.tasks[materialID] = nil
        }
    }

    private func run(materialID: UUID, resume: Bool) async {
        guard let material = try? repository.material(id: materialID) else { return }
        do {
            guard let textService = textServiceProvider(), textService.isConfiguredNow else {
                throw GenerationError.notConfigured
            }
            let pages = (try? repository.materialPages(materialID: materialID)) ?? []
            let pageMaterials = pages.map { page in
                MaterialDigestPrompt.PageMaterial(
                    pageNumber: page.pageNumber,
                    text: page.effectiveText,
                    isImagePage: page.effectiveText.isEmpty
                )
            }
            // Source hash over the effective text (the content the digest
            // is grounded in) — extracted + OCR both count.
            let sourceHash = Self.sourceHash(of: pageMaterials)

            var chunkState: MaterialDigestChunkState
            if !resume, let existing = MaterialDigestChunkState.decode(material.digestChunkStateJSON),
               existing.sourceHash == sourceHash, existing.hasAnyProgress {
                // A same-content resume is indistinguishable from resume.
                chunkState = existing
            } else if resume,
                      let existing = MaterialDigestChunkState.decode(material.digestChunkStateJSON),
                      existing.sourceHash == sourceHash {
                chunkState = existing
            } else {
                chunkState = Self.chunkPlan(
                    pages: pageMaterials.map { ($0.pageNumber, $0.text) },
                    sourceHash: sourceHash
                )
                guard !chunkState.chunks.isEmpty else {
                    throw GenerationError.noContent
                }
                try repository.beginMaterialDigestGeneration(
                    material, chunkStateJSON: chunkState.encodedString() ?? ""
                )
            }

            let context = MaterialDigestPrompt.MaterialContext(
                materialTitle: material.title,
                courseName: Self.courseName(
                    courseID: material.courseID, repository: repository
                ),
                kindName: material.kind.displayName,
                pageCount: max(material.pageCount, 1)
            )

            // ---- Chunk extraction --------------------------------------
            progressByMaterial[materialID] = Progress(
                stage: .extracting, done: chunkState.doneCount, total: chunkState.chunks.count
            )
            for chunkIndex in chunkState.chunks.indices {
                guard chunkState.chunks[chunkIndex].status != .done else { continue }
                let chunk = chunkState.chunks[chunkIndex]
                let chunkPages = pageMaterials.filter { chunk.pageNumbers.contains($0.pageNumber) }
                let userPrompt = MaterialDigestPrompt.extractionUserPrompt(
                    context: context, pages: chunkPages
                )
                do {
                    let raw = try await AICallScope.with(
                        AICallContext(feature: .materialDigest, textCategory: .ocr)
                    ) {
                        try await textService.complete(
                            systemPrompt: MaterialDigestPrompt.extractionSystemPrompt(),
                            userPrompt: userPrompt,
                            maxTokens: 2_400
                        )
                    }
                    let normalized = try MaterialDigestParser.normalizeExtraction(raw)
                    chunkState.chunks[chunkIndex].extractionJSON = normalized
                    chunkState.chunks[chunkIndex].status = .done
                } catch is CancellationError {
                    try? persistProgress(material, chunkState: chunkState, terminal: nil)
                    try? repository.markMaterialDigestInterrupted(material)
                    progressByMaterial[materialID] = nil
                    return
                } catch {
                    // A failed chunk never aborts the whole run.
                    chunkState.chunks[chunkIndex].status = .failed
                    chunkState.chunks[chunkIndex].extractionJSON = nil
                    Self.logger.error(
                        "digest chunk \(chunk.index) failed: \(String(describing: error), privacy: .public)"
                    )
                }
                progressByMaterial[materialID] = Progress(
                    stage: .extracting, done: chunkState.doneCount, total: chunkState.chunks.count
                )
                try? persistProgress(material, chunkState: chunkState, terminal: nil)
            }

            guard !Task.isCancelled else { return }

            let failedChunks = chunkState.chunks.filter { $0.status == .failed }
            if !failedChunks.isEmpty {
                try? persistProgress(material, chunkState: chunkState, terminal: .partial)
                progressByMaterial[materialID] = nil
                return
            }

            // ---- Scanned-page descriptions (bounded, optional) ---------
            var imageObservations: [(pageNumber: Int, json: String)] = []
            let emptyPages = pageMaterials.filter(\.isImagePage).prefix(Self.imagePageBudget)
            if let first = emptyPages.first,
               let imageService = imageServiceProvider(),
               imageService.isConfiguredNow,
               let imageData = imagePageData(material: material, pageNumber: first.pageNumber) {
                progressByMaterial[materialID] = Progress(
                    stage: .describing, done: 0, total: emptyPages.count
                )
                // One representative scanned page per digest run (bounded
                // payload); the remaining empty pages stay honestly
                // uncertain in the digest.
                let pageNumber = first.pageNumber
                let raw = try? await AICallScope.with(
                    AICallContext(feature: .materialDigest, textCategory: .none)
                ) {
                    try await imageService.complete(
                        systemPrompt: MaterialDigestPrompt.imagePageSystemPrompt(),
                        userPrompt: MaterialDigestPrompt.imagePageUserPrompt(
                            pageNumber: pageNumber
                        ),
                        imageData: imageData,
                        imageMIME: "image/jpeg",
                        maxTokens: 1_200
                    )
                }
                if let raw, let parsed = MaterialDigestParser.parseImagePage(text: raw) {
                    imageObservations.append((pageNumber, Self.imageObservationJSON(parsed)))
                }
            }

            // ---- Merge ---------------------------------------------------
            guard !Task.isCancelled else { return }
            progressByMaterial[materialID] = Progress(
                stage: .merging, done: chunkState.chunks.count, total: chunkState.chunks.count
            )
            let extractions = chunkState.chunks.compactMap(\.extractionJSON)
            let mergePrompt = MaterialDigestPrompt.mergeUserPrompt(
                context: context,
                chunkExtractions: extractions,
                imagePageObservations: imageObservations
            )
            let mergedRaw: String
            do {
                mergedRaw = try await AICallScope.with(
                    AICallContext(feature: .materialDigest, textCategory: .ocr)
                ) {
                    try await textService.complete(
                        systemPrompt: MaterialDigestPrompt.mergeSystemPrompt(),
                        userPrompt: mergePrompt,
                        maxTokens: 4_096
                    )
                }
            } catch is CancellationError {
                try? persistProgress(material, chunkState: chunkState, terminal: .partial)
                try? repository.markMaterialDigestInterrupted(material)
                progressByMaterial[materialID] = nil
                return
            }
            let digest = try MaterialDigestParser.parse(
                text: mergedRaw, pageCount: max(material.pageCount, 1)
            )

            // ---- Save ----------------------------------------------------
            progressByMaterial[materialID] = Progress(
                stage: .saving, done: chunkState.chunks.count, total: chunkState.chunks.count
            )
            try repository.completeMaterialDigestGeneration(
                material,
                digest: digest,
                model: Self.textModelName(textService),
                sourceHash: sourceHash
            )
            progressByMaterial[materialID] = nil
            Self.logger.info(
                "digest generation completed (material=\(materialID.uuidString, privacy: .public))"
            )
        } catch {
            if let material = try? repository.material(id: materialID) {
                let hasProgress = MaterialDigestChunkState
                    .decode(material.digestChunkStateJSON)?.hasAnyProgress ?? false
                if hasProgress {
                    try? repository.updateMaterialDigestProgress(
                        material, chunkStateJSON: material.digestChunkStateJSON, terminal: .partial
                    )
                } else {
                    try? repository.failMaterialDigestGeneration(material)
                }
            }
            progressByMaterial[materialID] = nil
            Self.logger.error(
                "digest generation failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    // MARK: - Stage helpers

    private func persistProgress(
        _ material: CourseMaterial, chunkState: MaterialDigestChunkState,
        terminal: MaterialDigestStatus?
    ) throws {
        guard let json = chunkState.encodedString() else { return }
        try repository.updateMaterialDigestProgress(
            material, chunkStateJSON: json, terminal: terminal
        )
    }

    /// Whether the material's content changed since its digest was
    /// generated (drives 资料内容已更新，可重新整理 — never auto-runs).
    func isDigestStale(_ material: CourseMaterial) -> Bool {
        guard !material.digestJSON.isEmpty else { return false }
        let pages = (try? repository.materialPages(materialID: material.id)) ?? []
        let hash = Self.sourceHash(of: pages.map {
            MaterialDigestPrompt.PageMaterial(
                pageNumber: $0.pageNumber, text: $0.effectiveText, isImagePage: false
            )
        })
        return !material.digestSourceHash.isEmpty && material.digestSourceHash != hash
    }

    static func sourceHash(of pages: [MaterialDigestPrompt.PageMaterial]) -> String {
        let joined = pages.map { "\($0.pageNumber):\($0.text)" }.joined(separator: "\n")
        let digest = Insecure.SHA1.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func textModelName(_ service: any StudyReviewModelService) -> String {
        (service as? OpenAICompatibleStudyService)?.config.model ?? ""
    }

    /// Course display name for the prompt context (display-only).
    private static func courseName(
        courseID: UUID?, repository: any ClassroomRepositoryProtocol
    ) -> String {
        guard let courseID, let course = try? repository.course(id: courseID) else {
            return ""
        }
        return course.name
    }

    /// One page image (JPEG, bounded) for the multimodal description of
    /// a text-empty page: PDF pages reuse the extraction-time thumbnail
    /// (bounded by construction); image materials use their own bytes or
    /// the borrowed attachment's analysis copy. Never re-renders large
    /// originals.
    private func imagePageData(material: CourseMaterial, pageNumber: Int) -> Data? {
        guard let store = MaterialFileStoreShared.store else { return nil }
        switch material.format {
        case .image:
            if let attachmentID = material.sourceAttachmentID,
               let attachment = try? repository.attachment(id: attachmentID) {
                return AttachmentFileStoreShared.store?.analysisData(
                    for: attachment.id, sessionID: attachment.sessionID
                )
            }
            let ext = MaterialFileStore.fileExtension(
                fileName: material.originalFileName, mime: material.mimeType
            )
            return store.originalData(materialID: material.id, fileExtension: ext)
        default:
            return store.pageThumbnailData(materialID: material.id, pageNumber: pageNumber)
        }
    }

    private static func imageObservationJSON(
        _ parsed: MaterialDigestParser.RawImagePage
    ) -> String {
        struct Observation: Codable {
            var text: String
            var uncertainties: [String]?
        }
        let observation = Observation(
            text: parsed.text ?? "", uncertainties: parsed.uncertainties
        )
        guard let data = try? JSONEncoder().encode(observation),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }
}
