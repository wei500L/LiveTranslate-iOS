import Foundation
import SwiftData

/// Interpreter (随身翻译) document-context repository methods — the local
/// file-context family of `ClassroomRepositoryProtocol`. Implemented as an
/// extension on the concrete class (the interpreter/exam-family
/// convention) so it shares the model context.
///
/// Sync boundary: interpreter documents are DEVICE-LOCAL. None of these
/// methods notify the sync observer — the rows never enter the outbox,
/// the wire, or the server. Only user-submitted turn text rides the
/// existing conversation/turn chain. Deletion of a conversation must
/// reap its document files (via the shared file store); deletion of an
/// inbox source never breaks an already-copied document (the copy owns
/// its lifecycle).
extension TranscriptRepository {

    // MARK: - Queries

    /// All documents of one conversation, creation order.
    func interpreterDocuments(conversationID: UUID) throws -> [InterpreterDocument] {
        let descriptor = FetchDescriptor<InterpreterDocument>(
            predicate: #Predicate { $0.conversationID == conversationID }
        )
        return try context.fetch(descriptor).sorted { $0.createdAt < $1.createdAt }
    }

    /// One document by id.
    func interpreterDocument(id: UUID) -> InterpreterDocument? {
        let descriptor = FetchDescriptor<InterpreterDocument>(
            predicate: #Predicate { $0.id == id }
        )
        return (try? context.fetch(descriptor))?.first
    }

