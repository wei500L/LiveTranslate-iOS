import Foundation
import SwiftData

/// What a classroom image depicts — presentation grouping + search labels.
enum AttachmentKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case blackboard   // 黑板
    case slides       // 课件/投影
    case handwriting  // 手写笔记
    case document     // 教材或文件
    case chart        // 图表
    case code         // 代码
    case other        // 其他

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .blackboard: return String(localized: "黑板")
        case .slides: return String(localized: "课件")
        case .handwriting: return String(localized: "手写笔记")
        case .document: return String(localized: "教材或文件")
        case .chart: return String(localized: "图表")
        case .code: return String(localized: "代码")
        case .other: return String(localized: "其他")
        }
    }
}

/// Analysis lifecycle of one attachment. `pending` = never analyzed;
/// `analyzing` is device-local progress (like StudyReview's generating)
/// and never syncs; terminal states do.
enum AttachmentAnalysisStatus: String, Codable, Sendable {
    case pending
    case analyzing    // local-only, never pushed
    case completed
    case partial      // some fields parsed, some failed
    case failed
}

/// A classroom image (blackboard photo, slide, handwritten note…) tied to
/// one session, optionally anchored to the transcript entry it was taken
/// about. The anchor is metadata — images survive their entry's deletion
/// (the anchor is then cleared), mirroring SessionNote semantics.
///
/// No SwiftData relationship and no binary payload: the entity carries
/// only metadata; the files (original / preview / analysis copy) live on
/// disk under `AttachmentFileStore`, addressed by `id` + account scope.
/// `contentHash` is the identity contract used for sync upload and
/// duplicate-import detection (duplicates prompt, never auto-delete).
@Model
final class SessionAttachment {
    @Attribute(.unique) var id: UUID
    var sessionID: UUID
    /// The course the SESSION belonged to at capture time (denormalized
    /// snapshot — course deletion clears the session's course but the
    /// attachment keeps this for display/sync bookkeeping; nil = the
    /// session was standalone).
    var courseID: UUID?
    /// The transcript entry this image was taken about (nil = session-only).
    var anchorEntryID: UUID?
    /// When the photo was taken / the image imported.
    var capturedAt: Date
    var title: String
    /// The user's own description (distinct from any AI-generated text).
    var caption: String
    /// Raw value of `AttachmentKind`.
    var kindRaw: String
    var mimeType: String
    var pixelWidth: Int
    var pixelHeight: Int
    /// Size of the ORIGINAL file in bytes (the sync size contract).
    var fileSize: Int64
    /// SHA-256 of the original file bytes (hex).
    var contentHash: String
    /// Manual ordering within the session's timeline (user reorderable).
    var sortIndex: Int
    /// Non-destructive display transform (rotation + normalized crop) as
    /// AttachmentTransform JSON. The ORIGINAL file is never re-encoded;
    /// viewers and exports apply this when rendering. Empty = identity.
    var transformJSON: String
    /// Raw value of `AttachmentAnalysisStatus`.
    var analysisStatusRaw: String
    /// AttachmentAnalysisResult JSON (empty = none). Model output only —
    /// local OCR text is separate (`ocrText`).
    var analysisJSON: String
    /// Local Vision OCR text (user-editable; never mixed with model
    /// output). Empty = not run / no text found.
    var ocrText: String
    var createdAt: Date
    var updatedAt: Date
    /// Cloud-sync metadata (0 = never synced).
    var serverVersion: Int

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        courseID: UUID? = nil,
        anchorEntryID: UUID? = nil,
        capturedAt: Date = .now,
        title: String = "",
        caption: String = "",
        kind: AttachmentKind = .other,
        mimeType: String = "",
        pixelWidth: Int = 0,
        pixelHeight: Int = 0,
        fileSize: Int64 = 0,
        contentHash: String = "",
        sortIndex: Int = 0,
        analysisStatus: AttachmentAnalysisStatus = .pending,
        analysisJSON: String = "",
        ocrText: String = "",
        serverVersion: Int = 0
    ) {
        self.id = id
        self.sessionID = sessionID
        self.courseID = courseID
        self.anchorEntryID = anchorEntryID
        self.capturedAt = capturedAt
        self.title = title
        self.caption = caption
        self.kindRaw = kind.rawValue
        self.mimeType = mimeType
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.fileSize = fileSize
        self.contentHash = contentHash
        self.sortIndex = sortIndex
        self.transformJSON = ""
        self.analysisStatusRaw = analysisStatus.rawValue
        self.analysisJSON = analysisJSON
        self.ocrText = ocrText
        self.createdAt = .now
        self.updatedAt = .now
        self.serverVersion = serverVersion
    }

    var kind: AttachmentKind {
        get { AttachmentKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }

    var analysisStatus: AttachmentAnalysisStatus {
        get { AttachmentAnalysisStatus(rawValue: analysisStatusRaw) ?? .pending }
        set { analysisStatusRaw = newValue.rawValue }
    }

    var transform: AttachmentTransform {
        get { AttachmentTransform.decode(transformJSON) ?? .identity }
        set { transformJSON = newValue.encodedJSON() ?? "" }
    }
}

