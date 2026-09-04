import Foundation
import OSLog
import PDFKit
import UIKit
import Vision

/// Text-extraction pipeline for course materials:
///
///     classify (PDF / text file / image)
///     → PDF: stream pages in BATCHES off the main actor (text layer +
///       ~600px thumbnail per page), persist page rows + thumbnails as
///       each batch lands (a 300-page PDF never loads whole)
///     → text file: one page row with the full text (bounded read)
///     → image: one empty-text page row (Vision OCR runs on demand,
///       page by page, with real persisted progress)
///
/// Crash/interrupt safety mirrors StudyReviewGenerator: an interrupted
/// run leaves the material `partial` (resumable — pages that already
/// have text are skipped) or `failed` (nothing landed). Progress comes
/// from real pipeline stages, never a timer.
@MainActor
@Observable
final class MaterialExtractionRunner {
    private static let logger = Logger(
        subsystem: "com.livetranslate.ios", category: "material-extraction"
    )

    /// Real pipeline progress for the UI.
    struct Progress: Equatable, Sendable {
        enum Stage: Equatable, Sendable {
            case extracting   // 页面文本提取
            case ocr          // 逐页识别
        }

        var stage: Stage
        var done: Int
        var total: Int

        var label: String {
            switch stage {
            case .extracting:
                return total > 0
                    ? "正在读取第 \(min(done + 1, total))/\(total) 页…"
                    : "正在读取资料内容…"
            case .ocr:
                return total > 1
                    ? "正在识别第 \(min(done + 1, total))/\(total) 页…"
                    : "正在识别页面文字…"
            }
        }
    }

    /// Pages per PDF batch (PDFKit work happens detached; each batch
    /// re-opens the document so PDFDocument never crosses actors).
    static let pdfBatchSize = 8
    /// Upper bound for a text-file read (larger files truncate honestly).
    static let textFileByteLimit = 5_000_000

    private let repository: any ClassroomRepositoryProtocol
    private let fileStore: () -> MaterialFileStore?
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private(set) var progressByMaterial: [UUID: Progress] = [:]

    init(
        repository: any ClassroomRepositoryProtocol,
        fileStore: @escaping () -> MaterialFileStore?
    ) {
        self.repository = repository
        self.fileStore = fileStore
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

    // MARK: - Launch

    /// Starts (or resumes) extraction for one material. Resume skips
    /// pages that already carry extracted text.
    func start(material: CourseMaterial, resume: Bool = false) {
        guard tasks[material.id] == nil else { return }
        let materialID = material.id
        tasks[materialID] = Task { [weak self] in
            await self?.run(materialID: materialID, resume: resume)
            self?.tasks[materialID] = nil
        }
    }

    /// Launch-time reconciliation: an orphaned `extracting` row (the app
    /// was killed mid-run) becomes resumable `partial` when any page
    /// landed, else `failed`.
    func reconcileInterrupted() {
        guard let materials = try? repository.materials(courseID: nil) else { return }
        for material in materials where material.extractionStatus == .extracting {
            try? repository.markMaterialExtractionInterrupted(material)
        }
    }

    // MARK: - Run

    private func run(materialID: UUID, resume: Bool) async {
        guard let material = try? repository.material(id: materialID) else { return }
        switch material.format {
        case .pdf:
            await runPDF(material: material, resume: resume)
        case .text, .markdown:
            runTextFile(material: material)
        case .image:
            runImage(material: material)
        case .other:
            // Nothing to extract — the import already marked it
            // unsupported. Keep the row honest.
            try? repository.finishMaterialExtraction(material, status: .unsupported)
        }
    }

    private func runPDF(material: CourseMaterial, resume: Bool) async {
        let materialID = material.id
        guard let store = fileStore() else { return }
        let ext = MaterialFileStore.fileExtension(
            fileName: material.originalFileName, mime: material.mimeType
        )
        let fileURL = store.originalURL(materialID: materialID, fileExtension: ext)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            try? repository.finishMaterialExtraction(material, status: .failed)
            return
        }

        // Existing pages let a resume skip finished work (a page with a
        // non-empty text layer is final; scanned pages legitimately have
        // empty text and re-extract — there is nothing to skip).
        let existingPages = (try? repository.materialPages(materialID: materialID)) ?? []
        let donePageNumbers = resume
            ? Set(existingPages.filter { !$0.extractedText.isEmpty }.map(\.pageNumber))
            : []

        let pageCount = material.pageCount > 0
            ? material.pageCount
            : (await Self.probePageCount(url: fileURL) ?? 0)
        guard pageCount > 0 else {
            try? repository.finishMaterialExtraction(material, status: .failed)
            return
        }
        try? repository.beginMaterialExtraction(material, pageCount: pageCount)
        progressByMaterial[materialID] = Progress(
            stage: .extracting, done: donePageNumbers.count, total: pageCount
        )

        var failedAny = false
        var index = 1
        while index <= pageCount {
            if Task.isCancelled {
                try? repository.markMaterialExtractionInterrupted(material)
                progressByMaterial[materialID] = nil
                return
            }
            let batchEnd = min(index + Self.pdfBatchSize - 1, pageCount)
            let range = index...batchEnd
            // Skip fully-extracted pages on resume (nothing to redo).
            let pending = range.filter { !donePageNumbers.contains($0) }
            if !pending.isEmpty {
                let outcomes = await Self.extractPDFBatch(
                    url: fileURL, pages: pending
                )
                do {
                    for outcome in outcomes {
                        _ = try repository.upsertMaterialPageText(
                            material, pageNumber: outcome.pageNumber,
                            extractedText: outcome.text
                        )
                        if let thumbnail = outcome.thumbnail {
                            store.writePageThumbnail(
                                thumbnail, materialID: materialID,
                                pageNumber: outcome.pageNumber
                            )
                        }
                    }
                    if outcomes.count < pending.count { failedAny = true }
                } catch {
                    Self.logger.error(
                        "pdf page persist failed: \(String(describing: error), privacy: .public)"
                    )
                    failedAny = true
                }
            }
            progressByMaterial[materialID] = Progress(
                stage: .extracting, done: batchEnd, total: pageCount
            )
            index = batchEnd + 1
        }

        try? repository.finishMaterialExtraction(
            material, status: failedAny ? .partial : .completed
        )
        progressByMaterial[materialID] = nil
    }

