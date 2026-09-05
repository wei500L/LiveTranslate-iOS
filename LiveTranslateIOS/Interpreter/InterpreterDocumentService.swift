import Foundation
import CryptoKit
import OSLog
import Observation
import PDFKit
import UIKit
import UniformTypeIdentifiers

/// The interpreter document import + extraction pipeline (现场文件):
///
///     pick a file / capture / scan / inbox item
///     → classify (extension + UTType/MIME — never the file name alone)
///     → duplicate check by content hash within the CONVERSATION
///       (提示已存在 — never auto-drop; the user may keep a second copy)
///     → InterpreterDocumentStore.importFile / importData
///       (STREAMING hash + copy; temp → atomic rename)
///     → persist the metadata row LAST (an interrupted import never
///       leaves a row whose files are missing)
///     → local text extraction (PDF text layer per page / text file
///       read / image OCR on demand), all OFF the main actor in bounded
///       batches
///
/// Formats without a reliable local parsing chain (DOC/DOCX/XLS/PPT…)
/// are classified `other`: stored and previewed, honestly marked
/// 暂不支持内容提取 — their extension is never renamed and no content
/// is ever claimed.
@MainActor
@Observable
final class InterpreterDocumentService {
    static let logger = Logger(
        subsystem: "com.livetranslate.ios", category: "interpreter-documents"
    )

    private let repository: any ClassroomRepositoryProtocol
    private let fileStore: () -> InterpreterDocumentStore?
    /// In-flight jobs keyed by document id (one extraction at a time per
    /// document; the dictionary itself is the idempotence guard).
    private var extractionTasks: [UUID: Task<Void, Never>] = [:]
    /// Real per-page progress (page numbers, never a timer).
    private(set) var extractionProgress: [UUID: Progress] = [:]

    struct Progress: Equatable, Sendable {
        enum Stage: Equatable, Sendable {
            case extracting   // PDF 文字层 / 文本读取
            case ocr          // 逐页 Vision 识别
        }

        var stage: Stage
        var done: Int
        var total: Int

        var label: String {
            switch stage {
            case .extracting:
                return total > 0
                    ? "正在读取第 \(min(done + 1, total))/\(total) 页…"
                    : "正在读取文件内容…"
            case .ocr:
                return total > 1
                    ? "正在识别第 \(min(done + 1, total))/\(total) 页…"
                    : "正在识别页面文字…"
            }
        }
    }

    /// Pages per PDF batch (PDFKit work happens detached; each batch
    /// re-opens the document so PDFDocument never crosses actors — the
    /// MaterialExtractionRunner convention).
    static let pdfBatchSize = 8
    /// Upper bound for a text-file read (larger files truncate honestly).
    static let textFileByteLimit = 5_000_000
    /// Above this page count the UI asks the user to pick a page range
    /// before extraction (default never silently reads page 1 only).
    static let largeDocumentPageThreshold = 30
    /// Current extraction algorithm version (sidecar cache key).
    static let extractionVersion = "1"

    init(
        repository: any ClassroomRepositoryProtocol,
        fileStore: @escaping () -> InterpreterDocumentStore?
    ) {
        self.repository = repository
        self.fileStore = fileStore
    }

    // MARK: - Classification

    /// What the import pipeline will do with a picked item (honest UI
    /// BEFORE any bytes move). `utType` (from the picker / inbox hints)
    /// and the file extension are BOTH consulted — never the name alone.
    struct Classification: Sendable, Equatable {
        var format: InterpreterDocumentFormat
        var mimeType: String
        /// Whether local text extraction is possible.
        var canExtract: Bool
        /// The canonical file extension for the stored original.
        var fileExtension: String
    }

