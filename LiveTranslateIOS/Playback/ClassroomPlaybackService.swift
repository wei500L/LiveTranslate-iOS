import Foundation
import AVFoundation
import OSLog

/// Playback state of one classroom recording, derived from real
/// AVAudioPlayer events — the UI never hardcodes "playing".
enum RecordingPlaybackPhase: Equatable, Sendable {
    case idle
    case loading
    case playing
    case paused
    /// The audio session was interrupted (call/Siri); playback stopped
    /// and the position is kept for an explicit resume.
    case interrupted
    /// The file could not be opened (missing, corrupt or truncated).
    case failed(String)
}

/// Speed options for classroom re-listening. Speech stays intelligible
/// across all of them; no pitch/equalizer processing.
enum PlaybackSpeed: Double, CaseIterable, Sendable, Identifiable {
    case x075 = 0.75
    case x100 = 1.0
    case x125 = 1.25
    case x150 = 1.5
    case x200 = 2.0

    var id: Double { rawValue }

    var label: String {
        switch self {
        case .x075: return "0.75×"
        case .x100: return "1×"
        case .x125: return "1.25×"
        case .x150: return "1.5×"
        case .x200: return "2×"
        }
    }
}

/// One local classroom recording's playback engine. AVFoundation is fully
/// encapsulated here — SwiftUI views talk to this service only. One
/// service instance per app (owned by the composition root) so account
/// switches and new live classes can stop the CURRENT playback from one
/// place; loading a different session replaces the loaded player.
@MainActor
@Observable
final class ClassroomPlaybackService {
    private static let logger = Logger(
        subsystem: "com.livetranslate.ios", category: "playback"
    )

    // MARK: - Observable state

    private(set) var phase: RecordingPlaybackPhase = .idle
    /// The session whose recording is loaded (nil when idle).
    private(set) var sessionID: UUID?
    private(set) var currentTime: TimeInterval = 0
    private(set) var totalDuration: TimeInterval = 0
    private(set) var speed: PlaybackSpeed = .x100
    /// True when the loaded file was flagged incomplete at load time
    /// (abnormal class end) — the UI may play but shows an honest hint.
    private(set) var isLoadedFileIncomplete = false

    // MARK: - Internals

    private var player: AVAudioPlayer?
    private var tickTimer: Timer?
    /// Guards replay of a completed session (an automatic restart would
    /// look like a loop bug).
    private var finishedPlayback = false

    // MARK: - Interruption handling

    private var interruptionTask: Task<Void, Never>?

    init() {
        // Reuse the capture service's interruption handler stream (route
        // changes matter for playback too — e.g. AirPods reconnect).
        interruptionTask = Task { [weak self] in
            let events = AudioInterruptionHandler().start()
            for await event in events {
                guard !Task.isCancelled else { break }
                self?.handleInterruption(event)
            }
        }
    }

    deinit {
        interruptionTask?.cancel()
    }

    private func handleInterruption(_ event: AudioInterruptionEvent) {
        switch event {
        case .interruptionBegan:
            // Playback pauses for the interruption; the position survives
            // for the user's explicit resume.
            pause()
            if phase == .paused { phase = .interrupted }
        case .interruptionEnded, .routeChanged, .mediaServicesReset:
            // Never auto-resume: the user decides (honest state, no sound
            // appearing out of nowhere after a phone call).
            break
        }
    }

    // MARK: - Loading

