import CryptoKit
import Foundation
import SwiftData

// Course-material entities: teacher handouts, problem sets, lab guides and
// text documents the student imports, reads, searches and asks about.
//
// All entities follow the SessionNote/SessionAttachment/LearningModels
// conventions: a stable client-generated UUID, plain UUID columns for source
// references (never SwiftData relationships — entities sync independently and
// rows may arrive before their sources), and `serverVersion` cloud-sync
// metadata.
//
// Survival semantics:
// - deleting a COURSE clears the material's `courseID` (资料转入未归类,
//   never deleted);
// - deleting a SESSION clears the material's `sessionID` (资料属于课程);
// - deleting a MATERIAL cascades to its pages and annotations and reaps its
//   files (derived thumbnails, page caches included);
// - materials created FROM a classroom image (`sourceAttachmentID`) never
//   copy the original — they borrow the attachment's files until deleted.

/// What a material is used for — presentation grouping + search labels.
enum MaterialKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case lecture       // 讲义
    case homework      // 习题
    case lab           // 实验指导
    case reading       // 阅读材料
    case exam          // 考试资料
    case other         // 其他

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .lecture: return String(localized: "讲义")
        case .homework: return String(localized: "习题")
        case .lab: return String(localized: "实验")
        case .reading: return String(localized: "阅读材料")
        case .exam: return String(localized: "考试资料")
        case .other: return String(localized: "其他")
        }
    }
}

/// The file format of a material — decides what the pipeline can honestly
/// do with it. `other` (DOCX/PPTX/…) files are STORED and previewed via
/// Quick Look only; their content is never claimed as extracted. `link`
/// carries no file at all: the content is a saved web URL (opened in the
/// browser; the title and any shared text are searchable).
enum MaterialFormat: String, Codable, Sendable {
    case pdf
    case text          // plain .txt
    case markdown      // .md (stored raw; rendered as plain text)
    case image         // JPEG/PNG/HEIC single-page material
    case link          // saved web URL (no file; opened in the browser)
    case other         // docx/pptx/unknown — save + Quick Look only

    var displayName: String {
        switch self {
        case .pdf: return String(localized: "PDF")
        case .text: return String(localized: "文本")
        case .markdown: return String(localized: "Markdown")
        case .image: return String(localized: "图片")
        case .link: return String(localized: "链接")
        case .other: return String(localized: "文档")
        }
    }
}

/// Text-extraction lifecycle of a material. `extracting` is device-local
/// progress (never synced); terminal states sync. `unsupported` is the
/// honest state for formats the pipeline cannot parse (DOCX/PPTX…).
enum MaterialExtractionStatus: String, Codable, Sendable {
    case pending
    case extracting    // local-only, never pushed
    case completed
    case partial       // some pages failed — resumable
    case failed
    case unsupported
}

/// Per-page OCR lifecycle (Vision). `running` is device-local; terminal
/// states sync with the OCR text they produced.
enum MaterialOCRStatus: String, Codable, Sendable {
    case none          // never requested
    case pending       // queued
    case running       // local-only, never pushed
    case done
    case failed
}

/// Digest (导读) lifecycle — mirrors AttachmentAnalysisStatus semantics.
/// `analyzing` is device-local progress and never syncs; terminal states do.
enum MaterialDigestStatus: String, Codable, Sendable {
    case pending
    case analyzing     // local-only, never pushed
    case completed
    case partial       // some chunks finished, merge not run — resumable
    case failed
}

// MARK: - CourseMaterial

