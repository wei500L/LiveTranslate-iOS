import Foundation
import CryptoKit
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// The single component that owns attachment file paths and writes.
/// Views and ViewModels NEVER build attachment paths themselves — they
/// go through this store (the same rule SessionRecordings follows).
///
/// Layout (per account scope, see AccountScope.attachmentsRoot):
///
///     <root>/<sessionID>/<attachmentID>/original.<ext>
///     <root>/<sessionID>/<attachmentID>/preview.jpg
///     <root>/<sessionID>/<attachmentID>/analysis.jpg
///
/// Three distinct renditions:
///   - original: the untouched imported bytes (long-term keep; EXIF-oriented
///     display only);
///   - preview: ~1024px JPEG for lists/grids (cheap to load, cheap to
///     upload first on new devices);
///   - analysis: a downscaled copy tuned for the multimodal model request
///     (keeps small text and formulas legible at a bounded payload size).
///
/// Non-destructive editing: crop/rotate are presentation transforms
/// stored by the caller, or a NEW attachment — this store never rewrites
/// an existing original.
///
/// All writes go temp-file → atomic rename, so an interrupted import can
/// never leave a database row whose files are half-present (the row is
/// only created after the files commit).
struct AttachmentFileStore: Sendable {
    /// Which stored rendition a path refers to.
    enum Variant: String, Sendable, CaseIterable {
        case original
        case preview
        case analysis
    }

    let root: URL

