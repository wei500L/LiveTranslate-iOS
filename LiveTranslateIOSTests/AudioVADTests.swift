import XCTest
@testable import LiveTranslateIOS

/// AudioResampler and AudioRingBuffer — the pure DSP and bounded-queue
/// foundations of the capture path.
final class AudioVADTests: XCTestCase {

    // MARK: - Resampler: 48 kHz → 16 kHz

    func testResample48kTo16kRampIsExact() {
        // The reference project resamples with `np.linspace(0, n-1, n_out)`
        // (endpoint-stretched positions), not a pure 3:1 rate-ratio grid:
        // for 4800→1600 the step is 4799/1599, not exactly 3. A linear ramp
        // is reproduced exactly under linear interpolation, so the output
        // must be exactly the ramp sampled at those stretched positions —
        // first sample hits input[0], last hits input[4799].
        let input = (0..<4800).map { Float($0) }
        let output = AudioResampler.resample(input, from: 48_000, to: 16_000)
        XCTAssertEqual(output.count, 1600)
        let step = 4799.0 / 1599.0
        for i in 0..<output.count {
            XCTAssertEqual(Double(output[i]), Double(i) * step, accuracy: 1e-2,
                           "output[\(i)] should hit the ramp at stretched position \(Double(i) * step)")
        }
        XCTAssertEqual(output.first!, 0, accuracy: 1e-6)
        XCTAssertEqual(output.last!, 4799, accuracy: 1e-3)
    }

    func testResample48kTo16kSinePreservesFrequency() {
        // A 440 Hz sine at 48 kHz downsampled to 16 kHz stays 440 Hz when
        // sampled at the same stretched positions the reference uses — the
        // remaining difference from a directly synthesized reference is the
        // linear-interpolation error alone.
        let frequency: Float = 440
        let input = (0..<4800).map { i in
            sin(2 * .pi * frequency * Float(i) / 48_000)
        }
        let output = AudioResampler.resample(input, from: 48_000, to: 16_000)
        let step = 4799.0 / 1599.0
        let reference = (0..<1600).map { i in
            sin(2 * .pi * frequency * Float(Double(i) * step) / 48_000)
        }
        for i in 0..<output.count {
            XCTAssertEqual(output[i], reference[i], accuracy: 0.005)
        }
    }

    // MARK: - Resampler: 44.1 kHz → 16 kHz (non-integer ratio)

    func testResample44_1kTo16k() {
        let input = (0..<4410).map { Float($0) }
        let output = AudioResampler.resample(input, from: 44_100, to: 16_000)
        // 4410 * 16000 / 44100 = 1600 exactly.
        XCTAssertEqual(output.count, 1600)
        // Monotonic ramp stays monotonic; endpoints track the input span.
        for i in 1..<output.count {
            XCTAssertLessThanOrEqual(output[i - 1], output[i] + 1e-6,
                                     "ramp must stay monotonic after resampling")
        }
        XCTAssertLessThan(abs(output[0]), 1e-6)
        XCTAssertGreaterThan(output.last!, 4400, "last sample must approach the input end")
    }

    // MARK: - Downmix

    func testStereoToMonoAveragesChannels() {
        // Interleaved stereo: L, R, L, R… with L = 1.0 and R = 0.5.
        var interleaved = [Float]()
        for _ in 0..<100 {
            interleaved.append(contentsOf: [1.0, 0.5])
        }
        let mono = AudioResampler.normalizeToMono(interleaved, channels: 2)
        XCTAssertEqual(mono.count, 100)
        for value in mono {
            XCTAssertEqual(value, 0.75, accuracy: 1e-6)
        }
    }

    func testMonoPassthrough() {
        let input: [Float] = [0.1, -0.2, 0.3, -0.4]
        let mono = AudioResampler.normalizeToMono(input, channels: 1)
        XCTAssertEqual(mono, input)
    }

    func testThreeChannelDownmix() {
        let interleaved: [Float] = [0.3, 0.6, 0.9, 0.3, 0.6, 0.9]
        let mono = AudioResampler.normalizeToMono(interleaved, channels: 3)
        XCTAssertEqual(mono.count, 2)
        for value in mono {
            XCTAssertEqual(value, 0.6, accuracy: 1e-6)
        }
    }

    // MARK: - Sanitization

    func testSanitizeCleansNaNCausesAndClamps() {
        let input: [Float] = [.nan, .infinity, -.infinity, 2.0, -2.0, 0.25, -0.25]
        let clean = AudioResampler.sanitize(input)
        XCTAssertEqual(clean.count, input.count)
        XCTAssertEqual(clean[0], 0, accuracy: 1e-9, "NaN must become silence")
        XCTAssertEqual(clean[1], 1, accuracy: 1e-9, "+Inf must clamp to +1")
        XCTAssertEqual(clean[2], -1, accuracy: 1e-9, "-Inf must clamp to -1")
        XCTAssertEqual(clean[3], 1, accuracy: 1e-9)
        XCTAssertEqual(clean[4], -1, accuracy: 1e-9)
        XCTAssertEqual(clean[5], 0.25, accuracy: 1e-9)
        XCTAssertEqual(clean[6], -0.25, accuracy: 1e-9)
    }

