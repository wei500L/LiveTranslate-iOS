import Foundation

/// Per-window voice activity verdict. Implementations are fed 512-sample
/// (32 ms) windows of 16 kHz mono audio and answer "is this window speech?".
///
/// The VAD layer is shared by *both* ASR backends — Silero VAD runs whether
/// recognition uses Core ML or sherpa-onnx.
protocol SpeechActivityDetector: AnyObject, Sendable {
    /// Feed one window and get the verdict for it.
    func process(window: ArraySlice<Float>) -> Bool
    /// Drop internal state for a fresh stream.
    func reset()
}

/// Simple RMS fallback. NOT used by default — the product prefers Silero
/// VAD; energy mode exists as an explicit user setting for cases where the
/// Silero model file is unavailable and the user accepts cruder gating.
/// A missing Silero model is surfaced as an error, never silently replaced
/// by this.
final class EnergyVAD: SpeechActivityDetector, @unchecked Sendable {
    private let lock = NSLock()
    private var threshold: Float
    /// Windows of recent verdicts (hysteresis against single-window noise).
    private var recent: [Bool] = []
    private var hysteresisCount = 2

    init(threshold: Float = 0.02) {
        self.threshold = threshold
    }

    func process(window: ArraySlice<Float>) -> Bool {
        let level = AudioResampler.rms(window)
        let raw = level >= threshold
        lock.lock(); defer { lock.unlock() }
        recent.append(raw)
        if recent.count > 5 { recent.removeFirst(recent.count - 5) }
        let hits = recent.filter { $0 }.count
        return hits >= (recent.count - hysteresisCount) && hits > 0
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        recent = []
    }
}
