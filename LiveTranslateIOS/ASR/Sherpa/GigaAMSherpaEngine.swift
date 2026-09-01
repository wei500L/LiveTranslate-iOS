import Foundation
import OSLog
import SherpaOnnxC

/// GigaAM-v3 `e2e_rnnt` via the sherpa-onnx offline transducer recognizer.
///
/// - One recognizer instance, created in `prepare()` and destroyed in
///   `unload()`. Every inference creates a fresh offline stream.
/// - All C API calls happen inside `RecognizerCore` (an actor) so inference
///   is serialized by construction — the pipeline never runs two
///   transcriptions at once.
/// - The returned text is GigaAM's own punctuated/cased output. No
///   post-processing beyond whitespace trimming.
/// - On failure this engine throws; it never silently falls back to Core ML,
///   Apple Speech or any cloud ASR.
struct GigaAMSherpaEngine: ASREngine {
    let backendKind: ASRBackendKind = .sherpaONNXInt8

    private let core: RecognizerCore
    /// Populated by prepare/warmup for benchmark reporting.
    private let metrics: MetricsBox

    init(threadCount: Int) {
        self.core = RecognizerCore(
            config: SherpaModelConfiguration.InferenceConfig.threads(threadCount)
        )
        self.metrics = MetricsBox()
    }

    // MARK: - ASREngine

    func prepare() async throws {
        guard SherpaModelConfiguration.isInstalled() else {
            throw ASREngineError.modelNotInstalled(.sherpaONNXInt8)
        }
        let started = Date()
        try await core.createRecognizer()
        metrics.loadDuration = Date().timeIntervalSince(started)
    }

    func warmup() async throws {
        // 0.5 s of silence: exercises the full feature-extraction → encoder →
        // decoder → joiner path so the first real segment isn't the first
        // inference ever.
        let started = Date()
        _ = try await core.transcribe(samples: [Float](repeating: 0, count: 8_000))
        metrics.firstInferenceDuration = Date().timeIntervalSince(started)
    }

    func transcribe(
        samples: [Float],
        sampleRate: Int,
        segmentStart: TimeInterval,
        segmentEnd: TimeInterval
    ) async throws -> ASRResult {
        guard sampleRate == 16_000 else {
            throw ASREngineError.incompatibleInput(
                "sherpa engine requires 16 kHz input, got \(sampleRate)"
            )
        }
        guard !samples.isEmpty else {
            throw ASREngineError.incompatibleInput("empty segment")
        }

        let started = Date()
        let text = try await core.transcribe(samples: samples)
        let inference = Date().timeIntervalSince(started)
        let audioDuration = Double(samples.count) / 16_000.0

        if metrics.hotInferenceDuration == nil {
            metrics.hotInferenceDuration = inference
        }
        return ASRResult(
            text: text,
            language: "ru",
            backend: .sherpaONNXInt8,
            audioDuration: audioDuration,
            inferenceDuration: inference,
            realTimeFactor: audioDuration > 0 ? inference / audioDuration : 0,
            segmentStart: segmentStart,
            segmentEnd: segmentEnd
        )
    }

    func unload() async {
        await core.destroyRecognizer()
        metrics.reset()
    }

    // MARK: - Performance metrics (read by the benchmark runner)

    struct PerformanceMetrics: Sendable {
        var loadDuration: TimeInterval?
        var firstInferenceDuration: TimeInterval?
        var hotInferenceDuration: TimeInterval?
    }

    func performanceMetrics() -> PerformanceMetrics {
        PerformanceMetrics(
            loadDuration: metrics.loadDuration,
            firstInferenceDuration: metrics.firstInferenceDuration,
            hotInferenceDuration: metrics.hotInferenceDuration
        )
    }
}

// MARK: - Thread-safe metric storage

