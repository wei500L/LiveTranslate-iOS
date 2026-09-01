import XCTest
@testable import LiveTranslateIOS

/// SpeechSegmenter policy tests, driven by a scripted VAD oracle (the
/// segmenter takes a per-window boolean, so no real model is needed).
///
/// Window geometry (512 samples @ 16 kHz = 32 ms) with default parameters:
/// minSpeech 250 ms ≈ 8 windows, silenceEnd 600 ms ≈ 19 windows,
/// postRoll 200 ms ≈ 6 windows, preRoll 300 ms ≈ 9 windows,
/// forcedSplit 12 s = 375 windows, maxWait 3 s ≈ 94 windows,
/// hardMax 20 s = 625 windows, absoluteMax 25 s ≈ 781 windows,
/// forcedSplit overlap 300 ms ≈ 9 windows.
final class SegmenterTests: XCTestCase {
    private let windowSamples = 512
    private let windowDuration = 512.0 / 16_000.0   // 0.032 s

    private func makeSegmenter(_ parameters: SpeechSegmenter.Parameters = .init()) -> SpeechSegmenter {
        SpeechSegmenter(parameters: parameters)
    }

    /// Feed one window; returns segments that closed.
    private func push(
        _ segmenter: SpeechSegmenter, voiced: Bool, amplitude: Float = 0.5
    ) -> [SpeechSegment] {
        let samples = [Float](repeating: amplitude, count: windowSamples)
        return segmenter.push(window: samples[...], isSpeech: voiced)
    }

    /// Feed a run of same-verdict windows.
    @discardableResult
    private func push(
        _ segmenter: SpeechSegmenter, voiced: Bool, windows: Int, amplitude: Float = 0.5
    ) -> [SpeechSegment] {
        var segments: [SpeechSegment] = []
        for _ in 0..<windows {
            segments.append(contentsOf: push(segmenter, voiced: voiced, amplitude: amplitude))
        }
        return segments
    }

    // MARK: - Onset with pre-roll

    func testSpeechOnsetIncludesPreRoll() {
        let segmenter = makeSegmenter()
        // 20 unvoiced (0.64 s of room tone), then real speech.
        push(segmenter, voiced: false, windows: 20)
        push(segmenter, voiced: true, windows: 30)
        let segments = push(segmenter, voiced: false, windows: 20)

        XCTAssertEqual(segments.count, 1)
        let segment = segments[0]
        // Pre-roll is 300 ms (9 windows): onset window is #20, so the
        // segment must start at window 11, not 20.
        XCTAssertEqual(segment.startOffset, 11 * windowDuration, accuracy: 0.001)
        // Content: 9 pre-roll + 30 speech + ~6 post-roll windows.
        XCTAssertEqual(segment.duration, 45 * windowDuration, accuracy: windowDuration * 1.5)
        XCTAssertEqual(segment.sampleRate, 16_000)
        XCTAssertEqual(Double(segment.samples.count), segment.duration * 16_000, accuracy: 550)
    }

    // MARK: - Minimum speech duration

    func testShortBlipIsDiscarded() {
        let segmenter = makeSegmenter()
        push(segmenter, voiced: false, windows: 10)
        // 4 voiced windows = 128 ms < 250 ms minimum.
        push(segmenter, voiced: true, windows: 4)
        let segments = push(segmenter, voiced: false, windows: 25)
        XCTAssertTrue(segments.isEmpty, "sub-minimum speech must be discarded")
        XCTAssertTrue(segmenter.flush().isEmpty)
    }

    func testMinimumSpeechIsKept() {
        let segmenter = makeSegmenter()
        push(segmenter, voiced: false, windows: 10)
        // 9 voiced windows = 288 ms ≥ 250 ms.
        push(segmenter, voiced: true, windows: 9)
        let segments = push(segmenter, voiced: false, windows: 25)
        XCTAssertEqual(segments.count, 1)
    }

    // MARK: - Silence close with post-roll

    func testSilenceClosesSegmentWithPostRollOnly() {
        let segmenter = makeSegmenter()
        push(segmenter, voiced: true, windows: 40)
        // 19 silence windows (600 ms) trigger the close; only ~6 are kept.
        let segments = push(segmenter, voiced: false, windows: 19)
        XCTAssertEqual(segments.count, 1)
        let segment = segments[0]
        XCTAssertEqual(segment.startOffset, 0, accuracy: 0.001)
        // 40 speech + 6 post-roll ≈ 46 windows.
        XCTAssertEqual(segment.duration, 46 * windowDuration, accuracy: windowDuration * 1.5)
        // The very next window must start a fresh timeline (no overlap on
        // natural close).
        push(segmenter, voiced: false, windows: 5)
        push(segmenter, voiced: true, windows: 30)
        let second = push(segmenter, voiced: false, windows: 19)
        XCTAssertEqual(second.count, 1)
        XCTAssertGreaterThan(second[0].startOffset, segment.endOffset - windowDuration * 2)
    }

