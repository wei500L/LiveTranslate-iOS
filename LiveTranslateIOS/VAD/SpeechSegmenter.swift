import Foundation
import OSLog

/// The product's VAD segmentation policy, in pure Swift over
/// (window, isSpeech) ticks so it is fully unit-testable.
///
/// Policy (from the product spec):
/// - Speech shorter than `minSpeechSeconds` (250 ms) is discarded.
/// - A segment closes after `silenceEndSeconds` (600 ms) of silence,
///   keeping only `postRollSeconds` (200 ms) of trailing silence.
/// - `preRollSeconds` (300 ms) of audio *before* speech onset is included
///   so leading consonants survive the VAD's trigger latency.
/// - Once a segment exceeds `forcedSplitStartSeconds` (12 s) of continuous
///   speech, the segmenter starts looking for a low-energy valley to split
///   at; it waits at most `maxWaitForBoundarySeconds` (3 s) for a good one.
/// - At `hardMaxSeconds` (20 s) the segment is split regardless, at the
///   best valley or failing that, hard. `absoluteMaxSeconds` (25 s) is a
///   defense-in-depth cap that can never be exceeded.
/// - Forced splits overlap by `forcedSplitOverlapSeconds` (300 ms): the
///   *next* segment starts 300 ms before the cut, so words spanning the
///   boundary are fully audible to ASR in both segments. Text-level
///   deduplication (conservative, see `deduplicateOverlap`) removes the
///   resulting duplication without eating legitimate teacher repetitions.
///
/// Segments shorter than 2 s are still emitted when they are real speech
/// (≥ 250 ms) — a short classroom interjection is content, not noise. The
/// 2–12 s range in the spec is the design operating range, not a floor.
final class SpeechSegmenter: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.livetranslate.ios", category: "segmenter")

    struct Parameters: Sendable {
        var sampleRate: Int = 16_000
        var windowSamples: Int = 512
        var minSpeechSeconds: TimeInterval = 0.25
        var silenceEndSeconds: TimeInterval = 0.6
        var preRollSeconds: TimeInterval = 0.3
        var postRollSeconds: TimeInterval = 0.2
        var forcedSplitStartSeconds: TimeInterval = 12
        var maxWaitForBoundarySeconds: TimeInterval = 3
        var hardMaxSeconds: TimeInterval = 20
        var absoluteMaxSeconds: TimeInterval = 25
        var forcedSplitOverlapSeconds: TimeInterval = 0.3
        /// Smoothed-energy window for valley search (~160 ms).
        var valleySmoothWindows = 5
        /// A valley must dip below this fraction of the local average.
        var valleyDipRatio: Double = 0.8
    }

    private struct Window {
        let samples: [Float]
        let energy: Float
        let voiced: Bool
        let absoluteStart: Int
    }

    let parameters: Parameters
    private var nextSequenceID: Int
    private var absoluteSampleIndex = 0

    private var preRoll: [Window] = []
    private var speech: [Window] = []
    private var inSpeech = false
    private var silenceWindows = 0
    /// True once the current segment has passed the forced-split threshold.
    private var huntingBoundary = false

    private let lock = NSLock()

    init(parameters: Parameters = Parameters(), firstSequenceID: Int = 0) {
        self.parameters = parameters
        self.nextSequenceID = firstSequenceID
    }

    // Derived window counts

    private var samplesPerSecond: Double { Double(parameters.sampleRate) }

    private func windowCount(forSeconds seconds: TimeInterval) -> Int {
        let windowDuration = Double(parameters.windowSamples) / samplesPerSecond
        return max(1, Int((seconds / windowDuration).rounded()))
    }

    private var speechSamples: Int { speech.reduce(0) { $0 + $1.samples.count } }
    private var voicedSamples: Int { speech.filter(\.voiced).reduce(0) { $0 + $1.samples.count } }
    private var speechSeconds: Double { Double(speechSamples) / samplesPerSecond }

    // MARK: - Feeding

    /// Feed one window with its VAD verdict. Returns any segments that
    /// closed as a result.
    func push(window: ArraySlice<Float>, isSpeech: Bool) -> [SpeechSegment] {
        let samples = Array(window)
        precondition(samples.count == parameters.windowSamples,
                     "windows must be \(parameters.windowSamples) samples")
        lock.lock(); defer { lock.unlock() }

        let windowStart = absoluteSampleIndex
        absoluteSampleIndex += samples.count
        let energy = AudioResampler.rms(samples)
        let entry = Window(samples: samples, energy: energy, voiced: isSpeech, absoluteStart: windowStart)

        guard inSpeech else {
            if isSpeech {
                // Speech onset: prepend the pre-roll ring so onsets keep
                // their leading consonants. Pre-roll windows count as
                // unvoiced padding.
                speech.append(contentsOf: preRoll)
                preRoll.removeAll()
                speech.append(entry)
                inSpeech = true
                silenceWindows = 0
                huntingBoundary = false
            } else {
                preRoll.append(entry)
                let maxPreRoll = windowCount(forSeconds: parameters.preRollSeconds)
                if preRoll.count > maxPreRoll {
                    preRoll.removeFirst(preRoll.count - maxPreRoll)
                }
            }
            return []
        }

        speech.append(entry)
        silenceWindows = isSpeech ? 0 : silenceWindows + 1

        // Defense in depth: nothing ever exceeds the absolute cap.
        if speechSeconds >= parameters.absoluteMaxSeconds {
            return splitCurrent(atWindow: speech.count, forced: true)
        }

        // Hard maximum: split now, at the best valley or hard at the end.
        if speechSeconds >= parameters.hardMaxSeconds {
            return splitCurrent(atWindow: atBestValleyOrEnd(), forced: true)
        }

        // Continuous speech: once past the forced-split threshold, hunt a
        // natural boundary — the teacher speaking without pause must never
        // make the segmenter wait forever for silence.
        if speechSeconds >= parameters.forcedSplitStartSeconds {
            huntingBoundary = true
        }

        if huntingBoundary {
            let waitDeadline = parameters.forcedSplitStartSeconds + parameters.maxWaitForBoundarySeconds
            // A genuine dip in smoothed energy is a natural boundary.
            if let index = bestValleyIndex(), isGoodValley(at: index) {
                return splitCurrent(atWindow: index, forced: true)
            }
            // Waited long enough without a boundary: take the best we have.
            if speechSeconds >= waitDeadline {
                return splitCurrent(atWindow: bestValleyIndex() ?? speech.count, forced: true)
            }
        }

        // Natural close: enough trailing silence.
        if silenceWindows >= windowCount(forSeconds: parameters.silenceEndSeconds) {
            return closeOnSilence()
        }

        return []
    }

    /// Close the current segment on trailing silence, keeping only the
    /// post-roll tail of it.
    private func closeOnSilence() -> [SpeechSegment] {
        // Keep postRollSeconds of the accumulated silence, drop the rest.
        let keepSilence = windowCount(forSeconds: parameters.postRollSeconds)
        let trailingSilence = min(silenceWindows, speech.count)
        let dropSilence = max(0, trailingSilence - keepSilence)
        if dropSilence > 0 {
            speech.removeLast(dropSilence)
        }
        return emitIfValid()
    }

    /// Split the current buffer at window index `index`; emit the head and
    /// keep the tail. The tail starts `forcedSplitOverlapSeconds` *before*
    /// the cut so words spanning the boundary are fully present in both
    /// segments (text-level dedup removes the repetition later).
    private func splitCurrent(atWindow index: Int, forced: Bool) -> [SpeechSegment] {
        let overlapWindows = windowCount(forSeconds: parameters.forcedSplitOverlapSeconds)
        let clamped = max(overlapWindows + 1, min(index, speech.count - 1))
        guard clamped > 0, clamped < speech.count else {
            return emitIfValid()
        }

        let head = Array(speech[0..<clamped])
        let tailStart = max(0, clamped - overlapWindows)
        let tail = Array(speech[tailStart...])

        var segments: [SpeechSegment] = []
        let headVoiced = head.filter(\.voiced).reduce(0) { $0 + $1.samples.count }
        if Double(headVoiced) / samplesPerSecond >= parameters.minSpeechSeconds {
            segments.append(makeSegment(windows: head))
        }

        // Keep the tail for continued accumulation.
        speech = tail
        silenceWindows = 0
        huntingBoundary = speechSeconds >= parameters.forcedSplitStartSeconds
        return segments
    }

    private func emitIfValid() -> [SpeechSegment] {
        defer { resetSpeechState() }
        guard voicedSeconds() >= parameters.minSpeechSeconds else {
            // Mostly-silence buffer: discard entirely.
            return []
        }
        return [makeSegment(windows: speech)]
    }

    private func voicedSeconds() -> Double {
        Double(voicedSamples) / samplesPerSecond
    }

    private func makeSegment(windows: [Window]) -> SpeechSegment {
        let totalSamples = windows.reduce(0) { $0 + $1.samples.count }
        var samples = [Float]()
        samples.reserveCapacity(totalSamples)
        for window in windows {
            samples.append(contentsOf: window.samples)
        }
        let start = windows.first?.absoluteStart ?? 0
        let segment = SpeechSegment(
            sequenceID: nextSequenceID,
            samples: samples,
            sampleRate: parameters.sampleRate,
            startOffset: Double(start) / samplesPerSecond,
            endOffset: Double(start + totalSamples) / samplesPerSecond
        )
        nextSequenceID += 1
        return segment
    }

    private func resetSpeechState() {
        speech = []
        inSpeech = false
        silenceWindows = 0
        huntingBoundary = false
    }

    // MARK: - Valley search

    /// Smoothed energy per window (sliding average of `valleySmoothWindows`).
    private func smoothedEnergies() -> [Double] {
        let energies = speech.map { Double($0.energy) }
        let width = max(1, parameters.valleySmoothWindows)
        var smoothed: [Double] = []
        smoothed.reserveCapacity(energies.count)
        for i in 0..<energies.count {
            let lo = max(0, i - width / 2)
            let hi = min(energies.count, i + width / 2 + 1)
            let slice = energies[lo..<hi]
            smoothed.append(slice.reduce(0, +) / Double(slice.count))
        }
        return smoothed
    }

    /// Global minimum of the smoothed curve over the latter 70% of the
    /// buffer (never split in the opening — the head must stay substantial).
    private func bestValleyIndex() -> Int? {
        let smoothed = smoothedEnergies()
        let n = smoothed.count
        guard n >= 4 else { return nil }
        let searchStart = max(1, n * 3 / 10)
        var bestIndex: Int?
        var bestValue = Double.greatestFiniteMagnitude
        for i in searchStart..<n where smoothed[i] <= bestValue {
            bestValue = smoothed[i]
            bestIndex = i
        }
        return bestIndex
    }

    private func isGoodValley(at index: Int) -> Bool {
        let smoothed = smoothedEnergies()
        guard index < smoothed.count else { return false }
        let searchStart = max(1, smoothed.count * 3 / 10)
        let searchSlice = smoothed[searchStart...]
        guard !searchSlice.isEmpty else { return false }
        let average = searchSlice.reduce(0, +) / Double(searchSlice.count)
        let value = smoothed[index]
        return value <= average * parameters.valleyDipRatio
    }

    private func atBestValleyOrEnd() -> Int {
        bestValleyIndex() ?? speech.count
    }

    // MARK: - Flush

    /// Emit the pending tail when the classroom stops (only if it holds
    /// enough real speech).
    func flush() -> [SpeechSegment] {
        lock.lock(); defer { lock.unlock() }
        guard inSpeech else { return [] }
        return emitIfValid()
    }

    /// Total windows fed — lets the coordinator sanity-check offsets.
    var fedSamples: Int {
        lock.lock(); defer { lock.unlock() }
        return absoluteSampleIndex
    }

    // MARK: - Overlap dedup (text level)

    /// Conservative removal of duplicated text at a forced-split boundary.
    ///
    /// A forced split repeats 300 ms of audio in the next segment, so ASR
    /// may repeat the tail of the previous utterance at the head of the
    /// next. Following the reference implementation
    /// (`_strip_committed_overlap` in the desktop project):
    ///
    /// - matching is case-insensitive, and the previous tail is matched with
    ///   trailing punctuation/whitespace removed;
    /// - only the *longest* exact match is considered;
    /// - an overlap only counts when it **spans a word boundary** — a single
    ///   repeated word is genuinely ambiguous (a teacher opening the next
    ///   sentence with the previous one's keyword), and deleting a real word
    ///   is unrecoverable while a duplicated one is easy to read past.
    ///
    /// This is a Russian-classroom app; the reference's unspaced-script
    /// (Han/kana) branch has no Cyrillic analogue and is not ported.
    static func deduplicateOverlap(previous: String, next: String, minOverlap: Int = 3) -> String {
        guard !previous.isEmpty, !next.isEmpty else { return next }

        // Committed text may end in punctuation that never begins the next
        // recognition — strip it from the tail before matching.
        var tail = previous
        while let last = tail.unicodeScalars.last, Self.echoBoundary.contains(last) {
            tail.unicodeScalars.removeLast()
        }
        guard !tail.isEmpty else { return next }

        let loweredTail = Array(tail.lowercased())
        let loweredNext = Array(next.lowercased())
        // lowercased() can change the Character count in exotic locales;
        // the index math below assumes it did not.
        guard loweredNext.count == Array(next).count else { return next }

        let maxCheck = min(loweredTail.count, loweredNext.count)
        guard maxCheck >= minOverlap else { return next }

        for length in stride(from: maxCheck, through: minOverlap, by: -1) {
            let head = String(loweredNext[..<length])
            guard head == String(loweredTail[(loweredTail.count - length)...]) else { continue }
            // Longest match found; every shorter one is its prefix, so if
            // this one is not substantial none of them are.
            let trimmedHead = head.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedHead.contains(" ") || trimmedHead.contains("\t") else { return next }
            return String(next.dropFirst(length))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return next
    }

    /// Punctuation and spacing that ends a committed sentence but never
    /// begins the next recognition (mirrors `_ECHO_BOUNDARY`).
    private static let echoBoundary = CharacterSet(charactersIn: " \t\n。．.!！?？,，、;；:：\"'）)》」』…")
}