    func testRMSOfConstantSignal() {
        let constant = [Float](repeating: 0.5, count: 512)
        XCTAssertEqual(AudioResampler.rms(constant), 0.5, accuracy: 1e-6)
        XCTAssertEqual(AudioResampler.rms([0, 0, 0]), 0, accuracy: 1e-9)
    }

    // MARK: - Ring buffer

    func testRingBufferFillsWithoutDropping() {
        let ring = AudioRingBuffer(capacitySamples: 1000)
        ring.append((0..<1000).map { Float($0) })
        XCTAssertEqual(ring.available, 1000)
        XCTAssertEqual(ring.droppedSamples, 0)
        let read = ring.read(upTo: 1000)
        XCTAssertEqual(read.count, 1000)
        XCTAssertEqual(read.first, 0)
        XCTAssertEqual(read.last, 999)
        XCTAssertEqual(ring.available, 0)
    }

    func testRingBufferDropsOldestWhenFull() {
        let ring = AudioRingBuffer(capacitySamples: 100)
        ring.append((0..<100).map { Float($0) })
        XCTAssertEqual(ring.droppedSamples, 0)
        // 20 more samples: the oldest 20 (0…19) are dropped.
        ring.append((100..<120).map { Float($0) })
        XCTAssertEqual(ring.available, 100)
        XCTAssertEqual(ring.droppedSamples, 20)
        let read = ring.read(upTo: 100)
        XCTAssertEqual(read.first!, 20, "oldest samples must be the ones dropped")
        XCTAssertEqual(read.last!, 119)
        XCTAssertEqual(ring.appendedSamples, 120)
    }

    func testRingBufferWraparoundPreservesOrder() {
        let ring = AudioRingBuffer(capacitySamples: 10)
        ring.append([1, 2, 3, 4, 5, 6, 7, 8])
        _ = ring.read(upTo: 6)          // consumes 1…6, head now at 6
        ring.append([9, 10, 11, 12])    // wraps the storage array
        let read = ring.read(upTo: 10)
        XCTAssertEqual(read, [7, 8, 9, 10, 11, 12], "order must survive wraparound")
    }

    func testRingBufferReadExactly() {
        let ring = AudioRingBuffer(capacitySamples: 100)
        ring.append([1, 2, 3])
        XCTAssertNil(ring.read(exactly: 4), "partial data must not be returned")
        let read = ring.read(exactly: 3)
        XCTAssertEqual(read, [1, 2, 3])
        XCTAssertEqual(ring.available, 0)
    }

    func testRingBufferRemoveAll() {
        let ring = AudioRingBuffer(capacitySamples: 100)
        ring.append([1, 2, 3])
        ring.removeAll()
        XCTAssertEqual(ring.available, 0)
        XCTAssertEqual(ring.read(upTo: 10), [])
    }

    func testRingBufferWaitForDataReturnsImmediatelyWhenNonEmpty() async {
        let ring = AudioRingBuffer(capacitySamples: 100)
        ring.append([1, 2, 3])
        let count = await ring.waitForData(timeout: 0.05)
        XCTAssertEqual(count, 3)
    }

    func testRingBufferWaitForDataTimesOutAtZero() async {
        let ring = AudioRingBuffer(capacitySamples: 100)
        let count = await ring.waitForData(timeout: 0.05)
        XCTAssertEqual(count, 0, "empty buffer must time out with 0, not hang")
    }

    // MARK: - EnergyVAD (opt-in fallback only)

    func testEnergyVADHysteresis() {
        let vad = EnergyVAD(threshold: 0.1)
        let loud = [Float](repeating: 0.5, count: 512)
        let quiet = [Float](repeating: 0.001, count: 512)

        XCTAssertFalse(vad.process(window: quiet[...]))
        XCTAssertTrue(vad.process(window: loud[...]), "loud window is speech")

        // Hysteresis: one quiet window after speech must not end speech.
        XCTAssertTrue(vad.process(window: quiet[...]))

        // Sustained silence does end it.
        for _ in 0..<10 {
            _ = vad.process(window: quiet[...])
        }
        XCTAssertFalse(vad.process(window: quiet[...]))

        vad.reset()
        XCTAssertFalse(vad.process(window: quiet[...]),
                       "after reset there is no speech to sustain")
        XCTAssertTrue(vad.process(window: loud[...]))
    }
}