    // MARK: - Forced split at a valley (≥ 12 s continuous speech)

    func testForcedSplitAtEnergyValley() {
        let segmenter = makeSegmenter()
        // Continuous speech: 12.5 s loud, a dip, then more loud speech.
        var segments: [SpeechSegment] = []
        segments += push(segmenter, voiced: true, windows: 390, amplitude: 0.5)
        segments += push(segmenter, voiced: true, windows: 4, amplitude: 0.05)   // valley ≈ 12.5 s
        segments += push(segmenter, voiced: true, windows: 200, amplitude: 0.5)  // keep talking
        // Then silence closes the tail.
        segments += push(segmenter, voiced: false, windows: 25)

        XCTAssertEqual(segments.count, 2, "continuous speech must be split at the valley")
        let head = segments[0]
        let tail = segments[1]

        // Head: ~12.5 s (past the 12 s threshold, before the 15 s deadline).
        XCTAssertGreaterThanOrEqual(head.duration, 12.0)
        XCTAssertLessThanOrEqual(head.duration, 13.5)
        // Overlap: the tail begins 300 ms (9 windows = 0.288 s) *before*
        // the head ends.
        XCTAssertLessThan(tail.startOffset, head.endOffset)
        XCTAssertEqual(head.endOffset - tail.startOffset, 0.288, accuracy: 0.01)
        // The tail holds the remainder of the utterance (6+ seconds).
        XCTAssertGreaterThanOrEqual(tail.duration, 6.0)
        // Every sample of the utterance is covered by head ∪ tail.
        XCTAssertLessThanOrEqual(head.startOffset, 0.001)
    }

    // MARK: - No natural boundary: cut by the deadline (≈ 15 s)

    func testContinuousSpeechCutByDeadline() {
        let segmenter = makeSegmenter()
        // Constant-amplitude speech offers no valley: the segmenter must
        // cut by forcedSplitStart + maxWait = 15 s.
        var segments: [SpeechSegment] = []
        segments += push(segmenter, voiced: true, windows: 500)   // 16 s
        segments += push(segmenter, voiced: false, windows: 25)

        XCTAssertEqual(segments.count, 2)
        let head = segments[0]
        XCTAssertGreaterThanOrEqual(head.duration, 14.5)
        XCTAssertLessThanOrEqual(head.duration, 15.5,
                                 "no-valley speech must be cut by the 15 s deadline")
    }

    // MARK: - Hard maximum (20 s)

    func testHardMaxCap() {
        let segmenter = makeSegmenter(
            SpeechSegmenter.Parameters(
                maxWaitForBoundarySeconds: 3600   // disable the deadline; only hardMax applies
            )
        )
        var segments: [SpeechSegment] = []
        segments += push(segmenter, voiced: true, windows: 640)   // 20.5 s
        segments += push(segmenter, voiced: false, windows: 25)

        XCTAssertEqual(segments.count, 2)
        XCTAssertLessThanOrEqual(segments[0].duration, 20.1,
                                 "hard maximum is 20 s")
        XCTAssertGreaterThanOrEqual(segments[0].duration, 19.0)
        XCTAssertGreaterThanOrEqual(segments[1].duration, 0.25,
                                     "remainder after the hard cut is kept")
    }

    // MARK: - Absolute cap (25 s), defense in depth

    func testAbsoluteCapNeverExceeded() {
        // Even with both earlier limits disabled, nothing exceeds 25 s.
        let segmenter = makeSegmenter(
            SpeechSegmenter.Parameters(
                forcedSplitStartSeconds: 3600,
                maxWaitForBoundarySeconds: 3600,
                hardMaxSeconds: 3600
            )
        )
        var segments: [SpeechSegment] = []
        segments += push(segmenter, voiced: true, windows: 790)   // 25.3 s
        segments += push(segmenter, voiced: false, windows: 25)

        XCTAssertEqual(segments.count, 2)
        XCTAssertLessThanOrEqual(segments[0].duration, 25.1,
                                 "the absolute cap is 25 s, always")
        XCTAssertGreaterThanOrEqual(segments[1].duration, 0.25)
    }

    // MARK: - Flush

    func testFlushEmitsPendingTail() {
        let segmenter = makeSegmenter()
        push(segmenter, voiced: true, windows: 40)
        let segments = segmenter.flush()
        XCTAssertEqual(segments.count, 1, "speech still pending at stop must be flushed")
        XCTAssertEqual(segments[0].duration, 40 * windowDuration, accuracy: windowDuration)
        XCTAssertTrue(segmenter.flush().isEmpty, "flush is idempotent")
    }