    static func classify(fileName: String, utTypeIdentifier: String? = nil) -> Classification {
        let ext = (fileName as NSString).pathExtension.lowercased()
        // UTType signal first (the picker's source of truth), extension
        // as the fallback — the same three-signal rule the material
        // pipeline uses, minus the byte-level probe (import failures
        // throw honestly instead).
        let declared = utTypeIdentifier.flatMap { UTType($0) }
        func fromType(_ type: UTType?) -> Classification? {
            guard let type else { return nil }
            if type.conforms(to: .pdf) {
                return Classification(format: .pdf, mimeType: "application/pdf", canExtract: true, fileExtension: "pdf")
            }
            if type.conforms(to: .image), !type.conforms(to: .svg) {
                let mime = type.preferredMIMEType ?? "image/jpeg"
                let ext = type.preferredFilenameExtension ?? "jpg"
                return Classification(format: .image, mimeType: mime, canExtract: true, fileExtension: ext)
            }
            if type.conforms(to: .plainText) || type.preferredFilenameExtension == "md" {
                // Markdown arrives as plain text from pickers; the
                // extension (below) refines txt vs md when present.
                return Classification(format: .text, mimeType: type.preferredMIMEType ?? "text/plain", canExtract: true, fileExtension: "txt")
            }
            return nil
        }
        if let result = fromType(declared) { return result }
        switch ext {
        case "pdf":
            return Classification(format: .pdf, mimeType: "application/pdf", canExtract: true, fileExtension: "pdf")
        case "txt":
            return Classification(format: .text, mimeType: "text/plain", canExtract: true, fileExtension: "txt")
        case "md", "markdown", "mdown":
            return Classification(format: .markdown, mimeType: "text/markdown", canExtract: true, fileExtension: "md")
        case "jpg", "jpeg":
            return Classification(format: .image, mimeType: "image/jpeg", canExtract: true, fileExtension: "jpg")
        case "png":
            return Classification(format: .image, mimeType: "image/png", canExtract: true, fileExtension: "png")
        case "heic", "heif":
            return Classification(format: .image, mimeType: "image/heic", canExtract: true, fileExtension: "heic")
        case "webp":
            return Classification(format: .image, mimeType: "image/webp", canExtract: true, fileExtension: "webp")
        default:
            // DOC/DOCX/XLS/PPT/RTF/… — stored and previewed only. The
            // extension is kept verbatim; no content claim is made.
            let mime = UTType(filenameExtension: ext)?.preferredMIMEType
                ?? "application/octet-stream"
            return Classification(format: .other, mimeType: mime, canExtract: false, fileExtension: ext.isEmpty ? "bin" : ext)
        }
    }

    // MARK: - Import errors

    enum ImportError: LocalizedError, Equatable, Sendable {
        case unreadableFile
        case emptyFile
        case pdfUnreadable
        case duplicateInConversation
        case unknownFormat

        var errorDescription: String? {
            switch self {
            case .unreadableFile:
                return String(localized: "无法读取所选文件")
            case .emptyFile:
                return String(localized: "文件为空")
            case .pdfUnreadable:
                return String(localized: "无法读取该 PDF 文件")
            case .duplicateInConversation:
                return String(localized: "本次对话中已有相同文件")
            case .unknownFormat:
                return String(localized: "无法识别该文件类型")
            }
        }
    }

    // MARK: - Duplicate detection

    /// Whether a file with the same bytes already exists in the
    /// conversation (the import UI offers the 查看已有/仍要导入 choice —
    /// never a silent drop).
    func duplicateExists(for fileURL: URL, conversationID: UUID) async -> Bool {
        guard let hash = await Self.probeHash(of: fileURL) else { return false }
        let duplicates = (try? repository.interpreterDocuments(
            conversationID: conversationID, contentHash: hash
        )) ?? []
        return !duplicates.isEmpty
    }

    /// Streams the file to compute its SHA-256 without copying it.
    static func probeHash(of url: URL) async -> String? {
        let task = Task.detached(priority: .utility) { () -> String? in
            guard let input = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? input.close() }
            var hasher = SHA256()
            while let chunk = try? input.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return await task.value
    }

    // MARK: - Import: file URL (Files picker / inbox payload)

