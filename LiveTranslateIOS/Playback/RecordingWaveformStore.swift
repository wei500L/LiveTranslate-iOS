import Foundation
import OSLog

/// Precomputed waveform buckets for one classroom recording, derived from
/// the REAL audio data (never random bars). Computation runs on a
/// background task reading the WAV in bounded chunks — a two-hour file is
/// never parsed on the main thread. The result caches next to the audio
/// file; the row only carries the status.
@MainActor
@Observable
final class RecordingWaveformStore {
    private static let logger = Logger(
        subsystem: "com.livetranslate.ios", category: "waveform"
    )

    /// Downsampled peaks: each bucket = max(abs(sample)) over its window,
    /// in [0, 1]. Roughly one bucket per second of audio.
    static let bucketsPerSecond = 1.0
    /// How many samples one read step pulls (keeps memory bounded on
    /// two-hour files: 64 k samples = 256 KB per step).
    private static let readSampleChunk = 65_536
    /// Waveform files older than this are pruned with the recording.
    static let waveformFileExtension = "wfm"

    // MARK: - Observable state

    /// Buckets of the recording last requested (nil until generated).
    private(set) var buckets: [Float] = []
    private(set) var isGenerating = false
    /// The session whose waveform is held in `buckets`.
    private(set) var loadedSessionID: UUID?

    private var tasks: [UUID: Task<Void, Never>] = [:]

    // MARK: - Access

    /// Cached-file URL next to the recording (session-local — never
    /// synced, deleted with the session directory).
    private static func cacheURL(sessionID: UUID) -> URL {
        SessionRecordings.directory(for: sessionID)
            .appendingPathComponent("waveform.\(waveformFileExtension)")
    }

    /// Returns the buckets for a recording: cached file when present,
    /// otherwise empty (the caller may then start a generation).
    func waveform(for recording: SessionRecording) -> [Float] {
        guard !recording.isDeleted else { return [] }
        if loadedSessionID == recording.sessionID, !buckets.isEmpty {
            return buckets
        }
        guard let cached = Self.readCache(sessionID: recording.sessionID) else {
            return []
        }
        loadedSessionID = recording.sessionID
        buckets = cached
        return cached
    }

    /// Kicks off (or returns) the background computation. Idempotent per
    /// session; progress lands in `buckets` when done. Only the waveform
    /// status column changes — duration/completion stay untouched.
    func generateIfNeeded(for recording: SessionRecording, repository: any ClassroomRepositoryProtocol) {
        guard !recording.isDeleted else { return }
        let sessionID = recording.sessionID
        guard tasks[sessionID] == nil else { return }
        guard waveform(for: recording).isEmpty else { return }
        isGenerating = true
        try? repository.updateRecordingWaveformStatus(recording, status: .generating)
        let url = SessionRecordings.fileURL(for: recording)
        tasks[sessionID] = Task.detached(priority: .utility) { [weak self] in
            let computed = await Self.computeBuckets(url: url)
            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                self.tasks[sessionID] = nil
                self.isGenerating = false
                guard let computed, !computed.isEmpty else {
                    try? repository.updateRecordingWaveformStatus(recording, status: .failed)
                    return
                }
                Self.writeCache(sessionID: sessionID, buckets: computed)
                try? repository.updateRecordingWaveformStatus(recording, status: .generated)
                if self.loadedSessionID == sessionID || self.loadedSessionID == nil {
                    self.loadedSessionID = sessionID
                    self.buckets = computed
                }
            }
        }
    }

    // MARK: - WAV parsing (background)

    /// Reads the WAV once, downsampling to per-second peaks. Tolerates the
    /// zero-sized RIFF header of interrupted files (trusts the file
    /// length). Returns nil on any structural failure — the player falls
    /// back to the plain progress bar.
    static func computeBuckets(url: URL) async -> [Float]? {
        let result = Task.detached(priority: .utility) { () -> [Float]? in
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            let total = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0
            guard total > 44 else { return nil }
            guard let header = try? handle.read(upToCount: 44), header.count == 44 else { return nil }
            // Validate "RIFF"/"WAVE" magic; data size may be 0 (interrupted
            // write) — the real byte count is total − header.
            let magic = String(data: header.prefix(4), encoding: .ascii)
            guard magic == "RIFF" else { return nil }
            let dataBytes = total - 44
            let bytesPerFrame = 2 // 16-bit mono (our writer's layout)
            let sampleRate = 16_000
            let frames = Int(dataBytes) / bytesPerFrame
            guard frames > 0 else { return nil }

            let bucketFrames = Int(Double(sampleRate) / bucketsPerSecond)
            let bucketCount = frames / bucketFrames + 1
            var buckets = [Float](repeating: 0, count: bucketCount)
            var frameIndex = 0
            var leftover: [Int16] = []
            while frameIndex < frames {
                let chunk = (try? handle.read(upToCount: readSampleChunk * 2)) ?? Data()
                guard !chunk.isEmpty else { break }
                chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    let samples = raw.bindMemory(to: Int16.self)
                    var window: [Int16] = leftover
                    window.append(contentsOf: samples)
                    var consumed = 0
                    while window.count - consumed >= bucketFrames {
                        var peak: Float = 0
                        for i in consumed..<(consumed + bucketFrames) {
                            let magnitude = abs(Float(Int16(littleEndian: window[i])) / 32_768)
                            if magnitude > peak { peak = magnitude }
                        }
                        let bucket = frameIndex / bucketFrames
                        if bucket < buckets.count {
                            buckets[bucket] = max(buckets[bucket], peak)
                        }
                        frameIndex += bucketFrames
                        consumed += bucketFrames
                    }
                    leftover = Array(window[(window.count - min(window.count - consumed, bucketFrames))...])
                }
            }
            return Array(buckets.prefix(max(1, frames / bucketFrames)))
        }
        return await result.value
    }

    // MARK: - Cache

    private static func readCache(sessionID: UUID) -> [Float]? {
        let url = cacheURL(sessionID: sessionID)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        // Layout: Int32 count + count × Float32 (little-endian, host order
        // for simplicity — the cache is device-local and disposable).
        let count = data.withUnsafeBytes { $0.load(as: Int32.self) }
        guard count > 0, data.count >= 4 + Int(count) * 4 else { return nil }
        return data.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: 4)
                .assumingMemoryBound(to: Float.self)
            return Array(UnsafeBufferPointer(start: base, count: Int(count)))
        }
    }

    private static func writeCache(sessionID: UUID, buckets: [Float]) {
        var data = withUnsafeBytes(of: Int32(buckets.count)) { Data($0) }
        buckets.withUnsafeBytes { raw in
            data.append(Data(raw))
        }
        try? data.write(to: cacheURL(sessionID: sessionID), options: .atomic)
    }
}
