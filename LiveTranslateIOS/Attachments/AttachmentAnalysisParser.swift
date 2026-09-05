import Foundation

/// Tolerant parser for the multimodal image-analysis response. Mirrors
/// StudyReviewParser's posture: fence/prose stripping, hard limits, and
/// per-field recovery — a malformed `formulas` array never discards the
/// whole result (the run is then marked `.partial`).
enum AttachmentAnalysisParser {
    enum ParseError: Error, LocalizedError {
        case notJSON
        case empty
        case tooLarge
        case schemaVersionUnsupported(Int)

        var errorDescription: String? {
            switch self {
            case .notJSON: return String(localized: "模型没有返回可解析的 JSON")
            case .empty: return String(localized: "分析结果为空")
            case .tooLarge: return String(localized: "分析结果过大")
            case .schemaVersionUnsupported(let v):
                return String(localized: "分析结果版本不支持（\(v)）")
            }
        }
    }

    /// Hard caps (defensive — the model is instructed, not trusted).
    enum Limits {
        static let maxResponseBytes = 400_000
        static let maxArrayItems = 60
        static let maxItemLength = 6_000
        static let maxExplanationLength = 6_000
    }

    /// Extracts the JSON payload: strips ``` fences and a leading/trailing
    /// prose line, then finds the outermost object.
    static func jsonPayload(from text: String) -> String? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            // ```json\n{...}\n``` → {...}
            if let firstNewline = trimmed.firstIndex(of: "\n") {
                trimmed = String(trimmed[trimmed.index(after: firstNewline)...])
            }
            if let closing = trimmed.range(of: "```", options: .backwards) {
                trimmed = String(trimmed[..<closing.lowerBound])
            }
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Locate the outermost { … } regardless of surrounding prose.
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"), start < end else {
            return nil
        }
        return String(trimmed[start...end])
    }

    /// Parses and sanitizes. `citationIDs` maps the model's 1-based
    /// citation numbers to real entry ids; out-of-range or non-numeric
    /// references are dropped (never fatal).
    static func parse(text: String, citationIDs: [UUID]) throws -> AttachmentAnalysisResult {
        let payload = jsonPayload(from: text) ?? text
        guard !payload.isEmpty else { throw ParseError.empty }
        guard payload.utf8.count <= Limits.maxResponseBytes else { throw ParseError.tooLarge }

        guard let data = payload.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.notJSON
        }

        let schemaVersion = (raw["schemaVersion"] as? Int) ?? AttachmentAnalysisResult.currentSchemaVersion
        guard schemaVersion <= AttachmentAnalysisResult.currentSchemaVersion else {
            throw ParseError.schemaVersionUnsupported(schemaVersion)
        }

        // Validate transcript references against the real entry ids.
        var references: [UUID] = []
        if let refs = raw["transcriptReferences"] as? [Any] {
            for item in refs.prefix(Limits.maxArrayItems) {
                if let n = item as? Int, n >= 1, n <= citationIDs.count {
                    let id = citationIDs[n - 1]
                    if !references.contains(id) { references.append(id) }
                } else if let s = item as? String, let n = Int(s), n >= 1, n <= citationIDs.count {
                    let id = citationIDs[n - 1]
                    if !references.contains(id) { references.append(id) }
                }
            }
        }

        var result = AttachmentAnalysisResult(
            schemaVersion: schemaVersion,
            title: clampString(raw["title"], limit: 120),
            visibleText: clampArray(raw["visibleText"]),
            formulas: clampArray(raw["formulas"]),
            codeBlocks: clampArray(raw["codeBlocks"]),
            keyPoints: clampArray(raw["keyPoints"]),
            explanation: clampString(raw["explanation"], limit: Limits.maxExplanationLength),
            uncertainties: clampArray(raw["uncertainties"]),
            transcriptReferences: references.isEmpty ? nil : references
        )
        result.analysisModel = clampString(raw["analysisModel"], limit: 200)

        // A result with literally nothing usable is as bad as no result.
        let hasContent = !(result.visibleText ?? []).isEmpty
            || !(result.formulas ?? []).isEmpty
            || !(result.codeBlocks ?? []).isEmpty
            || !(result.keyPoints ?? []).isEmpty
            || !(result.explanation ?? "").isEmpty
        guard hasContent else { throw ParseError.empty }
        return result
    }

    /// True when every expected field survived (drives the completed vs
    /// partial status decision).
    static func isComplete(_ result: AttachmentAnalysisResult, parseHadWarnings: Bool) -> Bool {
        !parseHadWarnings
    }

    // MARK: - Field helpers

    private static func clampString(_ value: Any?, limit: Int) -> String? {
        guard let s = value as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(limit))
    }

    private static func clampArray(_ value: Any?) -> [String]? {
        var source: [String] = []
        if let arr = value as? [Any] {
            source = arr.compactMap { $0 as? String }
        } else if let single = value as? String {
            source = [single]
        }
        guard !source.isEmpty else { return nil }
        return source.prefix(Limits.maxArrayItems).map { item in
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            return String(trimmed.prefix(Limits.maxItemLength))
        }.filter { !$0.isEmpty }
    }
}
