import Foundation
import AVFoundation
import OSLog

/// One 512-sample block of 16 kHz mono Float32 audio (≈32 ms) plus its
/// lightweight level measurement. The unit the whole downstream pipeline
/// consumes.
struct AudioChunk: Sendable, Equatable {
    /// Exactly 512 samples in [-1, 1] except possibly the final chunk of a
    /// session.
    let samples: [Float]
    let rms: Float

    static let sampleCount = 512
    static let sampleRate = 16_000
}

/// Capture health as observed by the UI.
enum CaptureState: Sendable, Equatable {
    case idle
    case requestingPermission
    case running
    /// Interruption began (call/Siri) and has not ended yet.
    case interrupted
    /// Pipeline is being rebuilt after an interruption/route change/watchdog.
    case recovering
    /// Unrecoverable — user action required. Never claim "listening" here.
    case failed(String)

    var isDeliveringAudio: Bool { self == .running }
}

/// Microphone capture producing 16 kHz mono Float32 512-sample chunks.
///
/// Architecture:
/// - The AVAudioEngine tap callback runs on a private queue and does *only*:
///   convert to the target format, then one bounded, drop-oldest append into
///   `AudioRingBuffer` (plus a timestamp the watchdog reads). No inference,
///   no network, no SwiftData, no main-thread hops.
/// - A pump task drains the ring and emits fixed 512-sample chunks.
/// - Interruptions, route changes and a no-data watchdog all funnel into the
///   same 10-step recovery sequence; if no audio arrives within the timeout
///   the service reports `.failed` — it never pretends to be listening.
@MainActor
@Observable
final class AudioCaptureService {
    private static let logger = Logger(
        subsystem: "com.livetranslate.ios", category: "audio-capture"
    )

    // MARK: - Observable state

    private(set) var state: CaptureState = .idle
    /// e.g. "iPhone microphone", "AirPods" — updated on route changes.
    private(set) var inputRouteDescription: String = ""
    private(set) var droppedChunkCount = 0
    /// Elapsed seconds since the last delivered audio, while running.
    private(set) var secondsSinceLastAudio: TimeInterval = 0

    // MARK: - Configuration

    static let targetSampleRate = 16_000
    static let chunkSamples = 512
    /// Ring capacity: 10 s of 16 kHz audio.
    static let ringCapacity = 160_000
    /// Tap stopped delivering for this long → rebuild (spec: 3 s).
    static let watchdogTimeout: TimeInterval = 3.0
    /// Wait this long for the first buffer after (re)starting the engine.
    static let firstBufferTimeout: TimeInterval = 3.0
    /// Give up recovery after this many consecutive failed rebuilds.
    static let maxRecoveryAttempts = 3

    // MARK: - Internals

    private let ring = AudioRingBuffer(capacitySamples: ringCapacity)
    private let interruptionHandler = AudioInterruptionHandler()
    private var engine = AVAudioEngine()
    /// Tap-thread-only state. Rebuilt on every (re)install.
    private var bridge: TapBridge?
    private var chunkContinuation: AsyncStream<AudioChunk>.Continuation?
    private var pumpTask: Task<Void, Never>?
    private var interruptionTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var recoveryAttempts = 0
    private var isRecovering = false

    // MARK: - Permission

    nonisolated static func recordPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    // MARK: - Lifecycle

    /// Activate the session, install the tap and start delivering chunks.
    /// Returns the chunk stream; it finishes when the service stops.
    func start() async throws -> AsyncStream<AudioChunk> {
        guard state != .running, state != .recovering else {
            throw NSError(
                domain: "AudioCaptureService", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Capture is already running."]
            )
        }

        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            break
        case .undetermined:
            state = .requestingPermission
            guard await Self.recordPermission() else {
                state = .failed(String(localized: "Microphone permission denied."))
                throw NSError(
                    domain: "AudioCaptureService", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied."]
                )
            }
        case .denied:
            state = .failed(String(localized: "Microphone permission denied. Enable it in Settings."))
            throw NSError(
                domain: "AudioCaptureService", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied."]
            )
        @unknown default:
            break
        }

        let stream = AsyncStream<AudioChunk>(bufferingPolicy: .bufferingNewest(600)) { continuation in
            self.chunkContinuation = continuation
        }
        ring.removeAll()
        recoveryAttempts = 0

        try buildAndStartPipeline()

        pumpTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.pumpLoop()
        }
        interruptionTask = Task { [weak self] in
            await self?.interruptionLoop()
        }
        watchdogTask = Task { [weak self] in
            await self?.watchdogLoop()
        }

        // Step 9 of the recovery contract: wait for the first real PCM data.
        let gotAudio = await waitForFirstBuffer(timeout: Self.firstBufferTimeout)
        if gotAudio {
            state = .running
            Self.logger.info("Capture running: \(self.inputRouteDescription, privacy: .public)")
        } else {
            // Step 10: report the failure — never claim to be listening.
            let message = String(localized: "No audio arrived from the microphone within 3 s.")
            Self.logger.error("\(message, privacy: .public)")
            state = .failed(message)
            await stop()
            throw NSError(
                domain: "AudioCaptureService", code: 3,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
        return stream
    }

    func stop() async {
        pumpTask?.cancel()
        pumpTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        interruptionTask?.cancel()
        interruptionTask = nil
        interruptionHandler.stop()
        teardownPipeline()
        chunkContinuation?.finish()
        chunkContinuation = nil
        state = .idle
        Self.logger.info("Capture stopped")
    }

    // MARK: - Pipeline construction (the 10-step recovery sequence)

    /// Steps 1–8: stop engine, remove tap, reactivate session, re-read input
    /// format, rebuild converter, reinstall tap, prepare, start.
    private func buildAndStartPipeline() throws {
        // 1. Stop the engine (no-op when already stopped).
        engine.stop()
        // 2. Remove the old tap (removeTap is safe without an installed tap).
        engine.inputNode.removeTap(onBus: 0)

        // 3. (Re)activate the audio session.
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord, mode: .voiceChat,
            options: [.allowBluetoothHFP, .defaultToSpeaker]
        )
        try session.setPreferredSampleRate(Double(Self.targetSampleRate))
        try session.setPreferredIOBufferDuration(0.032)
        try session.setActive(true)

        // 4. Re-read the *actual* input format — never assume 16 kHz.
        let inputFormat = engine.inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(
                domain: "AudioCaptureService", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Input format is invalid (rate \(inputFormat.sampleRate), channels \(inputFormat.channelCount))."]
            )
        }
        updateRouteDescription()

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(Self.targetSampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(
                domain: "AudioCaptureService", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Could not create 16 kHz mono output format."]
            )
        }

        // 5. Rebuild the converter (fresh state — old converter may hold
        // stale rate-conversion leftovers from the previous route).
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw NSError(
                domain: "AudioCaptureService", code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Could not create the audio format converter."]
            )
        }
        let bridge = TapBridge(converter: converter, inputFormat: inputFormat, outputFormat: outputFormat, ring: ring)
        self.bridge = bridge

        // 6. Reinstall the tap. The closure captures only the Sendable bridge.
        let inputNode = engine.inputNode
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            bridge.process(buffer)
        }

        // 7. Prepare.
        engine.prepare()

        // 8. Start.
        try engine.start()
        Self.logger.info(
            "Pipeline started: \(inputFormat.sampleRate, privacy: .public) Hz, \(inputFormat.channelCount, privacy: .public) ch -> 16 kHz mono"
        )
    }

    /// Steps 1–10 with retry accounting and state transitions.
    private func recover(reason: String) async {
        guard !isRecovering, state != .idle else { return }
        isRecovering = true
        state = .recovering
        Self.logger.notice("Recovering capture: \(reason, privacy: .public)")

        do {
            try buildAndStartPipeline()
            if await waitForFirstBuffer(timeout: Self.firstBufferTimeout) {
                recoveryAttempts = 0
                state = .running
            } else {
                throw NSError(
                    domain: "AudioCaptureService", code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "No audio after recovery."]
                )
            }
        } catch {
            recoveryAttempts += 1
            Self.logger.error("Recovery attempt \(self.recoveryAttempts) failed: \(String(describing: error), privacy: .public)")
            if recoveryAttempts >= Self.maxRecoveryAttempts {
                state = .failed(String(localized: "Microphone recovery failed: \(error.localizedDescription)"))
            } else {
                // Back off briefly, then let the next watchdog tick retry.
                state = .interrupted
            }
        }
        isRecovering = false
    }

    private func teardownPipeline() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        bridge = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Poll the ring's last-append timestamp for up to `timeout`.
    private func waitForFirstBuffer(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let last = ring.lastAppendAt, Date().timeIntervalSince(last) < timeout {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return ring.lastAppendAt.map { Date().timeIntervalSince($0) < timeout } ?? false
    }

    // MARK: - Background loops

    /// Drain the ring and emit fixed-size chunks.
    private func pumpLoop() async {
        while !Task.isCancelled {
            let available = await ring.waitForData(timeout: 0.5)
            guard available > 0 else { continue }
            while !Task.isCancelled {
                guard let samples = ring.read(exactly: Self.chunkSamples) else { break }
                let chunk = AudioChunk(samples: samples, rms: AudioResampler.rms(samples))
                chunkContinuation?.yield(chunk)
            }
        }
    }

    /// React to system audio events.
    private func interruptionLoop() async {
        let events = interruptionHandler.start()
        for await event in events {
            guard !Task.isCancelled else { break }
            switch event {
            case .interruptionBegan:
                Self.logger.notice("Interruption began")
                engine.stop()
                state = .interrupted
            case .interruptionEnded(let shouldResume):
                Self.logger.notice("Interruption ended (resume: \(shouldResume, privacy: .public))")
                if shouldResume || state == .interrupted || state == .running {
                    await recover(reason: "interruption ended")
                }
            case .routeChanged(let reason):
                Self.logger.notice("Route changed: \(reason, privacy: .public)")
                updateRouteDescription()
                if state == .running || state == .recovering {
                    await recover(reason: "route change: \(reason)")
                }
            case .mediaServicesReset:
                Self.logger.notice("Media services reset")
                engine = AVAudioEngine()
                await recover(reason: "media services reset")
            }
        }
    }

    /// If the engine claims to run but the tap has gone silent (AirPods
    /// walking out of range, session weirdness), rebuild the pipeline.
    private func watchdogLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { break }
            guard state == .running, !isRecovering else { continue }
            if let last = ring.lastAppendAt {
                let age = Date().timeIntervalSince(last)
                secondsSinceLastAudio = age
                droppedChunkCount = ring.droppedSamples / Self.chunkSamples
                if age > Self.watchdogTimeout {
                    await recover(reason: "watchdog: no audio for \(Int(age))s")
                }
            } else {
                // No data has *ever* arrived — start() handles that via its
                // own first-buffer wait; here only react if we were running.
                if state == .running {
                    await recover(reason: "watchdog: no audio ever")
                }
            }
        }
    }

    private func updateRouteDescription() {
        let session = AVAudioSession.sharedInstance()
        let inputs = session.currentRoute.inputs
        inputRouteDescription = inputs.first?.portName ?? String(localized: "No input")
    }
}

