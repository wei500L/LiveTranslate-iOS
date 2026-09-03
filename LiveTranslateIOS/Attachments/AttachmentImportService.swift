import Foundation
import OSLog
import UIKit

/// The classroom-image import pipeline:
///
///     pick/capture bytes
///     → AttachmentFileStore.processImport (hash, dimensions, preview,
///       analysis copy)
///     → duplicate check by hash (prompt, NEVER auto-delete)
///     → write files (temp → atomic; on failure the partial bundle is
///       removed — no orphan half-bundles)
///     → persist the metadata row LAST (an interrupted import never leaves
///       a row whose files are missing)
///     → optional local OCR (failure tolerated, empty text fine)
///
/// One import service per profile. All heavy work runs off the main
/// actor; the repository write hops back.
@MainActor
@Observable
final class AttachmentImportService {
    static let logger = Logger(subsystem: "com.livetranslate.ios", category: "attachment-import")

    struct ImportOutcome: Equatable, Sendable {
        var imported: [UUID]
        var duplicates: [String] // hashes already present in the session
        var failures: [String]   // per-item error descriptions
    }

    /// Transient observable state for the live-classroom capture UI.
    private(set) var isImporting = false
    /// Brief success feedback (含数量) for the capture sheet.
    private(set) var lastOutcome: ImportOutcome?

    private let repository: any ClassroomRepositoryProtocol
    private let fileStore: AttachmentFileStore

    init(repository: any ClassroomRepositoryProtocol, fileStore: AttachmentFileStore) {
        self.repository = repository
        self.fileStore = fileStore
    }

    /// Imports one or more images into a session. Anchored to the
    /// currently-displayed transcript entry by default (the anchor is
    /// metadata — nil keeps the image session-scoped).
    func importImages(
        _ payloads: [AttachmentImagePayload], sessionID: UUID,
        defaultKind: AttachmentKind, anchorEntryID: UUID?
    ) async -> ImportOutcome {
        guard !payloads.isEmpty else {
            return ImportOutcome(imported: [], duplicates: [], failures: [])
        }
        isImporting = true
        defer { isImporting = false }

        var outcome = ImportOutcome(imported: [], duplicates: [], failures: [])
        // The session's course rides the attachment for display bookkeeping.
        let courseID = try? repository.courseID(sessionID: sessionID)
        // sortIndex continues the session's existing timeline.
        let existingCount = (try? repository.attachments(forSessionID: sessionID).count) ?? 0
        var sortIndex = existingCount

        for payload in payloads {
            do {
                let processed = try fileStore.processImport(payload.data)
                // Duplicate detection by content hash — surface, never
                // silently drop (the user decides).
                if try repository.attachmentExists(
                    sessionID: sessionID, contentHash: processed.contentHash
                ) {
                    outcome.duplicates.append(processed.contentHash)
                    continue
                }
                let attachmentID = UUID()
                try fileStore.write(
                    original: payload.data, importResult: processed,
                    attachmentID: attachmentID, sessionID: sessionID
                )
                let draft = AttachmentDraft(
                    capturedAt: payload.capturedAt ?? .now,
                    title: payload.suggestedTitle ?? defaultKind.displayName,
                    caption: "",
                    kind: payload.suggestedKind ?? defaultKind,
                    mimeType: processed.mimeType,
                    fileExtension: processed.fileExtension,
                    pixelWidth: processed.pixelWidth,
                    pixelHeight: processed.pixelHeight,
                    fileSize: processed.fileSize,
                    contentHash: processed.contentHash,
                    sortIndex: sortIndex,
                    anchorEntryID: anchorEntryID,
                    courseID: courseID
                )
                let attachment = try repository.addAttachment(draft, toSessionID: sessionID)
                sortIndex += 1
                outcome.imported.append(attachment.id)

                // Best-effort local OCR (auxiliary search index only).
                let attachmentObjectID = attachment.id
                Task { [weak self] in
                    guard let self else { return }
                    if let recognized = await AttachmentOCRService.recognize(
                        imageData: processed.previewData
                    ), !recognized.text.isEmpty,
                       let current = try? self.repository.attachment(id: attachmentObjectID) {
                        try? self.repository.updateAttachmentOCRText(
                            current, text: recognized.text
                        )
                    }
                }
            } catch {
                Self.logger.error(
                    "import failed: \(String(describing: error), privacy: .public)"
                )
                outcome.failures.append(
                    (error as? LocalizedError)?.errorDescription
                        ?? String(localized: "导入失败")
                )
                // One bad image never blocks the rest.
                continue
            }
        }
        lastOutcome = outcome
        return outcome
    }
}

/// Raw image bytes as picked/captured, before processing.
struct AttachmentImagePayload: Identifiable, Sendable {
    var id: UUID = UUID()
    var data: Data
    var capturedAt: Date?
    var suggestedTitle: String?
    var suggestedKind: AttachmentKind?
}
