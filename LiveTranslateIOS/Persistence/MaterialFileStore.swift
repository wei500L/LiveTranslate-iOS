import Foundation
import CryptoKit
import UniformTypeIdentifiers

/// The single component that owns course-material file paths and writes.
/// Views and ViewModels NEVER build material paths themselves — the same
/// rule AttachmentFileStore established for classroom images.
///
/// Layout (per account scope, see AccountScope.materialsRoot):
///
///     <root>/<materialID>/original.<ext>
///     <root>/<materialID>/page-<n>.jpg
///
/// Two renditions only:
///   - original: the untouched imported bytes (PDF / TXT / MD / image /
///     office document — whatever the user imported);
///   - page-n: a ~600px JPEG page thumbnail (PDF pages and image
///     materials), a CACHE that can be regenerated at any time from the
///     original (never synced, reaped on delete/re-extract).
///
/// Materials created from a classroom image (`sourceAttachmentID`) never
/// write here at all — the attachment's renditions are borrowed, so the
/// same photo is never stored twice.
///
/// All writes go temp-file → atomic rename (the AttachmentFileStore
/// contract): an interrupted import can never leave a database row whose
/// files are half-present.
struct MaterialFileStore: Sendable {
    /// Thumbnail edge length in pixels (page thumbnails; caches only).
    static let pageThumbnailMaxDimension = 600

    let root: URL

    /// File store scoped to a profile (account or guest).
    init(accountID: UUID?) {
        self.root = AccountScope.materialsRoot(accountID: accountID)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Store-internal init for tests/demo containers.
    init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Canonical file extension for a MIME type (sync write-backs and
    /// duplicate imports). Unknown types fall back to bin.
    static func fileExtension(forMIME mime: String) -> String {
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

    /// Canonical extension for an imported file name (the picker's source
    /// of truth) with a MIME fallback.
    static func fileExtension(fileName: String, mime: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if !ext.isEmpty { return ext }
        return fileExtension(forMIME: mime)
    }

    // MARK: - Paths

    /// The one directory holding a material's files.
    func directory(for materialID: UUID) -> URL {
        root.appendingPathComponent(materialID.uuidString, isDirectory: true)
    }

    /// Path of the original file. The extension follows the import's
    /// (pdf/txt/md/jpg/…/bin).
    func originalURL(materialID: UUID, fileExtension: String) -> URL {
        directory(for: materialID)
            .appendingPathComponent("original.\(fileExtension)")
    }

    /// Path of one page thumbnail cache.
    func pageThumbnailURL(materialID: UUID, pageNumber: Int) -> URL {
        directory(for: materialID)
            .appendingPathComponent("page-\(pageNumber).jpg")
    }

    func originalExists(materialID: UUID, fileExtension: String) -> Bool {
        FileManager.default.fileExists(
            atPath: originalURL(materialID: materialID, fileExtension: fileExtension).path
        )
    }

    /// Bytes of the original file (export / Quick Look / small files).
    /// Nil when missing. Large-PDF consumers must use `originalURL` and
    /// stream instead of loading everything into memory.
    func originalData(materialID: UUID, fileExtension: String) -> Data? {
        try? Data(contentsOf: originalURL(
            materialID: materialID, fileExtension: fileExtension
        ))
    }

    // MARK: - Import

    /// Metadata gathered while importing a file.
    struct ImportOutcome: Sendable {
        var contentHash: String
        var fileSize: Int64
    }

    /// Streams a file from `sourceURL` into the store: computes SHA-256
    /// and copies bytes in 1 MiB chunks — a 200 MB PDF never fully enters
    /// memory. The copy lands as a temp file first and is atomically
    /// renamed into place, so an interrupted import leaves nothing behind.
    func importFile(
        at sourceURL: URL, materialID: UUID, fileExtension: String
    ) throws -> ImportOutcome {
        let dir = directory(for: materialID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = originalURL(materialID: materialID, fileExtension: fileExtension)
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
            let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return ImportOutcome(contentHash: hex, fileSize: total)
        } catch {
            try? FileManager.default.removeItem(at: temp) // no half-imports
            throw error
        }
    }

    /// Writes bytes received from the server (temp file → atomic rename —
    /// the synced-download path for small files; PDFs ride the same path
    /// because URLSession materializes the response anyway).
    func writeSyncedOriginal(
        _ data: Data, materialID: UUID, fileExtension: String
    ) throws {
        let dir = directory(for: materialID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(
            to: originalURL(materialID: materialID, fileExtension: fileExtension),
            options: .atomic
        )
    }

    // MARK: - Page thumbnail cache

    /// Persists one page thumbnail (regenerable cache — absent is normal).
    func writePageThumbnail(_ data: Data, materialID: UUID, pageNumber: Int) {
        let dir = directory(for: materialID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: pageThumbnailURL(materialID: materialID, pageNumber: pageNumber))
    }

    func pageThumbnailData(materialID: UUID, pageNumber: Int) -> Data? {
        try? Data(contentsOf: pageThumbnailURL(
            materialID: materialID, pageNumber: pageNumber
        ))
    }

    func pageThumbnailExists(materialID: UUID, pageNumber: Int) -> Bool {
        FileManager.default.fileExists(
            atPath: pageThumbnailURL(materialID: materialID, pageNumber: pageNumber).path
        )
    }

    /// Drops every page thumbnail (re-extraction / re-OCR reset). The
    /// original file stays.
    func removeAllPageCaches(for materialID: UUID) {
        let dir = directory(for: materialID)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.lastPathComponent.hasPrefix("page-") {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Deletion / cleanup

    /// Removes every file of one material (material deletion — the
    /// original AND the derived page caches go together). Best-effort.
    func removeFiles(for materialID: UUID) {
        try? FileManager.default.removeItem(at: directory(for: materialID))
    }

    /// Removes everything (account-local purge). Best-effort.
    func removeAll() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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

    /// Bytes of one material's files.
    func materialBytes(for materialID: UUID) -> Int64 {
        var total: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(
            at: directory(for: materialID),
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
    /// a live material row. `liveIDs` is the set of material ids that
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
