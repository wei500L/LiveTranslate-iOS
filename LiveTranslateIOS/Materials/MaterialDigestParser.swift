import Foundation

/// Tolerant parser for material-digest model outputs. Never fabricates a
/// successful digest: when nothing usable can be parsed it throws; when
/// only some fields are usable the rest default to empty. Page
/// references are validated against the material's real page range —
/// an AI claim must never point at a page that does not exist.
enum MaterialDigestParser {
    /// Hard bounds so a runaway response can never write unbounded data
    /// into the store.
    enum Limits {
        static let overview = 3_000
        static let itemText = 1_200
        static let detail = 1_200
        static let outlineNodes = 120
        static let keyPoints = 60
        static let terms = 80
        static let formulas = 60
        static let examples = 40
        static let assignments = 40
        static let prerequisites = 20
        static let uncertainties = 30
        static let recommendedPages = 10
        static let pagesPerItem = 20
    }

    enum ParseError: Error, Equatable {
        case notJSON
        case empty
    }

    // MARK: - Raw model shapes (pages are request-scoped numbers)

    private struct RawDigest: Decodable {
        var topic: String?
        var overview: String?
        var outline: [RawOutlineNode]?
        var keyPoints: [RawRefItem]?
        var terms: [RawTerm]?
        var formulas: [RawRefItem]?
        var examples: [RawRefItem]?
        var assignments: [RawRefItem]?
        var prerequisites: [String]?
        var recommendedPages: [Int]?
        var uncertainties: [RawRefItem]?
    }

    private struct RawOutlineNode: Decodable {
        var title: String?
        var detail: String?
        var pages: [Int]?
        var children: [RawOutlineNode]?
    }

    private struct RawRefItem: Decodable {
        var text: String?
        var detail: String?
        var pages: [Int]?
    }

    private struct RawTerm: Decodable {
        var russian: String?
        var chinese: String?
        var explanation: String?
        var pages: [Int]?
    }

    /// Raw shape of one scanned-page image description.
    struct RawImagePage: Decodable {
        var text: String?
        var uncertainties: [String]?
    }

    // MARK: - Public API

    /// Parses a merge response into the final digest. Page references
    /// outside 1...pageCount are dropped (never shown as a jump target).
    static func parse(text: String, pageCount: Int) throws -> MaterialDigestResult {
        let raw = try decodeRaw(text)
        var digest = MaterialDigestResult()
        digest.overview = bounded(
            raw.overview ?? raw.topic, limit: Limits.overview
        )
        var outlineBudget = Limits.outlineNodes
        digest.outline = mapOutline(
            raw.outline ?? [], pageCount: pageCount, remaining: &outlineBudget
        )
        digest.keyConcepts = mapRefItems(raw.keyPoints, pageCount: pageCount, limit: Limits.keyPoints)
        digest.terms = (raw.terms ?? []).prefix(Limits.terms).compactMap { item in
            let russian = bounded(item.russian, limit: Limits.itemText)
            guard !russian.isEmpty else { return nil }
            return MaterialDigestResult.TermEntry(
                id: UUID(),
                russian: russian,
                chinese: bounded(item.chinese, limit: Limits.itemText),
                explanation: bounded(item.explanation, limit: Limits.detail),
                pageRefs: validPages(item.pages, pageCount: pageCount)
            )
        }
        digest.formulas = mapRefItems(raw.formulas, pageCount: pageCount, limit: Limits.formulas)
        digest.examples = mapRefItems(raw.examples, pageCount: pageCount, limit: Limits.examples)
        digest.assignments = mapRefItems(raw.assignments, pageCount: pageCount, limit: Limits.assignments)
        digest.prerequisites = (raw.prerequisites ?? [])
            .prefix(Limits.prerequisites)
            .compactMap { bounded($0, limit: Limits.itemText).nilIfEmpty }
        digest.recommendedPages = validPages(raw.recommendedPages, pageCount: pageCount)
            .prefix(Limits.recommendedPages).map { $0 }
        digest.uncertainties = (raw.uncertainties ?? []).prefix(Limits.uncertainties)
            .compactMap { bounded($0.text, limit: Limits.itemText).nilIfEmpty }

        guard digest.overview?.isEmpty == false
            || !(digest.outline ?? []).isEmpty
            || !(digest.keyConcepts ?? []).isEmpty
            || !(digest.terms ?? []).isEmpty
            || !(digest.formulas ?? []).isEmpty
            || !(digest.examples ?? []).isEmpty
            || !(digest.assignments ?? []).isEmpty
            || !(digest.prerequisites ?? []).isEmpty
        else { throw ParseError.empty }
        return digest
    }