    /// File store scoped to a profile (account or guest).
    init(accountID: UUID?) {
        self.root = AccountScope.attachmentsRoot(accountID: accountID)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Store-internal init for tests/demo containers.
    init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Canonical file extension for a MIME type (used when writing synced
    /// originals back to disk). Unknown types fall back to jpg.
    static func fileExtension(forMIME mime: String) -> String {
        switch mime {
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "image/heic", "image/heif": return "heic"
        case "image/webp": return "webp"
        default: return "jpg"
        }
    }

    // MARK: - Paths

    /// The one directory holding an attachment's renditions.
    func directory(for attachmentID: UUID, sessionID: UUID) -> URL {
        root.appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .appendingPathComponent(attachmentID.uuidString, isDirectory: true)
    }

    /// Path of one rendition. The extension follows the original's mime
    /// for `original`; previews/analysis copies are always JPEG.
    func fileURL(
        for attachmentID: UUID, sessionID: UUID, variant: Variant, fileExtension: String = "jpg"
    ) -> URL {
        let dir = directory(for: attachmentID, sessionID: sessionID)
        switch variant {
        case .original:
            return dir.appendingPathComponent("original.\(fileExtension)")
        case .preview:
            return dir.appendingPathComponent("preview.jpg")
        case .analysis:
            return dir.appendingPathComponent("analysis.jpg")
        }
    }

    func fileExists(for attachmentID: UUID, sessionID: UUID, variant: Variant) -> Bool {
        // The original's extension is not fixed (HEIC/JPEG/PNG); probe the
        // common ones.
        switch variant {
        case .original:
            return ["jpg", "jpeg", "heic", "png", "webp"].contains { ext in
                FileManager.default.fileExists(
                    atPath: fileURL(
                        for: attachmentID, sessionID: sessionID, variant: .original,
                        fileExtension: ext
                    ).path
                )
            }
        default:
            return FileManager.default.fileExists(
                atPath: fileURL(for: attachmentID, sessionID: sessionID, variant: variant).path
            )
        }
    }

    /// All files of one attachment (any rendition present).
    func existingFiles(for attachmentID: UUID, sessionID: UUID) -> [URL] {
        let dir = directory(for: attachmentID, sessionID: sessionID)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return urls.filter { !$0.hasDirectoryPath }
    }

    // MARK: - Import

    /// Metadata gathered while importing image data.
    struct ImportResult: Sendable {
        var contentHash: String
        var fileSize: Int64
        var pixelWidth: Int
        var pixelHeight: Int
        var mimeType: String
        var fileExtension: String
        var previewData: Data
        var analysisData: Data
    }

    /// Processes imported image data into the three-rendition bundle:
    /// returns metadata + the rendered preview/analysis copies (the
    /// caller persists files and then the database row — the row must be
    /// the LAST thing written).
    ///
    /// The original is written verbatim (data as imported — the camera or
    /// PhotosPicker already produced optimized bytes; re-encoding would
    /// only lose quality). EXIF orientation is applied at RENDER time
    /// (UIImage respects it), never baked into the stored original.
    func processImport(_ data: Data) throws -> ImportResult {
        guard !data.isEmpty else { throw ImportError.emptyData }
        let hash = SHA256.hash(data: data)
        let contentHash = hash.map { String(format: "%02x", $0) }.joined()

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any]
        else { throw ImportError.unreadableImage }

        var width = 0, height = 0
        if let w = properties[kCGImagePropertyPixelWidth] as? Int { width = w }
        if let h = properties[kCGImagePropertyPixelHeight] as? Int { height = h }
        guard width > 0, height > 0 else { throw ImportError.unreadableImage }

        let mimeType: String
        var fileExtension = "jpg"
        if let typeID = CGImageSourceGetType(source) as String?,
           let utType = UTType(typeID) {
            mimeType = utType.preferredMIMEType ?? "application/octet-stream"
            if let preferredExt = utType.preferredFilenameExtension {
                fileExtension = preferredExt.lowercased()
            }
        } else {
            mimeType = "application/octet-stream"
        }

        // Render the derived copies (orientation-normalized, JPEG).
        let previewData = try renderJPEG(source: source, maxDimension: 1024, quality: 0.8)
        let analysisData = try renderJPEG(source: source, maxDimension: 2048, quality: 0.72)

        return ImportResult(
            contentHash: contentHash,
            fileSize: Int64(data.count),
            pixelWidth: width,
            pixelHeight: height,
            mimeType: mimeType,
            fileExtension: fileExtension,
            previewData: previewData,
            analysisData: analysisData
        )
    }

    /// Atomically writes all renditions of a NEW attachment. Returns the
    /// original's URL. The original writes as-is; a failure removes the
    /// partial directory (no orphan half-bundles).
    @discardableResult
    func write(
        original: Data, importResult: ImportResult,
        attachmentID: UUID, sessionID: UUID
    ) throws -> URL {
        let dir = directory(for: attachmentID, sessionID: sessionID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try original.write(
                to: fileURL(
                    for: attachmentID, sessionID: sessionID, variant: .original,
                    fileExtension: importResult.fileExtension
                ),
                options: .atomic
            )
            try importResult.previewData.write(
                to: fileURL(for: attachmentID, sessionID: sessionID, variant: .preview),
                options: .atomic
            )
            try importResult.analysisData.write(
                to: fileURL(for: attachmentID, sessionID: sessionID, variant: .analysis),
                options: .atomic
            )
            return fileURL(
                for: attachmentID, sessionID: sessionID, variant: .original,
                fileExtension: importResult.fileExtension
            )
        } catch {
            try? FileManager.default.removeItem(at: dir) // no half-bundles
            throw error
        }
    }

    /// Loads the analysis copy for a model request (nil when the file is
    /// missing — e.g. the local original was reclaimed after sync).
    func analysisData(for attachmentID: UUID, sessionID: UUID) -> Data? {
        try? Data(contentsOf: fileURL(
            for: attachmentID, sessionID: sessionID, variant: .analysis
        ))
    }

    /// Loads the preview JPEG (lists/grids). Falls back to the original
    /// when no preview exists.
    func previewOrOriginalData(for attachmentID: UUID, sessionID: UUID) -> Data? {
        let preview = fileURL(for: attachmentID, sessionID: sessionID, variant: .preview)
        if let data = try? Data(contentsOf: preview) { return data }
        for ext in ["jpg", "jpeg", "heic", "png", "webp"] {
            if let data = try? Data(contentsOf: fileURL(
                for: attachmentID, sessionID: sessionID, variant: .original, fileExtension: ext
            )) { return data }
        }
        return nil
    }

    /// Original bytes (export / upload). Nil when reclaimed.
    func originalData(for attachmentID: UUID, sessionID: UUID) -> Data? {
        for ext in ["jpg", "jpeg", "heic", "png", "webp"] {
            if let data = try? Data(contentsOf: fileURL(
                for: attachmentID, sessionID: sessionID, variant: .original, fileExtension: ext
            )) { return data }
        }
        return nil
    }

    // MARK: - Sync file plumbing

    /// Writes bytes received from the server for one variant (temp file →
    /// atomic rename; the extension is normalized to jpg for the derived
    /// variants and comes from the row's mime for originals — the server
    /// stores the file name's hash, we re-derive our own layout).
    func writeSynced(
        _ data: Data, variant: Variant,
        attachmentID: UUID, sessionID: UUID, fileExtension: String = "jpg"
    ) throws {
        let dir = directory(for: attachmentID, sessionID: sessionID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(
            to: fileURL(
                for: attachmentID, sessionID: sessionID, variant: variant,
                fileExtension: fileExtension
            ),
            options: .atomic
        )
    }

    // MARK: - Deletion / cleanup

    /// Removes every file of one attachment. Best-effort.
    func removeFiles(for attachmentID: UUID, sessionID: UUID) {
        try? FileManager.default.removeItem(
            at: directory(for: attachmentID, sessionID: sessionID)
        )
    }

    /// Removes a whole session's attachments (session deletion). Best-effort.
    func removeSessionFiles(for sessionID: UUID) {
        try? FileManager.default.removeItem(
            at: root.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        )
    }

    /// Removes everything (delete-all-sessions / account-local purge).
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

    /// Bytes of the whole session's attachments.
    func sessionBytes(for sessionID: UUID) -> Int64 {
        var total: Int64 = 0
        let dir = root.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            ), values.isRegularFile == true, let size = values.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }

    /// Deletes left-over temp/corrupt files: directories that no longer
    /// correspond to a live attachment row. `liveIDs` is the set of
    /// attachment ids that still exist in the database.
    func removeOrphans(liveIDs: Set<UUID>) {
        guard let sessionDirs = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }
        for sessionDir in sessionDirs {
            guard sessionDir.hasDirectoryPath else { continue }
            guard let attachmentDirs = try? FileManager.default.contentsOfDirectory(
                at: sessionDir, includingPropertiesForKeys: [.isDirectoryKey]
            ) else { continue }
            for attachmentDir in attachmentDirs {
                guard attachmentDir.hasDirectoryPath,
                      let id = UUID(uuidString: attachmentDir.lastPathComponent) else { continue }
                if !liveIDs.contains(id) {
                    try? FileManager.default.removeItem(at: attachmentDir)
                }
            }
            // Drop the now-empty session directory too.
            if let remaining = try? FileManager.default.contentsOfDirectory(
                at: sessionDir, includingPropertiesForKeys: nil
            ), remaining.isEmpty {
                try? FileManager.default.removeItem(at: sessionDir)
            }
        }
    }

