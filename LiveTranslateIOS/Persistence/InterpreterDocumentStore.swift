import Foundation
import CryptoKit

/// The single component that owns interpreter document file paths and
/// writes. Views and ViewModels NEVER build document paths themselves —
/// the MaterialFileStore rule, applied to 随身翻译's local file context.
///
/// Layout (per account scope, see AccountScope.interpreterDocumentsRoot):
///
///     <root>/<documentID>/original.<ext>
///     <root>/<documentID>/extraction.json      (sidecar — page texts,
///                                               OCR results, confidence)
///     <root>/<documentID>/form-draft.json      (sidecar — 俄语表单逐项
///                                               填写草稿，第二十一轮)
///     <root>/<documentID>/page-<n>.jpg         (~600px thumbnail cache)
///
/// Rendition rules:
///   - original: the untouched imported bytes (PDF / image / text);
///   - extraction.json: the local text-extraction sidecar (page text
///     layers + Vision OCR output). Device-local, NEVER synced;
///   - form-draft.json: the local form-filling draft (field list, user
///     values, statuses). Device-local, NEVER synced — the same contract
///     as extraction.json;
///   - page-n.jpg: regenerable thumbnail cache, reaped on delete.
///
/// All writes go temp-file → atomic rename (the MaterialFileStore
/// contract): an interrupted import can never leave a database row whose
/// files are half-present.
struct InterpreterDocumentStore: Sendable {
    /// Thumbnail edge length in pixels (page thumbnails; caches only).
    static let pageThumbnailMaxDimension = 600

    let root: URL

    /// Store scoped to a profile (account or guest).
    init(accountID: UUID?) {
        self.root = AccountScope.interpreterDocumentsRoot(accountID: accountID)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Self.protectRoot(root)
    }