    /// Imports one file from a (security-scoped) URL. The caller holds
    /// the sandbox extension; the bytes are copied OUT of the inbox/Files
    /// scope immediately into the interpreter's own store — no fragile
    /// references to source paths survive.
    func importFile(
        at fileURL: URL,
        conversationID: UUID,
        source: InterpreterDocumentSource,
        keepDuplicateCopy: Bool = false
    ) async throws -> InterpreterDocument {
        let fileName = fileURL.lastPathComponent
        let classification = Self.classify(fileName: fileName)
        guard let started = try? fileURL.startAccessingSecurityScopedResource() else {
            throw ImportError.unreadableFile
        }
        if started {
            defer { fileURL.stopAccessingSecurityScopedResource() }
        }

        let documentID = UUID()
        let outcome: InterpreterDocumentStore.ImportOutcome
        do {
            guard let store = fileStore() else { throw ImportError.unreadableFile }
            outcome = try store.importFile(
                at: fileURL, documentID: documentID,
                fileExtension: classification.fileExtension
            )
        } catch {
            throw ImportError.unreadableFile
        }

        // In-conversation duplicate check AFTER hashing, BEFORE the row.
        if !keepDuplicateCopy {
            let duplicates = (try? repository.interpreterDocuments(
                conversationID: conversationID, contentHash: outcome.contentHash
            )) ?? []
            if let existing = duplicates.first {
                fileStore()?.removeFiles(for: documentID)
                _ = existing // the UI surfaces the existing document
                throw ImportError.duplicateInConversation
            }
        }

        // Page-count probe for PDFs (PDFKit loads lazily).
        var pageCount = 1
        if classification.format == .pdf {
            guard let document = PDFDocument(url: fileURL) else {
                fileStore()?.removeFiles(for: documentID)
                throw ImportError.pdfUnreadable
            }
            pageCount = document.pageCount
        }
        if classification.format == .other && classification.fileExtension == "bin" {
            fileStore()?.removeFiles(for: documentID)
            throw ImportError.unknownFormat
        }

        let draft = InterpreterDocumentDraft(
            id: documentID,
            conversationID: conversationID,
            source: source,
            originalFileName: fileName,
            format: classification.format,
            mimeType: classification.mimeType,
            fileSize: outcome.fileSize,
            contentHash: outcome.contentHash,
            pageCount: pageCount,
            status: .imported,
            originalRelativePath: outcome.relativePath
        )
        let document = try repository.addInterpreterDocument(draft)

        // Text files complete inline; PDFs extract when the user opens
        // the context panel (large PDFs ask for a page range first);
        // images wait for explicit OCR; `other` stays honest.
        if classification.canExtract, classification.format != .image {
            startExtraction(document: document)
        }
        return document
    }

    // MARK: - Import: raw data (camera / scanner / photos)

    /// Imports raw image or text bytes (camera capture, scanner pages,
    /// photo-library picks). A multi-page scan imports as ONE document
    /// whose "original" is the concatenation of JPEG pages into a single
    /// PDF built locally (pages keep their order; the page count is the
    /// scan's page count).
    func importData(
        _ data: Data,
        fileName: String,
        conversationID: UUID,
        source: InterpreterDocumentSource,
        utTypeIdentifier: String? = nil,
        keepDuplicateCopy: Bool = false
    ) async throws -> InterpreterDocument {
        let classification = Self.classify(fileName: fileName, utTypeIdentifier: utTypeIdentifier)
        guard classification.format != .other else {
            throw ImportError.unknownFormat
        }
        let documentID = UUID()
        let outcome: InterpreterDocumentStore.ImportOutcome
        do {
            guard let store = fileStore() else { throw ImportError.unreadableFile }
            outcome = try store.importData(
                data, documentID: documentID, fileExtension: classification.fileExtension
            )
        } catch {
            throw ImportError.unreadableFile
        }
        if !keepDuplicateCopy {
            let duplicates = (try? repository.interpreterDocuments(
                conversationID: conversationID, contentHash: outcome.contentHash
            )) ?? []
            if !duplicates.isEmpty {
                fileStore()?.removeFiles(for: documentID)
                throw ImportError.duplicateInConversation
            }
        }
        let draft = InterpreterDocumentDraft(
            id: documentID,
            conversationID: conversationID,
            source: source,
            originalFileName: fileName,
            format: classification.format,
            mimeType: classification.mimeType,
            fileSize: outcome.fileSize,
            contentHash: outcome.contentHash,
            pageCount: 1,
            status: .imported,
            originalRelativePath: outcome.relativePath
        )
        let document = try repository.addInterpreterDocument(draft)
        if classification.format == .text || classification.format == .markdown {
            startExtraction(document: document)
        }
        return document
    }

    // MARK: - Import: scanner pages → local PDF

