import XCTest
@testable import LiveTranslateIOS

/// Real-model Core ML engine integration: compile → load → warmup →
/// recognize actual Russian speech → unload.
///
/// Runs only in the integration test plan. Performance figures are **logged,
/// never asserted** here — the spec's RTF < 0.5 acceptance targets iPhone
/// hardware, and simulator numbers are meaningless for acceptance. What these
/// tests do assert: the engine loads, produces real (non-empty, correct)
/// Russian text, reports honest timings, and unloads cleanly.
final class CoreMLEngineIntegrationTests: XCTestCase {
    func testLoadWarmupRecognizeUnload() async throws {
        try await IntegrationModels.requireInstalled(.coreMLFP16)
        let fixture = try IntegrationFixtures.load(named: "test_ru_short")

        let engine = GigaAMCoreMLEngine(computePreference: .accuracy)
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

        XCTAssertFalse(result.text.isEmpty, "Core ML produced empty text for real Russian speech")
        XCTAssertEqual(result.backend, .coreMLFP16)
        XCTAssertGreaterThan(result.inferenceDuration, 0)
        XCTAssertGreaterThan(result.audioDuration, 2.8)

        // Recognition must be recognizably correct — CER against the
        // PyTorch reference leaves headroom for FP16 numeric drift while
        // still failing loudly on a broken decode loop.
        let cer = TextMetrics.cer(hypothesis: result.text, reference: fixture.referenceText)
        XCTAssertLessThanOrEqual(cer, 0.3,
            "CER \(cer) vs reference \"\(fixture.referenceText)\" — got \"\(result.text)\"")

        // Honest numbers, logged for the report. RTF is informational here.
        let rtf = result.realTimeFactor
        print("""
            [CoreML] load=\(String(format: "%.2f", loadDuration))s \
            audio=\(String(format: "%.2f", fixture.duration))s \
            inference=\(String(format: "%.2f", result.inferenceDuration))s \
            RTF=\(String(format: "%.3f", rtf)) (simulator — not an acceptance number)
            [CoreML] text=\"\(result.text)\"
            """)

        await engine.unload()
    }

    func testUnloadThenReload() async throws {
        try await IntegrationModels.requireInstalled(.coreMLFP16)
        let fixture = try IntegrationFixtures.load(named: "test_ru_short")

        let engine = GigaAMCoreMLEngine(computePreference: .accuracy)
        try await engine.prepare()
        try await engine.warmup()
        _ = try await engine.transcribe(samples: fixture.samples, sampleRate: 16_000,
                                        segmentStart: 0, segmentEnd: fixture.duration)
        await engine.unload()

        // A second load cycle must work identically (no stale state).
        try await engine.prepare()
        try await engine.warmup()
        let again = try await engine.transcribe(samples: fixture.samples, sampleRate: 16_000,
                                                segmentStart: 0, segmentEnd: fixture.duration)
        XCTAssertFalse(again.text.isEmpty)
        await engine.unload()
    }

    /// 35 s audio is longer than the 30 s window; the engine must still
    /// return a result (pipeline-level windowing is the coordinator's job,
    /// but the engine must not crash or truncate catastrophically).
    func testLongerThanWindowAudio() async throws {
        try await IntegrationModels.requireInstalled(.coreMLFP16)
        let fixture = try IntegrationFixtures.load(named: "test_ru_35s")

        let engine = GigaAMCoreMLEngine(computePreference: .accuracy)
        try await engine.prepare()
        try await engine.warmup()
        let result = try await engine.transcribe(
            samples: fixture.samples, sampleRate: 16_000,
            segmentStart: 0, segmentEnd: fixture.duration
        )
        print("[CoreML] 35s input → \"\(result.text)\"")
        await engine.unload()
    }
}
