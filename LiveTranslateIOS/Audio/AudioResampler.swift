import Foundation
import Accelerate

/// Pure, testable audio normalization helpers.
///
/// The live capture path uses `AVAudioConverter` (see AudioCaptureService);
/// these functions implement the same contract for tests, file imports and
/// the benchmark runner. Everything operates on mono Float32 in [-1, 1].
enum AudioResampler {
    /// Normalize arbitrary interleaved PCM to mono Float32 in [-1, 1].
    ///
    /// - Interleaved multi-channel input is downmixed by channel average.
    /// - NaN → 0, +Inf → +1, -Inf → -1 (numpy `nan_to_num` semantics).
    /// - Values outside [-1, 1] are clamped.
    static func normalizeToMono(_ samples: [Float], channels: Int) -> [Float] {
        precondition(channels >= 1, "channels must be >= 1")
        var clean = sanitize(samples)
        guard channels > 1 else { return clean }
        let usable = clean.count - clean.count % channels
        clean.removeSubrange(usable...)
        let frames = usable / channels
        var mono = [Float](repeating: 0, count: frames)
        mono.withUnsafeMutableBufferPointer { dst in
            clean.withUnsafeBufferPointer { src in
                for frame in 0..<frames {
                    var sum: Float = 0
                    for channel in 0..<channels {
                        sum += src[frame * channels + channel]
                    }
                    dst[frame] = sum / Float(channels)
                }
            }
        }
        return mono
    }

    /// Replace NaN with 0, ±Inf with ±1, and clamp everything to [-1, 1].
    static func sanitize(_ samples: [Float]) -> [Float] {
        var result = samples
        for i in result.indices {
            let value = result[i]
            if value.isNaN {
                result[i] = 0
            } else if value > 1 {
                result[i] = 1
            } else if value < -1 {
                result[i] = -1
            }
        }
        return result
    }

    /// Linear-interpolation resampler (arbitrary rates).
    ///
    /// Output length is `round(count * to / from)` — matching the reference
    /// project's `numpy.interp` behavior so segment durations line up with
    /// the desktop implementation.
    static func resample(_ samples: [Float], from sourceRate: Int, to targetRate: Int) -> [Float] {
        precondition(sourceRate > 0 && targetRate > 0, "rates must be positive")
        guard sourceRate != targetRate, samples.count > 1 else {
            return samples
        }
        let targetCount = max(1, Int((Double(samples.count) * Double(targetRate) / Double(sourceRate)).rounded()))
        var output = [Float](repeating: 0, count: targetCount)
        let step = Double(samples.count - 1) / Double(max(1, targetCount - 1))
        for i in 0..<targetCount {
            let position = Double(i) * step
            let index = Int(position)
            let fraction = Float(position - Double(index))
            let next = min(index + 1, samples.count - 1)
            output[i] = samples[index] * (1 - fraction) + samples[next] * fraction
        }
        return output
    }

    /// Root-mean-square level of a window, in [0, 1].
    static func rms(_ samples: ArraySlice<Float>) -> Float {
        let n = samples.count
        guard n > 0 else { return 0 }
        var sum: Float = 0
        let copy = Array(samples)
        copy.withUnsafeBufferPointer { buffer in
            vDSP_svesq(buffer.baseAddress!, 1, &sum, vDSP_Length(n))
        }
        return sqrt(sum / Float(n))
    }

    static func rms(_ samples: [Float]) -> Float {
        rms(samples[...])
    }
}
