import Foundation

/// The structured content of one study review — what the model produced
/// (parsed and bounded) plus the user's own additions. Encoded as JSON
/// inside `StudyReview.contentJSON` / `generatedJSON`.
///
/// AI-generated fields and user additions are deliberately separated:
/// regeneration replaces the AI fields but always keeps `userNotes`.
struct StudyReviewContent: Codable, Sendable, Equatable {
    var schemaVersion = 1
    /// One-line topic of the class.
    var topic = ""
    /// A review-oriented Chinese summary (a few hundred characters).
    var summary = ""
    var outline: [OutlineNode] = []
    var keyPoints: [KeyPoint] = []
    var terms: [TermItem] = []
    var assignments: [AssignmentItem] = []
    var uncertainties: [UncertaintyItem] = []
    /// The user's own additions — never produced by the model, never
    /// dropped by regeneration.
    var userNotes: [UserAddition] = []

    // MARK: - Item types

    struct OutlineNode: Codable, Sendable, Equatable, Identifiable {
        var id = UUID()
        var title = ""
        var detail = ""
        var refEntryIDs: [UUID] = []
        var refAttachmentIDs: [UUID] = []
        var children: [OutlineNode] = []
    }

    struct KeyPoint: Codable, Sendable, Equatable, Identifiable {
        var id = UUID()
        var text = ""
        var refEntryIDs: [UUID] = []
        var refAttachmentIDs: [UUID] = []
    }

    struct TermItem: Codable, Sendable, Equatable, Identifiable {
        var id = UUID()
        var russian = ""
        var chinese = ""
        var explanation = ""
        var refEntryIDs: [UUID] = []
        var refAttachmentIDs: [UUID] = []
    }

    struct AssignmentItem: Codable, Sendable, Equatable, Identifiable {
        var id = UUID()
        var text = ""
        var refEntryIDs: [UUID] = []
        var refAttachmentIDs: [UUID] = []
    }

    struct UncertaintyItem: Codable, Sendable, Equatable, Identifiable {
        var id = UUID()
        var text = ""
        var refEntryIDs: [UUID] = []
        var refAttachmentIDs: [UUID] = []
    }

    struct UserAddition: Codable, Sendable, Equatable, Identifiable {
        var id = UUID()
        var text = ""
    }

    // MARK: - Coding (stable keys; `id` stays client-local)

    enum CodingKeys: String, CodingKey {
        case schemaVersion, topic, summary, outline, keyPoints, terms
        case assignments, uncertainties, userNotes
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        topic = try c.decodeIfPresent(String.self, forKey: .topic) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        outline = try c.decodeIfPresent([OutlineNode].self, forKey: .outline) ?? []
        keyPoints = try c.decodeIfPresent([KeyPoint].self, forKey: .keyPoints) ?? []
        terms = try c.decodeIfPresent([TermItem].self, forKey: .terms) ?? []
        assignments = try c.decodeIfPresent([AssignmentItem].self, forKey: .assignments) ?? []
        uncertainties = try c.decodeIfPresent([UncertaintyItem].self, forKey: .uncertainties) ?? []
        userNotes = try c.decodeIfPresent([UserAddition].self, forKey: .userNotes) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(topic, forKey: .topic)
        try c.encode(summary, forKey: .summary)
        try c.encode(outline, forKey: .outline)
        try c.encode(keyPoints, forKey: .keyPoints)
        try c.encode(terms, forKey: .terms)
        try c.encode(assignments, forKey: .assignments)
        try c.encode(uncertainties, forKey: .uncertainties)
        try c.encode(userNotes, forKey: .userNotes)
    }

    /// All text of the AI fields (search matching + staleness checks).
    var searchableText: String {
        var parts: [String] = [topic, summary]
        func walk(_ nodes: [OutlineNode]) {
            for node in nodes {
                parts.append(node.title)
                parts.append(node.detail)
                walk(node.children)
            }
        }
        walk(outline)
        parts.append(contentsOf: keyPoints.map(\.text))
        for term in terms {
            parts.append(term.russian)
            parts.append(term.chinese)
            parts.append(term.explanation)
        }
        parts.append(contentsOf: assignments.map(\.text))
        parts.append(contentsOf: uncertainties.map(\.text))
        parts.append(contentsOf: userNotes.map(\.text))
        return parts.joined(separator: "\n")
    }