    /// Parses one scanned-page image description (text + uncertainties).
    static func parseImagePage(text: String) -> RawImagePage? {
        let stripped = stripFences(text)
        guard let data = stripped.data(using: .utf8),
              let raw = try? JSONDecoder().decode(RawImagePage.self, from: data)
        else {
            // A non-JSON but non-empty answer is still usable as plain
            // description text (never fabricated — it is the model's own
            // output, used verbatim).
            let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return RawImagePage(text: trimmed, uncertainties: nil)
        }
        return raw
    }

    /// Normalizes a chunk-extraction response for the merge prompt:
    /// JSON-object-only, bounded (the merge input stays small even when
    /// a chunk response was verbose).
    static func normalizeExtraction(_ text: String) throws -> String {
        let stripped = stripFences(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { throw ParseError.notJSON }
        guard let data = stripped.data(using: .utf8),
              let _ = try? JSONSerialization.jsonObject(with: data) else {
            throw ParseError.notJSON
        }
        guard stripped.count <= 60_000 else {
            return String(stripped.prefix(60_000))
        }
        return stripped
    }

    // MARK: - Mapping helpers

    private static func mapRefItems(
        _ items: [RawRefItem]?, pageCount: Int, limit: Int
    ) -> [MaterialDigestResult.RefItem] {
        (items ?? []).prefix(limit).compactMap { item in
            let text = bounded(item.text, limit: Limits.itemText)
            guard !text.isEmpty else { return nil }
            return MaterialDigestResult.RefItem(
                id: UUID(),
                text: text,
                detail: bounded(item.detail, limit: Limits.detail),
                pageRefs: validPages(item.pages, pageCount: pageCount)
            )
        }
    }

    private static func mapOutline(
        _ nodes: [RawOutlineNode], pageCount: Int, remaining: inout Int
    ) -> [MaterialDigestResult.OutlineNode] {
        guard remaining > 0 else { return [] }
        var mapped: [MaterialDigestResult.OutlineNode] = []
        for node in nodes {
            guard remaining > 0 else { break }
            remaining -= 1
            let title = bounded(node.title, limit: Limits.itemText)
            guard !title.isEmpty else { continue }
            mapped.append(MaterialDigestResult.OutlineNode(
                id: UUID(),
                title: title,
                detail: bounded(node.detail, limit: Limits.detail),
                pageRefs: validPages(node.pages, pageCount: pageCount),
                children: mapOutline(node.children ?? [], pageCount: pageCount, remaining: &remaining)
            ))
        }
        return mapped
    }

    /// Page numbers within 1...pageCount (a citation must be able to
    /// jump to a real page; anything else is dropped, never shown).
    static func validPages(_ pages: [Int]?, pageCount: Int) -> [Int] {
        guard let pages, pageCount > 0 else { return [] }
        var seen: Set<Int> = []
        var result: [Int] = []
        for page in pages.prefix(Limits.pagesPerItem) {
            guard (1...pageCount).contains(page), !seen.contains(page) else { continue }
            seen.insert(page)
            result.append(page)
        }
        return result.sorted()
    }

    // MARK: - Raw decode helpers

    private static func decodeRaw(_ text: String) throws -> RawDigest {
        let stripped = stripFences(text)
        guard let data = stripped.data(using: .utf8),
              let raw = try? JSONDecoder().decode(RawDigest.self, from: data)
        else { throw ParseError.notJSON }
        return raw
    }

    /// Strips ``` fences and a leading/trailing prose line around the
    /// JSON body (common model behaviors; harmless when absent).
    private static func stripFences(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            if let firstNewline = trimmed.firstIndex(of: "\n") {
                trimmed = String(trimmed[trimmed.index(after: firstNewline)...])
            }
            if let closingRange = trimmed.range(of: "```", options: .backwards) {
                trimmed = String(trimmed[..<closingRange.lowerBound])
            }
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func bounded(_ text: String?, limit: Int) -> String {
        guard let text, !text.isEmpty else { return "" }
        return text.count > limit ? String(text.prefix(limit)) : text
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
