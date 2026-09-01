import XCTest
@testable import LiveTranslateIOS

/// `CoreMLModelLoader` pieces that do not require the model files:
/// SHA256 hashing (including the multi-chunk path) and compiled-cache path
/// layout. Model compilation/loading is covered by the integration tests —
/// unit tests never touch the 400 MB artifacts.
final class CoreMLModelLoaderTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreMLModelLoaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - SHA256

    func testSHA256KnownVectors() throws {
        // SHA256("") and SHA256("hello") — standard test vectors.
        let empty = tempDir.appendingPathComponent("empty")
        try Data().write(to: empty)
        XCTAssertEqual(
            try CoreMLModelLoader.sha256File(at: empty),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )

        let hello = tempDir.appendingPathComponent("hello")
        try Data("hello".utf8).write(to: hello)
        XCTAssertEqual(
            try CoreMLModelLoader.sha256File(at: hello),
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        )
    }

    /// 8 MB + 3 bytes exercises the 4 MB chunked-read loop across two full
    /// chunk boundaries plus a remainder. Digest precomputed with `shasum -a 256`.
    func testSHA256ChunkedRead() throws {
        let big = tempDir.appendingPathComponent("big")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let chunk = [UInt8](repeating: 0, count: 1 << 20)
        let handle = try FileHandle(forWritingTo: big)
        defer { try? handle.close() }
        for _ in 0..<8 { try handle.write(contentsOf: Data(chunk)) }
        try handle.write(contentsOf: Data([0x01, 0x02, 0x03]))
        // sha256(8 MiB of zeros || 01 02 03), verified independently with
        // `shasum -a 256`.
        XCTAssertEqual(
            try CoreMLModelLoader.sha256File(at: big),
            "8d34707f6dba91b317df9ba2a18b2e79384d281cf30c7166ae12061d651788d5"
        )
    }

    func testSHA256MissingFileThrows() {
        let missing = tempDir.appendingPathComponent("missing")
        XCTAssertThrowsError(try CoreMLModelLoader.sha256File(at: missing))
    }

    // MARK: - Compiled cache layout

    func testCompiledRootPathLayout() {
        let root = CoreMLModelLoader.compiledRoot(cacheVersion: 7)
        XCTAssertEqual(root.lastPathComponent, "v7")
        XCTAssertEqual(root.deletingLastPathComponent().lastPathComponent, "Compiled")
        // .../Models/gigaam-v3-e2e-rnnt/coreml-fp16/Compiled/v7
        let backendDir = root.deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertEqual(backendDir.lastPathComponent, ASRBackendKind.coreMLFP16.manifestKey)
    }

    /// A version that was never compiled reports no artifacts — used by
    /// `hasCompiledModel()` to detect stale caches.
    func testCompiledURLsForNeverCreatedVersion() {
        let urls = CoreMLModelLoader.compiledURLs(cacheVersion: 999_999)
        XCTAssertEqual(urls.count, CoreMLModelLoader.packageNames.count)
        XCTAssertTrue(urls.allSatisfy { $0 == nil })
    }

    func testPackageNamesMatchContract() {
        XCTAssertEqual(CoreMLModelLoader.packageNames, [
            "GigaAMv3Encoder", "GigaAMv3DecoderStep", "GigaAMv3JointStep",
        ])
    }
}