    /// Loads a session's recording from its metadata row. The file is
    /// resolved through `SessionRecordings` (never a view-built path).
    /// AVAudioPlayer tolerates the zero-sized RIFF header of an
    /// interrupted file by trusting the actual file length; a file that
    /// fails to open lands in `.failed` — text records are unaffected.
    func load(recording: SessionRecording) {
        stopInternal()
        sessionID = recording.sessionID
        isLoadedFileIncomplete = !recording.isComplete
        let url = SessionRecordings.fileURL(for: recording)
        guard FileManager.default.fileExists(atPath: url.path) else {
            phase = .failed("录音文件不存在，课堂文字记录不受影响。")
            return
        }
        do {
            // Playback must not steal the record category from a possible
            // live classroom — and must work when no classroom is running.
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .spokenAudio)
            try audioSession.setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            self.player = player
            player.delegate = PlaybackDelegate.shared
            PlaybackDelegate.shared.owner = self
            player.enableRate = true
            player.rate = Float(speed.rawValue)
            totalDuration = max(0, player.duration)
            // An incomplete file's declared duration may exceed the bytes
            // actually on disk; AVAudioPlayer reports what it can decode —
            // trust its number over the metadata row.
            currentTime = 0
            finishedPlayback = false
            phase = .paused
            Self.logger.info(
                "recording loaded: \(recording.sessionID.uuidString, privacy: .public) \(self.totalDuration, privacy: .public)s"
            )
        } catch {
            phase = .failed("无法播放录音（文件可能已损坏）。课堂文字记录不受影响。")
            Self.logger.error(
                "recording load failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// Unloads and returns to idle (leaving the playback screen).
    func unload() {
        stopInternal()
        sessionID = nil
        isLoadedFileIncomplete = false
        phase = .idle
    }

    private func stopInternal() {
        tickTimer?.invalidate()
        tickTimer = nil
        player?.stop()
        player = nil
        currentTime = 0
        totalDuration = 0
        finishedPlayback = false
        if PlaybackDelegate.shared.owner === self {
            PlaybackDelegate.shared.owner = nil
        }
    }

    // MARK: - Transport

    func play() {
        guard let player else { return }
        guard phase == .paused || phase == .interrupted else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // The session being unavailable (another app owns recording)
            // surfaces as a failure — never silent.
            phase = .failed("暂时无法开始播放：\(error.localizedDescription)")
            return
        }
        if finishedPlayback {
            player.currentTime = 0
            finishedPlayback = false
        }
        player.rate = Float(speed.rawValue)
        player.play()
        phase = .playing
        startTicking()
    }

    func pause() {
        guard let player, phase == .playing else { return }
        player.pause()
        currentTime = player.currentTime
        phase = .paused
        tickTimer?.invalidate()
        tickTimer = nil
    }

    func togglePlayPause() {
        switch phase {
        case .playing: pause()
        case .paused, .interrupted: play()
        default: break
        }
    }

    /// Seek to an absolute position (clamped to [0, duration]; the
    /// 1–2 s pre-roll context is the caller's choice — never negative).
    func seek(to target: TimeInterval) {
        guard let player else { return }
        let clamped = min(max(0, target), max(0, totalDuration - 0.05))
        player.currentTime = clamped
        currentTime = clamped
        finishedPlayback = false
    }

    func skip(by delta: TimeInterval) {
        guard let player else { return }
        seek(to: player.currentTime + delta)
    }

    func setSpeed(_ newSpeed: PlaybackSpeed) {
        speed = newSpeed
        player?.rate = Float(newSpeed.rawValue)
    }

    /// Stops playback entirely (a new live classroom is starting, an
    /// account switch happened, or the recording was deleted mid-play).
    func stop() {
        stopInternal()
        sessionID = nil
        isLoadedFileIncomplete = false
        phase = .idle
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )
    }

    // MARK: - Progress ticking

    private func startTicking() {
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let player = self.player, self.phase == .playing else { return }
                self.currentTime = player.currentTime
            }
        }
    }

    /// Called by the shared delegate on playback completion.
    private func handlePlaybackEnded() {
        guard let player else { return }
        currentTime = player.duration
        finishedPlayback = true
        phase = .paused
        tickTimer?.invalidate()
        tickTimer = nil
    }

    /// The shared delegate's MainActor hop target (kept internal).
    fileprivate func playbackEnded() {
        handlePlaybackEnded()
    }
}

/// One shared delegate object (AVAudioPlayer's delegate is not
/// per-instance retainable the way closures are; a single owner pointer
/// keeps it simple — only one playback service exists per app).
/// @unchecked Sendable: the only mutable state (`owner`) is MainActor-
/// isolated, and the delegate callbacks hop to the main actor themselves.
private final class PlaybackDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    static let shared = PlaybackDelegate()
    @MainActor weak var owner: ClassroomPlaybackService?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let ended = flag
        Task { @MainActor [weak self] in
            guard let owner = self?.owner else { return }
            if ended {
                owner.playbackEnded()
            } else {
                // A decode failure mid-file: the position is kept, the
                // state is honest, the text records are untouched.
                owner.pause()
            }
        }
    }
}