/// The engine struct is copied around; metrics live behind a reference so
/// every copy reports the same engine instance's numbers.
final class MetricsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: GigaAMSherpaEngine.PerformanceMetrics = .init(
        loadDuration: nil, firstInferenceDuration: nil, hotInferenceDuration: nil
    )

    var loadDuration: TimeInterval? {
        get { lock.lock(); defer { lock.unlock() }; return storage.loadDuration }
        set { lock.lock(); defer { lock.unlock() }; storage.loadDuration = newValue }
    }

    var firstInferenceDuration: TimeInterval? {
        get { lock.lock(); defer { lock.unlock() }; return storage.firstInferenceDuration }
        set { lock.lock(); defer { lock.unlock() }; storage.firstInferenceDuration = newValue }
    }

    var hotInferenceDuration: TimeInterval? {
        get { lock.lock(); defer { lock.unlock() }; return storage.hotInferenceDuration }
        set { lock.lock(); defer { lock.unlock() }; storage.hotInferenceDuration = newValue }
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        storage = .init(loadDuration: nil, firstInferenceDuration: nil, hotInferenceDuration: nil)
    }

    func snapshot() -> GigaAMSherpaEngine.PerformanceMetrics {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

// MARK: - Recognizer core (actor-isolated C state)

/// Owns the C recognizer pointer. Being an actor, every call — including
/// inference — is serialized; concurrent transcribe() calls queue instead
/// of racing the ONNX runtime.
actor RecognizerCore {
    private static let logger = Logger(subsystem: "com.livetranslate.ios", category: "sherpa-engine")

    private let config: SherpaModelConfiguration.InferenceConfig
    private var recognizer: OpaquePointer?

    init(config: SherpaModelConfiguration.InferenceConfig) {
        self.config = config
    }

    func createRecognizer() throws {
        guard recognizer == nil else { return }
        let paths = try SherpaModelConfiguration.paths()
        for url in paths.all where !FileManager.default.fileExists(atPath: url.path) {
            throw ASREngineError.integrityFailure(
                path: url.lastPathComponent,
                reason: "file missing"
            )
        }

        // C strings must outlive the create call; keep the NSStrings alive
        // in this scope.
        let encoderPath = paths.encoder.path as NSString
        let decoderPath = paths.decoder.path as NSString
        let joinerPath = paths.joiner.path as NSString
        let tokensPath = paths.tokens.path as NSString
        let provider = config.provider as NSString
        let modelType = config.modelType as NSString
        let decodingMethod = config.decodingMethod as NSString

        var cConfig = SherpaOnnxOfflineRecognizerConfig()
        memset(&cConfig, 0, MemoryLayout<SherpaOnnxOfflineRecognizerConfig>.size)

        cConfig.feat_config.sample_rate = Int32(self.config.sampleRate)
        cConfig.feat_config.feature_dim = Int32(self.config.featureDim)

        cConfig.model_config.transducer.encoder = encoderPath.utf8String
        cConfig.model_config.transducer.decoder = decoderPath.utf8String
        cConfig.model_config.transducer.joiner = joinerPath.utf8String
        cConfig.model_config.tokens = tokensPath.utf8String
        cConfig.model_config.num_threads = Int32(self.config.threadCount)
        cConfig.model_config.provider = provider.utf8String
        cConfig.model_config.model_type = modelType.utf8String
        cConfig.model_config.debug = 0

        cConfig.decoding_method = decodingMethod.utf8String

        guard let created = SherpaOnnxCreateOfflineRecognizer(&cConfig) else {
            throw ASREngineError.loadFailed(
                .sherpaONNXInt8,
                underlying: "SherpaOnnxCreateOfflineRecognizer returned null (config: \(self.config))"
            )
        }
        recognizer = created
        Self.logger.info(
            "sherpa-onnx recognizer created: threads=\(self.config.threadCount), model=\(self.config.modelType)"
        )
    }

    func destroyRecognizer() {
        if let recognizer {
            SherpaOnnxDestroyOfflineRecognizer(recognizer)
        }
        recognizer = nil
    }

    func transcribe(samples: [Float]) throws -> String {
        guard let recognizer else {
            throw ASREngineError.engineNotLoaded
        }

        let stream = SherpaOnnxCreateOfflineStream(recognizer)
        guard let stream else {
            throw ASREngineError.predictionFailed("could not create offline stream")
        }
        defer { SherpaOnnxDestroyOfflineStream(stream) }

        // Sanitize: NaN/Inf poison the feature extractor.
        let clean = AudioResampler.sanitize(samples)
        clean.withUnsafeBufferPointer { buffer in
            SherpaOnnxAcceptWaveformOffline(
                stream, Int32(config.sampleRate), buffer.baseAddress, Int32(clean.count)
            )
        }
        SherpaOnnxDecodeOfflineStream(recognizer, stream)

        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else {
            throw ASREngineError.predictionFailed("no result returned")
        }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }

        let text = result.pointee.text.map { String(cString: $0) } ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