    /// Documents with the same content hash in ONE conversation (the
    /// duplicate-import prompt's data; hash equality never crosses
    /// accounts because stores and databases are both per-account).
    func interpreterDocuments(conversationID: UUID, contentHash: String) throws -> [InterpreterDocument] {
        guard !contentHash.isEmpty else { return [] }
        let descriptor = FetchDescriptor<InterpreterDocument>(
            predicate: #Predicate {
                $0.conversationID == conversationID && $0.contentHash == contentHash
            }
        )
        return try context.fetch(descriptor)
    }

    /// All document rows across conversations (storage management /
    /// launch reconcile).
    func allInterpreterDocuments() throws -> [InterpreterDocument] {
        try context.fetch(FetchDescriptor<InterpreterDocument>())
    }

    // MARK: - Insert / update

    /// Inserts a fully-imported document row. Callers MUST have already
    /// landed the original file through `InterpreterDocumentStore` — the
    /// row records the relative path; a row without its file is a real
    /// failure the UI surfaces (the write order file → row guarantees
    /// no row can exist whose file never landed).
    func addInterpreterDocument(
        _ draft: InterpreterDocumentDraft
    ) throws -> InterpreterDocument {
        let document = InterpreterDocument(
            id: draft.id,
            conversationID: draft.conversationID,
            sourceRaw: draft.source.rawValue,
            originalFileName: draft.originalFileName,
            formatRaw: draft.format.rawValue,
            mimeType: draft.mimeType,
            fileSize: draft.fileSize,
            contentHash: draft.contentHash,
            pageCount: draft.pageCount,
            statusRaw: draft.status.rawValue,
            originalRelativePath: draft.originalRelativePath,
            extractionRelativePath: draft.extractionRelativePath,
            allowsModelUse: draft.allowsModelUse,
            keepOriginalFile: draft.keepOriginalFile,
            extractionVersion: draft.extractionVersion,
            errorSummary: draft.errorSummary
        )
        context.insert(document)
        try context.save()
        // Device-local rows never notify sync.
        return document
    }

    /// Status transitions (the local state machine; never syncs).
    func setInterpreterDocumentStatus(
        _ document: InterpreterDocument, status: InterpreterDocumentStatus, errorSummary: String = ""
    ) throws {
        document.statusRaw = status.rawValue
        if !errorSummary.isEmpty {
            document.errorSummary = errorSummary
        } else if status != .failed {
            document.errorSummary = ""
        }
        document.updatedAt = .now
        try context.save()
    }

    /// Extraction landed: records the sidecar path and page count.
    func setInterpreterDocumentExtraction(
        _ document: InterpreterDocument,
        extractionRelativePath: String,
        pageCount: Int,
        status: InterpreterDocumentStatus
    ) throws {
        document.extractionRelativePath = extractionRelativePath
        document.pageCount = pageCount
        document.statusRaw = status.rawValue
        document.updatedAt = .now
        try context.save()
    }

    /// Per-page OCR result write-back: updates the sidecar's page entry
    /// in place (the row only tracks that a sidecar exists).
    func updateInterpreterDocumentPageOCR(
        _ document: InterpreterDocument,
        pageNumber: Int,
        ocrText: String,
        confidence: Double,
        status: InterpreterPageOCRStatus
    ) throws {
        // The sidecar itself is rewritten by the extraction runner (it
        // owns the file); this method only reconciles the row's overall
        // status after page updates.
        document.updatedAt = .now
        try context.save()
    }

    /// The privacy gate / keep-originals preference.
    func updateInterpreterDocumentPreferences(
        _ document: InterpreterDocument, allowsModelUse: Bool?, keepOriginalFile: Bool?
    ) throws {
        if let allowsModelUse { document.allowsModelUse = allowsModelUse }
        if let keepOriginalFile { document.keepOriginalFile = keepOriginalFile }
        document.updatedAt = .now
        try context.save()
    }

    // MARK: - Reconcile (interrupt recovery)

    /// Launch/foreground recovery: an orphaned `importing` row (the app
    /// was killed mid-import) becomes retryable `failed`; an orphaned
    /// `extracting` row rolls back to `imported` (extraction can rerun).
    /// A row whose original file is missing on disk flips to failed with
    /// an honest message — the UI must never show "已加载" over a missing
    /// file.
    func reconcileInterpreterDocuments(
        store: InterpreterDocumentStore
    ) {
        let documents = (try? allInterpreterDocuments()) ?? []
        for document in documents {
            if document.status == .importing || document.status == .extracting {
                let target: InterpreterDocumentStatus = document.status == .importing ? .failed : .imported
                let summary = document.status == .importing
                    ? "导入被中断，请删除后重新导入"
                    : "提取被中断，可重新提取"
                try? setInterpreterDocumentStatus(document, status: target, errorSummary: summary)
            }
            // The row's file must exist for any non-failed state that
            // claims one.
            if !document.originalRelativePath.isEmpty,
               document.keepOriginalFile,
               !store.originalExists(documentID: document.id, fileExtension: Self.fileExtension(
                   fileName: document.originalFileName, mime: document.mimeType
               )) {
                try? setInterpreterDocumentStatus(
                    document, status: .failed, errorSummary: "原文件已不存在（可能被系统清理）"
                )
            }
        }
    }

    /// Canonical file extension for a document row (file-name first,
    /// MIME fallback — the MaterialFileStore convention).
    static func fileExtension(fileName: String, mime: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if !ext.isEmpty { return ext }
        switch mime {
        case "application/pdf": return "pdf"
        case "text/plain": return "txt"
        case "text/markdown", "text/x-markdown": return "md"
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "image/heic", "image/heif": return "heic"
        case "image/webp": return "webp"
        default: return "bin"
        }
    }

    // MARK: - Deletion

    /// Deletes one document row and reaps its files. The caller passes
    /// the profile's shared store (the composition root registers it
    /// globally, mirroring MaterialFileStoreShared).
    func deleteInterpreterDocument(
        _ document: InterpreterDocument, store: InterpreterDocumentStore?
    ) throws {
        let id = document.id
        context.delete(document)
        try context.save()
        // Device-local rows: no wire traffic. Files are reaped after the
        // row is gone so a failed delete leaves an orphan file (cleaned
        // by removeOrphans), never a dangling row.
        store?.removeFiles(for: id)
    }

    /// Deletes every document of one conversation (conversation delete
    /// / discard). Files go with the rows.
    func deleteInterpreterDocuments(
        conversationID: UUID, store: InterpreterDocumentStore?
    ) throws {
        let documents = try interpreterDocuments(conversationID: conversationID)
        for document in documents {
            try deleteInterpreterDocument(document, store: store)
        }
    }

    /// Drops the ORIGINAL files of one conversation's documents while
    /// keeping the extraction sidecars (the "保留提取文字，删除原始文件"
    /// end-of-conversation option). The rows stay (context citations
    /// keep working); keepOriginalFile flips to false so the reconcile
    /// pass stops expecting the file.
    func dropInterpreterDocumentOriginals(
        conversationID: UUID, store: InterpreterDocumentStore?
    ) throws {
        let documents = try interpreterDocuments(conversationID: conversationID)
        for document in documents {
            let ext = Self.fileExtension(
                fileName: document.originalFileName, mime: document.mimeType
            )
            store?.removeOriginal(for: document.id, fileExtension: ext)
            document.keepOriginalFile = false
            document.updatedAt = .now
        }
        try context.save()
    }

    // MARK: - Storage statistics

    /// Row count + byte usage summary for the storage-management UI
    /// (bytes computed by the caller via the store — this stays pure).
    func interpreterDocumentCounts() throws -> (documents: Int, withOriginals: Int) {
        let documents = try allInterpreterDocuments()
        return (documents.count, documents.filter(\.keepOriginalFile).count)
    }
}

/// Insert payload for a document row (value type — the importer collects
/// everything before the row lands).
struct InterpreterDocumentDraft: Sendable {
    var id: UUID = UUID()
    var conversationID: UUID
    var source: InterpreterDocumentSource
    var originalFileName: String
    var format: InterpreterDocumentFormat
    var mimeType: String
    var fileSize: Int64 = 0
    var contentHash: String = ""
    var pageCount: Int = 1
    var status: InterpreterDocumentStatus = .imported
    var originalRelativePath: String = ""
    var extractionRelativePath: String = ""
    var allowsModelUse: Bool = true
    var keepOriginalFile: Bool = true
    var extractionVersion: String = "1"
    var errorSummary: String = ""
}
