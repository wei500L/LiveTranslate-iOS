import XCTest
@testable import LiveTranslateIOS

/// Real-model sherpa-onnx INT8 engine integration: load → warmup →
/// recognize the same Russian speech through the pinned INT8 export.
final class SherpaEngineIntegrationTests: XCTestCase {
    func testLoadWarmupRecognizeUnload() async throws {
        try await IntegrationModels.requireInstalled(.sherpaONNXInt8)
        let fixture = try IntegrationFixtures.load(named: "test_ru_short")

        let engine = GigaAMSherpaEngine(threadCount: 2)
        let loadStart = Date()
        try await engine.prepare()
        let loadDuration = Date().timeIntervalSince(loadStart)
        try await engine.warmup()

        let result = try await engine.transcribe(
            samples: fixture.samples,
            sampleRate: 16_000,
            segmentStart: 0,
            segmentEnd: fixture.duration
        )

        XCTAssertFalse(result.text.isEmpty, "sherpa-onnx produced empty text for real Russian speech")
        XCTAssertEqual(result.backend, .sherpaONNXInt8)
        XCTAssertGreaterThan(result.inferenceDuration, 0)

        let cer = TextMetrics.cer(hypothesis: result.text, reference: fixture.referenceText)
        XCTAssertLessThanOrEqual(cer, 0.3,
            "CER \(cer) vs reference \"\(fixture.referenceText)\" — got \"\(result.text)\"")

        print("""
            [sherpa] load=\(String(format: "%.2f", loadDuration))s \
            audio=\(String(format: "%.2f", fixture.duration))s \
            inference=\(String(format: "%.2f", result.inferenceDuration))s \
            RTF=\(String(format: "%.3f", result.realTimeFactor)) (simulator — not an acceptance number)
            [sherpa] text=\"\(result.text)\"
            """)

        await engine.unload()
    }

    /// Wrong sample rate must be rejected loudly, never silently resampled
    /// inside the engine (the pipeline owns resampling).
    func testRejectsNon16kInput() async throws {
        try await IntegrationModels.requireInstalled(.sherpaONNXInt8)
        let engine = GigaAMSherpaEngine(threadCount: 2)
        try await engine.prepare()
        try await engine.warmup()
        defer { Task { await engine.unload() } }

        do {
            _ = try await engine.transcribe(
                samples: [Float](repeating: 0, count: 1600),
                sampleRate: 44_100,
                segmentStart: 0, segmentEnd: 0.1
            )
            XCTFail("44.1 kHz input must be rejected")
        } catch {
            // expected
        }
    }

    func testBackendAgreementWithCoreML() async throws {
        // Both backends run the SAME checkpoint; their outputs on clean
        // speech should be close (INT8 quantization allows small drift).
        // This test documents the agreement; the strict comparison lives in
        // the in-app benchmark (ASRBenchmarkRunner), which records exact
        // per-backend texts rather than asserting a threshold.
        try await IntegrationModels.requireInstalled(.sherpaONNXInt8)
        try await IntegrationModels.requireInstalled(.coreMLFP16)
        let fixture = try IntegrationFixtures.load(named: "test_ru_short")

        let sherpa = GigaAMSherpaEngine(threadCount: 2)
        try await sherpa.prepare()
        try await sherpa.warmup()
        let sherpaText = try await sherpa.transcribe(
            samples: fixture.samples, sampleRate: 16_000,
            segmentStart: 0, segmentEnd: fixture.duration
        ).text
        await sherpa.unload()

        let coreML = GigaAMCoreMLEngine(computePreference: .accuracy)
        try await coreML.prepare()
        try await coreML.warmup()
        let coreMLText = try await coreML.transcribe(
            samples: fixture.samples, sampleRate: 16_000,
            segmentStart: 0, segmentEnd: fixture.duration
        ).text
        await coreML.unload()

        let cer = TextMetrics.cer(hypothesis: sherpaText, reference: coreMLText)
        print("[agreement] CoreML=\"\(coreMLText)\"")
        print("[agreement] sherpa=\"\(sherpaText)\"")
        print("[agreement] sherpa-vs-coreML CER=\(cer)")
        XCTAssertLessThanOrEqual(cer, 0.4,
            "the two exports of the same checkpoint diverged more than expected")
    }
}