    private func runTextFile(material: CourseMaterial) {
        guard let store = fileStore() else { return }
        let ext = MaterialFileStore.fileExtension(
            fileName: material.originalFileName, mime: material.mimeType
        )
        guard let data = store.originalData(materialID: material.id, fileExtension: ext),
              !data.isEmpty else {
            try? repository.finishMaterialExtraction(material, status: .failed)
            return
        }
        let bounded = data.prefix(Self.textFileByteLimit)
        let text = String(data: Data(bounded), encoding: .utf8)
            ?? String(data: Data(bounded), encoding: .ascii)
            ?? ""
        try? repository.beginMaterialExtraction(material, pageCount: 1)
        _ = try? repository.upsertMaterialPageText(
            material, pageNumber: 1, extractedText: text
        )
        try? repository.finishMaterialExtraction(
            material, status: text.isEmpty ? .failed : .completed
        )
    }

    private func runImage(material: CourseMaterial) {
        // One page, no text layer — OCR runs on demand (runOCR below).
        try? repository.beginMaterialExtraction(material, pageCount: 1)
        _ = try? repository.upsertMaterialPageText(
            material, pageNumber: 1, extractedText: ""
        )
        try? repository.finishMaterialExtraction(material, status: .completed)
    }

    // MARK: - Vision OCR (user-initiated, page by page)

    /// Runs Vision OCR over the material's text-empty pages (or an
    /// explicit page list). Each page's status is persisted as it
    /// finishes — real progress, resumable, cancellable. Failure of one
    /// page never stops the rest.
    func runOCR(material: CourseMaterial, pages pageFilter: [Int] = []) {
        guard tasks[material.id] == nil else { return }
        let materialID = material.id
        tasks[materialID] = Task { [weak self] in
            await self?.runOCRTask(materialID: materialID, pageFilter: pageFilter)
            self?.tasks[materialID] = nil
        }
    }