/// One imported course document. The entity carries metadata only: the
/// original file lives under `MaterialFileStore`, addressed by `id` +
/// account scope (the AttachmentFileStore rule — views never build paths).
/// `contentHash` (SHA-256 of the original bytes) is the identity contract
/// for duplicate-import detection and sync upload.
///
/// Page-level content lives in `MaterialPage` rows (never one giant JSON):
/// extraction is chunked, page text syncs row by row, and a 300-page PDF
/// never loads into memory at once. A material created from a classroom
/// image keeps `sourceAttachmentID` and stores NO file of its own — the
/// attachment's renditions are borrowed (no duplicate originals).
@Model
final class CourseMaterial {
    @Attribute(.unique) var id: UUID
    /// The course this material belongs to (nil = 未归类 — the user may
    /// import first and organize later).
    var courseID: UUID?
    /// Optional link to one classroom session this material was used in
    /// (nil = not tied to a specific class). Cleared, never cascaded, when
    /// the session is deleted — the material still belongs to the course.
    var sessionID: UUID?
    /// Optional link to the schedule occurrence this is 课前资料 for
    /// ("scheduleUUID:YYYY-MM-DD"; nil = none). Cleared when the schedule
    /// chain goes away — the string is opaque grouping metadata.
    var occurrenceKey: String?
    /// Display title (user-editable; defaults to the file name).
    var title: String
    /// The imported file's original name (search + provenance).
    var originalFileName: String
    var mimeType: String
    /// Raw value of `MaterialKind`.
    var kindRaw: String
    /// Raw value of `MaterialFormat`.
    var formatRaw: String
    /// Size of the ORIGINAL file in bytes (the sync size contract).
    var fileSize: Int64
    /// SHA-256 of the original file bytes (hex).
    var contentHash: String
    /// Real page count for paged materials (PDF); 1 for text/image
    /// materials; 0 = unknown (not yet probed).
    var pageCount: Int
    /// Set when this material borrows a classroom image's files instead of
    /// storing its own copy (nil = owns files in MaterialFileStore).
    var sourceAttachmentID: UUID?
    /// Saved web URL (format .link only; "" otherwise). Insert-only
    /// identity — a link material's content is the URL it was shared as.
    var sourceURL: String
    /// Text shared alongside the URL (the sender's selected text / share
    /// note). User-searchable; never claimed as page content.
    var sharedText: String
    /// Raw value of `MaterialExtractionStatus`.
    var extractionStatusRaw: String
    /// Raw value of `MaterialDigestStatus`.
    var digestStatusRaw: String
    /// MaterialDigestResult JSON (empty = none). Model output only —
    /// user notes live in MaterialAnnotation rows (AI/user separation).
    var digestJSON: String
    /// Digest generation progress (chunk plan + per-chunk results) —
    /// device-local, never synced.
    var digestChunkStateJSON: String
    /// Model used for the last completed digest (display only).
    var digestModel: String
    /// When the last successful digest finished.
    var digestGeneratedAt: Date?
    /// Hash of the extracted text at digest time — staleness detection
    /// (资料内容已更新，可重新整理).
    var digestSourceHash: String
    /// Most recently read page (1-based; 0 = never opened). Syncs so the
    /// reading position follows the user across devices.
    var lastReadPage: Int
    /// Last time the reader opened this material (最近使用 ordering).
    var lastOpenedAt: Date?
    var createdAt: Date
    var updatedAt: Date
    /// Cloud-sync metadata (0 = never synced).
    var serverVersion: Int

    init(
        id: UUID = UUID(),
        courseID: UUID? = nil,
        sessionID: UUID? = nil,
        occurrenceKey: String? = nil,
        title: String,
        originalFileName: String,
        mimeType: String = "",
        kind: MaterialKind = .other,
        format: MaterialFormat = .other,
        fileSize: Int64 = 0,
        contentHash: String = "",
        pageCount: Int = 0,
        sourceAttachmentID: UUID? = nil,
        sourceURL: String = "",
        sharedText: String = "",
        extractionStatus: MaterialExtractionStatus = .pending,
        digestStatus: MaterialDigestStatus = .pending,
        digestJSON: String = "",
        digestChunkStateJSON: String = "",
        digestModel: String = "",
        digestGeneratedAt: Date? = nil,
        digestSourceHash: String = "",
        lastReadPage: Int = 0,
        lastOpenedAt: Date? = nil,
        serverVersion: Int = 0
    ) {
        self.id = id
        self.courseID = courseID
        self.sessionID = sessionID
        self.occurrenceKey = occurrenceKey
        self.title = title
        self.originalFileName = originalFileName
        self.mimeType = mimeType
        self.kindRaw = kind.rawValue
        self.formatRaw = format.rawValue
        self.fileSize = fileSize
        self.contentHash = contentHash
        self.pageCount = pageCount
        self.sourceAttachmentID = sourceAttachmentID
        self.sourceURL = sourceURL
        self.sharedText = sharedText
        self.extractionStatusRaw = extractionStatus.rawValue
        self.digestStatusRaw = digestStatus.rawValue
        self.digestJSON = digestJSON
        self.digestChunkStateJSON = digestChunkStateJSON
        self.digestModel = digestModel
        self.digestGeneratedAt = digestGeneratedAt
        self.digestSourceHash = digestSourceHash
        self.lastReadPage = lastReadPage
        self.lastOpenedAt = lastOpenedAt
        self.createdAt = .now
        self.updatedAt = .now
        self.serverVersion = serverVersion
    }

