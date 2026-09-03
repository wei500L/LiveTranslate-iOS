import Foundation

/// Presentation-layer helper that turns a stored session + entries into the
/// existing `TranscriptExporter` input and writes a temporary file for the
/// system Share Sheet. The export *formats themselves* stay in the Export
/// module — this is purely binding glue.
enum SessionExport {
    /// Which image files ride along an export (课堂资料包).
    enum AttachmentFileOption: String, Sendable, CaseIterable, Identifiable {
        case none
        case previews
        case originals

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .none: return String(localized: "不包含图片文件")
            case .previews: return String(localized: "附带图片（压缩版）")
            case .originals: return String(localized: "附带图片（原图）")
            }
        }
    }

    /// Temp files older than this are pruned on the next export (the
    /// system also evicts tmp/ under storage pressure; this bounds the
    /// common case ourselves).
    private static let staleFileLifetime: TimeInterval = 24 * 60 * 60

    /// Build the export payload from persisted data. The scope selects
    /// which parts ride along; `review` is the classroom's current review
    /// content when the scope includes it. Attachments (metadata +
    /// analysis) ride in the fullMaterial scope.
    @MainActor
    static func payload(
        session: ClassroomSession,
        entries: [TranscriptEntry],
        notes: [SessionNote] = [],
        scope: ExportScope = .transcriptAndNotes,
        review: StudyReviewContent? = nil,
        attachments: [SessionAttachment] = [],
        corrections: [TranscriptCorrection] = [],
        fallbackBackend: ASRBackendKind
    ) -> TranscriptExportData {
        let ordered = entries.sorted { $0.sequenceID < $1.sequenceID }
        let entriesByID = Dictionary(
            ordered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let correctionsByEntry = Dictionary(
            corrections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let includesTranscript = scope != .reviewOnly
        let includeNotes = scope == .transcriptAndNotes || scope == .fullMaterial
        let includeReview = scope == .reviewOnly || scope == .fullMaterial
        let includeAttachments = scope == .fullMaterial
        return TranscriptExportData(
            title: session.title,
            startTime: session.startTime,
            endTime: session.endTime,
            duration: session.duration,
            backend: ASRBackendKind(rawValue: session.asrBackend) ?? fallbackBackend,
            modelVersion: session.modelVersion,
            computeDescription: session.computePreference,
            translationModel: session.translationModel,
            entries: includesTranscript ? ordered.map { entry in
                let correction = correctionsByEntry[entry.id]
                let effectiveRussian = entry.effectiveRussianText(correction: correction)
                let effectiveChinese = entry.effectiveChineseText(correction: correction)
                // JSON-only provenance: model raw + user correction.
                let corrected = entry.isCorrected(correction: correction)
                return ExportEntry(
                    sequenceID: entry.sequenceID,
                    startOffset: entry.startOffset,
                    endOffset: entry.endOffset,
                    originalText: effectiveRussian,
                    translatedText: effectiveChinese,
                    createdAt: entry.createdAt,
                    modelRussianText: corrected ? entry.originalText : nil,
                    modelChineseText: corrected ? entry.translatedText : nil,
                    correctedRussianText: correction?.russianText,
                    correctedChineseText: correction?.chineseText
                )
            } : [],
            notes: includeNotes ? notes.map { note in
                ExportNote(
                    id: note.id,
                    text: note.text,
                    createdAt: note.createdAt,
                    anchorOffset: note.anchorEntryID.flatMap { entriesByID[$0]?.startOffset }
                )
            } : [],
            review: (includeReview ? review : nil).map { content in
                ExportReview(
                    topic: content.topic,
                    summary: content.summary,
                    sections: content.markdownSections.map { section in
                        ExportReview.Section(title: section.title, body: section.body)
                    },
                    contentJSON: content.encodedString() ?? ""
                )
            },
            attachments: includeAttachments ? attachments.map { attachment in
                let analysis = AttachmentAnalysisResult.decode(attachment.analysisJSON)
                let captured = attachment.capturedAt.timeIntervalSince(session.startTime)
                return ExportAttachment(
                    id: attachment.id,
                    kindName: attachment.kind.displayName,
                    title: attachment.title,
                    caption: attachment.caption,
                    capturedOffset: captured >= 0 ? captured : nil,
                    anchorOffset: attachment.anchorEntryID.flatMap { entriesByID[$0]?.startOffset },
                    mimeType: attachment.mimeType,
                    fileSize: attachment.fileSize,
                    visibleText: analysis?.visibleText ?? [],
                    formulas: analysis?.formulas ?? [],
                    codeBlocks: analysis?.codeBlocks ?? [],
                    keyPoints: analysis?.keyPoints ?? [],
                    explanation: analysis?.explanation ?? "",
                    ocrText: attachment.ocrText
                )
            } : [],
            includesTranscript: includesTranscript
        )
    }

    /// Write the export file(s) for sharing. With image files requested,
    /// returns the document PLUS the image copies (课堂资料包 — multiple
    /// share items, no hand-rolled zip). Missing originals (reclaimed
    /// after sync) fall back to their previews; an image with no local
    /// file is skipped rather than silently missing.
    @MainActor
    static func writeTemporaryFiles(
        session: ClassroomSession,
        entries: [TranscriptEntry],
        notes: [SessionNote] = [],
        scope: ExportScope = .transcriptAndNotes,
        review: StudyReviewContent? = nil,
        attachments: [SessionAttachment] = [],
        corrections: [TranscriptCorrection] = [],
        attachmentFiles: AttachmentFileOption,
        format: ExportFormat,
        fallbackBackend: ASRBackendKind
    ) async -> [URL] {
        let data = payload(
            session: session,
            entries: entries,
            notes: notes,
            scope: scope,
            review: review,
            attachments: attachments,
            corrections: corrections,
            fallbackBackend: fallbackBackend
        )
        // Plain-value snapshot for the file copies — SwiftData models
        // never cross the isolation boundary.
        struct ImageCopyRequest: Sendable {
            let attachmentID: UUID
            let sessionID: UUID
            let title: String
            let kindName: String
            let mimeType: String
        }
        let sessionID = session.id
        let requests: [ImageCopyRequest] = attachments.map { attachment in
            ImageCopyRequest(
                attachmentID: attachment.id,
                sessionID: sessionID,
                title: attachment.title,
                kindName: attachment.kind.displayName,
                mimeType: attachment.mimeType
            )
        }
        let fileOption = attachmentFiles
        return await Task.detached(priority: .userInitiated) { () -> [URL] in
            Self.pruneStaleTemporaryFiles()
            var urls: [URL] = []
            if let document = Self.writeUnique(data: data, format: format) {
                urls.append(document)
            }
            guard fileOption != .none, !requests.isEmpty else { return urls }
            // Image copies into one export directory, numbered by timeline
            // order so any receiver sees them in class order.
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "LiveTranslate-Images-\(Int(Date().timeIntervalSince1970))",
                    isDirectory: true
                )
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (index, request) in requests.enumerated() {
                let store = AttachmentFileStoreShared.store
                let bytes: Data?
                switch fileOption {
                case .originals:
                    bytes = store?.originalData(
                        for: request.attachmentID, sessionID: request.sessionID
                    ) ?? store?.previewOrOriginalData(
                        for: request.attachmentID, sessionID: request.sessionID
                    )
                case .previews:
                    bytes = store?.previewOrOriginalData(
                        for: request.attachmentID, sessionID: request.sessionID
                    )
                case .none:
                    bytes = nil
                }
                guard let bytes else { continue } // no local file — skipped
                let ext = fileOption == .originals
                    ? AttachmentFileStore.fileExtension(forMIME: request.mimeType)
                    : "jpg"
                let name = String(
                    format: "%02d-%@.%@", index + 1,
                    sanitizeFileName(request.title.isEmpty ? request.kindName : request.title),
                    ext
                )
                let url = dir.appendingPathComponent(name)
                do {
                    try bytes.write(to: url, options: .atomic)
                    urls.append(url)
                } catch {
                    // One failing image never blocks the share of the rest.
                    continue
                }
            }
            return urls
        }.value
    }

    private nonisolated static func sanitizeFileName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(
            of: "[\\\\/:*?\"<>|\\s]+", with: "-", options: .regularExpression
        )
        return String(cleaned.prefix(40))
    }

    /// Write the export file for sharing (document only).
    ///
    /// Sendable boundary: the SwiftData models are MainActor-isolated, so
    /// this entry point stays on the main actor and converts everything
    /// into the immutable `TranscriptExportData` value snapshot *before*
    /// any isolation crossing. Only that snapshot plus the `ExportFormat`
    /// enum (both plain Sendable values) reach the background task — no
    /// model, no ModelContext, no view model, no actor-isolated object.
    /// Returns nil on failure so callers surface an honest error rather
    /// than a silent no-op.
    @MainActor
    static func writeTemporaryFile(
        session: ClassroomSession,
        entries: [TranscriptEntry],
        notes: [SessionNote] = [],
        scope: ExportScope = .transcriptAndNotes,
        review: StudyReviewContent? = nil,
        attachments: [SessionAttachment] = [],
        corrections: [TranscriptCorrection] = [],
        format: ExportFormat,
        fallbackBackend: ASRBackendKind
    ) async -> URL? {
        let data = payload(
            session: session,
            entries: entries,
            notes: notes,
            scope: scope,
            review: review,
            attachments: attachments,
            corrections: corrections,
            fallbackBackend: fallbackBackend
        )
        return await writeSnapshot(data: data, format: format)
    }

    /// Format + write the already-Sendable snapshot off the main actor, so
    /// a long transcript never freezes the UI mid-share.
    static func writeSnapshot(
        data: TranscriptExportData,
        format: ExportFormat
    ) async -> URL? {
        await Task.detached(priority: .userInitiated) { () -> URL? in
            Self.pruneStaleTemporaryFiles()
            return Self.writeUnique(data: data, format: format)
        }.value
    }

    /// `TranscriptExporter.suggestedFileName` is minute-granular, so a
    /// repeated export of the same session within one minute would silently
    /// replace a file that may still be open in the share sheet. Append a
    /// counter instead. The file name itself stays sanitized and content
    /// formatting stays entirely inside `TranscriptExporter`.
    private static func writeUnique(data: TranscriptExportData, format: ExportFormat) -> URL? {
        let directory = FileManager.default.temporaryDirectory
        let baseName = TranscriptExporter.suggestedFileName(title: data.title, format: format)
        var url = directory.appendingPathComponent(baseName)
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            let stem = (baseName as NSString).deletingPathExtension
            let ext = (baseName as NSString).pathExtension
            url = directory.appendingPathComponent("\(stem)-\(suffix).\(ext)")
            suffix += 1
        }
        do {
            try TranscriptExporter.exportData(data, format: format).write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Remove our own stale exports from tmp/ (best effort; never fatal).
    private static func pruneStaleTemporaryFiles() {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
        guard
            let contents = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
            )
        else { return }
        let cutoff = Date().addingTimeInterval(-staleFileLifetime)
        for url in contents where url.lastPathComponent.hasPrefix("LiveTranslate-") {
            let modified = try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
            if let modified, modified < cutoff {
                try? fileManager.removeItem(at: url)
            }
        }
    }
}
