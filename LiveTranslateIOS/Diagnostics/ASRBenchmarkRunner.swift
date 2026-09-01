import Foundation
import AVFoundation
import OSLog

/// One piece of audio to run through both backends, plus an optional
/// human reference transcript.
struct BenchmarkAudioItem: Sendable, Identifiable, Equatable {
    let id: UUID
    var name: String
    /// Mono Float32 samples (any sample rate; resampled on decode).
    var samples: [Float]
    var sampleRate: Int
    var referenceText: String?

    init(name: String, samples: [Float], sampleRate: Int, referenceText: String? = nil) {
        self.id = UUID()
        self.name = name
        self.samples = samples
        self.sampleRate = sampleRate
        self.referenceText = referenceText
    }
}

/// Runs the strict two-backend comparison: load Core ML → transcribe all
/// items → unload → confirm memory release → load sherpa-onnx → transcribe
/// the same items → unload → build the report.
///
/// The two backends are **never** resident at the same time — the sequence
/// is the whole point of the benchmark. Engine control is injected as
/// closures so this file has no dependency on `ASREngineManager` internals.
@MainActor
@Observable
final class ASRBenchmarkRunner {
    static let logger = Logger(subsystem: "com.livetranslate.ios", category: "benchmark")

    enum Phase: Equatable, Sendable {
        case idle
        case loadingCoreML
        case runningCoreML(itemIndex: Int, itemCount: Int)
        case unloadingCoreML
        case loadingSherpa
        case runningSherpa(itemIndex: Int, itemCount: Int)
        case unloadingSherpa
        case done
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var report: BackendComparisonReport?

    /// True while a comparison is in flight (any phase except idle).
    var isRunning: Bool {
        if case .idle = phase { return false }
        return true
    }

    /// Engine control injected by the app (backed by ASREngineManager).
    /// Loading must raise an error on failure — never silently substitute
    /// the other backend.
    private let loadBackend: @MainActor (ASRBackendKind) async throws -> Void
    private let unloadBackend: @MainActor () async -> Void
    private let transcribe: @MainActor (SpeechSegment) async throws -> ASRResult
    private let modelVersionProvider: @MainActor () -> String

    init(
        loadBackend: @escaping @MainActor (ASRBackendKind) async throws -> Void,
        unloadBackend: @escaping @MainActor () async -> Void,
        transcribe: @escaping @MainActor (SpeechSegment) async throws -> ASRResult,
        modelVersionProvider: @escaping @MainActor () -> String = { "" }
    ) {
        self.loadBackend = loadBackend
        self.unloadBackend = unloadBackend
        self.transcribe = transcribe
        self.modelVersionProvider = modelVersionProvider
    }

    /// Convenience wiring over the shared `ASREngineManager`. Loading goes
    /// through `ensureLoaded` so the single-resident-backend rule applies to
    /// benchmarks exactly as it does to live sessions.
    convenience init(engineManager: ASREngineManager) {
        self.init(
            loadBackend: { try await engineManager.ensureLoaded($0) },
            unloadBackend: { await engineManager.unloadCurrent() },
            transcribe: { try await engineManager.transcribe($0) }
        )
    }

