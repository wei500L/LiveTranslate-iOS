import Foundation
import CoreML
import OSLog

/// Core ML FP16 backend for GigaAM-v3 `e2e_rnnt` — precision-first, Apple
/// native, no sherpa-onnx/PyTorch dependency on the ASR path.
///
/// The engine owns everything through `CoreMLEngineActor`, so inference is
/// serialized by construction and the non-Sendable Core ML objects never
/// escape. One engine = one resident backend; switching is coordinated by
/// `ASREngineManager`.
struct GigaAMCoreMLEngine: ASREngine {
    let backendKind: ASRBackendKind = .coreMLFP16

    private let computePreference: CoreMLComputePreference
    private let state = CoreMLEngineActor()

    init(computePreference: CoreMLComputePreference = .accuracy) {
        self.computePreference = computePreference
    }

    func prepare() async throws {
        try await state.prepare(computePreference: computePreference)
    }

    func warmup() async throws {
        try await state.warmup()
    }

    func transcribe(
        samples: [Float],
        sampleRate: Int,
        segmentStart: TimeInterval,
        segmentEnd: TimeInterval
    ) async throws -> ASRResult {
        try await state.transcribe(
            samples: samples, sampleRate: sampleRate,
            segmentStart: segmentStart, segmentEnd: segmentEnd
        )
    }

    func unload() async {
        await state.unload()
    }

    /// Load/warmup/inference timings for the benchmark runner and the model
    /// management page.
    func currentMetrics() async -> CoreMLEngineMetrics {
        await state.metricsSnapshot()
    }
}

/// Snapshot of engine performance counters (Sendable).
struct CoreMLEngineMetrics: Sendable, Codable {
    var loadDuration: TimeInterval?
    var warmupDuration: TimeInterval?
    var lastInferenceDuration: TimeInterval?
    var lastRTF: Double?
    var lastAudioDuration: TimeInterval?
    var computeUnitsDescription: String?
    var compiledDuringLoad: Bool = false
    var inferenceCount: Int = 0
}