// MARK: - Display transform (non-destructive)

/// Presentation-only rotation + crop of an attachment image. The stored
/// original bytes are never modified; every render (thumbnail, viewer,
/// export) applies this transform. The crop rect is NORMALIZED (0…1) in
/// the rotated coordinate space.
struct AttachmentTransform: Codable, Sendable, Equatable {
    /// Clockwise quarter turns (0…3).
    var quarterTurns: Int
    /// Normalized crop rect (x, y, width, height; all 0…1). Identity =
    /// full image.
    var cropX: Double
    var cropY: Double
    var cropWidth: Double
    var cropHeight: Double

    static let identity = AttachmentTransform(
        quarterTurns: 0, cropX: 0, cropY: 0, cropWidth: 1, cropHeight: 1
    )

    var isIdentity: Bool { self == .identity }

    func rotatedRight() -> AttachmentTransform {
        var copy = self
        copy.quarterTurns = (quarterTurns + 1) % 4
        // Re-normalize the crop rect into the rotated space: a cw quarter
        // turn maps (x, y) → (1 - y - h, x) for rect sizes swapped.
        let nx = 1 - cropY - cropHeight
        let ny = cropX
        copy.cropX = nx
        copy.cropY = ny
        copy.cropWidth = cropHeight
        copy.cropHeight = cropWidth
        return copy
    }

    func encodedJSON() -> String? {
        guard !isIdentity else { return nil }
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ json: String) -> AttachmentTransform? {
        guard !json.isEmpty, let data = json.data(using: .utf8) else { return nil }
        guard var value = try? JSONDecoder().decode(AttachmentTransform.self, from: data) else {
            return nil
        }
        // Clamp defensively — a malformed stored rect must never break
        // rendering. (One optional value, no overlapping optional-chained
        // read+write accesses.)
        value.quarterTurns = ((value.quarterTurns % 4) + 4) % 4
        value.cropX = min(max(value.cropX, 0), 1)
        value.cropY = min(max(value.cropY, 0), 1)
        value.cropWidth = min(max(value.cropWidth, 0.05), 1)
        value.cropHeight = min(max(value.cropHeight, 0.05), 1)
        return value
    }
}

// MARK: - Structured analysis result