    var kind: MaterialKind {
        get { MaterialKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }

    var format: MaterialFormat {
        get { MaterialFormat(rawValue: formatRaw) ?? .other }
        set { formatRaw = newValue.rawValue }
    }

    var extractionStatus: MaterialExtractionStatus {
        get { MaterialExtractionStatus(rawValue: extractionStatusRaw) ?? .pending }
        set { extractionStatusRaw = newValue.rawValue }
    }

    var digestStatus: MaterialDigestStatus {
        get { MaterialDigestStatus(rawValue: digestStatusRaw) ?? .pending }
        set { digestStatusRaw = newValue.rawValue }
    }

    /// Whether this material carries its own file (vs borrowing a
    /// classroom attachment's renditions or carrying no file at all —
    /// links are URL-only).
    var ownsFile: Bool { sourceAttachmentID == nil && format != .link }

    /// Whether any content is retrievable: a text layer exists on some
    /// page, or the format is parsed by construction (txt/md), or a digest
    /// exists. `unsupported` formats are honestly excluded.
    var hasExtractableContent: Bool {
        format == .text || format == .markdown || format == .pdf
    }

    /// Whether this material is a saved web link (no file of its own).
    var isLink: Bool { format == .link }

    /// The saved URL as a URL (nil when malformed/empty).
    var linkURL: URL? {
        guard isLink, !sourceURL.isEmpty else { return nil }
        return URL(string: sourceURL)
    }

    var digest: MaterialDigestResult? {
        guard !digestJSON.isEmpty else { return nil }
        return MaterialDigestResult.decode(digestJSON)
    }
}

// MARK: - MaterialPage

/// One page of a paged material. Text materials (TXT/Markdown) and image
/// materials carry exactly ONE page row (pageNumber 1); PDFs carry one row
/// per page. The row id is DETERMINISTIC — derived from materialID +
/// pageNumber — so two devices extracting the same PDF produce identical
/// page rows that sync as the same entity instead of duplicating.
///
/// `extractedText` is the PDF text layer (born-digital PDFs); `ocrText`
/// is Vision OCR output for scanned pages (user-editable, never mixed
/// with the text layer). The EFFECTIVE text a reader/search/digest sees:
/// extracted text when the page has one, OCR otherwise — the same
/// effective-first rule the transcript corrections follow.
@Model
final class MaterialPage {
    @Attribute(.unique) var id: UUID
    var materialID: UUID
    /// 1-based page number.
    var pageNumber: Int
    /// PDF text layer / text-file content (empty = no text layer).
    var extractedText: String
    /// Local Vision OCR text (empty = not run / none found).
    var ocrText: String
    /// Raw value of `MaterialOCRStatus`.
    var ocrStatusRaw: String
    var createdAt: Date
    var updatedAt: Date
    /// Cloud-sync metadata (0 = never synced).
    var serverVersion: Int

    init(
        id: UUID,
        materialID: UUID,
        pageNumber: Int,
        extractedText: String = "",
        ocrText: String = "",
        ocrStatus: MaterialOCRStatus = .none,
        serverVersion: Int = 0
    ) {
        self.id = id
        self.materialID = materialID
        self.pageNumber = pageNumber
        self.extractedText = extractedText
        self.ocrText = ocrText
        self.ocrStatusRaw = ocrStatus.rawValue
        self.createdAt = .now
        self.updatedAt = .now
        self.serverVersion = serverVersion
    }

