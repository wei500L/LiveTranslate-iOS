import Foundation

/// Presentation-layer helper that turns a stored session + entries into the
/// existing `TranscriptExporter` input and writes a temporary file for the
/// system Share Sheet. The export *formats themselves* stay in the Export
/// module — this is purely binding glue.
enum SessionExport {
    /// Temp files older than this are pruned on the next export (the
    /// system also evicts tmp/ under storage pressure; this bounds the
    /// common case ourselves).
    private static let staleFileLifetime: TimeInterval = 24 * 60 * 60

    /// Build the export payload from persisted data.
    @MainActor
    static func payload(
        session: ClassroomSession,
        entries: [TranscriptEntry],
        fallbackBackend: ASRBackendKind
    ) -> TranscriptExportData {
        let ordered = entries.sorted { $0.sequenceID < $1.sequenceID }
        return TranscriptExportData(
            title: session.title,
            startTime: session.startTime,
            endTime: session.endTime,
            duration: session.duration,
            backend: ASRBackendKind(rawValue: session.asrBackend) ?? fallbackBackend,
            modelVersion: session.modelVersion,
            computeDescription: session.computePreference,
            translationModel: session.translationModel,
            entries: ordered.map { entry in
                ExportEntry(
                    sequenceID: entry.sequenceID,
                    startOffset: entry.startOffset,
                    endOffset: entry.endOffset,
                    originalText: entry.originalText,
                    translatedText: entry.translatedText,
                    createdAt: entry.createdAt
                )
            }
        )
    }

    /// Write the export file for sharing.
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
        format: ExportFormat,
        fallbackBackend: ASRBackendKind
    ) async -> URL? {
        let data = payload(
            session: session, entries: entries, fallbackBackend: fallbackBackend
        )
        return await writeSnapshot(data: data, format: format)
    }

    /// Format + write the already-Sendable snapshot off the main actor, so
    /// a long transcript never freezes the UI mid-share.
    private static func writeSnapshot(
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
