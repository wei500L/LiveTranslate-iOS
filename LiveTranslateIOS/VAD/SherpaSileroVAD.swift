import Foundation
import OSLog
import SherpaOnnxC

/// Silero VAD via the sherpa-onnx C API — the shared voice-activity layer
/// used by both ASR backends.
///
/// We use sherpa's detector as a *state oracle*: windows are fed one at a
/// time and `SherpaOnnxVoiceActivityDetectorDetected` reports whether the
/// model currently considers the stream inside speech. The higher-level
/// segmentation policy (durations, forced splits, pre/post-roll) lives in
/// `SpeechSegmenter` so it stays pure Swift and unit-testable.
///
/// Model resolution order:
/// 1. `ModelPaths.vadModelURL()` (Application Support — the model manager
///    installs it there).
/// 2. The app bundle (`silero_vad.onnx` resource) as a fallback.
final class SherpaSileroVAD: SpeechActivityDetector, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.livetranslate.ios", category: "vad")

    private let lock = NSLock()
    private var detector: OpaquePointer?
    private let modelPath: String

    enum VADError: LocalizedError {
        case modelMissing
        case initializationFailed

        var errorDescription: String? {
            switch self {
            case .modelMissing:
                return String(localized: "The Silero VAD model is not installed. Download it from Model Management.")
            case .initializationFailed:
                return String(localized: "Silero VAD failed to initialize.")
            }
        }
    }

    struct Parameters {
        var threshold: Float = 0.5
        /// Silence that closes a segment — the segmenter's own policy layer
        /// refines this; sherpa's internal segmentation is not used.
        var minSilenceDuration: Float = 0.6
        var minSpeechDuration: Float = 0.25
        var maxSpeechDuration: Float = 25.0
        var windowSize: Int32 = 512
    }

    /// - Throws: `VADError.modelMissing` when no model file can be found.
    init(parameters: Parameters = Parameters()) throws {
        let url = Self.resolveModelURL()
        guard let url else { throw VADError.modelMissing }
        modelPath = url.path
        // Keep a strong reference: the C string must outlive the
        // SherpaOnnxCreateVoiceActivityDetector call below.
        let modelPathCString = (modelPath as NSString).utf8String
        let providerCString = ("cpu" as NSString).utf8String

        var config = SherpaOnnxVadModelConfig()
        memset(&config, 0, MemoryLayout<SherpaOnnxVadModelConfig>.size)
        config.sample_rate = 16_000
        config.num_threads = 1
        config.provider = providerCString
        config.debug = 0
        config.silero_vad.model = modelPathCString
        config.silero_vad.threshold = parameters.threshold
        config.silero_vad.min_silence_duration = parameters.minSilenceDuration
        config.silero_vad.min_speech_duration = parameters.minSpeechDuration
        config.silero_vad.max_speech_duration = parameters.maxSpeechDuration
        config.silero_vad.window_size = parameters.windowSize

        guard let created = SherpaOnnxCreateVoiceActivityDetector(&config, 30.0) else {
            throw VADError.initializationFailed
        }
        detector = created
        Self.logger.info("Silero VAD loaded from \(self.modelPath, privacy: .public)")
    }

    deinit {
        if let detector {
            SherpaOnnxDestroyVoiceActivityDetector(detector)
        }
    }

    private static func resolveModelURL() -> URL? {
        if let support = try? ModelPaths.vadModelURL(),
           FileManager.default.fileExists(atPath: support.path) {
            return support
        }
        return Bundle.main.url(forResource: "silero_vad", withExtension: "onnx")
    }

    /// Where the model actually loaded from — surfaced in diagnostics.
    var resolvedModelPath: String { modelPath }

    func process(window: ArraySlice<Float>) -> Bool {
        let base = Array(window)
        let samples: [Float]
        if base.count < 512 {
            // Pad the final short window so the model always sees 512.
            samples = base + [Float](repeating: 0, count: 512 - base.count)
        } else {
            samples = base
        }
        lock.lock(); defer { lock.unlock() }
        guard let detector else { return false }
        samples.withUnsafeBufferPointer { buffer in
            SherpaOnnxVoiceActivityDetectorAcceptWaveform(
                detector, buffer.baseAddress, Int32(samples.count)
            )
        }
        return SherpaOnnxVoiceActivityDetectorDetected(detector) == 1
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        guard let detector else { return }
        SherpaOnnxVoiceActivityDetectorReset(detector)
    }

    /// Force-close any pending segment inside sherpa (used on stream end
    /// even though the product's segmentation policy is ours).
    func flush() {
        lock.lock(); defer { lock.unlock() }
        guard let detector else { return }
        SherpaOnnxVoiceActivityDetectorFlush(detector)
        // Drain anything sherpa closed internally — its segmentation output
        // is unused, but the queue must not grow.
        while SherpaOnnxVoiceActivityDetectorEmpty(detector) == 0 {
            if let segment = SherpaOnnxVoiceActivityDetectorFront(detector) {
                SherpaOnnxDestroySpeechSegment(segment)
            }
            SherpaOnnxVoiceActivityDetectorPop(detector)
        }
    }
}
