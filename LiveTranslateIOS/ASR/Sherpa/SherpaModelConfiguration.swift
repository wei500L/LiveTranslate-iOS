import Foundation

/// File layout and configuration for the sherpa-onnx INT8 backend.
///
/// Install directory (under Application Support, see `ModelPaths`):
/// ```
/// gigaam-v3-e2e-rnnt/sherpa-onnx-int8/
///   encoder.int8.onnx   (~214 MB)
///   decoder.onnx        (~1.1 MB)
///   joiner.onnx         (~0.7 MB)
///   tokens.txt
/// ```
enum SherpaModelConfiguration {
    struct Paths: Sendable {
        let encoder: URL
        let decoder: URL
        let joiner: URL
        let tokens: URL

        var all: [URL] { [encoder, decoder, joiner, tokens] }
    }

    /// Fixed inference configuration. `feature_dim = 64` and
    /// `model_type = "nemo_transducer"` must be set explicitly — the
    /// GigaAM e2e_rnnt export is a NeMo transducer with a 64-bin HTK Log-Mel
    /// front end; sherpa-onnx would misconfigure both if left to defaults.
    struct InferenceConfig: Sendable {
        let sampleRate: Int = 16_000
        let featureDim: Int = 64
        let modelType: String = "nemo_transducer"
        let decodingMethod: String = "greedy_search"
        let provider: String = "cpu"
        var threadCount: Int = 2

        /// Benchmark-only preset: 4 threads is *not* assumed faster — the
        /// benchmark runner exists to measure it.
        static func threads(_ n: Int) -> InferenceConfig {
            var config = InferenceConfig()
            config.threadCount = n
            return config
        }
    }

    static let encoderFileName = "encoder.int8.onnx"
    static let decoderFileName = "decoder.onnx"
    static let joinerFileName = "joiner.onnx"
    static let tokensFileName = "tokens.txt"

    /// Resolve install paths. Does not check existence.
    static func paths() throws -> Paths {
        let root = try ModelPaths.backendRoot(.sherpaONNXInt8)
        return Paths(
            encoder: root.appendingPathComponent(encoderFileName),
            decoder: root.appendingPathComponent(decoderFileName),
            joiner: root.appendingPathComponent(joinerFileName),
            tokens: root.appendingPathComponent(tokensFileName)
        )
    }

    /// Minimum plausible file sizes — the integrity verifier does the full
    /// SHA256 pass; this catches half-written installs cheaply.
    static func isInstalled() -> Bool {
        guard let paths = try? paths() else { return false }
        let minimumBytes: [URL: Int] = [
            paths.encoder: 200_000_000,
            paths.decoder: 1_000_000,
            paths.joiner: 500_000,
            paths.tokens: 10_000,
        ]
        for (url, minimum) in minimumBytes {
            guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
                  size >= minimum else {
                return false
            }
        }
        return true
    }

    /// Bytes on disk for the whole install (0 when not installed).
    static func installedBytes() -> Int {
        guard let paths = try? paths() else { return 0 }
        return paths.all.reduce(0) { total, url in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            return total + size
        }
    }
}