    /// Builds a single PDF from scanned page images (VisionKit returns
    /// page images; we re-encode to JPEG and compose with PDFKit). The
    /// PDF is the document's original; each page is a scan page.
    static func makePDFData(from pages: [Data]) -> Data? {
        guard !pages.isEmpty else { return nil }
        let pdfDocument = PDFDocument()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        for (index, pageData) in pages.enumerated() {
            guard let image = UIImage(data: pageData) else { continue }
            let pageBounds = CGRect(x: 0, y: 0, width: 595, height: 842) // A4 points
            let renderer = UIGraphicsImageRenderer(size: pageBounds.size, format: format)
            // Fit-contain each scan page into the A4 box.
            let full = renderer.image { _ in
                let scale = min(
                    pageBounds.width / image.size.width,
                    pageBounds.height / image.size.height
                )
                let drawSize = CGSize(
                    width: image.size.width * scale,
                    height: image.size.height * scale
                )
                let origin = CGPoint(
                    x: (pageBounds.width - drawSize.width) / 2,
                    y: (pageBounds.height - drawSize.height) / 2
                )
                image.draw(in: CGRect(origin: origin, size: drawSize))
            }
            if let page = PDFPage(image: full) {
                pdfDocument.insert(page, at: index)
            }
        }
        guard pdfDocument.pageCount > 0 else { return nil }
        return pdfDocument.dataRepresentation()
    }

    // MARK: - Extraction control

    func isExtracting(_ documentID: UUID) -> Bool {
        extractionTasks[documentID] != nil
    }

    func progress(for documentID: UUID) -> Progress? {
        extractionProgress[documentID]
    }

    func cancel(_ documentID: UUID) {
        extractionTasks[documentID]?.cancel()
        // 取消不标失败：状态留给 reconcile 或用户重试决定。
    }

    /// Starts (or resumes) extraction for one document. Resume skips
    /// pages that already carry effective text.
    func startExtraction(document: InterpreterDocument, resume: Bool = true) {
        guard extractionTasks[document.id] == nil else { return }
        let documentID = document.id
        extractionTasks[documentID] = Task { [weak self] in
            await self?.runExtraction(documentID: documentID, resume: resume)
            self?.extractionTasks[documentID] = nil
            self?.extractionProgress[documentID] = nil
        }
    }

    /// Runs OCR over the document's text-empty pages (user-initiated,
    /// page by page, resumable). `pageFilter` empty = all OCR candidates.
    func runOCR(document: InterpreterDocument, pages pageFilter: [Int] = []) {
        guard extractionTasks[document.id] == nil else { return }
        let documentID = document.id
        extractionTasks[documentID] = Task { [weak self] in
            await self?.runOCRTask(documentID: documentID, pageFilter: pageFilter)
            self?.extractionTasks[documentID] = nil
            self?.extractionProgress[documentID] = nil
        }
    }

    // MARK: - Extraction run

    private func runExtraction(documentID: UUID, resume: Bool) async {
        guard let document = repository.interpreterDocument(id: documentID),
              let store = fileStore() else { return }
        let url = store.originalURL(forRelativePath: document.originalRelativePath)
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            try? repository.setInterpreterDocumentStatus(
                document, status: .failed, errorSummary: "原文件不存在，无法提取"
            )
            return
        }

        // Existing sidecar lets a resume skip finished pages.
        let existing = store.readExtraction(documentID: documentID)
        let donePages = resume ? Set((existing?.pages ?? []).filter {
            !$0.effectiveText.isEmpty
        }.map(\.pageNumber)) : []