    /// Execute the full comparison. Audio longer than 30 s is split into
    /// ≤30 s windows and the transcripts are joined — matching the pipeline's
    /// VAD segmentation behavior (both engines take ≤30 s windows).
    func run(
        items: [BenchmarkAudioItem],
        coreMLComputeDescription: String,
        onnxThreadCount: Int
    ) async throws -> BackendComparisonReport {
        precondition(!items.isEmpty, "benchmark needs at least one audio item")
        defer { phase = .idle }

        // ---- Core ML pass ----
        phase = .loadingCoreML
        var coreMLMetrics = BackendRunMetrics()
        let coreMLLoadStart = Date()
        try await loadBackend(.coreMLFP16)
        coreMLMetrics.loadDuration = Date().timeIntervalSince(coreMLLoadStart)
        var coreMLTexts: [String] = []
        do {
            for (index, item) in items.enumerated() {
                phase = .runningCoreML(itemIndex: index, itemCount: items.count)
                let windows = try await transcribeItem(item)
                coreMLTexts.append(windows.map(\.text).joined(separator: " "))
                coreMLMetrics = absorb(coreMLMetrics, windows: windows)
            }
        } catch {
            await unloadBackend()
            phase = .failed("Core ML pass failed: \(error.localizedDescription)")
            throw error
        }
        coreMLMetrics.thermalState = PerformanceMetrics.thermalStateDescription()
        phase = .unloadingCoreML
        await unloadBackend()
        let postCoreMLUnload = await settleMemory()

        // ---- sherpa-onnx pass (only after Core ML is fully unloaded) ----
        phase = .loadingSherpa
        var sherpaMetrics = BackendRunMetrics()
        let sherpaLoadStart = Date()
        try await loadBackend(.sherpaONNXInt8)
        sherpaMetrics.loadDuration = Date().timeIntervalSince(sherpaLoadStart)
        var sherpaTexts: [String] = []
        do {
            for (index, item) in items.enumerated() {
                phase = .runningSherpa(itemIndex: index, itemCount: items.count)
                let windows = try await transcribeItem(item)
                sherpaTexts.append(windows.map(\.text).joined(separator: " "))
                sherpaMetrics = absorb(sherpaMetrics, windows: windows)
            }
        } catch {
            await unloadBackend()
            phase = .failed("sherpa-onnx pass failed: \(error.localizedDescription)")
            throw error
        }
        sherpaMetrics.thermalState = PerformanceMetrics.thermalStateDescription()
        phase = .unloadingSherpa
        await unloadBackend()
        let postSherpaUnload = await settleMemory()

        // ---- Report ----
        var reportItems: [BackendComparisonReport.ItemResult] = []
        for (index, item) in items.enumerated() {
            let coreText = coreMLTexts[index]
            let sherpaText = sherpaTexts[index]
            let totalAudio = Double(item.samples.count) / Double(max(item.sampleRate, 1))
            reportItems.append(
                .init(
                    name: item.name,
                    audioDuration: totalAudio,
                    coreMLText: coreText,
                    sherpaText: sherpaText,
                    textsIdentical: coreText == sherpaText,
                    characterDiff: TextMetrics.characterDiffSummary(coreText, sherpaText),
                    sherpaCERvsCoreML: TextMetrics.cer(hypothesis: sherpaText, reference: coreText),
                    coreMLCERvsSherpa: TextMetrics.cer(hypothesis: coreText, reference: sherpaText),
                    punctuationStrippedCER: TextMetrics.cer(
                        hypothesis: sherpaText, reference: coreText, stripPunctuation: true
                    ),
                    referenceText: item.referenceText,
                    coreMLCERvsReference: item.referenceText.map {
                        TextMetrics.cer(hypothesis: coreText, reference: $0)
                    },
                    coreMLWERvsReference: item.referenceText.map {
                        TextMetrics.wer(hypothesis: coreText, reference: $0)
                    },
                    sherpaCERvsReference: item.referenceText.map {
                        TextMetrics.cer(hypothesis: sherpaText, reference: $0)
                    },
                    sherpaWERvsReference: item.referenceText.map {
                        TextMetrics.wer(hypothesis: sherpaText, reference: $0)
                    }
                )
            )
        }

        let report = BackendComparisonReport(
            items: reportItems,
            coreML: .init(
                loadDuration: coreMLMetrics.loadDuration,
                firstInference: coreMLMetrics.firstInference,
                medianWarmInference: coreMLMetrics.medianWarmInference,
                totalAudioDuration: coreMLMetrics.audioDurations.reduce(0, +),
                realTimeFactor: coreMLMetrics.realTimeFactor,
                peakMemoryBytes: coreMLMetrics.peakMemoryBytes
            ),
            sherpa: .init(
                loadDuration: sherpaMetrics.loadDuration,
                firstInference: sherpaMetrics.firstInference,
                medianWarmInference: sherpaMetrics.medianWarmInference,
                totalAudioDuration: sherpaMetrics.audioDurations.reduce(0, +),
                realTimeFactor: sherpaMetrics.realTimeFactor,
                peakMemoryBytes: sherpaMetrics.peakMemoryBytes
            ),
            postCoreMLUnloadMemoryBytes: postCoreMLUnload,
            postSherpaUnloadMemoryBytes: postSherpaUnload,
            thermalState: PerformanceMetrics.thermalStateDescription(),
            coreMLComputeUnit: coreMLComputeDescription,
            onnxThreadCount: onnxThreadCount,
            modelVersion: modelVersionProvider(),
            deviceModel: PerformanceMetrics.deviceModelIdentifier(),
            osVersion: PerformanceMetrics.osVersionString(),
            testedAt: .now,
            hasReferenceText: items.contains { $0.referenceText != nil }
        )
        self.report = report
        phase = .done
        Self.logger.info("Benchmark finished: identical=\(report.allTextsIdentical, privacy: .public)")
        return report
    }

    // MARK: - Internals

    struct WindowTranscription {
        var text: String
        var audioDuration: TimeInterval
        var inferenceDuration: TimeInterval
    }

