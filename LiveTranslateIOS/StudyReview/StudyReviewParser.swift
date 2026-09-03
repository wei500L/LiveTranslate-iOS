import Foundation

/// Tolerant parser for model outputs. Never fabricates a successful
/// review: when nothing usable can be parsed it throws; when only some
/// fields are usable the rest default to empty. Citation numbers are
/// validated against the chunk plan and invalid ones are dropped — an AI
/// claim must never point at a transcript line that was not sent.
enum StudyReviewParser {
    /// Hard bounds so a runaway response can never write unbounded data
    /// into the store.
    enum Limits {
        static let topic = 160
        static let summary = 4_000
        static let itemText = 1_200
        static let outlineNodes = 120
        static let keyPoints = 60
        static let terms = 80
        static let assignments = 40
        static let uncertainties = 30
        static let citesPerItem = 20
        static let extractionJSON = 120_000
    }

    enum ParseError: Error, Equatable {
        /// The response was not JSON at all (after fence stripping).
        case notJSON
        /// JSON parsed but produced no usable field.
        case empty
        /// Extraction JSON exceeded the persistence bound.
        case tooLarge
    }

    // MARK: - Raw model shapes (cites are request-scoped numbers)

    private struct RawContent: Decodable {
        var topic: String?
        var summary: String?
        var outline: [RawOutlineNode]?
        var keyPoints: [RawKeyPoint]?
        var terms: [RawTerm]?
        var assignments: [RawAssignment]?
        var uncertainties: [RawUncertainty]?
    }

    private struct RawOutlineNode: Decodable {
        var title: String?
        var detail: String?
        var cites: [Int]?
        var refAttachments: [Int]?
        var children: [RawOutlineNode]?
    }

    private struct RawKeyPoint: Decodable {
        var text: String?
        var cites: [Int]?
        var refAttachments: [Int]?
    }

    private struct RawTerm: Decodable {
        var russian: String?
        var chinese: String?
        var explanation: String?
        var cites: [Int]?
        var refAttachments: [Int]?
    }

    private struct RawAssignment: Decodable {
        var text: String?
        var cites: [Int]?
        var refAttachments: [Int]?
    }

    private struct RawUncertainty: Decodable {
        var text: String?
        var cites: [Int]?
        var refAttachments: [Int]?
    }

    // MARK: - Public API

    /// Parses a chunk-extraction or merge response into the final content,
    /// mapping citation numbers back to real entry ids.
    /// - Parameters:
    ///   - text: raw model output (possibly fenced, possibly with prose).
    ///   - citationIDs: global table — number n maps to citationIDs[n-1].
    static func parse(
        text: String, citationIDs: [UUID], attachmentIDs: [UUID] = []
    ) throws -> StudyReviewContent {
        let raw = try decodeRaw(text)
        var content = StudyReviewContent()
        content.topic = bounded(raw.topic, limit: Limits.topic)
        content.summary = bounded(raw.summary, limit: Limits.summary)
        var outlineBudget = Limits.outlineNodes
        content.outline = mapOutline(
            raw.outline ?? [], citationIDs: citationIDs,
            attachmentIDs: attachmentIDs, remaining: &outlineBudget
        )
        content.keyPoints = (raw.keyPoints ?? []).prefix(Limits.keyPoints)
            .map { .init(
                text: bounded($0.text, limit: Limits.itemText),
                refEntryIDs: mapCites($0.cites, citationIDs: citationIDs),
                refAttachmentIDs: mapAttachmentRefs($0.refAttachments, attachmentIDs: attachmentIDs)
            ) }
        content.terms = (raw.terms ?? []).prefix(Limits.terms)
            .map { .init(
                russian: bounded($0.russian, limit: Limits.itemText),
                chinese: bounded($0.chinese, limit: Limits.itemText),
                explanation: bounded($0.explanation, limit: Limits.itemText),
                refEntryIDs: mapCites($0.cites, citationIDs: citationIDs),
                refAttachmentIDs: mapAttachmentRefs($0.refAttachments, attachmentIDs: attachmentIDs)
            ) }
        content.assignments = (raw.assignments ?? []).prefix(Limits.assignments)
            .map { .init(
                text: bounded($0.text, limit: Limits.itemText),
                refEntryIDs: mapCites($0.cites, citationIDs: citationIDs),
                refAttachmentIDs: mapAttachmentRefs($0.refAttachments, attachmentIDs: attachmentIDs)
            ) }
        content.uncertainties = (raw.uncertainties ?? []).prefix(Limits.uncertainties)
            .map { .init(
                text: bounded($0.text, limit: Limits.itemText),
                refEntryIDs: mapCites($0.cites, citationIDs: citationIDs),
                refAttachmentIDs: mapAttachmentRefs($0.refAttachments, attachmentIDs: attachmentIDs)
            ) }

        guard !content.isEmptyParse else { throw ParseError.empty }
        return content
    }

