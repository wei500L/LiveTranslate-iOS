import Foundation

/// Supported classroom record export formats.
enum ExportFormat: String, CaseIterable, Codable, Sendable, Identifiable {
    case markdown
    case bilingualTXT
    case russianTXT
    case chineseTXT
    case json
    case srt

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .markdown: return String(localized: "Markdown (bilingual)")
        case .bilingualTXT: return String(localized: "Plain text (bilingual)")
        case .russianTXT: return String(localized: "Plain text (Russian)")
        case .chineseTXT: return String(localized: "Plain text (Chinese)")
        case .json: return "JSON"
        case .srt: return "SRT subtitles"
        }
    }

    var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .bilingualTXT, .russianTXT, .chineseTXT: return "txt"
        case .json: return "json"
        case .srt: return "srt"
        }
    }
}

/// One exported utterance.
struct ExportEntry: Sendable, Identifiable, Equatable {
    let sequenceID: Int
    let startOffset: TimeInterval
    let endOffset: TimeInterval
    let originalText: String
    let translatedText: String?
    let createdAt: Date

    var id: Int { sequenceID }
}

/// One user-typed note. `anchorOffset` is the session-relative timestamp of
/// the transcript entry the note was taken about (nil = unanchored note).
struct ExportNote: Sendable, Identifiable, Equatable {
    let id: UUID
    let text: String
    let createdAt: Date
    let anchorOffset: TimeInterval?

    init(id: UUID, text: String, createdAt: Date, anchorOffset: TimeInterval?) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.anchorOffset = anchorOffset
    }
}

/// Everything a session export needs. Plain values only — exports must
/// never contain API keys, auth headers, internal paths or raw stacks.
struct TranscriptExportData: Sendable, Equatable {
    let title: String
    let startTime: Date
    let endTime: Date?
    let duration: TimeInterval
    let backend: ASRBackendKind
    let modelVersion: String
    /// "CPU + GPU" / "CPU + Neural Engine" / "INT8 · 2 threads" etc.
    let computeDescription: String
    let translationModel: String
    let entries: [ExportEntry]
    /// The user's own classroom notes (empty when none were taken).
    var notes: [ExportNote] = []

    init(
        title: String,
        startTime: Date,
        endTime: Date?,
        duration: TimeInterval,
        backend: ASRBackendKind,
        modelVersion: String,
        computeDescription: String,
        translationModel: String,
        entries: [ExportEntry],
        notes: [ExportNote] = []
    ) {
        self.title = title
        self.startTime = startTime
        self.endTime = endTime
        self.duration = duration
        self.backend = backend
        self.modelVersion = modelVersion
        self.computeDescription = computeDescription
        self.translationModel = translationModel
        self.entries = entries
        self.notes = notes
    }
}

enum TranscriptExporter {
    /// Unified model identity printed in every export header.
    static let modelIdentity = "GigaAM-v3 e2e_rnnt"

    // MARK: - Public API

    static func export(_ data: TranscriptExportData, format: ExportFormat) -> String {
        switch format {
        case .markdown: return markdown(data)
        case .bilingualTXT: return bilingualTXT(data)
        case .russianTXT: return singleLanguageTXT(data, translated: false)
        case .chineseTXT: return singleLanguageTXT(data, translated: true)
        case .json: return json(data)
        case .srt: return srt(data)
        }
    }

    static func exportData(_ data: TranscriptExportData, format: ExportFormat) -> Data {
        Data(export(data, format: format).utf8)
    }

    /// File-system-safe export file name.
    static func suggestedFileName(title: String, format: ExportFormat, date: Date = .now) -> String {
        let sanitized = title
            .replacingOccurrences(of: "[\\\\/:*?\"<>|\\s]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let stamp = Self.fileStampFormatter.string(from: date)
        let base = sanitized.isEmpty ? "Classroom" : String(sanitized.prefix(60))
        return "LiveTranslate-\(base)-\(stamp).\(format.fileExtension)"
    }

    /// Write the export to a temporary file for the share sheet.
    static func writeTemporaryFile(
        data: TranscriptExportData,
        format: ExportFormat,
        fileManager: FileManager = .default
    ) throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent(suggestedFileName(title: data.title, format: format))
        try exportData(data, format: format).write(to: url, options: .atomic)
        return url
    }

    // MARK: - Markdown