/// Isolated owner of the Core ML model instances and work buffers.
actor CoreMLEngineActor {
    private static let logger = Logger(
        subsystem: "com.livetranslate.ios", category: "coreml-engine"
    )

    private struct Loaded {
        let encoder: MLModel
        let rnnt: GigaAMRNNTDecoder
        let tokens: GigaAMTokenDecoder
        let extractor: GigaAMLogMelExtractor
        let encoderInputs: MLDictionaryFeatureProvider
        let lengthInput: MLMultiArray
        let computeUnits: MLComputeUnits
        let compiledDuringLoad: Bool
        let loadDuration: TimeInterval
    }

    private var loaded: Loaded?
    private var warmupDuration: TimeInterval?
    private var metrics = CoreMLEngineMetrics()

    // MARK: - Lifecycle

    func prepare(computePreference: CoreMLComputePreference) throws {
        guard loaded == nil else { return }
        let signpostID = OSSignposter().makeSignpostID()
        let signposter = OSSignposter(subsystem: "com.livetranslate.ios", category: "coreml-engine")
        let state = signposter.beginInterval("prepare", id: signpostID)
        defer { signposter.endInterval("prepare", state) }

        let started = Date()
        let models = try CoreMLModelLoader.loadModels(computePreference: computePreference)
        let loadDuration = Date().timeIntervalSince(started)

        let extractor: GigaAMLogMelExtractor
        let tokens: GigaAMTokenDecoder
        do {
            extractor = try GigaAMLogMelExtractor()
            let metadataRoot = try ModelPaths.coreMLMetadataRoot()
            tokens = try GigaAMTokenDecoder(metadataURL: metadataRoot.appendingPathComponent("tokens.json"))
        } catch {
            throw ASREngineError.loadFailed(.coreMLFP16, underlying: String(describing: error))
        }

        let lengthInput = try MLMultiArray(shape: [1], dataType: .int32)
        let encoderInputs: MLDictionaryFeatureProvider
        do {
            encoderInputs = try MLDictionaryFeatureProvider(dictionary: [
                "features": extractor.outputFeatures,
                "length": lengthInput,
            ])
        } catch {
            throw ASREngineError.loadFailed(.coreMLFP16, underlying: "encoder input provider: \(error)")
        }

        let rnnt: GigaAMRNNTDecoder
        do {
            rnnt = try GigaAMRNNTDecoder(decoderModel: models.decoder, jointModel: models.joint)
        } catch {
            throw ASREngineError.loadFailed(.coreMLFP16, underlying: "RNN-T decoder init: \(error)")
        }

        // Validate the encoder contract up front so a bad conversion fails
        // at load, not mid-classroom.
        for name in ["features", "length"] {
            guard models.encoder.modelDescription.inputDescriptionsByName[name] != nil else {
                throw ASREngineError.loadFailed(
                    .coreMLFP16, underlying: "encoder missing input '\(name)'"
                )
            }
        }
        for name in ["encoded", "encoded_len"] {
            guard models.encoder.modelDescription.outputDescriptionsByName[name] != nil else {
                throw ASREngineError.loadFailed(
                    .coreMLFP16, underlying: "encoder missing output '\(name)'"
                )
            }
        }

        loaded = Loaded(
            encoder: models.encoder,
            rnnt: rnnt,
            tokens: tokens,
            extractor: extractor,
            encoderInputs: encoderInputs,
            lengthInput: lengthInput,
            computeUnits: models.computeUnits,
            compiledDuringLoad: models.compiledDuringLoad,
            loadDuration: loadDuration
        )
        metrics.loadDuration = loadDuration
        metrics.compiledDuringLoad = models.compiledDuringLoad
        metrics.computeUnitsDescription = Self.describe(models.computeUnits)
        Self.logger.info(
            "Core ML backend ready (compute=\(Self.describe(models.computeUnits), privacy: .public), load=\(loadDuration, privacy: .public)s)"
        )
    }

    func warmup() throws {
        guard let current = loaded else {
            throw ASREngineError.engineNotLoaded
        }
        let started = Date()
        // 0.5 s of silence — pays one-time GPU/Metal pipeline compilation.
        let silence = [Float](repeating: 0, count: GigaAMLogMelExtractor.sampleRate / 2)
        _ = try runInference(samples: silence, using: current)
        warmupDuration = Date().timeIntervalSince(started)
        metrics.warmupDuration = warmupDuration
        Self.logger.info("Core ML warmup took \(self.warmupDuration ?? 0, privacy: .public)s")
    }

    func unload() {
        guard loaded != nil else { return }
        loaded = nil
        warmupDuration = nil
        Self.logger.info("Core ML backend unloaded")
    }

    // MARK: - Inference

    func transcribe(
        samples: [Float],
        sampleRate: Int,
        segmentStart: TimeInterval,
        segmentEnd: TimeInterval
    ) throws -> ASRResult {
        guard let current = loaded else {
            throw ASREngineError.engineNotLoaded
        }
        guard sampleRate == GigaAMLogMelExtractor.sampleRate else {
            throw ASREngineError.incompatibleInput(
                "Core ML backend requires 16 kHz input, got \(sampleRate) Hz"
            )
        }
        guard samples.count <= GigaAMLogMelExtractor.maxSamples else {
            throw ASREngineError.incompatibleInput(
                "segment of \(samples.count) samples exceeds the 30 s window; the VAD layer must split it"
            )
        }

        let started = Date()
        let text = try runInference(samples: samples, using: current)
        let inferenceDuration = Date().timeIntervalSince(started)
        let audioDuration = Double(samples.count) / Double(GigaAMLogMelExtractor.sampleRate)
        let rtf = audioDuration > 0 ? inferenceDuration / audioDuration : 0

        metrics.inferenceCount += 1
        metrics.lastInferenceDuration = inferenceDuration
        metrics.lastRTF = rtf
        metrics.lastAudioDuration = audioDuration

        Self.logger.debug(
            "transcribe: \(samples.count) samples, \(inferenceDuration * 1000, format: .fixed(precision: 1), privacy: .public) ms, RTF \(rtf, format: .fixed(precision: 3), privacy: .public)"
        )

        return ASRResult(
            text: text,
            language: "ru",
            backend: .coreMLFP16,
            audioDuration: audioDuration,
            inferenceDuration: inferenceDuration,
            realTimeFactor: rtf,
            segmentStart: segmentStart,
            segmentEnd: segmentEnd
        )
    }

    func metricsSnapshot() -> CoreMLEngineMetrics {
        metrics
    }

    // MARK: - Internals

    /// Full pipeline: log-mel → encoder → RNN-T greedy → tokens.
    private func runInference(samples: [Float], using current: Loaded) throws -> String {
        let features = try current.extractor.extract(samples: samples)

        // length = real frame count; the padded tail is log(1e-9) filler.
        let lengthPtr = current.lengthInput.dataPointer.bindMemory(
            to: Int32.self, capacity: 1
        )
        lengthPtr[0] = Int32(features.frameCount)

        let output: MLFeatureProvider
        do {
            output = try current.encoder.prediction(from: current.encoderInputs)
        } catch {
            throw ASREngineError.predictionFailed("encoder: \(error)")
        }
        guard let encoded = output.featureValue(for: "encoded")?.multiArrayValue,
              let encodedLenValue = output.featureValue(for: "encoded_len")?.multiArrayValue
        else {
            throw ASREngineError.predictionFailed("encoder outputs missing encoded/encoded_len")
        }

        let encodedLength = Self.safelyToInt(encodedLenValue, name: "encoded_len")
        let ids = try current.rnnt.decode(encoded: encoded, encodedLength: encodedLength)
        return current.tokens.decode(ids: ids)
    }

    /// `encoded_len` is emitted as a float array but semantically an integer
    /// count. Convert defensively and range-check.
    private static func safelyToInt(_ array: MLMultiArray, name: String) -> Int {
        let reader = ArrayReader(array)
        guard array.count > 0 else { return 0 }
        let raw = reader.value(atLinearIndex: 0)
        let value = Int(raw.rounded())
        let upperBound = 750  // encoder contract: subsampled 2999 frames
        guard value >= 0, value <= upperBound else {
            logger.warning("\(name, privacy: .public) out of range: \(raw, privacy: .public) — clamping")
            return min(max(value, 0), upperBound)
        }
        return value
    }

    private static func describe(_ units: MLComputeUnits) -> String {
        switch units {
        case .cpuOnly: return "cpuOnly"
        case .cpuAndGPU: return "cpuAndGPU"
        case .cpuAndNeuralEngine: return "cpuAndNeuralEngine"
        case .all: return "all"
        @unknown default: return "unknown"
        }
    }
}