    /// Store-internal init for tests/demo containers.
    init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Self.protectRoot(root)
    }

    /// 随身翻译 documents are the most sensitive files the app keeps
    /// (证件、银行、医疗文书): `.complete` — unreadable while the device
    /// is locked — and excluded from device/iCloud backups. They are
    /// device-local BY DESIGN (never synced, never uploaded); losing the
    /// device loses them, which the privacy center states plainly. The
    /// exclusion set on the root covers the whole subtree.
    private static func protectRoot(_ root: URL) {
        FileProtection.apply(.sensitiveLocalDocument, to: root)
    }

    // MARK: - Paths

    /// The one directory holding a document's files.
    func directory(for documentID: UUID) -> URL {
        root.appendingPathComponent(documentID.uuidString, isDirectory: true)
    }

    func originalURL(documentID: UUID, fileExtension: String) -> URL {
        directory(for: documentID)
            .appendingPathComponent("original.\(fileExtension)")
    }

    func extractionURL(documentID: UUID) -> URL {
        directory(for: documentID).appendingPathComponent("extraction.json")
    }

    func pageThumbnailURL(documentID: UUID, pageNumber: Int) -> URL {
        directory(for: documentID).appendingPathComponent("page-\(pageNumber).jpg")
    }

    func originalExists(documentID: UUID, fileExtension: String) -> Bool {
        FileManager.default.fileExists(
            atPath: originalURL(documentID: documentID, fileExtension: fileExtension).path
        )
    }

    func extractionExists(documentID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: extractionURL(documentID: documentID).path)
    }

    // MARK: - Import

    /// Metadata gathered while importing a file.
    struct ImportOutcome: Sendable {
        var contentHash: String
        var fileSize: Int64
        /// Path of the landed original, RELATIVE to the store root.
        var relativePath: String
    }

    /// Streams a file from `sourceURL` into the store: computes SHA-256
    /// and copies bytes in 1 MiB chunks — a large PDF never fully enters
    /// memory. The copy lands as a temp file first and is atomically
    /// renamed into place, so an interrupted import leaves nothing behind.
    func importFile(
        at sourceURL: URL, documentID: UUID, fileExtension: String
    ) throws -> ImportOutcome {
        let dir = directory(for: documentID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileProtection.apply(.sensitiveLocalDocument, to: dir)
        let destination = originalURL(documentID: documentID, fileExtension: fileExtension)
        let temp = dir.appendingPathComponent(".tmp-\(UUID().uuidString)")

        do {
            guard FileManager.default.createFile(atPath: temp.path, contents: nil) else {
                throw ImportError.createFailed
            }
            let input = try FileHandle(forReadingFrom: sourceURL)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: temp)
            defer { try? output.close() }
            var hasher = SHA256()
            var total: Int64 = 0
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
                try output.write(contentsOf: chunk)
                total += Int64(chunk.count)
            }
            guard total > 0 else { throw ImportError.emptyFile }
            // Same-directory move = atomic rename on APFS.
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(
                    destination, withItemAt: temp
                )
            } else {
                try FileManager.default.moveItem(at: temp, to: destination)
            }
            FileProtection.apply(.sensitiveLocalDocument, to: destination)
            let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return ImportOutcome(
                contentHash: hex,
                fileSize: total,
                relativePath: "\(documentID.uuidString)/original.\(fileExtension)"
            )
        } catch {
            try? FileManager.default.removeItem(at: temp) // no half-imports
            throw error
        }
    }

    /// Imports raw bytes (camera capture / scanner output / photos):
    /// hash over the full data, then atomic write. Photo-scale payloads
    /// are bounded by the capture pipeline, so a one-shot write is safe
    /// here (file-URL imports use the streaming path above).
    func importData(
        _ data: Data, documentID: UUID, fileExtension: String
    ) throws -> ImportOutcome {
        guard !data.isEmpty else { throw ImportError.emptyFile }
        let dir = directory(for: documentID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileProtection.apply(.sensitiveLocalDocument, to: dir)
        let destination = originalURL(documentID: documentID, fileExtension: fileExtension)
        do {
            try data.write(to: destination, options: [.atomic, .completeFileProtection])
        } catch {
            throw ImportError.createFailed
        }
        FileProtection.apply(.sensitiveLocalDocument, to: destination)
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ImportOutcome(
            contentHash: hex,
            fileSize: Int64(data.count),
            relativePath: "\(documentID.uuidString)/original.\(fileExtension)"
        )
    }

    // MARK: - Extraction sidecar

    /// Persists the extraction sidecar (temp file → atomic rename).
    func writeExtraction(_ extraction: InterpreterDocumentExtraction, documentID: UUID) throws {
        guard let json = extraction.encodedJSON() else {
            throw ImportError.createFailed
        }
        let dir = directory(for: documentID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileProtection.apply(.sensitiveLocalDocument, to: dir)
        let temp = dir.appendingPathComponent(".tmp-extraction-\(UUID().uuidString)")
        do {
            try json.data(using: .utf8)?.write(to: temp, options: .atomic)
            let destination = extractionURL(documentID: documentID)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: destination)
            }
            FileProtection.apply(.sensitiveLocalDocument, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    /// Reads the sidecar back (nil when missing or unreadable).
    func readExtraction(documentID: UUID) -> InterpreterDocumentExtraction? {
        guard let data = try? Data(contentsOf: extractionURL(documentID: documentID)),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return InterpreterDocumentExtraction.decode(json)
    }

    // MARK: - Form-draft sidecar (第二十一轮：俄语表单逐项填写)

    /// 表单填写草稿 sidecar（字段清单、用户值、状态 —— 全部设备本地，
    /// 绝不进 wire / outbox / 备份之外的第二份存储）。同一文档只有这
    /// 一份活动草稿；随文档目录一起被 removeFiles 删除。
    func formDraftURL(documentID: UUID) -> URL {
        directory(for: documentID)
            .appendingPathComponent(InterpreterFormDraft.fileName)
    }

    /// Persists the form-draft sidecar (temp file → atomic rename, the
    /// extraction-sidecar contract).
    func writeFormDraft(_ draft: InterpreterFormDraft, documentID: UUID) throws {
        guard let json = draft.encodedJSON() else {
            throw ImportError.createFailed
        }
        let dir = directory(for: documentID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileProtection.apply(.sensitiveLocalDocument, to: dir)
        let temp = dir.appendingPathComponent(".tmp-form-draft-\(UUID().uuidString)")
        do {
            try json.data(using: .utf8)?.write(to: temp, options: .atomic)
            let destination = formDraftURL(documentID: documentID)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: destination)
            }
            FileProtection.apply(.sensitiveLocalDocument, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    /// Reads the form draft back (nil when missing, unreadable or not
    /// belonging to this document).
    func readFormDraft(documentID: UUID) -> InterpreterFormDraft? {
        guard let data = try? Data(contentsOf: formDraftURL(documentID: documentID)),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return InterpreterFormDraft.decode(json, documentID: documentID)
    }

    func formDraftExists(documentID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: formDraftURL(documentID: documentID).path)
    }

    // MARK: - Page thumbnails

    func writePageThumbnail(_ data: Data, documentID: UUID, pageNumber: Int) {
        let dir = directory(for: documentID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = pageThumbnailURL(documentID: documentID, pageNumber: pageNumber)
        try? data.write(to: url, options: .atomic)
        FileProtection.apply(.sensitiveLocalDocument, to: url)
    }

    func pageThumbnailData(documentID: UUID, pageNumber: Int) -> Data? {
        try? Data(contentsOf: pageThumbnailURL(documentID: documentID, pageNumber: pageNumber))
    }

    /// The original file's URL resolved from a row's relative path
    /// (nil when the row has no file or the path escapes the store root).
    func originalURL(forRelativePath relativePath: String) -> URL? {
        guard !relativePath.isEmpty else { return nil }
        // Path containment: the stored relative path must stay inside the
        // store root (defense against a corrupted/edited row).
        let candidate = root.appendingPathComponent(relativePath)
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        guard candidatePath.hasPrefix(rootPath + "/") else { return nil }
        return candidate
    }

    // MARK: - Deletion / cleanup

    /// Removes every file of one document (document deletion — the
    /// original, sidecar and thumbnails go together). Best-effort.
    func removeFiles(for documentID: UUID) {
        try? FileManager.default.removeItem(at: directory(for: documentID))
    }

    /// Removes the original file only (the "保留提取文字，删除原始文件"
    /// end-of-conversation option). The sidecar and thumbnails stay.
    func removeOriginal(for documentID: UUID, fileExtension: String) {
        try? FileManager.default.removeItem(
            at: originalURL(documentID: documentID, fileExtension: fileExtension)
        )
    }

    /// Removes everything (account-local purge). Best-effort.
    func removeAll() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Self.protectRoot(root)
    }

    /// Removes left-over `.tmp-*` files under every document directory
    /// (launch/foreground reconcile: an interrupted import or sidecar
    /// write leaves nothing behind anyway, but a killed process between
    /// create and rename can).
    func removeStaleTempFiles() {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }
        for dir in dirs where dir.hasDirectoryPath {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil
            ) else { continue }
            for file in files where file.lastPathComponent.hasPrefix(".tmp-") {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// Total bytes under the store (storage management UI).
    func totalBytes() -> Int64 {
        var total: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            ), values.isRegularFile == true, let size = values.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }

    /// Bytes of one document's files.
    func documentBytes(for documentID: UUID) -> Int64 {
        var total: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(
            at: directory(for: documentID),
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            ), values.isRegularFile == true, let size = values.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }

    /// Deletes left-over files: directories that no longer correspond to
    /// a live document row. `liveIDs` is the set of document ids that
    /// still exist in the database.
    func removeOrphans(liveIDs: Set<UUID>) {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }
        for dir in dirs {
            guard dir.hasDirectoryPath,
                  let id = UUID(uuidString: dir.lastPathComponent) else { continue }
            if !liveIDs.contains(id) {
                try? FileManager.default.removeItem(at: dir)
            }
        }
    }

    enum ImportError: Error, LocalizedError, Sendable {
        case emptyFile
        case createFailed

        var errorDescription: String? {
            switch self {
            case .emptyFile: return String(localized: "文件为空")
            case .createFailed: return String(localized: "无法写入文件")
            }
        }
    }
}