    /// Reclaims local space for fully-synced attachments (storage
    /// management): removes the ORIGINAL files only, keeping previews and
    /// analysis copies. Returns the bytes freed. Rows whose original was
    /// reclaimed can re-download from the server on demand.
    @discardableResult
    func reclaimOriginals(attachmentIDs: [UUID], sessionIDs: [UUID: UUID]) -> Int64 {
        var freed: Int64 = 0
        let fm = FileManager.default
        for id in attachmentIDs {
            guard let sessionID = sessionIDs[id] else { continue }
            for ext in ["jpg", "jpeg", "heic", "png", "webp"] {
                let url = fileURL(
                    for: id, sessionID: sessionID, variant: .original, fileExtension: ext
                )
                if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int {
                    try? fm.removeItem(at: url)
                    freed += Int64(size)
                }
            }
        }
        return freed
    }

    // MARK: - JPEG rendering

    /// Renders a downscaled, orientation-normalized JPEG from a source
    /// image. The analysis copy keeps fine detail (2048px) so board
    /// formulas and small handwriting stay legible to the model.
    private func renderJPEG(source: CGImageSource, maxDimension: Int, quality: CGFloat) throws -> Data {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // applies EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImportError.renderFailed
        }
        let ctx = CGContext(
            data: nil, width: thumb.width, height: thumb.height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        guard let ctx, let data = CFDataCreateMutable(nil, 0) else { throw ImportError.renderFailed }
        ctx.interpolationQuality = .high
        ctx.draw(thumb, in: CGRect(x: 0, y: 0, width: thumb.width, height: thumb.height))
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw ImportError.renderFailed }
        let jpegOptions: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, thumb, jpegOptions as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ImportError.renderFailed }
        return data as Data
    }

    enum ImportError: Error, LocalizedError, Sendable {
        case emptyData
        case unreadableImage
        case renderFailed

        var errorDescription: String? {
            switch self {
            case .emptyData: return String(localized: "图片数据为空")
            case .unreadableImage: return String(localized: "无法读取图片")
            case .renderFailed: return String(localized: "图片处理失败")
            }
        }
    }
}