    var ocrStatus: MaterialOCRStatus {
        get { MaterialOCRStatus(rawValue: ocrStatusRaw) ?? .none }
        set { ocrStatusRaw = newValue.rawValue }
    }

    /// Effective text for readers, search and digest: the text layer when
    /// present, else OCR (never concatenated — the same content would be
    /// indexed twice).
    var effectiveText: String {
        let extracted = extractedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extracted.isEmpty { return extracted }
        return ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Both text bodies for search indexing (a page can carry a partial
    /// text layer AND OCR text; search should see both).
    var searchableText: String {
        [extractedText, ocrText]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// True when the page is a candidate for OCR: no usable text layer
    /// (scanned page) and OCR not run/failed.
    var needsOCR: Bool {
        extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (ocrStatus == .none || ocrStatus == .failed)
    }

    /// Deterministic page id: the same (materialID, pageNumber) on every
    /// device — page rows sync as the same entity regardless of which
    /// device extracted them.
    static func deterministicID(materialID: UUID, pageNumber: Int) -> UUID {
        let seed = "\(materialID.uuidString)#\(pageNumber)"
        let digest = Insecure.SHA1DigestSeed.seed(for: seed)
        return digest
    }
}

// MARK: - MaterialAnnotation

/// A user mark on one page of a material: a page note or a page bookmark.
/// AI output never touches these rows (the digest is the AI layer; this is
/// the user layer). Anchored to (materialID, pageNumber) — deleting the
/// material cascades; deleting the page row (re-extraction) keeps the
/// annotation (the page number stays meaningful).
enum MaterialAnnotationKind: String, Codable, Sendable, CaseIterable {
    case note
    case bookmark

    var displayName: String {
        switch self {
        case .note: return String(localized: "笔记")
        case .bookmark: return String(localized: "书签")
        }
    }
}

@Model
final class MaterialAnnotation {
    @Attribute(.unique) var id: UUID
    var materialID: UUID
    /// 1-based page the annotation belongs to.
    var pageNumber: Int
    /// Raw value of `MaterialAnnotationKind`.
    var kindRaw: String
    /// Note text ("" for bookmarks).
    var text: String
    var createdAt: Date
    var updatedAt: Date
    /// Cloud-sync metadata (0 = never synced).
    var serverVersion: Int

    init(
        id: UUID = UUID(),
        materialID: UUID,
        pageNumber: Int,
        kind: MaterialAnnotationKind,
        text: String = "",
        serverVersion: Int = 0
    ) {
        self.id = id
        self.materialID = materialID
        self.pageNumber = pageNumber
        self.kindRaw = kind.rawValue
        self.text = text
        self.createdAt = .now
        self.updatedAt = .now
        self.serverVersion = serverVersion
    }

    var kind: MaterialAnnotationKind {
        get { MaterialAnnotationKind(rawValue: kindRaw) ?? .note }
        set { kindRaw = newValue.rawValue }
    }
}

// MARK: - Course assistant (问这门课)

/// One course-assistant conversation thread. Threads belong to a course
/// (nil = 未归类); every message records the scope it was asked in, so a
/// thread can mix course-wide, per-material and per-session questions.
@Model
final class CourseAssistantThread {
    @Attribute(.unique) var id: UUID
    var courseID: UUID?
    /// User-visible title (auto-seeded from the first question, renameable).
    var title: String
    var createdAt: Date
    var updatedAt: Date
    /// Cloud-sync metadata (0 = never synced).
    var serverVersion: Int

    init(
        id: UUID = UUID(),
        courseID: UUID? = nil,
        title: String,
        serverVersion: Int = 0
    ) {
        self.id = id
        self.courseID = courseID
        self.title = title
        self.createdAt = .now
        self.updatedAt = .now
        self.serverVersion = serverVersion
    }
}

/// One message of an assistant thread (user question or assistant answer).
/// The answer's provenance travels in `citationsJSON` — the retrieval
/// snapshot the answer was grounded in, with stable ids for one-tap jumps
/// (material page / transcript entry / note / attachment / review). An
/// answer with no usable evidence carries no citations and the honest
/// 没有找到足够依据 text instead of fabricated sources.
///
/// Visual Q&A (mode .visual) extends the SAME row — never a second chat
/// system: `visualEvidenceJSON` snapshots the evidence references (stable
/// source ids + normalized crop rects; no base64, no file paths) and
/// `answerJSON` the loosely-structured answer payload. Deleted sources
/// never invalidate history — chips render 原图片已不存在 and jump nowhere.
@Model
final class CourseAssistantMessage {
    @Attribute(.unique) var id: UUID
    var threadID: UUID
    /// Raw value of `AssistantMessageRole`.
    var roleRaw: String
    /// The message text (question or answer).
    var text: String
    /// Scope the question was asked in (nil = whole course).
    var scopeMaterialID: UUID?
    var scopeSessionID: UUID?
    /// AssistantMessageCitation list JSON (empty for user messages and
    /// no-evidence answers).
    var citationsJSON: String
    /// Raw value of `AssistantMessageMode` (added with a default so
    /// existing stores lightweight-migrate in place).
    var modeRaw: String = AssistantMessageMode.text.rawValue
    /// VisualEvidence list JSON — the turn's evidence snapshot (metadata
    /// only; images ride the request, never the row).
    var visualEvidenceJSON: String = ""
    /// VisualAnswer JSON — the structured answer payload (empty for text
    /// asks and plain user messages).
    var answerJSON: String = ""
    /// The model that produced the answer (provenance; empty on user
    /// messages and text asks).
    var answerModel: String = ""
    var createdAt: Date
    var updatedAt: Date
    /// Cloud-sync metadata (0 = never synced).
    var serverVersion: Int

    init(
        id: UUID = UUID(),
        threadID: UUID,
        role: AssistantMessageRole,
        text: String,
        scopeMaterialID: UUID? = nil,
        scopeSessionID: UUID? = nil,
        citationsJSON: String = "",
        mode: AssistantMessageMode = .text,
        visualEvidenceJSON: String = "",
        answerJSON: String = "",
        answerModel: String = "",
        serverVersion: Int = 0
    ) {
        self.id = id
        self.threadID = threadID
        self.roleRaw = role.rawValue
        self.text = text
        self.scopeMaterialID = scopeMaterialID
        self.scopeSessionID = scopeSessionID
        self.citationsJSON = citationsJSON
        self.modeRaw = mode.rawValue
        self.visualEvidenceJSON = visualEvidenceJSON
        self.answerJSON = answerJSON
        self.answerModel = answerModel
        self.createdAt = .now
        self.updatedAt = .now
        self.serverVersion = serverVersion
    }

    var role: AssistantMessageRole {
        get { AssistantMessageRole(rawValue: roleRaw) ?? .user }
        set { roleRaw = newValue.rawValue }
    }

    var citations: [AssistantMessageCitation] {
        guard !citationsJSON.isEmpty,
              let data = citationsJSON.data(using: .utf8),
              let list = try? JSONDecoder().decode([AssistantMessageCitation].self, from: data)
        else { return [] }
        return list
    }

    var assistantMode: AssistantMessageMode {
        get { AssistantMessageMode(rawValue: modeRaw) ?? .text }
        set { modeRaw = newValue.rawValue }
    }

    /// The turn's evidence snapshot (stable ids + normalized crops only).
    var visualEvidence: [VisualEvidence] {
        VisualEvidenceCodec.decode(visualEvidenceJSON)
    }

    /// The structured visual answer payload (nil when this is a text ask
    /// or a plain user message).
    var visualAnswer: VisualAnswer? {
        guard !answerJSON.isEmpty else { return nil }
        return VisualAnswer.decode(answerJSON)
    }
}

enum AssistantMessageRole: String, Codable, Sendable {
    case user
    case assistant
}

/// Whether a message belongs to a text or a visual turn.
enum AssistantMessageMode: String, Codable, Sendable {
    case text
    case visual
}

// MARK: - Digest result (AI layer, JSON payload)

/// The versioned structured output of the material digest (导读). Mirrors
/// the Go `course_materials.digest` JSONB shape 1:1 (the same JSON string
/// travels through the sync payload). Every item carries pageRefs — page
/// numbers the content was grounded in; taps jump to the real page.
///
/// Parsing is deliberately tolerant: every field is optional; a broken
/// item never discards the whole digest.
struct MaterialDigestResult: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    /// One-paragraph overview of the material.
    var overview: String?
    var outline: [OutlineNode]?
    var keyConcepts: [RefItem]?
    var terms: [TermEntry]?
    var formulas: [RefItem]?
    var examples: [RefItem]?
    /// Explicitly stated assignments/deadlines found in the material.
    var assignments: [RefItem]?
    /// Knowledge needed before reading (no page refs by nature).
    var prerequisites: [String]?
    /// Pages worth reading first.
    var recommendedPages: [Int]?
    /// Explicitly uncertain/unrecognizable content.
    var uncertainties: [String]?

    struct OutlineNode: Codable, Sendable, Equatable, Identifiable {
        var id = UUID()
        var title = ""
        var detail = ""
        var pageRefs: [Int] = []

        enum CodingKeys: String, CodingKey { case title, detail, pageRefs }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
            detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
            pageRefs = try c.decodeIfPresent([Int].self, forKey: .pageRefs) ?? []
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(title, forKey: .title)
            try c.encode(detail, forKey: .detail)
            try c.encode(pageRefs, forKey: .pageRefs)
        }
    }

    /// A generic item with page references (concept, formula, example,
    /// assignment). `detail` carries the explanation/requirements.
    struct RefItem: Codable, Sendable, Equatable, Identifiable {
        var id = UUID()
        var text = ""
        var detail = ""
        var pageRefs: [Int] = []

        enum CodingKeys: String, CodingKey { case text, detail, pageRefs }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
            detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
            pageRefs = try c.decodeIfPresent([Int].self, forKey: .pageRefs) ?? []
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(text, forKey: .text)
            try c.encode(detail, forKey: .detail)
            try c.encode(pageRefs, forKey: .pageRefs)
        }
    }

