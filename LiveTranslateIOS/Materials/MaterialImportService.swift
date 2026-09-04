import Foundation
import CryptoKit
import OSLog
import PDFKit
import UniformTypeIdentifiers

/// The course-material import pipeline:
///
///     pick a file (Files/document picker, security-scoped URL)
///     → classify by extension/UTType (PDF/TXT/MD/image/other)
///     → duplicate check by content hash across the whole library
///       (prompt 查看已有/建立新关联/保留副本 — NEVER auto-delete)
///     → MaterialFileStore.importFile (STREAMING hash + copy; temp →
///       atomic rename; a 200 MB PDF never enters memory)
///     → persist the metadata row LAST (an interrupted import never
///       leaves a row whose files are missing)
///     → kick off text extraction (PDF pages / text files; image
///       materials OCR on demand)
///
/// Formats without a parsing chain this round (DOCX/PPTX/…) are imported
/// as `other`: stored, Quick Look preview, honest 暂不支持内容提取 —
/// their extension is NEVER renamed and no content is ever claimed.
///
/// Materials created from a classroom image borrow the attachment's
/// files (`sourceAttachmentID`) — the original is never copied twice.
@MainActor
final class MaterialImportService {
    static let logger = Logger(subsystem: "com.livetranslate.ios", category: "material-import")

    private let repository: any ClassroomRepositoryProtocol
    private let fileStore: MaterialFileStore
    private let extractionRunner: MaterialExtractionRunner

    init(
        repository: any ClassroomRepositoryProtocol,
        fileStore: MaterialFileStore,
        extractionRunner: MaterialExtractionRunner
    ) {
        self.repository = repository
        self.fileStore = fileStore
        self.extractionRunner = extractionRunner
    }

    // MARK: - Classification

    /// What the import pipeline will do with a file name (drives honest
    /// UI BEFORE any bytes move).
    struct Classification: Sendable, Equatable {
        var format: MaterialFormat
        var mimeType: String
        /// Whether content extraction is possible this round.
        var canExtract: Bool
    }