        switch document.format {
        case .pdf:
            await extractPDF(
                document: document, url: url, store: store,
                donePages: donePages
            )
        case .text, .markdown:
            extractTextFile(document: document, url: url, store: store)
        case .image:
            // One page, no text layer — OCR runs on demand.
            let pages = [InterpreterDocumentPageText(pageNumber: 1)]
            try? store.writeExtraction(
                InterpreterDocumentExtraction(pages: pages, extractionVersion: Self.extractionVersion),
                documentID: document.id
            )
            try? repository.setInterpreterDocumentExtraction(
                document,
                extractionRelativePath: "\(document.id.uuidString)/extraction.json",
                pageCount: 1,
                status: .ready
            )
        case .other:
            try? repository.setInterpreterDocumentStatus(
                document, status: .ready, errorSummary: "暂不支持该格式的内容提取"
            )
        }
    }

    private func extractPDF(
        document: InterpreterDocument,
        url: URL,
        store: InterpreterDocumentStore,
        donePages: Set<Int>
    ) async {
        let pageCount = max(document.pageCount, 1)
        try? repository.setInterpreterDocumentStatus(document, status: .extracting)
        extractionProgress[document.id] = Progress(
            stage: .extracting, done: donePages.count, total: pageCount
        )

        var pages: [InterpreterDocumentPageText] = []
        var failedAny = false
        var index = 1
        while index <= pageCount {
            if Task.isCancelled {
                // 取消 ≠ 失败：保留已落盘的部分，状态交给 reconcile。
                return
            }
            let batchEnd = min(index + Self.pdfBatchSize - 1, pageCount)
            let range = index...batchEnd
            let pending = range.filter { !donePages.contains($0) }
            if !pending.isEmpty {
                let outcomes = await Self.extractPDFBatch(url: url, pages: pending)
                for outcome in outcomes {
                    pages.append(InterpreterDocumentPageText(
                        pageNumber: outcome.pageNumber,
                        extractedText: outcome.text
                    ))
                    if let thumbnail = outcome.thumbnail {
                        store.writePageThumbnail(
                            thumbnail, documentID: document.id, pageNumber: outcome.pageNumber
                        )
                    }
                }
                if outcomes.count < pending.count { failedAny = true }
                // Persist incrementally: each batch lands in the sidecar
                // so an interruption keeps completed pages.
                let merged = Self.mergePages(
                    existing: store.readExtraction(documentID: document.id)?.pages ?? [],
                    updated: pages
                )
                try? store.writeExtraction(
                    InterpreterDocumentExtraction(
                        pages: merged, extractionVersion: Self.extractionVersion
                    ),
                    documentID: document.id
                )
                pages.removeAll()
            }
            extractionProgress[document.id] = Progress(
                stage: .extracting, done: batchEnd, total: pageCount
            )
            index = batchEnd + 1
        }

        try? repository.setInterpreterDocumentExtraction(
            document,
            extractionRelativePath: "\(document.id.uuidString)/extraction.json",
            pageCount: pageCount,
            status: failedAny ? .partiallyExtracted : .ready
        )
    }

    private func extractTextFile(
        document: InterpreterDocument, url: URL, store: InterpreterDocumentStore
    ) {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            try? repository.setInterpreterDocumentStatus(
                document, status: .failed, errorSummary: "无法读取文件内容"
            )
            return
        }
        let bounded = data.prefix(Self.textFileByteLimit)
        // 真实编码读取：UTF-8 → UTF-16 → Latin-1；都无法确定时诚实提示。
        let text = String(data: Data(bounded), encoding: .utf8)
            ?? String(data: Data(bounded), encoding: .utf16)
            ?? String(data: Data(bounded), encoding: .isoLatin1)
        guard let text, !text.isEmpty else {
            try? repository.setInterpreterDocumentStatus(
                document, status: .failed, errorSummary: "无法确定文件编码"
            )
            return
        }
        let page = InterpreterDocumentPageText(pageNumber: 1, extractedText: text)
        do {
            try store.writeExtraction(
                InterpreterDocumentExtraction(
                    pages: [page], extractionVersion: Self.extractionVersion
                ),
                documentID: document.id
            )
            try repository.setInterpreterDocumentExtraction(
                document,
                extractionRelativePath: "\(document.id.uuidString)/extraction.json",
                pageCount: 1,
                status: .ready
            )
        } catch {
            try? repository.setInterpreterDocumentStatus(
                document, status: .failed, errorSummary: "提取结果写入失败"
            )
        }
    }

    // MARK: - OCR run

    private func runOCRTask(documentID: UUID, pageFilter: [Int]) async {
        guard let document = repository.interpreterDocument(id: documentID),
              let store = fileStore() else { return }
        guard var extraction = store.readExtraction(documentID: documentID) else { return }
        let targets = extraction.pages.filter { page in
            (pageFilter.isEmpty || pageFilter.contains(page.pageNumber))
                && page.ocrStatusRaw != InterpreterPageOCRStatus.done.rawValue
                && page.extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !targets.isEmpty else { return }
        try? repository.setInterpreterDocumentStatus(document, status: .extracting)
        extractionProgress[documentID] = Progress(stage: .ocr, done: 0, total: targets.count)

        let url = store.originalURL(forRelativePath: document.originalRelativePath)
        var done = 0
        for page in targets {
            if Task.isCancelled { return } // 取消不标失败
            let imageData = await Self.renderOCRImage(
                url: url, format: document.format, pageNumber: page.pageNumber
            )
            var updated = page
            if let imageData,
               let outcome = await InterpreterDocumentOCRService.recognize(imageData: imageData) {
                updated.ocrText = outcome.text
                updated.ocrConfidence = outcome.confidence
                updated.ocrStatusRaw = InterpreterPageOCRStatus.done.rawValue
            } else {
                updated.ocrStatusRaw = InterpreterPageOCRStatus.failed.rawValue
            }
            if let index = extraction.pages.firstIndex(where: { $0.pageNumber == updated.pageNumber }) {
                extraction.pages[index] = updated
            }
            try? store.writeExtraction(extraction, documentID: documentID)
            done += 1
            extractionProgress[documentID] = Progress(
                stage: .ocr, done: done, total: targets.count
            )
        }

        // 整体状态：有失败页 → partiallyExtracted（可只重试失败页）。
        let failedPages = extraction.pages.filter {
            $0.ocrStatusRaw == InterpreterPageOCRStatus.failed.rawValue
        }
        let emptyPages = extraction.pages.filter {
            $0.effectiveText.isEmpty
        }
        let status: InterpreterDocumentStatus = failedPages.isEmpty && emptyPages.isEmpty
            ? .ready : .partiallyExtracted
        try? repository.setInterpreterDocumentStatus(document, status: status)
    }

    // MARK: - Merge helpers

    /// Merges updated page entries into existing ones (update-in-place
    /// by page number; new page numbers append).
    static func mergePages(
        existing: [InterpreterDocumentPageText],
        updated: [InterpreterDocumentPageText]
    ) -> [InterpreterDocumentPageText] {
        var byNumber = Dictionary(uniqueKeysWithValues: existing.map { ($0.pageNumber, $0) })
        for page in updated {
            byNumber[page.pageNumber] = page
        }
        return byNumber.values.sorted { $0.pageNumber < $1.pageNumber }
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
                let bounds = page.bounds(for: .mediaBox)
                let longEdge = max(bounds.width, bounds.height)
                guard longEdge > 0 else { continue }
                let scale = min(600 / longEdge, 4)
                let thumb = page.thumbnail(
                    of: CGSize(width: bounds.width * scale, height: bounds.height * scale),
                    for: .mediaBox
                )
                outcomes.append(PageOutcome(
                    pageNumber: pageNumber,
                    text: text,
                    thumbnail: thumb.jpegData(compressionQuality: 0.75)
                ))
            }
            return outcomes
        }
        return await task.value
    }

    /// Renders one page at OCR resolution (~1600px): PDF pages via
    /// PDFKit; image documents use their own bytes.
    static func renderOCRImage(
        url: URL?, format: InterpreterDocumentFormat, pageNumber: Int
    ) async -> Data? {
        switch format {
        case .pdf:
            guard let url else { return nil }
            let task = Task.detached(priority: .utility) { () -> Data? in
                guard let document = PDFDocument(url: url),
                      pageNumber >= 1, pageNumber <= document.pageCount,
                      let page = document.page(at: pageNumber - 1) else { return nil }
                let bounds = page.bounds(for: .mediaBox)
                let longEdge = max(bounds.width, bounds.height)
                guard longEdge > 0 else { return nil }
                let scale = min(1600 / longEdge, 4)
                let image = page.thumbnail(
                    of: CGSize(width: bounds.width * scale, height: bounds.height * scale),
                    for: .mediaBox
                )
                return image.jpegData(compressionQuality: 0.8)
            }
            return await task.value
        case .image:
            guard let url else { return nil }
            return try? Data(contentsOf: url)
        default:
            return nil
        }
    }
}
