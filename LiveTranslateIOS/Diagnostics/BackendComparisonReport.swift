import Foundation

/// Pure text-similarity metrics used by the backend comparison report.
///
/// Normalization mirrors common ASR evaluation practice: lowercase, strip
/// punctuation, collapse whitespace. CER is character-level edit distance
/// over the reference length; WER is word-level over the space-split
/// tokens. These functions only *describe* differences — with no human
/// reference text, they never decide which backend is "more accurate".
enum TextMetrics {
    static let punctuation = CharacterSet(
        charactersIn: ".,!?;:\"'«»—–-()[]{}…‽„”’" + "。" + "，！？；：“”‘’（）《》【】…—"
    )

    static func normalize(_ text: String, stripPunctuation: Bool = true) -> String {
        var lowered = text.lowercased()
        if stripPunctuation {
            lowered = lowered.components(separatedBy: punctuation).joined()
        }
        return lowered
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Levenshtein distance between two arrays of comparable elements.
    static func editDistance<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// Character error rate. 0 = identical. Empty reference with non-empty
    /// hypothesis is a total mismatch (1.0), never a division by zero.
    static func cer(hypothesis: String, reference: String, stripPunctuation: Bool = true) -> Double {
        let hyp = Array(normalize(hypothesis, stripPunctuation: stripPunctuation))
        let ref = Array(normalize(reference, stripPunctuation: stripPunctuation))
        guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }
        return Double(editDistance(hyp, ref)) / Double(ref.count)
    }

    /// Word error rate over space-split normalized tokens.
    static func wer(hypothesis: String, reference: String) -> Double {
        let hyp = normalize(hypothesis).split(separator: " ").map(String.init)
        let ref = normalize(reference).split(separator: " ").map(String.init)
        guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }
        return Double(editDistance(hyp, ref)) / Double(ref.count)
    }

    /// Compact character-level diff summary for two transcripts: shared
    /// prefix/suffix plus the differing middle spans, capped for display.
    static func characterDiffSummary(_ a: String, _ b: String) -> String {
        let left = Array(a)
        let right = Array(b)
        var commonPrefix = 0
        while commonPrefix < left.count && commonPrefix < right.count
            && left[commonPrefix] == right[commonPrefix] {
            commonPrefix += 1
        }
        var commonSuffix = 0
        while commonSuffix < left.count - commonPrefix
            && commonSuffix < right.count - commonPrefix
            && left[left.count - 1 - commonSuffix] == right[right.count - 1 - commonSuffix] {
            commonSuffix += 1
        }
        let aMiddle = String(left[commonPrefix..<(left.count - commonSuffix)])
        let bMiddle = String(right[commonPrefix..<(right.count - commonSuffix)])
        if aMiddle.isEmpty && bMiddle.isEmpty { return "identical" }
        func clip(_ s: String) -> String { s.count > 40 ? "…" + s.suffix(40) : s }
        if aMiddle.isEmpty { return "+\(clip(bMiddle))" }
        if bMiddle.isEmpty { return "+\(clip(aMiddle))" }
        return "“\(clip(aMiddle))” ↔ “\(clip(bMiddle))”"
    }
}

/// Full comparison of the two backends over one or more audio items.
/// Codable so it can round-trip through JSON export.
struct BackendComparisonReport: Codable, Sendable, Equatable {
    struct ItemResult: Codable, Sendable, Equatable {
        var name: String
        var audioDuration: TimeInterval
        var coreMLText: String
        var sherpaText: String
        var textsIdentical: Bool
        var characterDiff: String
        /// CER of sherpa output using coreml output as reference.
        var sherpaCERvsCoreML: Double
        /// CER of coreml output using sherpa output as reference.
        var coreMLCERvsSherpa: Double
        /// CER ignoring punctuation entirely.
        var punctuationStrippedCER: Double
        var referenceText: String?
        var coreMLCERvsReference: Double?
        var coreMLWERvsReference: Double?
        var sherpaCERvsReference: Double?
        var sherpaWERvsReference: Double?
    }

    struct BackendSummary: Codable, Sendable, Equatable {
        var loadDuration: TimeInterval
        var firstInference: TimeInterval
        var medianWarmInference: TimeInterval?
        var totalAudioDuration: TimeInterval
        var realTimeFactor: Double?
        var peakMemoryBytes: Int64
    }