    // MARK: - Sequence IDs and offsets

    func testSequenceIDsAreMonotonicAndOffsetsConsistent() {
        let segmenter = makeSegmenter()
        var all: [SpeechSegment] = []
        for _ in 0..<3 {
            all += push(segmenter, voiced: true, windows: 30)
            all += push(segmenter, voiced: false, windows: 25)
        }
        all += push(segmenter, voiced: true, windows: 30)
        all += segmenter.flush()

        XCTAssertEqual(all.count, 4)
        for (index, segment) in all.enumerated() {
            XCTAssertEqual(segment.sequenceID, index,
                           "sequenceIDs are dense and monotonic")
        }
        for i in 1..<all.count {
            // Natural closes never overlap; each segment starts where the
            // stream has advanced to.
            XCTAssertGreaterThanOrEqual(all[i].startOffset, all[i - 1].startOffset)
            XCTAssertGreaterThan(all[i].endOffset, all[i].startOffset)
        }
    }

    func testOffsetsAreRelativeToFedSamples() {
        let segmenter = makeSegmenter()
        // 100 leading silence windows (3.2 s) — pre-roll only reaches back
        // 300 ms from onset.
        push(segmenter, voiced: false, windows: 100)
        push(segmenter, voiced: true, windows: 30)
        let segments = push(segmenter, voiced: false, windows: 25)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].startOffset, 91 * windowDuration, accuracy: 0.001)
        XCTAssertEqual(segments[0].endOffset,
                       segments[0].startOffset + segments[0].duration,
                       accuracy: 0.001)
    }

    // MARK: - Overlap dedup (text level)

    func testDeduplicateOverlapRemovesPhraseSeam() {
        // A genuine replay spans a word boundary and is removed.
        XCTAssertEqual(
            SpeechSegmenter.deduplicateOverlap(previous: "Привет мир как", next: "мир как дела"),
            "дела"
        )
    }

    func testDeduplicateOverlapKeepsSingleWordSeam() {
        // A single repeated word is genuinely ambiguous (the teacher may be
        // opening the next sentence with the previous one's keyword) — the
        // reference implementation deliberately keeps it.
        XCTAssertEqual(
            SpeechSegmenter.deduplicateOverlap(previous: "Привет мир", next: "мир как дела"),
            "мир как дела"
        )
    }

    func testDeduplicateOverlapFullDuplicate() {
        XCTAssertEqual(
            SpeechSegmenter.deduplicateOverlap(previous: "Привет мир", next: "Привет мир"),
            ""
        )
    }

    func testDeduplicateOverlapShortMatchIsKept() {
        // 3 shared characters: below the minimum overlap.
        XCTAssertEqual(
            SpeechSegmenter.deduplicateOverlap(previous: "дом", next: "дом"),
            "дом"
        )
    }

    func testDeduplicateOverlapNoMatchUnchanged() {
        XCTAssertEqual(
            SpeechSegmenter.deduplicateOverlap(previous: "Сегодня лекция", next: "про матрицы"),
            "про матрицы"
        )
    }

    func testDeduplicateOverlapPrefersLongestMatch() {
        // The longest exact seam wins, not a shorter prefix of it.
        XCTAssertEqual(
            SpeechSegmenter.deduplicateOverlap(previous: "abc дефг hij", next: "дефг hij xyz"),
            "xyz"
        )
    }

    func testDeduplicateOverlapIgnoresTailPunctuationAndCase() {
        // The committed tail's trailing punctuation never begins the next
        // recognition; matching itself is case-insensitive.
        XCTAssertEqual(
            SpeechSegmenter.deduplicateOverlap(previous: "Сегодня Большая Лекция.", next: "большая лекция продолжается"),
            "продолжается"
        )
    }

    // MARK: - Remainder retention after a split

    func testRemainderAfterSplitIsNotLost() {
        let segmenter = makeSegmenter()
        var segments: [SpeechSegment] = []
        // 12.5 s + valley + more speech, then stop *mid-speech* — the tail
        // must still surface via flush().
        segments += push(segmenter, voiced: true, windows: 390, amplitude: 0.5)
        segments += push(segmenter, voiced: true, windows: 4, amplitude: 0.05)
        segments += push(segmenter, voiced: true, windows: 100, amplitude: 0.5)
        segments += segmenter.flush()

        XCTAssertEqual(segments.count, 2,
                       "split head + flushed tail; no audio is dropped at the seam")
        let totalCovered = (segments[1].endOffset - segments[0].startOffset)
        XCTAssertGreaterThanOrEqual(totalCovered, 15.7,
                                     "all fed speech time is represented across the two segments")
    }
}