    /// A Russian term with its Chinese explanation.
    struct TermEntry: Codable, Sendable, Equatable, Identifiable {
        var id = UUID()
        var russian = ""
        var chinese = ""
        var explanation = ""
        var pageRefs: [Int] = []

        enum CodingKeys: String, CodingKey { case russian, chinese, explanation, pageRefs }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            russian = try c.decodeIfPresent(String.self, forKey: .russian) ?? ""
            chinese = try c.decodeIfPresent(String.self, forKey: .chinese) ?? ""
            explanation = try c.decodeIfPresent(String.self, forKey: .explanation) ?? ""
            pageRefs = try c.decodeIfPresent([Int].self, forKey: .pageRefs) ?? []
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(russian, forKey: .russian)
            try c.encode(chinese, forKey: .chinese)
            try c.encode(explanation, forKey: .explanation)
            try c.encode(pageRefs, forKey: .pageRefs)
        }
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, overview, outline, keyConcepts, terms, formulas
        case examples, assignments, prerequisites, recommendedPages, uncertainties
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? currentSchemaVersion
        overview = try c.decodeIfPresent(String.self, forKey: .overview)
        outline = try c.decodeIfPresent([OutlineNode].self, forKey: .outline)
        keyConcepts = try c.decodeIfPresent([RefItem].self, forKey: .keyConcepts)
        terms = try c.decodeIfPresent([TermEntry].self, forKey: .terms)
        formulas = try c.decodeIfPresent([RefItem].self, forKey: .formulas)
        examples = try c.decodeIfPresent([RefItem].self, forKey: .examples)
        assignments = try c.decodeIfPresent([RefItem].self, forKey: .assignments)
        prerequisites = try c.decodeIfPresent([String].self, forKey: .prerequisites)
        recommendedPages = try c.decodeIfPresent([Int].self, forKey: .recommendedPages)
        uncertainties = try c.decodeIfPresent([String].self, forKey: .uncertainties)
    }

