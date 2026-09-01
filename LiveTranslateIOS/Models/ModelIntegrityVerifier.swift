import Foundation
import CryptoKit

/// Streams a file through SHA256 and compares it against the manifest.
///
/// Hashes are computed in 8 KiB blocks so a 441 MB encoder weight file
/// never loads into memory. Files are read on a detached task to keep the
/// hashing off the main actor.
struct ModelIntegrityVerifier: Sendable {
    enum VerificationError: LocalizedError, Equatable {
        case fileMissing(String)
        case sizeMismatch(path: String, expected: Int, actual: Int)
        case hashMismatch(path: String, expected: String, actual: String)

        var errorDescription: String? {
            switch self {
            case .fileMissing(let path):
                return "Model file is missing: \(path)"
            case .sizeMismatch(let path, let expected, let actual):
                return "Model file has the wrong size: \(path) — expected \(expected) bytes, found \(actual)."
            case .hashMismatch(let path, _, let actual):
                return "Model file failed its SHA256 check: \(path) (computed \(actual.prefix(12))…). Re-download the model."
            }
        }
    }

    /// SHA256 of one file, streaming in 8 KiB blocks.
    static func sha256(of url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            var hasher = SHA256()
            let blockSize = 8 * 1024
            while let block = try handle.read(upToCount: blockSize), !block.isEmpty {
                hasher.update(data: block)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    /// Size-only quick check (cheap preflight before hashing).
    static func verifySize(of file: ModelManifest.BackendInfo.FileInfo, at url: URL) -> VerificationError? {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            return .fileMissing(file.path)
        }
        let actual = attributes[.size] as? Int ?? -1
        guard actual == file.bytes else {
            return .sizeMismatch(path: file.path, expected: file.bytes, actual: actual)
        }
        return nil
    }

    /// Full check: existence, size, SHA256.
    static func verify(file: ModelManifest.BackendInfo.FileInfo, at url: URL) async -> VerificationError? {
        if let sizeError = verifySize(of: file, at: url) {
            return sizeError
        }
        let actualHash: String
        do {
            actualHash = try await sha256(of: url)
        } catch {
            return .fileMissing(file.path)
        }
        guard actualHash == file.sha256.lowercased() else {
            return .hashMismatch(path: file.path, expected: file.sha256, actual: actualHash)
        }
        return nil
    }

    /// Verify every file of one backend against the manifest.
    /// - Returns: nil when the backend is fully intact, otherwise the first
    ///   failure (files are checked in manifest order).
    static func verifyBackend(_ backend: ModelManifest.BackendInfo, root: URL) async -> VerificationError? {
        for file in backend.files {
            let url = root.appendingPathComponent(file.path)
            if let failure = await verify(file: file, at: url) {
                return failure
            }
        }
        return nil
    }

    /// True when a manifest file path is safe to join onto an install root:
    /// no absolute paths, no parent traversal, no empty components. This is
    /// the defense-in-depth check against a tampered manifest acting like a
    /// zip-slip writer.
    static func isSafePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
    }
}
