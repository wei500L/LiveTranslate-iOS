import Foundation

/// The single protocol both inference backends implement.
///
/// Contract (enforced by `ASREngineManager`):
/// - Exactly one engine is resident at any time; switching requires an
///   explicit unload of the previous backend.
/// - Implementations are `Sendable`; the model instance must be isolated
///   inside an `actor` so inference is serialized by construction.
/// - `prepare()` loads and `warmup()` runs a short test inference so the
///   first real segment does not pay one-time costs.
/// - A backend that fails never falls back to Apple Speech, a cloud ASR,
///   or the other backend. The error is surfaced to the user.
protocol ASREngine: Sendable {
    var backendKind: ASRBackendKind { get }

    /// Load model files, verify integrity, set up reusable buffers.
    func prepare() async throws

    /// Run one short inference so first-use latency is measured separately.
    func warmup() async throws

    /// Transcribe one VAD segment. `samples` are mono Float32 at
    /// `sampleRate` (16 kHz from the pipeline; implementations may assert).
    func transcribe(
        samples: [Float],
        sampleRate: Int,
        segmentStart: TimeInterval,
        segmentEnd: TimeInterval
    ) async throws -> ASRResult

    /// Release the model and all caches. Safe to call when not loaded.
    func unload() async
}
