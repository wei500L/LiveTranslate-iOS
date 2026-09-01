import Foundation

/// The two local inference backends for the *same* GigaAM-v3 `e2e_rnnt`
/// checkpoint. These are NOT two different ASR models — product UI must
/// always present them as two runtimes of one model.
///
/// - `coreMLFP16`: Apple Core ML FP16 conversion (precision-first).
/// - `sherpaONNXInt8`: sherpa-onnx INT8 quantized ONNX (size-first).
enum ASRBackendKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case coreMLFP16
    case sherpaONNXInt8

    var id: String { rawValue }

    /// Product display name. Must always name the unified model identity.
    var displayName: String {
        switch self {
        case .coreMLFP16: return "GigaAM-v3 e2e_rnnt · Core ML FP16"
        case .sherpaONNXInt8: return "GigaAM-v3 e2e_rnnt · sherpa-onnx INT8"
        }
    }

    /// Short label for compact UI (subtitle chips, export headers).
    var shortLabel: String {
        switch self {
        case .coreMLFP16: return "Core ML FP16"
        case .sherpaONNXInt8: return "sherpa-onnx INT8"
        }
    }

    var positioning: String {
        switch self {
        case .coreMLFP16:
            return String(localized: "Precision first · Apple native · recommended for iPhone 17 Pro Max")
        case .sherpaONNXInt8:
            return String(localized: "Size first · mature mobile runtime · CPU inference")
        }
    }
}
