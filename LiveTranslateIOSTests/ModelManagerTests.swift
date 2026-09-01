import XCTest
import CryptoKit
@testable import LiveTranslateIOS

/// ModelManager / integrity-verification behavior that runs without
/// downloading anything: hashing fixtures, path checks, state recording,
/// and manifest-driven queries.
final class ModelManagerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-manager-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Integrity verifier

    func testSHA256MatchesKnownDigest() async throws {
        let url = tempDir.appendingPathComponent("known.bin")
        let payload = Data("LiveTranslate".utf8)
        try payload.write(to: url)

        let expected = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let computed = try await ModelIntegrityVerifier.sha256(of: url)
        XCTAssertEqual(computed, expected)
    }

    func testSHA256OfLargeFileStreamsWithoutLoadingItAll() async throws {
        // 3 MB of pseudo-random-ish data — enough to exercise multiple
        // 8 KiB blocks without being slow.
        let url = tempDir.appendingPathComponent("large.bin")
        var generator = SystemRandomNumberGenerator()
        var data = Data(capacity: 3 * 1024 * 1024)
        for _ in 0..<(3 * 1024 * 1024 / MemoryLayout<UInt32>.size) {
            var value = UInt32.random(in: .min ... .max, using: &generator)
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        try data.write(to: url)

        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let computed = try await ModelIntegrityVerifier.sha256(of: url)
        XCTAssertEqual(computed, expected)
    }

    private func makeFileInfo(path: String, data: Data) -> ModelManifest.BackendInfo.FileInfo {
        ModelManifest.BackendInfo.FileInfo(
            path: path,
            url: "https://example.invalid/\(path)",
            bytes: data.count,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        )
    }

    func testVerifyPassesForIntactFile() async throws {
        let data = Data("encoder weights".utf8)
        let url = tempDir.appendingPathComponent("encoder.bin")
        try data.write(to: url)
        let file = makeFileInfo(path: "encoder.bin", data: data)

        let failure = await ModelIntegrityVerifier.verify(file: file, at: url)
        XCTAssertNil(failure)
    }

    func testVerifyDetectsCorruptedFile() async throws {
        let data = Data("encoder weights".utf8)
        let url = tempDir.appendingPathComponent("encoder.bin")
        try Data("corrupted weights".utf8).write(to: url)
        let file = makeFileInfo(path: "encoder.bin", data: data)

        let failure = await ModelIntegrityVerifier.verify(file: file, at: url)
        guard case .hashMismatch? = failure else {
            return XCTFail("expected hashMismatch, got \(String(describing: failure))")
        }
    }

    func testVerifyDetectsWrongSize() async throws {
        let data = Data([0x01, 0x02, 0x03])
        let url = tempDir.appendingPathComponent("weights.bin")
        try Data([0x01, 0x02]).write(to: url)
        let file = makeFileInfo(path: "weights.bin", data: data)

        let failure = await ModelIntegrityVerifier.verify(file: file, at: url)
        guard case .sizeMismatch? = failure else {
            return XCTFail("expected sizeMismatch, got \(String(describing: failure))")
        }
    }

    func testVerifyDetectsMissingFile() async throws {
        let data = Data("x".utf8)
        let file = makeFileInfo(path: "missing.bin", data: data)
        let failure = await ModelIntegrityVerifier.verify(
            file: file, at: tempDir.appendingPathComponent("missing.bin")
        )
        guard case .fileMissing? = failure else {
            return XCTFail("expected fileMissing, got \(String(describing: failure))")
        }
    }

    func testVerifyBackendStopsAtFirstFailure() async throws {
        let good = Data("good".utf8)
        let bad = Data("bad".utf8)
        try good.write(to: tempDir.appendingPathComponent("a.bin"))
        try Data("tampered".utf8).write(to: tempDir.appendingPathComponent("b.bin"))
        let backend = ModelManifest.BackendInfo(
            id: "test", kind: .sherpaONNXInt8, repo: "r", revision: "0123456789abcdef0123456789abcdef01234567",
            files: [
                makeFileInfo(path: "a.bin", data: good),
                makeFileInfo(path: "b.bin", data: bad),
            ],
            totalDownloadBytes: good.count + bad.count,
            installedBytes: good.count + bad.count,
            stagingBytes: 0, minimumFreeDiskBytes: 0, license: "MIT",
            coreMLCompiledCacheVersion: nil
        )
        let failure = await ModelIntegrityVerifier.verifyBackend(backend, root: tempDir)
        XCTAssertNotNil(failure)
    }

    // MARK: - ModelManager state

    @MainActor
    func testRecordLoadAndRTFPersistAcrossInstances() throws {
        let suite = "model-manager-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = ModelManager(defaults: defaults)
        first.recordLoad(.sherpaONNXInt8)
        first.recordRTF(.sherpaONNXInt8, rtf: 0.17)

        // A fresh instance restores the recorded metrics from defaults.
        let second = ModelManager(defaults: defaults)
        let state = second.state(.sherpaONNXInt8)
        XCTAssertNotNil(state.lastLoadedAt)
        XCTAssertEqual(state.lastRTF ?? -1, 0.17, accuracy: 1e-9)
    }

    @MainActor
    func testStatesStartNotInstalled() {
        let suite = "model-manager-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let manager = ModelManager(defaults: defaults)
        // On a clean test environment no model is installed in Application
        // Support; if a previous test run left files behind the assert
        // still holds because refreshState has not run yet.
        XCTAssertFalse(manager.state(.coreMLFP16).isInstalled)
        XCTAssertFalse(manager.state(.sherpaONNXInt8).isInstalled)
    }

    @MainActor
    func testDeleteRefusedWhileBackendInUse() throws {
        let suite = "model-manager-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let manager = ModelManager(defaults: defaults)
        manager.isBackendInUse = { kind in kind == .sherpaONNXInt8 }

        XCTAssertThrowsError(try manager.delete(.sherpaONNXInt8)) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "ModelManager")
        }
        // The other backend is not blocked by the first one's session.
        XCTAssertNoThrow(try manager.delete(.coreMLFP16))
    }

    @MainActor
    func testInstallerProgressFraction() {
        let progress = ModelInstaller.Progress(completedBytes: 250, totalBytes: 1000)
        XCTAssertEqual(progress.fraction, 0.25, accuracy: 1e-9)
        let empty = ModelInstaller.Progress()
        XCTAssertEqual(empty.fraction, 0)
    }

    func testDiskSpaceErrorIsHumanReadable() {
        let error = ModelInstaller.InstallerError.diskSpaceLow(neededBytes: 1_300_000_000, availableBytes: 500_000_000)
        let text = error.localizedDescription
        XCTAssertTrue(text.contains("1.3"), "expected GB-scale numbers in: \(text)")
        XCTAssertTrue(text.contains("0.5"))
    }
}