    /// A plain-text rendering used by exports.
    var markdownSections: [(title: String, body: String)] {
        var sections: [(String, String)] = []
        if !topic.isEmpty { sections.append(("主题", topic)) }
        if !summary.isEmpty { sections.append(("摘要", summary)) }
        if !outline.isEmpty {
            var lines: [String] = []
            func walk(_ nodes: [OutlineNode], depth: Int) {
                for node in nodes {
                    let indent = String(repeating: "  ", count: depth)
                    lines.append("\(indent)- \(node.title)")
                    if !node.detail.isEmpty {
                        lines.append("\(indent)  \(node.detail)")
                    }
                    walk(node.children, depth: depth + 1)
                }
            }
            walk(outline, depth: 0)
            sections.append(("提纲", lines.joined(separator: "\n")))
        }
        if !keyPoints.isEmpty {
            sections.append(("重点知识", keyPoints.map { "- \($0.text)" }.joined(separator: "\n")))
        }
        if !terms.isEmpty {
            let lines = terms.map { term -> String in
                var line = "- **\(term.russian)** — \(term.chinese)"
                if !term.explanation.isEmpty { line += "：\(term.explanation)" }
                return line
            }
            sections.append(("俄语术语", lines.joined(separator: "\n")))
        }
        if !assignments.isEmpty {
            sections.append(("作业与待办", assignments.map { "- \($0.text)" }.joined(separator: "\n")))
        }
        if !uncertainties.isEmpty {
            sections.append(("待确认内容", uncertainties.map { "- \($0.text)" }.joined(separator: "\n")))
        }
        if !userNotes.isEmpty {
            sections.append(("我的补充", userNotes.map { "- \($0.text)" }.joined(separator: "\n")))
        }
        return sections
    }

    /// JSON encoding for persistence (sorted keys for stable equality).
    func encodedString() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ json: String) -> StudyReviewContent? {
        guard let data = json.data(using: .utf8),
              let content = try? JSONDecoder().decode(StudyReviewContent.self, from: data) else {
            return nil
        }
        return content
    }
}

/// Review status. `generating` exists only on the device actively
/// generating; it is never pushed (only terminal states sync).
enum StudyReviewStatus: String, Codable, Sendable {
    case generating
    case completed
    /// Some chunks finished but the final merge did not run (cancelled,
    /// partial chunk failures, app interrupted) — resumable.
    case partial
    case failed
}

/// Chunk-level generation progress persisted on the review row, so an
/// interrupted run can resume exactly where it stopped. Citations use
/// GLOBAL numbers (1-based index into `citationIDs`) so the merge stage
/// can reference any entry.
struct StudyChunkState: Codable, Sendable, Equatable {
    struct Chunk: Codable, Sendable, Equatable {
        enum Status: String, Codable, Sendable {
            case pending, done, failed
        }

        var index: Int
        /// Ordered entry ids of this chunk.
        var entryIDs: [UUID] = []
        /// Global citation number of the chunk's first entry.
        var firstCitation: Int = 1
        var status: Status = .pending
        /// The model's chunk extraction (as returned, citations still raw
        /// numbers) — fed verbatim into the merge prompt.
        var extractionJSON: String?
    }

    /// Global citation table: number n (1-based) ↔ citationIDs[n-1].
    var citationIDs: [UUID] = []
    var chunks: [Chunk] = []

    var doneCount: Int { chunks.filter { $0.status == .done }.count }
    var hasAnyProgress: Bool { doneCount > 0 }

    static func decode(_ json: String) -> StudyChunkState? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(StudyChunkState.self, from: data)
    }

    func encodedString() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
