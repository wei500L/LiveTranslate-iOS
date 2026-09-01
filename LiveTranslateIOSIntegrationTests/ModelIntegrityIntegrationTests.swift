import XCTest
@testable import LiveTranslateIOS

/// Model corruption detection: the SHA256/size gate that stands between a
/// damaged file and a silently degraded ASR backend.
final class ModelIntegrityIntegrationTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("integrity-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeFileInfo(for data: Data, path: String = "weights.bin")
        async throws -> (url: URL, info: ModelManifest.BackendInfo.FileInfo)
    {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let url = tempDir.appendingPathComponent(path)
        try data.write(to: url)
        let sha = try await ModelIntegrityVerifier.sha256(of: url)
        let info = ModelManifest.BackendInfo.FileInfo(
            path: path, url: "https://example.invalid/\(path)",
            bytes: data.count, sha256: sha
        )
        return (url, info)
    }

    func testIntactFilePasses() async throws {
        let data = Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let (url, info) = try await makeFileInfo(for: data)
        let intact = await ModelIntegrityVerifier.verify(file: info, at: url)
        XCTAssertNil(intact, "an intact file must verify")    }

    func testSingleFlippedByteIsDetected() async throws {
        let data = Data((0..<100_000).map { _ in UInt8.random(in: 0...255) })
        let (url, info) = try await makeFileInfo(for: data)

        // Corrupt one byte in the middle — the classic silent bit rot.
        var corrupted = data
        corrupted[corrupted.count / 2] ^= 0xFF
        try corrupted.write(to: url)

        let failure = await ModelIntegrityVerifier.verify(file: info, at: url)
        XCTAssertNotNil(failure, "a flipped byte must fail verification")
    }

    func testTruncatedFileIsDetected() async throws {
        let data = Data((0..<100_000).map { _ in UInt8.random(in: 0...255) })
        let (url, info) = try await makeFileInfo(for: data)

        try data.prefix(50_000).write(to: url)

        // Size check alone must catch it before any hashing.
        let sizeFailure = ModelIntegrityVerifier.verifySize(of: info, at: url)
        XCTAssertNotNil(sizeFailure)
        let fullFailure = await ModelIntegrityVerifier.verify(file: info, at: url)
        XCTAssertNotNil(fullFailure)
    }

    func testMissingFileIsDetected() async throws {
        let data = Data(repeating: 0xAB, count: 1024)
        let (url, info) = try await makeFileInfo(for: data)
        try FileManager.default.removeItem(at: url)
        let failure = await ModelIntegrityVerifier.verify(file: info, at: url)
        XCTAssertNotNil(failure, "a missing file must fail verification")
    }

    func testUnsafePathsAreRefused() {
        // Path traversal must never reach the file system.
        for path in ["../escape.bin", "/absolute/path.bin", "a/../../b.bin", "dir/../../c.bin"] {
            XCTAssertFalse(ModelIntegrityVerifier.isSafePath(path), "\(path) must be refused")
        }
        for path in ["weights.bin", "Source/Encoder.mlpackage/Manifest.json"] {
            XCTAssertTrue(ModelIntegrityVerifier.isSafePath(path), "\(path) must be allowed")
        }
    }

    /// Full end-to-end verify of a genuinely installed backend (integration
    /// only; skipped when no backend is installed).
    func testInstalledBackendFullVerification() async throws {
        let manifest = try ModelManifest.load()
        for kind in ASRBackendKind.allCases {
            guard let info = manifest.backend(kind) else { continue }
            let root = try ModelPaths.backendRoot(kind)
            let failure = await ModelIntegrityVerifier.verifyBackend(info, root: root)
            if failure == nil { continue } // verified — done
            if FileManager.default.fileExists(atPath: root.path) {
                XCTFail("\(kind.displayName) is present but fails verification: \(String(describing: failure))")
            } else {
                throw XCTSkip("\(kind.displayName) is not installed — run scripts/prepare_models.sh")
            }
        }
    }
}
