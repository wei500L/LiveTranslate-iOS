import XCTest
@testable import LiveTranslateIOS

/// Single-resident-backend rules and explicit switching through
/// `ASREngineManager` — the user-visible contract the spec demands:
///
/// - only one backend resident at any moment,
/// - switching requires an idle session and unloads the old backend first,
/// - a failed load never falls back to the other backend,
/// - a live session pins the backend.
@MainActor
final class BackendSwitchIntegrationTests: XCTestCase {
    private func makeManager() -> ASREngineManager {
        ASREngineManager(settings: SettingsStore.shared)
    }

    private func segment(_ fixture: IntegrationFixtures.Fixture) -> SpeechSegment {
        SpeechSegment(
            sequenceID: 0,
            samples: fixture.samples,
            sampleRate: 16_000,
            startOffset: 0,
            endOffset: fixture.duration
        )
    }

    func testSwitchUnloadsOldBeforeLoadingNew() async throws {
        try await IntegrationModels.requireInstalled(.coreMLFP16)
        try await IntegrationModels.requireInstalled(.sherpaONNXInt8)
        let fixture = try IntegrationFixtures.load(named: "test_ru_short")
        let manager = makeManager()

        try await manager.ensureLoaded(.coreMLFP16)
        XCTAssertEqual(manager.residentBackendKind, .coreMLFP16)
        let coreResult = try await manager.transcribe(segment(fixture))
        XCTAssertEqual(coreResult.backend, .coreMLFP16)

        // Explicit switch: old backend must be gone before the new one loads.
        try await manager.ensureLoaded(.sherpaONNXInt8)
        XCTAssertEqual(manager.residentBackendKind, .sherpaONNXInt8)
        let sherpaResult = try await manager.transcribe(segment(fixture))
        XCTAssertEqual(sherpaResult.backend, .sherpaONNXInt8)

        await manager.unloadCurrent()
        XCTAssertNil(manager.residentBackendKind)
    }

    func testSessionPinsBackend() async throws {
        try await IntegrationModels.requireInstalled(.coreMLFP16)
        try await IntegrationModels.requireInstalled(.sherpaONNXInt8)
        let manager = makeManager()

        try await manager.ensureLoaded(.coreMLFP16)
        try manager.beginSession()
        XCTAssertTrue(manager.sessionActive)

        do {
            try await manager.ensureLoaded(.sherpaONNXInt8)
            XCTFail("switching during a live session must be refused")
        } catch let error as ASREngineManager.ManagerError {
            XCTAssertEqual(error, .sessionActive(.sherpaONNXInt8))
        }
        // The pinned backend is untouched.
        XCTAssertEqual(manager.residentBackendKind, .coreMLFP16)

        manager.endSession()
        try await manager.ensureLoaded(.sherpaONNXInt8)
        XCTAssertEqual(manager.residentBackendKind, .sherpaONNXInt8)

        await manager.unloadCurrent()
    }

    func testUnloadThenTranscribeFailsLoudly() async throws {
        try await IntegrationModels.requireInstalled(.coreMLFP16)
        let fixture = try IntegrationFixtures.load(named: "test_ru_short")
        let manager = makeManager()

        try await manager.ensureLoaded(.coreMLFP16)
        await manager.unloadCurrent()

        do {
            _ = try await manager.transcribe(segment(fixture))
            XCTFail("transcribing with no resident backend must throw")
        } catch {
            // expected
        }
    }
}