    /// Split into ≤30 s windows (the engines' max window), transcribe each.
    private func transcribeItem(_ item: BenchmarkAudioItem) async throws -> [WindowTranscription] {
        let samples = resampleTo16k(item.samples, from: item.sampleRate)
        let maxWindow = 30 * 16000
        var windows: [(start: Int, samples: [Float])] = []
        var start = 0
        while start < samples.count {
            let end = min(start + maxWindow, samples.count)
            windows.append((start, Array(samples[start..<end])))
            start = end
        }
        if windows.isEmpty { windows.append((0, [Float](repeating: 0, count: 1600))) }

        var results: [WindowTranscription] = []
        for (index, window) in windows.enumerated() {
            let segment = SpeechSegment(
                sequenceID: index,
                samples: window.samples,
                sampleRate: 16000,
                startOffset: TimeInterval(window.start) / 16000,
                endOffset: TimeInterval(window.start + window.samples.count) / 16000
            )
            let result = try await transcribe(segment)
            results.append(
                WindowTranscription(
                    text: result.text,
                    audioDuration: segment.duration,
                    inferenceDuration: result.inferenceDuration
                )
            )
        }
        return results
    }

    /// Fold one item's window timings into the running metrics, tracking
    /// first-vs-warm inference and the memory peak.
    private func absorb(
        _ metrics: BackendRunMetrics,
        windows: [WindowTranscription]
    ) -> BackendRunMetrics {
        var metrics = metrics
        for window in windows {
            metrics.audioDurations.append(window.audioDuration)
            metrics.inferenceDurations.append(window.inferenceDuration)
            if metrics.firstInference == 0 {
                metrics.firstInference = window.inferenceDuration
            } else {
                metrics.warmInferences.append(window.inferenceDuration)
            }
        }
        metrics.peakMemoryBytes = max(metrics.peakMemoryBytes, PerformanceMetrics.physFootprint())
        return metrics
    }

    /// Give the allocator a moment to release freed pages, then sample.
    private func settleMemory() async -> Int64 {
        try? await Task.sleep(nanoseconds: 500_000_000)
        return PerformanceMetrics.physFootprint()
    }

    private func resampleTo16k(_ samples: [Float], from rate: Int) -> [Float] {
        guard rate != 16000, rate > 0, !samples.isEmpty else { return samples }
        let ratio = 16000.0 / Double(rate)
        let targetCount = max(1, Int(Double(samples.count) * ratio))
        var output = [Float](repeating: 0, count: targetCount)
        for i in 0..<targetCount {
            let position = Double(i) / ratio
            let index = min(Int(position), samples.count - 1)
            let fraction = Float(position - Double(index))
            let next = min(index + 1, samples.count - 1)
            output[i] = samples[index] * (1 - fraction) + samples[next] * fraction
        }
        return output
    }

    // MARK: - Audio import

    /// Load a WAV/M4A/CAF file as mono Float32, resampling to 16 kHz.
    /// Uses AVAudioFile + AVAudioConverter; throws on undecodable files.
    nonisolated static func loadAudioFile(at url: URL) throws -> BenchmarkAudioItem {
        let file = try AVAudioFile(forReading: url)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: file.processingFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "BenchmarkAudio", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create read format"])
        }
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "BenchmarkAudio", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot allocate audio buffer"])
        }
        try file.read(into: buffer)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false
        ) else {
            throw NSError(domain: "BenchmarkAudio", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create target format"])
        }
        let converted: AVAudioPCMBuffer
        if file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1 {
            converted = buffer
        } else {
            let ratio = 16000 / file.processingFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1600
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
                throw NSError(domain: "BenchmarkAudio", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "Cannot allocate converted buffer"])
            }
            let converter = AVAudioConverter(from: file.processingFormat, to: targetFormat)
            guard let converter = AVAudioConverter(from: file.processingFormat, to: targetFormat) else {
                throw NSError(domain: "BenchmarkAudio", code: 5,
                              userInfo: [NSLocalizedDescriptionKey: "Cannot create audio converter"])
            }
            var error: NSError?
            var inputExhausted = false
            converter.convert(to: outBuffer, error: &error) { _, inputStatus in
                if inputExhausted {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputExhausted = true
                inputStatus.pointee = .haveData
                return buffer
            }
            if let error { throw error }
            converted = outBuffer
        }

        let channelData = converted.floatChannelData![0]
        let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(converted.frameLength)))
        return BenchmarkAudioItem(
            name: url.lastPathComponent,
            samples: samples,
            sampleRate: 16000
        )
    }
}