    private static func markdown(_ data: TranscriptExportData) -> String {
        var lines: [String] = []
        lines.append("# \(data.title)")
        lines.append("")
        lines.append("- \(String(localized: "Start")): \(dateTimeFormatter.string(from: data.startTime))")
        if let end = data.endTime {
            lines.append("- \(String(localized: "End")): \(dateTimeFormatter.string(from: end))")
        }
        lines.append("- \(String(localized: "Duration")): \(durationText(data.duration))")
        lines.append("- \(String(localized: "Model")): \(modelIdentity)")
        lines.append("- \(String(localized: "ASR backend")): \(data.backend.displayName)")
        lines.append("- \(String(localized: "Compute")): \(data.computeDescription)")
        if !data.translationModel.isEmpty {
            lines.append("- \(String(localized: "Translation model")): \(data.translationModel)")
        }
        lines.append("")
        // The user's own notes come first — they are the shortest path back
        // into the material when reviewing.
        if !data.notes.isEmpty {
            lines.append("## \(String(localized: "Class notes"))")
            lines.append("")
            for note in data.notes {
                let stamp = note.anchorOffset.map { "[\(mmss($0))] " } ?? ""
                lines.append("- \(stamp)\(note.text)")
            }
            lines.append("")
        }
        lines.append("---")
        lines.append("")
        for entry in data.entries {
            lines.append("**[\(mmss(entry.startOffset))]** \(entry.originalText)")
            lines.append("")
            if let translated = entry.translatedText, !translated.isEmpty {
                lines.append(translated)
                lines.append("")
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    // MARK: - TXT

    private static func bilingualTXT(_ data: TranscriptExportData) -> String {
        var lines: [String] = []
        lines.append("# \(data.title) — \(dateTimeFormatter.string(from: data.startTime))")
        lines.append("\(modelIdentity) · \(data.backend.shortLabel)")
        lines.append("")
        for entry in data.entries {
            lines.append("[\(mmss(entry.startOffset))] \(entry.originalText)")
            if let translated = entry.translatedText, !translated.isEmpty {
                lines.append("→ \(translated)")
            }
            lines.append("")
        }
        if !data.notes.isEmpty {
            lines.append("— \(String(localized: "Class notes")) —")
            lines.append("")
            for note in data.notes {
                let stamp = note.anchorOffset.map { "[\(mmss($0))] " } ?? ""
                lines.append("✎ \(stamp)\(note.text)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func singleLanguageTXT(_ data: TranscriptExportData, translated: Bool) -> String {
        var lines: [String] = []
        lines.append("# \(data.title) — \(dateTimeFormatter.string(from: data.startTime))")
        lines.append("")
        for entry in data.entries {
            let text: String
            if translated {
                text = entry.translatedText ?? ""
            } else {
                text = entry.originalText
            }
            if !text.isEmpty {
                lines.append("[\(mmss(entry.startOffset))] \(text)")
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    // MARK: - SRT

    private static func srt(_ data: TranscriptExportData) -> String {
        var blocks: [String] = []
        for (index, entry) in data.entries.enumerated() {
            var block = "\(index + 1)\n"
            block += "\(srtTimestamp(entry.startOffset)) --> \(srtTimestamp(max(entry.endOffset, entry.startOffset + 0.001)))\n"
            block += entry.originalText
            if let translated = entry.translatedText, !translated.isEmpty {
                block += "\n\(translated)"
            }
            blocks.append(block)
        }
        return blocks.joined(separator: "\n\n") + (blocks.isEmpty ? "" : "\n")
    }

    // MARK: - JSON

    private static func json(_ data: TranscriptExportData) -> String {
        var object: [String: Any] = [
            "title": data.title,
            "startTime": isoFormatter.string(from: data.startTime),
            "duration": data.duration,
            "model": modelIdentity,
            "backend": data.backend.rawValue,
            "backendDisplayName": data.backend.displayName,
            "modelVersion": data.modelVersion,
            "compute": data.computeDescription,
            "entryCount": data.entries.count,
            "entries": data.entries.map { entry in
                var item: [String: Any] = [
                    "sequenceID": entry.sequenceID,
                    "startOffset": entry.startOffset,
                    "endOffset": entry.endOffset,
                    "originalText": entry.originalText,
                    "createdAt": isoFormatter.string(from: entry.createdAt),
                ]
                if let translated = entry.translatedText {
                    item["translatedText"] = translated
                }
                return item
            },
        ]
        if let end = data.endTime {
            object["endTime"] = isoFormatter.string(from: end)
        }
        if !data.translationModel.isEmpty {
            object["translationModel"] = data.translationModel
        }
        if !data.notes.isEmpty {
            object["notes"] = data.notes.map { note in
                var item: [String: Any] = [
                    "text": note.text,
                    "createdAt": isoFormatter.string(from: note.createdAt),
                ]
                if let offset = note.anchorOffset {
                    item["anchorOffset"] = offset
                }
                return item
            }
        }
        let jsonData = (try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys]
        )) ?? Data("{}".utf8)
        return String(data: jsonData, encoding: .utf8) ?? "{}"
    }

    // MARK: - Formatting helpers

    private static let fileStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// `[mm:ss]` session-relative stamp. Minutes keep growing past 59 so a
    /// two-hour classroom shows `[125:30]` rather than silently wrapping.
    static func mmss(_ offset: TimeInterval) -> String {
        let total = max(0, Int(offset.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// `hh:mm:ss,mmm` SRT timestamp relative to session start.
    static func srtTimestamp(_ offset: TimeInterval) -> String {
        let clamped = max(0, offset)
        let totalMillis = Int((clamped * 1000).rounded())
        let hours = totalMillis / 3_600_000
        let minutes = (totalMillis % 3_600_000) / 60_000
        let seconds = (totalMillis % 60_000) / 1000
        let millis = totalMillis % 1000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, millis)
    }

    /// `h:mm:ss` duration text for the Markdown header.
    static func durationText(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