    static func classify(fileName: String) -> Classification {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf":
            return Classification(
                format: .pdf, mimeType: "application/pdf", canExtract: true
            )
        case "txt":
            return Classification(
                format: .text, mimeType: "text/plain", canExtract: true
            )
        case "md", "markdown", "mdown":
            return Classification(
                format: .markdown, mimeType: "text/markdown", canExtract: true
            )
        case "jpg", "jpeg":
            return Classification(
                format: .image, mimeType: "image/jpeg", canExtract: true
            )
        case "png":
            return Classification(
                format: .image, mimeType: "image/png", canExtract: true
            )
        case "heic", "heif":
            return Classification(
                format: .image, mimeType: "image/heic", canExtract: true
            )
        case "webp":
            return Classification(
                format: .image, mimeType: "image/webp", canExtract: true
            )
        default:
            // DOCX/PPTX/DOC/PPT/RTF/HTML/… — stored and previewed only.
            // The extension is kept verbatim; no content claim is made.
            let mime = UTType(filenameExtension: ext)?.preferredMIMEType
                ?? "application/octet-stream"
            return Classification(
                format: .other, mimeType: mime, canExtract: false
            )
        }
    }

    // MARK: - Duplicate detection

    /// Materials already in the library with the SAME bytes (the import
    /// UI offers 查看已有 / 建立新关联 / 保留副本 — never a silent drop).
    func existingDuplicates(for fileURL: URL) async -> [CourseMaterial] {
        guard let hash = await Self.probeHash(of: fileURL) else { return [] }
        return (try? repository.materials(contentHash: hash)) ?? []
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

    // MARK: - Import

    /// Metadata the import form collected before the bytes move.
    struct Metadata: Sendable {
        var title: String
        var kind: MaterialKind
        var courseID: UUID?
        var sessionID: UUID?
        var occurrenceKey: String?
    }

    enum ImportError: LocalizedError, Equatable {
        case unreadableFile
        case duplicateHash(String)
        case pdfUnreadable

        var errorDescription: String? {
            switch self {
            case .unreadableFile:
                return String(localized: "无法读取所选文件")
            case .duplicateHash:
                return String(localized: "资料库中已存在相同文件")
            case .pdfUnreadable:
                return String(localized: "无法读取该 PDF 文件")
            }
        }
    }

    /// Imports one file from a (security-scoped) URL. The caller holds
    /// the sandbox extension. Extraction starts right after the row
    /// lands (PDF/text); image materials wait for explicit OCR.
    func importFile(
        at fileURL: URL, metadata: Metadata, keepDuplicateCopy: Bool = false
    ) async throws -> CourseMaterial {
        let fileName = fileURL.lastPathComponent
        let classification = Self.classify(fileName: fileName)
        guard let started = try? fileURL.startAccessingSecurityScopedResource() else {
            throw ImportError.unreadableFile
        }
        if started {
            defer { fileURL.stopAccessingSecurityScopedResource() }
        }

        // Streaming copy + hash.
        let materialID = UUID()
        let fileExtension = (fileName as NSString).pathExtension.lowercased()
        let ext = fileExtension.isEmpty
            ? MaterialFileStore.fileExtension(forMIME: classification.mimeType)
            : fileExtension
        let outcome: MaterialFileStore.ImportOutcome
        do {
            outcome = try fileStore.importFile(
                at: fileURL, materialID: materialID, fileExtension: ext
            )
        } catch {
            throw ImportError.unreadableFile
        }

        // Duplicate check AFTER hashing but BEFORE the row: the caller
        // normally screens with existingDuplicates(); this is the safety
        // net for races. keepDuplicateCopy (保留副本) imports anyway.
        if !keepDuplicateCopy {
            let duplicates = (try? repository.materials(contentHash: outcome.contentHash)) ?? []
            if let existing = duplicates.first {
                fileStore.removeFiles(for: materialID)
                throw ImportError.duplicateHash(existing.id.uuidString)
            }
        }

        // Probe the page count for paged formats (cheap: PDFKit loads
        // lazily, never the whole document).
        var pageCount = 0
        if classification.format == .pdf {
            guard let document = PDFDocument(url: fileURL) else {
                fileStore.removeFiles(for: materialID)
                throw ImportError.pdfUnreadable
            }
            pageCount = document.pageCount
        }

        let title = metadata.title.isEmpty ? (fileName as NSString).deletingPathExtension : metadata.title
        let draft = MaterialDraft(
            title: title,
            originalFileName: fileName,
            mimeType: classification.mimeType,
            kind: metadata.kind,
            format: classification.format,
            fileSize: outcome.fileSize,
            contentHash: outcome.contentHash,
            pageCount: pageCount,
            courseID: metadata.courseID,
            sessionID: metadata.sessionID,
            occurrenceKey: metadata.occurrenceKey,
            sourceAttachmentID: nil,
            extractionStatus: classification.canExtract ? .pending : .unsupported
        )
        let material = try repository.addMaterial(draft)

        // Extraction runs right away for parseable formats (text files
        // complete inline; PDFs stream page by page).
        if classification.canExtract {
            extractionRunner.start(material: material)
        }
        return material
    }

    /// Creates a material that BORROWS a classroom image's files — the
    /// attachment keeps its original; nothing is copied. The material is
    /// a one-page image material whose hash matches the attachment's (a
    /// second import of the same photo resolves to the same duplicate
    /// prompt).
    func importFromAttachment(
        _ attachment: SessionAttachment, metadata: Metadata
    ) throws -> CourseMaterial {
        let draft = MaterialDraft(
            title: metadata.title.isEmpty
                ? (attachment.title.isEmpty ? MaterialKind.lecture.displayName : attachment.title)
                : metadata.title,
            originalFileName: attachment.title.isEmpty
                ? "image.jpg" : "\(attachment.title).\(AttachmentFileStore.fileExtension(forMIME: attachment.mimeType))",
            mimeType: attachment.mimeType,
            kind: metadata.kind,
            format: .image,
            fileSize: attachment.fileSize,
            contentHash: attachment.contentHash,
            pageCount: 1,
            courseID: metadata.courseID ?? attachment.courseID,
            sessionID: metadata.sessionID ?? attachment.sessionID,
            occurrenceKey: metadata.occurrenceKey,
            sourceAttachmentID: attachment.id,
            extractionStatus: .pending
        )
        let material = try repository.addMaterial(draft)
        // The image material's single page carries the attachment's
        // existing OCR text (already user-editable there) — extraction
        // proper is Vision OCR on demand, like any scanned image.
        extractionRunner.start(material: material)
        return material
    }

    /// 保留副本 / re-import path: imports the file even though an
    /// identical byte set exists in the library (the row gets a fresh
    /// id; the two materials then live independent lives).
    func importDuplicateCopy(
        at fileURL: URL, metadata: Metadata
    ) async throws -> CourseMaterial {
        try await importFile(at: fileURL, metadata: metadata, keepDuplicateCopy: true)
    }
}