    /// Validates a chunk extraction for persistence: bounded, parseable
    /// JSON. Returns the (re-encoded, sorted) JSON string.
    static func normalizeExtraction(_ text: String) throws -> String {
        let raw = try decodeRaw(text)
        // Re-encode only the fields the merge stage consumes.
        var object: [String: Any] = [:]
        if let topic = raw.topic { object["topic"] = bounded(topic, limit: Limits.topic) }
        if let keyPoints = raw.keyPoints {
            object["keyPoints"] = keyPoints.prefix(Limits.keyPoints).map { point in
                var item: [String: Any] = ["text": bounded(point.text, limit: Limits.itemText)]
                item["cites"] = (point.cites ?? []).prefix(Limits.citesPerItem).map { $0 }
                item["refAttachments"] = (point.refAttachments ?? []).prefix(Limits.citesPerItem).map { $0 }
                return item
            }
        }
        if let terms = raw.terms {
            object["terms"] = terms.prefix(Limits.terms).map { term in
                var item: [String: Any] = [:]
                item["russian"] = bounded(term.russian, limit: Limits.itemText)
                item["chinese"] = bounded(term.chinese, limit: Limits.itemText)
                item["explanation"] = bounded(term.explanation, limit: Limits.itemText)
                item["cites"] = (term.cites ?? []).prefix(Limits.citesPerItem).map { $0 }
                item["refAttachments"] = (term.refAttachments ?? []).prefix(Limits.citesPerItem).map { $0 }
                return item
            }
        }
        if let assignments = raw.assignments {
            object["assignments"] = assignments.prefix(Limits.assignments).map { item in
                var entry: [String: Any] = ["text": bounded(item.text, limit: Limits.itemText)]
                entry["cites"] = (item.cites ?? []).prefix(Limits.citesPerItem).map { $0 }
                entry["refAttachments"] = (item.refAttachments ?? []).prefix(Limits.citesPerItem).map { $0 }
                return entry
            }
        }
        if let uncertainties = raw.uncertainties {
            object["uncertainties"] = uncertainties.prefix(Limits.uncertainties).map { item in
                var entry: [String: Any] = ["text": bounded(item.text, limit: Limits.itemText)]
                entry["cites"] = (item.cites ?? []).prefix(Limits.citesPerItem).map { $0 }
                return entry
            }
        }
        guard !object.isEmpty else { throw ParseError.empty }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let json = String(data: data, encoding: .utf8) ?? ""
        guard json.count <= Limits.extractionJSON else { throw ParseError.tooLarge }
        return json
    }

    // MARK: - Helpers

    /// Strips Markdown code fences and finds the outermost JSON object.
    static func jsonPayload(from text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // ```json … ``` fences (some models always wrap).
        if trimmed.hasPrefix("```") {
            if let firstNewline = trimmed.firstIndex(of: "\n") {
                trimmed = String(trimmed[trimmed.index(after: firstNewline)...])
            }
            if let closingRange = trimmed.range(of: "```", options: .backwards) {
                trimmed = String(trimmed[..<closingRange.lowerBound])
            }
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Prose before/after the object: use the outermost braces.
        if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start < end {
            return String(trimmed[start...end])
        }
        return trimmed
    }

    private static func decodeRaw(_ text: String) throws -> RawContent {
        let payload = jsonPayload(from: text)
        guard let data = payload.data(using: .utf8),
              let raw = try? JSONDecoder().decode(RawContent.self, from: data) else {
            throw ParseError.notJSON
        }
        return raw
    }

    private static func mapOutline(
        _ nodes: [RawOutlineNode], citationIDs: [UUID], attachmentIDs: [UUID],
        remaining: inout Int
    ) -> [StudyReviewContent.OutlineNode] {
        var result: [StudyReviewContent.OutlineNode] = []
        result.reserveCapacity(min(nodes.count, max(remaining, 0)))
        for node in nodes {
            guard remaining > 0 else { break }
            remaining -= 1
            let children = mapOutline(
                node.children ?? [], citationIDs: citationIDs,
                attachmentIDs: attachmentIDs, remaining: &remaining
            )
            result.append(.init(
                title: bounded(node.title, limit: Limits.itemText),
                detail: bounded(node.detail, limit: Limits.itemText),
                refEntryIDs: mapCites(node.cites, citationIDs: citationIDs),
                refAttachmentIDs: mapAttachmentRefs(
                    node.refAttachments, attachmentIDs: attachmentIDs
                ),
                children: children
            ))
        }
        return result
    }

    /// P-numbers → attachment ids; invalid numbers are dropped (the model
    /// may only cite images that were actually sent).
    private static func mapAttachmentRefs(_ refs: [Int]?, attachmentIDs: [UUID]) -> [UUID] {
        guard let refs, !refs.isEmpty else { return [] }
        var seen = Set<UUID>()
        var result: [UUID] = []
        for number in refs.prefix(Limits.citesPerItem) where number >= 1 && number <= attachmentIDs.count {
            let id = attachmentIDs[number - 1]
            if seen.insert(id).inserted {
                result.append(id)
            }
        }
        return result
    }

    /// Citation numbers → entry ids; invalid numbers are dropped (the
    /// model may only cite numbers that were actually sent).
    private static func mapCites(_ cites: [Int]?, citationIDs: [UUID]) -> [UUID] {
        guard let cites, !cites.isEmpty else { return [] }
        var seen = Set<UUID>()
        var result: [UUID] = []
        for number in cites.prefix(Limits.citesPerItem) where number >= 1 && number <= citationIDs.count {
            let id = citationIDs[number - 1]
            if seen.insert(id).inserted {
                result.append(id)
            }
        }
        return result
    }

    private static func bounded(_ raw: String?, limit: Int) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(limit))
    }
}

private extension StudyReviewContent {
    /// True when nothing survived parsing (used to reject empty responses
    /// instead of saving a blank "successful" review).
    var isEmptyParse: Bool {
        topic.isEmpty && summary.isEmpty && outline.isEmpty && keyPoints.isEmpty
            && terms.isEmpty && assignments.isEmpty && uncertainties.isEmpty
    }
}
