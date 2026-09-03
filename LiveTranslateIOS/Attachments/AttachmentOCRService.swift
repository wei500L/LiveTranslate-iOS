import Foundation
import Vision
import UIKit

/// Local OCR over classroom images, used as an AUXILIARY search index —
/// never as a substitute for the multimodal analysis. Recognition runs
/// with ru-RU + en-US languages when the system supports them; the result
/// is stored separately (SessionAttachment.ocrText) and failure is always
/// non-fatal (empty text, image still usable).
///
/// We do NOT claim reliable recognition of Russian handwriting — Vision's
/// accuracy on cursive blackboard writing is limited; the UI words this
/// honestly (自动识别，可能有误).
enum AttachmentOCRService {
    /// Whether this device's Vision runtime has Russian recognition
    /// support (drives honest UI copy — no fake capability claims).
    static var supportsRussian: Bool {
        let supported = VNRecognizeTextRequest.supportedRecognitionLanguages(
            for: .accurate, revision: VNRecognizeTextRequestRevision.current
        ) ?? []
        return supported.contains { $0.hasPrefix("ru") }
    }

    struct RecognitionOutcome {
        var text: String
        /// Whether ru/en was actually available (false → ran with system
        /// default languages only).
        var usedRussian: Bool
    }

    /// Synchronous recognition on a background executor. Returns nil on
    /// hard failure (caller treats OCR as absent — never an error path).
    static func recognize(imageData: Data) async -> RecognitionOutcome? {
        guard let image = UIImage(data: imageData)?.cgImage else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if supportsRussian {
            request.recognitionLanguages = ["ru-RU", "en-US"]
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        let lines = (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first?.string
        }
        guard !lines.isEmpty else { return nil }
        return RecognitionOutcome(
            text: lines.joined(separator: "\n"),
            usedRussian: supportsRussian
        )
    }
}
