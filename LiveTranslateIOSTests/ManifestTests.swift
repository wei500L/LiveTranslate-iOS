import XCTest
@testable import LiveTranslateIOS

/// Manifest contract tests: the pinned revisions, hash formats, path
/// safety, and the schema the installer depends on.
final class ManifestTests: XCTestCase {
    /// The generated manifest is bundled with the app.
    private func loadManifest() throws -> ModelManifest {
        try ModelManifest.load()
    }

    func testManifestBundlesAndDecodes() throws {
        let manifest = try loadManifest()
        XCTAssertEqual(manifest.schemaVersion, 2)
        XCTAssertEqual(manifest.model.id, "gigaam-v3-e2e-rnnt")
        XCTAssertEqual(manifest.model.language, "ru")
        XCTAssertEqual(manifest.model.upstreamRepo, "ai-sage/GigaAM-v3")
    }

    func testBothBackendsPresent() throws {
        let manifest = try loadManifest()
        XCTAssertNotNil(manifest.backend(.coreMLFP16))
        XCTAssertNotNil(manifest.backend(.sherpaONNXInt8))
        XCTAssertEqual(manifest.backends.count, 2)
    }

    /// Revisions must be full 40-char commit SHAs — never "main".
    func testRevisionsArePinnedCommitSHAs() throws {
        let manifest = try loadManifest()
        for backend in manifest.backends.values {
            XCTAssertEqual(backend.revision.count, 40, "\(backend.id) revision must be a full commit SHA")
            XCTAssertFalse(backend.revision.hasPrefix("main"))
            XCTAssertFalse(backend.revision.hasPrefix("master"))
            for char in backend.revision {
                XCTAssertTrue(char.isHexDigit, "revision contains non-hex character: \(char)")
            }
        }
    }

    func testCoreMLRevisionMatchesPinnedSHA() throws {
        let manifest = try loadManifest()
        XCTAssertEqual(
            manifest.backend(.coreMLFP16)?.revision,
            "846833ef075fde2a8e50521d093ddb9ed7b7fd45"
        )
        XCTAssertEqual(
            manifest.backend(.sherpaONNXInt8)?.revision,
            "c0acd38c8aeb2bdc04da221bd661ffcdb9645f7d"
        )
    }

    func testEveryFileHasValidHashAndPositiveSize() throws {
        let manifest = try loadManifest()
        for backend in manifest.backends.values {
            XCTAssertFalse(backend.files.isEmpty, "\(backend.id) has no files")
            for file in backend.files {
                XCTAssertEqual(file.sha256.count, 64, "\(file.path) sha256 must be 64 hex chars")
                XCTAssertTrue(file.sha256.allSatisfy(\.isHexDigit), "\(file.path) sha256 is not hex")
                XCTAssertGreaterThan(file.bytes, 0, "\(file.path) size must be positive")
                XCTAssertTrue(file.url.hasPrefix("https://"), "\(file.path) URL must be https")
                // URL must point at the pinned revision, never a branch.
                XCTAssertTrue(file.url.contains("/resolve/\(backend.revision)/"),
                              "\(file.path) URL does not use the pinned revision")
            }
            XCTAssertEqual(
                backend.totalDownloadBytes,
                backend.files.reduce(0) { $0 + $1.bytes },
                "\(backend.id) totalDownloadBytes must equal the sum of its files"
            )
            XCTAssertGreaterThan(backend.minimumFreeDiskBytes, backend.totalDownloadBytes,
                                 "disk requirement must exceed the bare download size")
        }
    }

    /// The Core ML disk requirement accounts for source + compiled copy +
    /// temp files, not just the ~446 MB download.
    func testCoreMLDiskBudgetCoversCompilation() throws {
        let manifest = try loadManifest()
        let coreML = try XCTUnwrap(manifest.backend(.coreMLFP16))
        XCTAssertGreaterThan(coreML.minimumFreeDiskBytes, 1_000_000_000)
        XCTAssertNotNil(coreML.coreMLCompiledCacheVersion)
    }

    /// No manifest path may escape the backend root (zip-slip defense).
    func testAllPathsAreSafe() throws {
        let manifest = try loadManifest()
        for backend in manifest.backends.values {
            for file in backend.files {
                XCTAssertTrue(ModelIntegrityVerifier.isSafePath(file.path),
                              "\(file.path) is not a safe relative path")
            }
        }
    }

    func testUnsafePathsRejected() {
        XCTAssertFalse(ModelIntegrityVerifier.isSafePath("../escape"))
        XCTAssertFalse(ModelIntegrityVerifier.isSafePath("a/../../b"))
        XCTAssertFalse(ModelIntegrityVerifier.isSafePath("/absolute"))
        XCTAssertFalse(ModelIntegrityVerifier.isSafePath(""))
        XCTAssertFalse(ModelIntegrityVerifier.isSafePath("a//b"))
        XCTAssertTrue(ModelIntegrityVerifier.isSafePath("Source/GigaAMv3Encoder.mlpackage/Manifest.json"))
    }

    func testCoreMLPackagesEachHaveTheirThreeLeafFiles() throws {
        let manifest = try loadManifest()
        let coreML = try XCTUnwrap(manifest.backend(.coreMLFP16))
        for package in ["GigaAMv3Encoder", "GigaAMv3DecoderStep", "GigaAMv3JointStep"] {
            let prefix = "Source/\(package).mlpackage/"
            XCTAssertTrue(coreML.files.contains { $0.path == "\(prefix)Manifest.json" })
            XCTAssertTrue(coreML.files.contains { $0.path == "\(prefix)Data/com.apple.CoreML/model.mlmodel" })
            XCTAssertTrue(coreML.files.contains { $0.path == "\(prefix)Data/com.apple.CoreML/weights/weight.bin" })
        }
        XCTAssertTrue(coreML.files.contains { $0.path == "Metadata/tokens.json" })
    }

    func testRuntimeSection() throws {
        let manifest = try loadManifest()
        XCTAssertEqual(manifest.runtime.sherpaOnnxVersion, "1.13.7")
        let vad = manifest.runtime.sileroVAD
        XCTAssertEqual(vad.sha256.count, 64)
        XCTAssertGreaterThan(vad.bytes, 0)
        XCTAssertTrue(vad.url.hasPrefix("https://"))
    }
}