// MARK: - Raw audio recording (opt-in)

/// Appendable 16 kHz mono WAV writer. The user must enable raw-audio saving
/// in Settings; by default nothing but text is ever persisted.
final class WAVFileWriter: @unchecked Sendable {
    private let fileHandle: FileHandle
    private let url: URL
    private let lock = NSLock()
    private var framesWritten = 0
    private let sampleRate: Int

    init(url: URL, sampleRate: Int = 16_000) throws {
        self.url = url
        self.sampleRate = sampleRate
        let header = Self.headerBytes(sampleRate: sampleRate, dataBytes: 0)
        try header.write(to: url)
        fileHandle = try FileHandle(forWritingTo: url)
        fileHandle.seekToEndOfFile()
    }

    /// Append mono Float32 samples ([-1, 1]).
    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var pcm = [Int16](repeating: 0, count: samples.count)
        for (i, sample) in samples.enumerated() {
            let clamped = max(-1.0, min(1.0, sample))
            pcm[i] = Int16(clamped * 32767.0)
        }
        pcm.withUnsafeBytes { raw in
            _ = try? fileHandle.write(contentsOf: Data(raw))
        }
        framesWritten += samples.count
    }

    /// Patch the RIFF sizes into the header and close.
    func finish() {
        lock.lock(); defer { lock.unlock() }
        let dataBytes = framesWritten * 2
        let sizes = Self.sizesBytes(dataBytes: dataBytes)
        try? fileHandle.seek(toOffset: 4)
        try? fileHandle.write(contentsOf: sizes.0)
        try? fileHandle.seek(toOffset: UInt64(Self.headerLength) - 4)
        try? fileHandle.write(contentsOf: sizes.1)
        try? fileHandle.close()
    }

    var bytesOnDisk: Int {
        44 + framesWritten * 2
    }

    static let headerLength = 44

    private static func headerBytes(sampleRate: Int, dataBytes: Int) -> Data {
        var data = Data()
        func append(_ string: String) { data.append(contentsOf: string.utf8) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        append("RIFF")
        append32(UInt32(36 + dataBytes))
        append("WAVE")
        append("fmt ")
        append32(16)                 // PCM chunk size
        append16(1)                  // format = PCM
        append16(1)                  // channels
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * 2))  // byte rate
        append16(2)                  // block align
        append16(16)                 // bits per sample
        append("data")
        append32(UInt32(dataBytes))
        return data
    }

    private static func sizesBytes(dataBytes: Int) -> (Data, Data) {
        var riff = Data()
        withUnsafeBytes(of: UInt32(36 + dataBytes).littleEndian) { riff.append(contentsOf: $0) }
        var dataSize = Data()
        withUnsafeBytes(of: UInt32(dataBytes).littleEndian) { dataSize.append(contentsOf: $0) }
        return (riff, dataSize)
    }
}

// MARK: - Tap-thread bridge

/// Everything the real-time tap callback touches. One instance per installed
/// tap; `process` is called only from the tap's queue.
private final class TapBridge: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let ring: AudioRingBuffer

    init(converter: AVAudioConverter, inputFormat: AVAudioFormat, outputFormat: AVAudioFormat, ring: AudioRingBuffer) {
        self.converter = converter
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.ring = ring
    }

    /// Convert one tap buffer to 16 kHz mono and append to the ring.
    /// This must stay allocation-light: convert, copy, append — nothing else.
    func process(_ buffer: AVAudioPCMBuffer) {
        let ratio = outputFormat.sampleRate / max(inputFormat.sampleRate, 1)
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return
        }

        var fedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: out, error: &conversionError) { [buffer] _, inputStatus in
            if fedInput {
                // The converter may ask again; it keeps leftovers internally.
                inputStatus.pointee = .noDataNow
                return nil
            }
            fedInput = true
            inputStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, conversionError == nil else { return }
        guard out.frameLength > 0, let channel = out.floatChannelData?[0] else { return }

        let samples = UnsafeBufferPointer(start: channel, count: Int(out.frameLength))
        ring.append(samples)
    }
}