    private func runOCRTask(materialID: UUID, pageFilter: [Int]) async {
        guard let material = try? repository.material(id: materialID) else { return }
        let allPages = (try? repository.materialPages(materialID: materialID)) ?? []
        let targets = allPages.filter { page in
            (pageFilter.isEmpty || pageFilter.contains(page.pageNumber))
                && page.needsOCR
        }
        guard !targets.isEmpty else { return }
        progressByMaterial[materialID] = Progress(
            stage: .ocr, done: 0, total: targets.count
        )

        var done = 0
        for page in targets {
            if Task.isCancelled { break }
            // SwiftData rows are main-actor references — the same row
            // updates in place (no refetch needed).
            try? repository.updateMaterialPageOCR(page, text: page.ocrText, status: .running)
            let imageData = await renderOCRImage(material: material, pageNumber: page.pageNumber)
            if let imageData,
               let outcome = await AttachmentOCRService.recognize(imageData: imageData) {
                try? repository.updateMaterialPageOCR(
                    page, text: outcome.text, status: .done
                )
            } else {
                try? repository.updateMaterialPageOCR(
                    page, text: page.ocrText, status: .failed
                )
            }
            done += 1
            progressByMaterial[materialID] = Progress(
                stage: .ocr, done: done, total: targets.count
            )
        }
        progressByMaterial[materialID] = nil
    }

    /// Renders one page at OCR resolution (~1600px): PDF pages via
    /// PDFKit; image materials via their own (or the borrowed
    /// attachment's) bytes.
    private func renderOCRImage(material: CourseMaterial, pageNumber: Int) async -> Data? {
        switch material.format {
        case .pdf:
            guard let store = fileStore() else { return nil }
            let ext = MaterialFileStore.fileExtension(
                fileName: material.originalFileName, mime: material.mimeType
            )
            let url = store.originalURL(materialID: material.id, fileExtension: ext)
            let task = Task.detached(priority: .utility) { () -> Data? in
                guard let document = PDFDocument(url: url),
                      pageNumber >= 1, pageNumber <= document.pageCount,
                      let page = document.page(at: pageNumber - 1) else { return nil }
                let size = page.thumbnailSizeFitting(
                    CGSize(width: 1600, height: 1600)
                )
                let image = page.thumbnail(of: size, for: .mediaBox)
                return image.jpegData(compressionQuality: 0.8)
            }
            return await task.value
        case .image:
            if let attachmentID = material.sourceAttachmentID,
               let attachment = try? repository.attachment(id: attachmentID),
               let data = AttachmentFileStoreShared.store?.analysisData(
                   for: attachment.id, sessionID: attachment.sessionID
               ) {
                return data
            }
            guard let store = fileStore() else { return nil }
            let ext = MaterialFileStore.fileExtension(
                fileName: material.originalFileName, mime: material.mimeType
            )
            return store.originalData(materialID: material.id, fileExtension: ext)
        default:
            return nil
        }
    }

    // MARK: - Detached PDF helpers

    struct PageOutcome: Sendable {
        var pageNumber: Int
        var text: String
        var thumbnail: Data?
    }

    /// One batch of pages, extracted off the main actor. PDFKit work is
    /// confined to this detached task; value results hop back.
    static func extractPDFBatch(url: URL, pages: [Int]) async -> [PageOutcome] {
        let task = Task.detached(priority: .utility) { () -> [PageOutcome] in
            guard let document = PDFDocument(url: url) else { return [] }
            var outcomes: [PageOutcome] = []
            for pageNumber in pages {
                guard pageNumber >= 1, pageNumber <= document.pageCount,
                      let page = document.page(at: pageNumber - 1) else { continue }
                let text = page.string ?? ""
                let thumbSize = page.thumbnailSizeFitting(
                    CGSize(width: 600, height: 600)
                )
                let image = page.thumbnail(of: thumbSize, for: .mediaBox)
                outcomes.append(PageOutcome(
                    pageNumber: pageNumber,
                    text: text,
                    thumbnail: image.jpegData(compressionQuality: 0.75)
                ))
            }
            return outcomes
        }
        return await task.value
    }

    static func probePageCount(url: URL) async -> Int? {
        let task = Task.detached(priority: .utility) { () -> Int? in
            PDFDocument(url: url)?.pageCount
        }
        return await task.value
    }
}

// MARK: - PDFKit helper

extension PDFPage {
    /// The largest 4:3-fitting size bounded by `max` that preserves the
    /// page's aspect ratio (thumbnail rendering at a controlled budget).
    func thumbnailSizeFitting(_ max: CGSize) -> CGSize {
        let bounds = bounds(for: .mediaBox)
        let width = bounds.width
        let height = bounds.height
        guard width > 0, height > 0 else { return max }
        let scale = min(max.width / width, max.height / height, 4)
        return CGSize(width: width * scale, height: height * scale)
    }
}