    /// Flattened searchable text (search + assistant retrieval).
    var searchableText: String {
        var parts: [String] = []
        if let overview, !overview.isEmpty { parts.append(overview) }
        for node in outline ?? [] {
            parts.append(node.title)
            parts.append(node.detail)
        }
        for item in keyConcepts ?? [] { parts.append(item.text); parts.append(item.detail) }
        for term in terms ?? [] {
            parts.append(term.russian)
            parts.append(term.chinese)
            parts.append(term.explanation)
        }
        for item in formulas ?? [] { parts.append(item.text); parts.append(item.detail) }
        for item in examples ?? [] { parts.append(item.text); parts.append(item.detail) }
        for item in assignments ?? [] { parts.append(item.text); parts.append(item.detail) }
        parts.append(contentsOf: prerequisites ?? [])
        parts.append(contentsOf: uncertainties ?? [])
        return parts.joined(separator: "\n")
    }

    /// Markdown rendering for exports (page refs inline as 第n页).
    var markdownSections: [(title: String, body: String)] {
        var sections: [(String, String)] = []
        if let overview, !overview.isEmpty { sections.append(("资料概述", overview)) }
        if let outline, !outline.isEmpty {
            let lines = outline.map { node -> String in
                var line = "- \(node.title)"
                if !node.detail.isEmpty { line += "：\(node.detail)" }
                if !node.pageRefs.isEmpty {
                    line += "（第 \(node.pageRefs.map(String.init).joined(separator: "、")) 页）"
                }
                return line
            }
            sections.append(("目录结构", lines.joined(separator: "\n")))
        }
        if let keyConcepts, !keyConcepts.isEmpty {
            sections.append(("重要概念", keyConcepts.map(refLine).joined(separator: "\n")))
        }
        if let terms, !terms.isEmpty {
            let lines = terms.map { term -> String in
                var line = "- **\(term.russian)** — \(term.chinese)"
                if !term.explanation.isEmpty { line += "：\(term.explanation)" }
                if !term.pageRefs.isEmpty {
                    line += "（第 \(term.pageRefs.map(String.init).joined(separator: "、")) 页）"
                }
                return line
            }
            sections.append(("俄语术语", lines.joined(separator: "\n")))
        }
        if let formulas, !formulas.isEmpty {
            sections.append(("公式与符号", formulas.map(refLine).joined(separator: "\n")))
        }
        if let examples, !examples.isEmpty {
            sections.append(("例题与步骤", examples.map(refLine).joined(separator: "\n")))
        }
        if let assignments, !assignments.isEmpty {
            sections.append(("作业与截止", assignments.map(refLine).joined(separator: "\n")))
        }
        if let prerequisites, !prerequisites.isEmpty {
            sections.append(("阅读前需掌握", prerequisites.map { "- \($0)" }.joined(separator: "\n")))
        }
        if let recommendedPages, !recommendedPages.isEmpty {
            sections.append(("建议重点阅读", "第 " + recommendedPages.map(String.init).joined(separator: "、") + " 页"))
        }
        if let uncertainties, !uncertainties.isEmpty {
            sections.append(("不确定的内容", uncertainties.map { "- \($0)" }.joined(separator: "\n")))
        }
        return sections
    }

