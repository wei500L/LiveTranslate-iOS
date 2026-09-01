import Foundation

/// Unified transcription result returned by every backend.
///
/// Both backends emit the raw GigaAM `e2e_rnnt` punctuated text — no
/// secondary punctuation model is applied anywhere in the pipeline.
struct ASRResult: Sendable, Equatable {
    let text: String
    /// Always "ru" — GigaAM-v3 is Russian-only.
    let language: String
    let backend: ASRBackendKind
    /// Duration of the audio segment in seconds.
    let audioDuration: TimeInterval
    /// Wall-clock time spent in inference (seconds).
    let inferenceDuration: TimeInterval
    /// inferenceDuration / audioDuration. Lower is faster than real time.
    let realTimeFactor: Double
    /// Segment offsets from session start (seconds).
    let segmentStart: TimeInterval
    let segmentEnd: TimeInterval

    static func == (lhs: ASRResult, rhs: ASRResult) -> Bool {
        lhs.text == rhs.text && lhs.language == rhs.language
            && lhs.backend == rhs.backend
            && lhs.segmentStart == rhs.segmentStart
    }
}

/// Errors surfaced by ASR backends. Never silently swallowed and never
/// silently switched to another backend.
enum ASREngineError: LocalizedError, Sendable {
    case modelNotInstalled(ASRBackendKind)
    case integrityFailure(path: String, reason: String)
    case loadFailed(ASRBackendKind, underlying: String)
    case predictionFailed(String)
    case engineNotLoaded
    case incompatibleInput(String)

    var errorDescription: String? {
        switch self {
        case .modelNotInstalled(let kind):
            return String(format: String(localized: "%@ is not installed. Open Model Management to download it."), kind.displayName)
        case .integrityFailure(let path, let reason):
            return "Integrity check failed for \(path): \(reason)"
        case .loadFailed(let kind, let underlying):
            return "\(kind.displayName) failed to load: \(underlying)"
        case .predictionFailed(let detail):
            return "Inference failed: \(detail)"
        case .engineNotLoaded:
            return String(localized: "The recognition engine is not loaded.")
        case .incompatibleInput(let detail):
            return "Incompatible audio input: \(detail)"
        }
    }
}