    var items: [ItemResult]
    var coreML: BackendSummary
    var sherpa: BackendSummary
    /// Footprint after each unload, for the memory-release check.
    var postCoreMLUnloadMemoryBytes: Int64
    var postSherpaUnloadMemoryBytes: Int64
    var thermalState: String
    var coreMLComputeUnit: String
    var onnxThreadCount: Int
    var modelVersion: String
    var deviceModel: String
    var osVersion: String
    var testedAt: Date
    /// True when at least one item had a human reference text — only then
    /// do the vs-reference columns mean anything.
    var hasReferenceText: Bool

    var allTextsIdentical: Bool { items.allSatisfy(\.textsIdentical) }

    // MARK: - Export

    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    static func fromJSON(_ data: Data) throws -> BackendComparisonReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackendComparisonReport.self, from: data)
    }

    /// Markdown export. Contains no API keys, no Authorization headers, no
    /// internal file paths — only file names supplied by the benchmark.
    func markdown() -> String {
        var lines: [String] = []
        lines.append("# GigaAM-v3 e2e_rnnt — Backend Comparison Report")
        lines.append("")
        lines.append("One model, two local inference backends. This report describes differences; it does **not** rank accuracy without a human reference transcript.")
        lines.append("")
        lines.append("| | Core ML FP16 | sherpa-onnx INT8 |")
        lines.append("|---|---|---|")
        lines.append("| Load time | \(fmt(coreML.loadDuration)) | \(fmt(sherpa.loadDuration)) |")
        lines.append("| First inference | \(fmt(coreML.firstInference)) | \(fmt(sherpa.firstInference)) |")
        lines.append("| Median warm inference | \(fmt(coreML.medianWarmInference)) | \(fmt(sherpa.medianWarmInference)) |")
        lines.append("| RTF | \(fmt(coreML.realTimeFactor)) | \(fmt(sherpa.realTimeFactor)) |")
        lines.append("| Peak memory | \(mb(coreML.peakMemoryBytes)) | \(mb(sherpa.peakMemoryBytes)) |")
        lines.append("")
        lines.append("- Thermal state: \(thermalState)")
        lines.append("- Core ML compute unit: \(coreMLComputeUnit)")
        lines.append("- INT8 threads: \(onnxThreadCount)")
        lines.append("- Model version (pinned revisions): \(modelVersion)")
        lines.append("- Device: \(deviceModel), \(osVersion)")
        lines.append("- Tested at: \(ISO8601DateFormatter().string(from: testedAt))")
        lines.append("- Transcripts identical on all items: \(allTextsIdentical ? "yes" : "no")")
        lines.append("")
        if hasReferenceText {
            lines.append("Human reference text was provided for at least one item, so vs-reference CER/WER columns are meaningful.")
        } else {
            lines.append("> No human reference text was provided. The CER columns below only measure the **difference between the two backends**; they cannot say which one is more accurate.")
        }
        lines.append("")
        for item in items {
            lines.append("## \(item.name) (\(String(format: "%.1f", item.audioDuration)) s)")
            lines.append("")
            lines.append("**Core ML FP16:** \(item.coreMLText.isEmpty ? "_(empty)_" : item.coreMLText)")
            lines.append("")
            lines.append("**sherpa-onnx INT8:** \(item.sherpaText.isEmpty ? "_(empty)_" : item.sherpaText)")
            lines.append("")
            lines.append("- Identical: \(item.textsIdentical ? "yes" : "no")")
            lines.append("- Character diff: \(item.characterDiff)")
            lines.append(String(format: "- CER sherpa-vs-coreml: %.4f · coreml-vs-sherpa: %.4f · punctuation-stripped: %.4f",
                                item.sherpaCERvsCoreML, item.coreMLCERvsSherpa, item.punctuationStrippedCER))
            if let ref = item.referenceText {
                lines.append("- Reference: \(ref)")
                if let c = item.coreMLCERvsReference, let w = item.coreMLWERvsReference {
                    lines.append(String(format: "- Core ML vs reference — CER %.4f · WER %.4f", c, w))
                }
                if let c = item.sherpaCERvsReference, let w = item.sherpaWERvsReference {
                    lines.append(String(format: "- sherpa-onnx vs reference — CER %.4f · WER %.4f", c, w))
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func fmt(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.3f s", value)
    }

    private func mb(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }
}