    private func refLine(_ item: RefItem) -> String {
        var line = "- \(item.text)"
        if !item.detail.isEmpty { line += "：\(item.detail)" }
        if !item.pageRefs.isEmpty {
            line += "（第 \(item.pageRefs.map(String.init).joined(separator: "、")) 页）"
        }
        return line
    }

    func encodedJSON() -> String? {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ json: String) -> MaterialDigestResult? {
        guard !json.isEmpty, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MaterialDigestResult.self, from: data)
    }
}

// MARK: - Assistant citation (answer provenance)

/// One source an assistant answer cited. Built from the LOCAL retrieval
/// snapshot — every citation resolves to a real, locally-verifiable row
/// (material page, transcript entry, note, attachment, review). Invalid
/// or fabricated markers are dropped at parse time; the UI never renders
/// a citation that cannot jump somewhere real.
struct AssistantMessageCitation: Codable, Sendable, Equatable, Identifiable {
    var id = UUID()
    /// The [n] marker used inside the answer text.
    var number: Int
    /// Raw value of `AssistantCitationKind`.
    var kindRaw: String
    /// Display label (材料名 · 第n页 / 课堂名 · 03:12 …) — denormalized so
    /// history stays readable after renames.
    var label: String
    var materialID: UUID?
    var pageNumber: Int?
    var sessionID: UUID?
    var entryID: UUID?
    var noteID: UUID?
    var attachmentID: UUID?
    var reviewID: UUID?
    /// Short quoted snippet (grounding evidence, ~1-2 lines).
    var snippet: String