/// The versioned structured output of the multimodal image analysis.
/// Mirrors the Go `session_attachments.analysis` JSONB shape 1:1 (the
/// same JSON string travels through the sync payload).
///
/// Parsing is deliberately tolerant (see AttachmentAnalysisParser): every
/// array is optional; a broken formula never discards the whole result.
struct AttachmentAnalysisResult: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    /// Short model-proposed title of the image content.
    var title: String?
    /// Faithful description of what is VISIBLE (model output).
    var visibleText: [String]?
    /// LaTeX strings (displayed as monospace, not rendered).
    var formulas: [String]?
    var codeBlocks: [String]?
    var keyPoints: [String]?
    /// Chinese explanation grounded in image + nearby transcript.
    var explanation: String?
    /// Explicitly uncertain items (model's own hedge list).
    var uncertainties: [String]?
    /// Entry ids the analysis referenced (validated against the session's
    /// real entries before display; dangling ids are dropped, never shown).
    var transcriptReferences: [UUID]?
    /// Model identity used (display only; never trusted as capability).
    var analysisModel: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion, title, visibleText, formulas, codeBlocks
        case keyPoints, explanation, uncertainties, transcriptReferences
        case analysisModel
    }

    init(
        schemaVersion: Int = currentSchemaVersion,
        title: String? = nil,
        visibleText: [String]? = nil,
        formulas: [String]? = nil,
        codeBlocks: [String]? = nil,
        keyPoints: [String]? = nil,
        explanation: String? = nil,
        uncertainties: [String]? = nil,
        transcriptReferences: [UUID]? = nil,
        analysisModel: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.title = title
        self.visibleText = visibleText
        self.formulas = formulas
        self.codeBlocks = codeBlocks
        self.keyPoints = keyPoints
        self.explanation = explanation
        self.uncertainties = uncertainties
        self.transcriptReferences = transcriptReferences
        self.analysisModel = analysisModel
    }

    /// Decode tolerant of missing keys AND wrong types (a string where an
    /// array was expected becomes a one-element array rather than losing
    /// the field).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? Self.currentSchemaVersion
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        visibleText = Self.flexibleStrings(c, .visibleText)
        formulas = Self.flexibleStrings(c, .formulas)
        codeBlocks = Self.flexibleStrings(c, .codeBlocks)
        keyPoints = Self.flexibleStrings(c, .keyPoints)
        uncertainties = Self.flexibleStrings(c, .uncertainties)
        explanation = try? c.decodeIfPresent(String.self, forKey: .explanation)
        transcriptReferences = (try? c.decodeIfPresent([UUID].self, forKey: .transcriptReferences)) ?? nil
        analysisModel = try? c.decodeIfPresent(String.self, forKey: .analysisModel)
    }

    /// One field of either [String] or String shape → [String].
    private static func flexibleStrings(
        _ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
    ) -> [String]? {
        if let arr = try? c.decodeIfPresent([String].self, forKey: key), arr != nil {
            return arr
        }
        if let single = try? c.decodeIfPresent(String.self, forKey: key), single != nil {
            return [single]
        }
        return nil
    }

    var encodedString: String? { encodedJSON() }

    /// Flattened searchable text (OCR text stays separate and is combined
    /// by the caller).
    var searchableText: String {
        var parts: [String] = []
        if let t = title, !t.isEmpty { parts.append(t) }
        parts.appendIfNotEmpty(visibleText)
        parts.appendIfNotEmpty(formulas)
        parts.appendIfNotEmpty(codeBlocks)
        parts.appendIfNotEmpty(keyPoints)
        if let e = explanation, !e.isEmpty { parts.append(e) }
        parts.appendIfNotEmpty(uncertainties)
        return parts.joined(separator: "\n")
    }
}

private extension Array where Element == String {
    mutating func appendIfNotEmpty(_ other: [String]?) {
        if let other, !other.isEmpty {
            append(contentsOf: other.filter { !$0.isEmpty })
        }
    }
}

extension AttachmentAnalysisResult {
    /// Canonical JSON encoding (schemaVersion pinned).
    func encodedJSON() -> String? {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ json: String) -> AttachmentAnalysisResult? {
        guard !json.isEmpty, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AttachmentAnalysisResult.self, from: data)
    }
}
