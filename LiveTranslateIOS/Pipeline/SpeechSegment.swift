import Foundation

/// One VAD-delimited speech segment entering the ASR pipeline.
struct SpeechSegment: Sendable, Identifiable, Equatable {
    /// Monotonic per-session counter, assigned before ASR. Orders every
    /// downstream stage regardless of translation completion order.
    let sequenceID: Int
    /// Samples, mono Float32 @ 16 kHz.
    let samples: [Float]
    let sampleRate: Int
    /// Offsets from session start (seconds).
    let startOffset: TimeInterval
    let endOffset: TimeInterval

    var duration: TimeInterval { endOffset - startOffset }

    var id: Int { sequenceID }
}
