import Foundation

/// Coarse pipeline phase shown in the Live screen status header.
enum PipelinePhase: String, Codable, Sendable, Equatable {
    case idle
    case modelNotInstalled
    case downloading
    case verifying
    case compilingCoreML
    case loadingModel
    case warmingUp
    case ready
    case listening
    case speechDetected
    case transcribing
    case translating
    case paused
    case micInterrupted
    case networkOffline
    case backendError
    case diskSpaceLow
    case finished

    var isTerminal: Bool { self == .finished }
}

/// Fine-grained, observable pipeline state published to the UI.
struct PipelineState: Sendable, Equatable {
    var phase: PipelinePhase = .idle
    var activeBackend: ASRBackendKind?
    var coreMLComputeDescription: String = ""
    var onnxThreadCount: Int = 2
    /// Present when `phase == .backendError`.
    var errorMessage: String?
    /// Elapsed classroom time (seconds, only while running).
    var elapsed: TimeInterval = 0
    /// Latest per-segment metrics.
    var lastASRLatency: TimeInterval?
    var lastTranslationLatency: TimeInterval?
    var lastRTF: Double?

    static func == (lhs: PipelineState, rhs: PipelineState) -> Bool {
        lhs.phase == rhs.phase && lhs.activeBackend == rhs.activeBackend
            && lhs.errorMessage == rhs.errorMessage
            && lhs.elapsed == rhs.elapsed
    }
}
