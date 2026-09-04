import Foundation
import CoreGraphics

/// A rectangle in NORMALIZED (0…1) image coordinates — the only crop
/// representation the visual-ask layer persists. Unified coordinate
/// definition: the rect lives in the UPRIGHT image space (EXIF
/// orientation applied, the attachment's non-destructive rotate/crop
/// transform applied) — exactly what the user sees in the viewer and
/// exactly what the model receives. Screen pixel coordinates are never
/// stored.
struct NormalizedRect: Codable, Sendable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(cgRect: CGRect) {
        self.x = cgRect.origin.x
        self.y = cgRect.origin.y
        self.width = cgRect.size.width
        self.height = cgRect.size.height
    }

    /// The full image.
    static let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)

    var isFull: Bool {
        x <= 0.0001 && y <= 0.0001 && width >= 0.9999 && height >= 0.9999
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    /// Clamps every component into its legal range (defensive: values
    /// arriving from synced JSON or stale geometry never crash a render).
    func clamped() -> NormalizedRect {
        let minX = min(max(x, 0), 1)
        let minY = min(max(y, 0), 1)
        let maxX = min(max(x + width, 0), 1)
        let maxY = min(max(y + height, 0), 1)
        return NormalizedRect(
            x: minX, y: minY,
            width: max(maxX - minX, 0), height: max(maxY - minY, 0)
        )
    }
}

/// What one piece of visual evidence points at. Image kinds ride the
/// multimodal request as content parts; text kinds ride the prompt as
/// labeled context. Every kind resolves through stable ids — never a
/// list index or a sort position.
enum VisualEvidenceKind: String, Codable, Sendable, CaseIterable {
    /// 课堂图片（黑板/幻灯片/笔记照片 — a SessionAttachment's files).
    case sessionAttachment = "session_attachment"
    /// 一份图片格式的课程资料（含借用课堂图片的资料）.
    case materialImage = "material_image"
    /// PDF 资料的某一页.
    case materialPage = "material_page"
    /// 课堂转录上下文（text context）.
    case transcript
    /// 课堂笔记（text context）.
    case note
    /// 图片既有本地 OCR（text context）.
    case ocr
    /// 图片既有结构化分析（text context）.
    case analysis

    var isImageKind: Bool {
        switch self {
        case .sessionAttachment, .materialImage, .materialPage:
            return true
        case .transcript, .note, .ocr, .analysis:
            return false
        }
    }

    var displayName: String {
        switch self {
        case .sessionAttachment: return "课堂图片"
        case .materialImage: return "资料图片"
        case .materialPage: return "资料页"
        case .transcript: return "课堂讲解"
        case .note: return "课堂笔记"
        case .ocr: return "图片文字"
        case .analysis: return "图片分析"
        }
    }

    var symbol: String {
        switch self {
        case .sessionAttachment: return "photo"
        case .materialImage: return "photo.on.rectangle"
        case .materialPage: return "doc.richtext"
        case .transcript: return "text.bubble"
        case .note: return "note.text"
        case .ocr: return "text.viewfinder"
        case .analysis: return "sparkles"
        }
    }
}

/// One stable, recoverable, syncable evidence reference attached to a
/// visual Q&A message. Metadata ONLY — no base64, no file paths, no
/// request bodies. When the referenced source is deleted the message
/// survives and the chip renders 原图片已不存在; another image is never
/// substituted.
///
/// `sourceID` semantics by kind: attachment id (sessionAttachment / ocr /
/// analysis), material id (materialImage / materialPage), session id
/// (transcript), note id (note). `cropRect` is optional and normalized
/// (upright image space).
struct VisualEvidence: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var kindRaw: String
    var sourceID: UUID
    var sessionID: UUID?
    var courseID: UUID?
    var materialID: UUID?
    var pageNumber: Int?
    var cropRect: NormalizedRect?
    /// Display title, denormalized at creation so history stays readable
    /// after renames.
    var title: String
    /// Short quoted snippet for text-context kinds.
    var snippet: String?

    init(
        id: UUID = UUID(),
        kind: VisualEvidenceKind,
        sourceID: UUID,
        sessionID: UUID? = nil,
        courseID: UUID? = nil,
        materialID: UUID? = nil,
        pageNumber: Int? = nil,
        cropRect: NormalizedRect? = nil,
        title: String,
        snippet: String? = nil
    ) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.sourceID = sourceID
        self.sessionID = sessionID
        self.courseID = courseID
        self.materialID = materialID
        self.pageNumber = pageNumber
        self.cropRect = cropRect
        self.title = title
        self.snippet = snippet
    }

    enum CodingKeys: String, CodingKey {
        case id, kindRaw, sourceID, sessionID, courseID
        case materialID, pageNumber, cropRect, title, snippet
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kindRaw = try c.decodeIfPresent(String.self, forKey: .kindRaw) ?? ""
        sourceID = try c.decodeIfPresent(UUID.self, forKey: .sourceID) ?? UUID()
        sessionID = try c.decodeIfPresent(UUID.self, forKey: .sessionID)
        courseID = try c.decodeIfPresent(UUID.self, forKey: .courseID)
        materialID = try c.decodeIfPresent(UUID.self, forKey: .materialID)
        pageNumber = try c.decodeIfPresent(Int.self, forKey: .pageNumber)
        cropRect = try c.decodeIfPresent(NormalizedRect.self, forKey: .cropRect)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        snippet = try c.decodeIfPresent(String.self, forKey: .snippet)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kindRaw, forKey: .kindRaw)
        try c.encode(sourceID, forKey: .sourceID)
        try c.encodeIfPresent(sessionID, forKey: .sessionID)
        try c.encodeIfPresent(courseID, forKey: .courseID)
        try c.encodeIfPresent(materialID, forKey: .materialID)
        try c.encodeIfPresent(pageNumber, forKey: .pageNumber)
        try c.encodeIfPresent(cropRect, forKey: .cropRect)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(snippet, forKey: .snippet)
    }

    var kind: VisualEvidenceKind {
        VisualEvidenceKind(rawValue: kindRaw) ?? .sessionAttachment
    }

    /// "图片 2" style label — the same labels the prompt emits so answers
    /// can reference evidence by number.
    func imageLabel(index: Int) -> String {
        "图片 \(index + 1)"
    }

    /// Subtitle for chips (page / crop hints).
    var detailLabel: String? {
        if let pageNumber {
            return "第 \(pageNumber) 页"
        }
        if let cropRect, !cropRect.isFull {
            return "选中区域"
        }
        return nil
    }
}

/// JSON codec for evidence lists riding `visualEvidenceJSON` columns and
/// the sync wire (as a JSON string).
enum VisualEvidenceCodec {
    static func encode(_ list: [VisualEvidence]) -> String {
        guard !list.isEmpty else { return "" }
        guard let data = try? JSONEncoder().encode(list),
              let json = String(data: data, encoding: .utf8) else { return "" }
        return json
    }

    static func decode(_ json: String?) -> [VisualEvidence] {
        guard let json, !json.isEmpty,
              let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([VisualEvidence].self, from: data)
        else { return [] }
        return list
    }
}

/// Raw image material for one image-kind evidence, resolved on the main
/// actor from the local stores. The pipeline converts it into a bounded
/// JPEG for the request lifecycle only.
enum VisualEvidenceImageSource: Sendable {
    /// Image bytes from the attachment renditions (analysis.jpg preferred
    /// — EXIF already baked) or the material's own file.
    case imageData(Data)
    /// A PDF page to rasterize on demand (never the whole document).
    case pdfPage(url: URL, pageNumber: Int)
}
