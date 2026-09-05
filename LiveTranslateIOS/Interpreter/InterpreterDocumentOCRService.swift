import Foundation
import Vision
import UIKit

/// Local OCR for interpreter (随身翻译) document pages — the primary
/// text-extraction path for photos and scanned PDFs. Unlike the classroom
/// attachment OCR (a search index), this output becomes the AI's context
/// and the citation source, so it records:
/// - per-line text in reading order (top-to-bottom, line order kept);
/// - the AVERAGE confidence of recognized lines (honest signal for the
///   低置信度 UI hint — never silently rewritten);
/// - ru-RU + zh-Hans + en-US recognition languages when the system
///   supports them (the on-site documents are Russian; Chinese/English
///   cover stamps and annotations).
///
/// We do NOT claim reliable recognition of Russian handwriting; the UI
/// words this honestly (自动识别，可能有误).
enum InterpreterDocumentOCRService {
    /// Whether this device's Vision runtime has Russian recognition
    /// support (drives honest UI copy — no fake capability claims).
    static var supportsRussian: Bool {
        let request = VNRecognizeTextRequest()
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        return supported.contains { $0.hasPrefix("ru") }
    }

    struct RecognitionOutcome: Sendable {
        var text: String
        /// Average confidence of recognized lines, 0…1 (-1 = unknown).
        var confidence: Double
        /// Whether Russian was actually available.
        var usedRussian: Bool
    }

    /// Synchronous recognition on a background-safe call path (callers
    /// await from a detached task). Returns nil on hard failure — the
    /// caller marks the page failed (resumable), never a fake success.
    static func recognize(imageData: Data) async -> RecognitionOutcome? {
        guard let image = UIImage(data: imageData)?.cgImage else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if supportsRussian {
            request.recognitionLanguages = ["ru-RU", "zh-Hans", "en-US"]
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        let observations = request.results ?? []
        guard !observations.isEmpty else { return nil }
        var lines: [String] = []
        var confidences: [Double] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            lines.append(candidate.string)
            // Vision confidence is 0…1; record the honest per-line value.
            confidences.append(Double(candidate.confidence))
        }
        guard !lines.isEmpty else { return nil }
        let average = confidences.isEmpty
            ? -1
            : confidences.reduce(0, +) / Double(confidences.count)
        return RecognitionOutcome(
            text: lines.joined(separator: "\n"),
            confidence: average,
            usedRussian: supportsRussian
        )
    }
}