    enum CodingKeys: String, CodingKey {
        case number, kindRaw, label, materialID, pageNumber, sessionID
        case entryID, noteID, attachmentID, reviewID, snippet
    }

    init(
        number: Int,
        kind: AssistantCitationKind,
        label: String,
        materialID: UUID? = nil,
        pageNumber: Int? = nil,
        sessionID: UUID? = nil,
        entryID: UUID? = nil,
        noteID: UUID? = nil,
        attachmentID: UUID? = nil,
        reviewID: UUID? = nil,
        snippet: String = ""
    ) {
        self.number = number
        self.kindRaw = kind.rawValue
        self.label = label
        self.materialID = materialID
        self.pageNumber = pageNumber
        self.sessionID = sessionID
        self.entryID = entryID
        self.noteID = noteID
        self.attachmentID = attachmentID
        self.reviewID = reviewID
        self.snippet = snippet
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decodeIfPresent(Int.self, forKey: .number) ?? 0
        kindRaw = try c.decodeIfPresent(String.self, forKey: .kindRaw) ?? ""
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        materialID = try c.decodeIfPresent(UUID.self, forKey: .materialID)
        pageNumber = try c.decodeIfPresent(Int.self, forKey: .pageNumber)
        sessionID = try c.decodeIfPresent(UUID.self, forKey: .sessionID)
        entryID = try c.decodeIfPresent(UUID.self, forKey: .entryID)
        noteID = try c.decodeIfPresent(UUID.self, forKey: .noteID)
        attachmentID = try c.decodeIfPresent(UUID.self, forKey: .attachmentID)
        reviewID = try c.decodeIfPresent(UUID.self, forKey: .reviewID)
        snippet = try c.decodeIfPresent(String.self, forKey: .snippet) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(number, forKey: .number)
        try c.encode(kindRaw, forKey: .kindRaw)
        try c.encode(label, forKey: .label)
        try c.encodeIfPresent(materialID, forKey: .materialID)
        try c.encodeIfPresent(pageNumber, forKey: .pageNumber)
        try c.encodeIfPresent(sessionID, forKey: .sessionID)
        try c.encodeIfPresent(entryID, forKey: .entryID)
        try c.encodeIfPresent(noteID, forKey: .noteID)
        try c.encodeIfPresent(attachmentID, forKey: .attachmentID)
        try c.encodeIfPresent(reviewID, forKey: .reviewID)
        try c.encode(snippet, forKey: .snippet)
    }

    var kind: AssistantCitationKind {
        AssistantCitationKind(rawValue: kindRaw) ?? .materialPage
    }
}

enum AssistantCitationKind: String, Codable, Sendable {
    case materialPage = "material_page"
    case transcript
    case note
    case attachment
    case review
    case learning
}

// MARK: - Deterministic page-id seed

enum InsecureSHA1DigestSeed {
    /// Stable UUID derived from a seed string: first 16 bytes of SHA-1,
    /// laid out as a v4-shaped UUID. Used for MaterialPage ids so the
    /// same (materialID, pageNumber) yields the same row id on every
    /// device — page rows sync as one entity, never duplicates.
    static func seed(for string: String) -> UUID {
        let digest = Insecure.SHA1.hash(data: Data(string.utf8))
        var bytes = [UInt8](digest.prefix(16))
        // RFC 4122 version/variant bits (cosmetic — stability is what
        // matters; the shape just keeps the id a valid-looking UUID).
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        var value = uuid_t()
        for (index, byte) in bytes.enumerated() { value[index] = byte }
        return UUID(uuid: value)
    }
}
