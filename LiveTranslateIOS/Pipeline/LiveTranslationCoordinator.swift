import Foundation
import Network
import OSLog

/// Orchestrates one live classroom session:
///
/// ```
/// AudioCaptureService → (VAD → SpeechSegmenter) → ASR (serial) →
///   persist Russian immediately → translation pool (2–3 concurrent) →
///   OrderedResultBuffer → persistence in sequenceID order
/// ```
///
/// Business rules inherited from the reference desktop project:
/// - ASR is strictly serial; translations run concurrently (bounded pool).
/// - The Russian original is persisted the moment ASR completes — a
///   translation failure can never lose it.
/// - Translations complete out of order; persistence follows utterance
///   order via `OrderedResultBuffer`, while the UI fills each entry as its
///   own translation lands.
/// - Retries: one immediate retry for transient failures (network, timeout,
///   429, 5xx); after that the entry is marked failed-but-retryable and
///   batch retry happens on network recovery or user action. 401/403/400
///   are never blindly retried.
/// One live transcript row as shown in the classroom feed (presentation
/// mirror of the pipeline's in-flight state; the persisted truth is
/// `TranscriptEntry`).
struct LiveTranscriptItem: Identifiable {
    let id = UUID()
    let sequenceID: Int
    let timestamp: String
    let startOffset: TimeInterval
    var originalText: String
    var translatedText: String?
    var translationStatus: TranslationStatus
    var asrLatency: TimeInterval = 0
    /// Translation failed with a retryable error — eligible for retry.
    var isRetryableTranslation = false
    /// Stable persisted `TranscriptEntry.id` (set once the Russian
    /// original is saved); nil only if that save itself failed. The UI
    /// uses it as the bookmark identity.
    var entryID: UUID?
}

@MainActor
@Observable
final class LiveTranslationCoordinator {
    private static let logger = Logger(subsystem: "com.livetranslate.ios", category: "coordinator")

    // MARK: - UI state

    private(set) var state = PipelineState()
    private(set) var entries: [LiveTranscriptItem] = []
    private(set) var isNetworkAvailable = true
    /// Rolling input-level history for the waveform, newest last, ~10 Hz,
    /// values clamped to [0, 1].
    private(set) var audioLevels: [Float] = []
    private static let levelHistoryCount = 64
    private(set) var isPaused = false

    // MARK: - Dependencies

    private let engineManager: ASREngineManager
    private let repository: (any ClassroomRepositoryProtocol)?
    /// MainActor-isolated provider (the coordinator only resolves it on the
    /// main actor), so it may read MainActor state such as the
    /// live-translation toggle.
    private let translationServiceProvider: @MainActor () -> (any TranslationService)?
    private let settings: SettingsStore

    // MARK: - Run state

    private var capture: AudioCaptureService?
    private var vad: SherpaSileroVAD?
    private var segmenter: SpeechSegmenter?
    private var wavWriter: WAVFileWriter?
    private var session: ClassroomSession?
    private var sessionStart = Date()
    private var pausedSeconds: TimeInterval = 0
    private var pauseStartedAt: Date?

    private var processingTask: Task<Void, Never>?
    private var asrTask: Task<Void, Never>?
    private var translationWorkers: [Task<Void, Never>] = []
    private var elapsedTimer: Task<Void, Never>?

    private var segmentContinuation: AsyncStream<SpeechSegment>.Continuation?
    private var translationContinuation: AsyncStream<PendingTranslation>.Continuation?

    private struct PendingTranslation: Sendable {
        let sequenceID: Int
        let attempt: Int
    }

    private var orderedTranslations = OrderedResultBuffer<TranslationOutcome>()
    private var history: [(source: String, translation: String)] = []
    private var lastEmittedSegment: (endOffset: TimeInterval, text: String)?
    private var entryIDBySequence: [Int: UUID] = [:]
    private let pauseFlag = AtomicFlag()
    private let pathMonitor = NWPathMonitor()

    init(
        engineManager: ASREngineManager,
        repository: (any ClassroomRepositoryProtocol)? = nil,
        settings: SettingsStore,
        translationServiceProvider: @escaping @MainActor () -> (any TranslationService)?
    ) {
        self.engineManager = engineManager
        self.repository = repository
        self.settings = settings
        self.translationServiceProvider = translationServiceProvider
        startNetworkMonitoring()
    }

    deinit {
        pathMonitor.cancel()
    }

    /// Append one waveform sample, trimming to the rolling window.
    private func appendLevel(_ level: Float) {
        audioLevels.append(level)
        if audioLevels.count > Self.levelHistoryCount {
            audioLevels.removeFirst(audioLevels.count - Self.levelHistoryCount)
        }
    }

    // MARK: - Session control

    /// Read-only session identity for the UI (bookmarking during a live
    /// classroom needs the persisted session's stable ID and title).
    var activeSessionID: UUID? { session?.id }
    var activeSessionTitle: String? { session?.title }
    var activeSessionCourseID: UUID? { session?.courseID }

    /// Start a classroom session. The optional `title` comes from the
    /// new-classroom form; when nil the previous behavior (date-derived
    /// default title) applies unchanged. `courseID` assigns the session to
    /// a course (nil = standalone). `schedule` carries the schedule
    /// attribution (schedule-launched sessions): the occurrence key and
    /// planned start are written once at creation and never edited.
    func start(
        title: String? = nil,
        courseID: UUID? = nil,
        schedule: ScheduleSessionContext? = nil
    ) async {
        guard state.phase == .idle || state.phase == .finished || state.phase == .backendError else {
            return
        }
        entries.removeAll()
        orderedTranslations = OrderedResultBuffer()
        history.removeAll()
        lastEmittedSegment = nil
        entryIDBySequence.removeAll()
        state.errorMessage = nil

        // 1. Load the (single, user-chosen) backend.
        state.phase = .loadingModel
        do {
            try await engineManager.ensureLoaded(settings.preferredBackend)
        } catch {
            state.errorMessage = error.localizedDescription
            if let managerError = error as? ASREngineManager.ManagerError,
               case .backendNotInstalled = managerError {
                state.phase = .modelNotInstalled
            } else {
                state.phase = .backendError
            }
            return
        }
        state.activeBackend = engineManager.residentBackendKind

        do {
            try engineManager.beginSession()
        } catch {
            state.phase = .backendError
            state.errorMessage = error.localizedDescription
            return
        }

        // 2. Shared VAD layer (used by both backends).
        let vad: SherpaSileroVAD
        do {
            vad = try SherpaSileroVAD(
                parameters: SherpaSileroVAD.Parameters(
                    threshold: Float(settings.vadThreshold)
                )
            )
        } catch {
            engineManager.endSession()
            state.phase = .backendError
            state.errorMessage = error.localizedDescription
            return
        }
        self.vad = vad

        let segmenter = SpeechSegmenter(
            parameters: SpeechSegmenter.Parameters(
                minSpeechSeconds: TimeInterval(settings.vadMinSpeechMs) / 1000,
                silenceEndSeconds: TimeInterval(settings.vadSilenceEndMs) / 1000
            )
        )
        self.segmenter = segmenter

        // 3. Microphone.
        let capture = AudioCaptureService()
        self.capture = capture
        let chunkStream: AsyncStream<AudioChunk>
        do {
            chunkStream = try await capture.start()
        } catch {
            self.capture = nil
            engineManager.endSession()
            state.phase = .backendError
            state.errorMessage = error.localizedDescription
            return
        }

        // 4. Persist the session record.
        sessionStart = Date()
        pausedSeconds = 0
        if let repository {
            let compute: String
            switch settings.preferredBackend {
            case .coreMLFP16:
                compute = settings.coreMLCompute == .accuracy ? "cpuAndGPU" : "cpuAndNeuralEngine"
            case .sherpaONNXInt8:
                compute = "int8-\(settings.onnxThreads)threads"
            }
            let draft = SessionDraft(
                title: title.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    ?? Self.defaultTitle(for: sessionStart),
                backend: settings.preferredBackend,
                modelVersion: "gigaam-v3-e2e-rnnt",
                computePreference: compute,
                translationModel: settings.translationModel,
                courseID: courseID,
                scheduleID: schedule?.scheduleID,
                occurrenceKey: schedule?.occurrenceKey,
                plannedStart: schedule?.plannedStart
            )
            session = try? repository.createSession(draft)
        }

        // 5. Optional raw audio recording (off by default). The metadata
        // row (SessionRecording) is created FIRST so the player's
        // existence probe never races the file creation; the WAV writer
        // opens the file right after.
        if settings.saveRawAudio, let session {
            let directory = Self.sessionsDirectory().appendingPathComponent(session.id.uuidString)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            wavWriter = try? WAVFileWriter(url: directory.appendingPathComponent("raw.wav"))
            if wavWriter != nil {
                try? repository.beginRecording(sessionID: session.id)
            }
        }

        state.phase = .ready
        state.coreMLComputeDescription = settings.preferredBackend == .coreMLFP16
            ? settings.coreMLCompute.displayName
            : ""
        state.onnxThreadCount = settings.onnxThreads

        // 6. Wire the stages.
        let segmentStream = AsyncStream<SpeechSegment>(bufferingPolicy: .unbounded) { continuation in
            self.segmentContinuation = continuation
        }
        let translationStream = AsyncStream<PendingTranslation>(bufferingPolicy: .unbounded) { continuation in
            self.translationContinuation = continuation
        }

        // Audio processing runs off the main actor: Silero inference must
        // never block UI. All state it touches is lock-isolated or
        // continuation-based; main-actor hops are explicit and throttled.
        // The sink and writer are captured as locals (Sendable) so the
        // nonisolated loop never touches main-actor storage.
        let segmentSink = segmentContinuation
        let rawAudioWriter = wavWriter
        processingTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.audioProcessingLoop(
                chunks: chunkStream, vad: vad, segmenter: segmenter,
                sink: segmentSink, writer: rawAudioWriter
            )
        }
        asrTask = Task { [weak self] in
            await self?.asrLoop(segments: segmentStream)
        }
        let workerCount = max(1, min(3, settings.translationConcurrency))
        for _ in 0..<workerCount {
            translationWorkers.append(Task { [weak self] in
                await self?.translationLoop(jobs: translationStream)
            })
        }
        elapsedTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.tickElapsed()
            }
        }

        state.phase = .listening
        Self.logger.info("Session started on \(self.engineManager.residentBackendKind?.rawValue ?? "?", privacy: .public)")
    }

    func pause() {
        guard !isPaused, isRunning else { return }
        isPaused = true
        pauseFlag.set(true)
        pauseStartedAt = Date()
        // Close any pending speech so the transcript stays coherent across
        // the gap; audio during the pause is discarded, never buffered.
        flushSegmenter()
        state.phase = .paused
    }

    func resume() {
        guard isPaused else { return }
        if let pauseStartedAt {
            pausedSeconds += Date().timeIntervalSince(pauseStartedAt)
            self.pauseStartedAt = nil
        }
        isPaused = false
        pauseFlag.set(false)
        vad?.reset()
        state.phase = isNetworkAvailable ? .listening : .networkOffline
    }

    var isRunning: Bool {
        switch state.phase {
        case .idle, .finished, .backendError, .modelNotInstalled:
            return false
        default:
            return true
        }
    }

    func stop() async {
        guard isRunning else { return }

        // Stop feeding, flush the final segment, then drain in order:
        // audio → segments → ASR → translations. In-flight work finishes;
        // nothing is abandoned mid-request.
        pauseFlag.set(true)
        processingTask?.cancel()
        await processingTask?.value
        flushSegmenter()
        segmentContinuation?.finish()
        segmentContinuation = nil
        await asrTask?.value
        translationContinuation?.finish()
        translationContinuation = nil
        for worker in translationWorkers {
            await worker.value
        }
        translationWorkers.removeAll()
        elapsedTimer?.cancel()
        elapsedTimer = nil

        let writer = wavWriter
        wavWriter = nil
        writer?.finish()
        if let session, let writer, let repository,
           let recording = try? repository.recording(sessionID: session.id) {
            // Metadata catches up with the file's real state even when the
            // stop is abnormal (the writer's frame count is the truth).
            try? repository.finishRecording(
                recording, duration: writer.durationSeconds, fileSize: Int64(writer.bytesOnDisk)
            )
        }
        await capture?.stop()
        capture = nil

        if let session, let repository {
            session.duration = elapsedClassroomTime
            try? repository.finishSession(session, abnormal: false)
        }
        engineManager.endSession()
        vad = nil
        segmenter = nil
        state.phase = .finished
        Self.logger.info("Session stopped after \(self.state.elapsed, privacy: .public)s")
    }

    // MARK: - Audio → segments (off the main actor)

    /// Feeds chunks through the VAD oracle and the segmenter. `nonisolated`
    /// by design: the detached task must not bounce to the main actor per
    /// window.
    private nonisolated func audioProcessingLoop(
        chunks: AsyncStream<AudioChunk>,
        vad: SherpaSileroVAD,
        segmenter: SpeechSegmenter,
        sink: AsyncStream<SpeechSegment>.Continuation?,
        writer: WAVFileWriter?
    ) async {
        var levelCounter = 0
        var wasSpeech = false
        for await chunk in chunks {
            if Task.isCancelled { break }
            if pauseFlag.value {
                continue
            }
            let isSpeech = vad.process(window: chunk.samples[...])
            let segments = segmenter.push(window: chunk.samples[...], isSpeech: isSpeech)
            for segment in segments {
                sink?.yield(segment)
            }
            writer?.append(chunk.samples)

            levelCounter += 1
            if levelCounter % 3 == 0 {
                let level = min(max(chunk.rms, 0), 1)
                Task { @MainActor [weak self] in
                    self?.appendLevel(level)
                }
            }
            // Leading-edge speech indication only (no per-window chatter).
            if isSpeech && !wasSpeech {
                Task { @MainActor [weak self] in
                    if self?.state.phase == .listening {
                        self?.state.phase = .speechDetected
                    }
                }
            }
            wasSpeech = isSpeech
        }
    }

    /// Emit the segmenter's pending tail (stop/pause paths).
    private func flushSegmenter() {
        guard let segmenter else { return }
        for segment in segmenter.flush() {
            segmentContinuation?.yield(segment)
        }
        vad?.reset()
    }

    // MARK: - Segments → ASR → persistence + translation dispatch

    /// ASR is strictly serial (the manager holds one engine and inference
    /// is actor-isolated inside it), so completion order equals dispatch
    /// order and the segment's own `sequenceID` can be carried through.
    private func asrLoop(segments: AsyncStream<SpeechSegment>) async {
        for await segment in segments {
            if Task.isCancelled { break }
            do {
                let started = Date()
                let result = try await engineManager.transcribe(segment)
                let latency = Date().timeIntervalSince(started)
                handleASRResult(result: result, segment: segment, latency: latency)
            } catch {
                if Task.isCancelled { break }
                Self.logger.error("ASR failed: \(String(describing: error), privacy: .public)")
                state.phase = .backendError
                state.errorMessage = error.localizedDescription
                // A failed backend ends the listening loop; the user decides
                // what happens next (never an automatic switch).
                break
            }
        }
    }

    private func handleASRResult(
        result: ASRResult, segment: SpeechSegment, latency: TimeInterval
    ) {
        let sequenceID = segment.sequenceID
        var text = result.text
        // Forced-split segments overlap by 300 ms; strip a duplicated word
        // run at the seam — conservatively, only on exact character match.
        if let last = lastEmittedSegment, segment.startOffset < last.endOffset - 0.05 {
            text = SpeechSegmenter.deduplicateOverlap(previous: last.text, next: text)
        }

        guard !text.isEmpty else {
            // No entry, but the ordered-buffer slot must still be released
            // or every later translation would wait forever.
            orderedTranslations.register(sequenceID)
            depositOutcome(Self.emptyOutcome(sequenceID: sequenceID))
            lastEmittedSegment = (result.segmentEnd, text)
            return
        }

        // Translation intent at dispatch time, kept distinct from service
        // availability: "user turned translation off" (`.skipped` — no
        // request is made at all) versus "user wants translation but no
        // service is configured" (`.notConfigured`). The toggle is applied
        // per utterance, so re-enabling affects subsequent segments only.
        let translationWanted = settings.liveTranslationEnabled
        // Single source of truth: the *current* translator decides whether
        // a service is configured (see `TranslationService.isConfiguredNow`)
        // — never a duplicated rule on the settings store.
        let translationConfigured = translationServiceProvider()?.isConfiguredNow ?? false
        let initialStatus: TranslationStatus = translationWanted
            ? (translationConfigured ? .pending : .notConfigured)
            : .skipped

        var entry = LiveTranscriptItem(
            sequenceID: sequenceID,
            timestamp: Self.timestamp(for: result.segmentStart),
            startOffset: result.segmentStart,
            originalText: text,
            translatedText: nil,
            translationStatus: initialStatus
        )

        // Persist the Russian original immediately — before any translation
        // is attempted, so a translation failure can never lose it. This
        // happens regardless of the translation toggle. Offsets come from
        // the segmenter's continuous sample count (the recorded file's own
        // timeline — paused audio is discarded before either sees it).
        if let session, let repository {
            let draft = EntryDraft(
                sequenceID: sequenceID,
                startOffset: result.segmentStart,
                endOffset: result.segmentEnd,
                originalText: text,
                asrBackend: result.backend,
                asrLatency: result.inferenceDuration,
                asrRTF: result.realTimeFactor,
                timeSource: .audio
            )
            // addEntry owns the entryCount increment — a second one here
            // would double every "N 段" the UI derives from the session.
            if let stored = try? repository.addEntry(draft, to: session) {
                entryIDBySequence[sequenceID] = stored.id
            }
        }
        entry.entryID = entryIDBySequence[sequenceID]
        entries.append(entry)
        lastEmittedSegment = (result.segmentEnd, text)

        state.lastASRLatency = latency
        state.lastRTF = result.realTimeFactor
        // pause() flushes the segmenter, so a tail segment's result can land
        // after the classroom is already paused — keep the chip honest.
        state.phase = isPaused
            ? .paused
            : (isNetworkAvailable ? .transcribing : .networkOffline)

        orderedTranslations.register(sequenceID)
        if translationWanted {
            translationContinuation?.yield(
                PendingTranslation(sequenceID: sequenceID, attempt: 0)
            )
        } else {
            // No translation requested: release the ordered slot right away
            // (so later utterances never wait on it) and persist the skipped
            // status — a user-intent state, never an error.
            depositSkipped(sequenceID: sequenceID)
        }
    }

    // MARK: - Translation workers

    /// Bounded-concurrency translation pool. Each worker pulls the next
    /// job; the pool size (settings.translationConcurrency, clamped to
    /// 1...3) bounds simultaneous network requests.
    private func translationLoop(jobs: AsyncStream<PendingTranslation>) async {
        for await job in jobs {
            await translate(job: job)
        }
    }

    private func translate(job: PendingTranslation) async {
        guard let itemIndex = entries.firstIndex(where: { $0.sequenceID == job.sequenceID }) else {
            depositOutcome(Self.emptyOutcome(sequenceID: job.sequenceID))
            return
        }
        let sourceText = entries[itemIndex].originalText
        guard let service = translationProvider() else {
            depositOutcome(TranslationOutcome(
                sequenceID: job.sequenceID, text: nil, latency: 0,
                isRetryable: false,
                errorDescription: TranslationError.notConfigured.errorDescription
            ))
            return
        }

        let contextTurns = max(0, min(10, settings.contextTurns))
        let historySnapshot = Array(history.suffix(contextTurns))
        let request = TranslationRequest(
            id: job.sequenceID,
            sequenceID: job.sequenceID,
            text: sourceText,
            sourceLanguage: "ru",
            targetLanguage: "zh-CN",
            history: historySnapshot
        )

        let outcome = await service.translate(request)

        // One immediate retry for transient failures only (network, timeout,
        // 429, 5xx). Fatal errors (401/403/400) go straight to the user.
        if outcome.text == nil, outcome.isRetryable, job.attempt == 0 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await translate(job: PendingTranslation(sequenceID: job.sequenceID, attempt: 1))
            return
        }
        depositOutcome(outcome)
    }

    private static func emptyOutcome(sequenceID: Int) -> TranslationOutcome {
        TranslationOutcome(
            sequenceID: sequenceID, text: nil, latency: 0,
            isRetryable: false, errorDescription: nil
        )
    }

    /// Release a translation-skipped entry (user turned live translation
    /// off): the UI entry keeps `.skipped`, persistence records `.skipped`
    /// (never `.failed`), and the ordered buffer slot frees immediately so
    /// subsequent translations don't wait behind it.
    private func depositSkipped(sequenceID: Int) {
        if let index = entries.firstIndex(where: { $0.sequenceID == sequenceID }) {
            entries[index].translationStatus = .skipped
            entries[index].isRetryableTranslation = false
        }
        for (id, released) in orderedTranslations.complete(sequenceID, Self.emptyOutcome(sequenceID: sequenceID)) {
            persistOutcome(released, sequenceID: id)
        }
        if orderedTranslations.depth == 0 {
            switch state.phase {
            case .transcribing, .translating, .speechDetected:
                state.phase = isNetworkAvailable ? .listening : .networkOffline
            default:
                break
            }
        }
    }

    /// Fill the UI entry immediately; release through the ordered buffer so
    /// persistence and context history follow utterance order.
    private func depositOutcome(_ outcome: TranslationOutcome) {
        let sequenceID = outcome.sequenceID
        if let index = entries.firstIndex(where: { $0.sequenceID == sequenceID }) {
            if let text = outcome.text, !text.isEmpty {
                entries[index].translatedText = text
                entries[index].translationStatus = .completed
                entries[index].isRetryableTranslation = false
                state.lastTranslationLatency = outcome.latency
            } else if outcome.errorDescription == TranslationError.notConfigured.errorDescription {
                entries[index].translationStatus = .notConfigured
            } else {
                entries[index].translationStatus = .failed
                entries[index].isRetryableTranslation = outcome.isRetryable
            }
        }

        for (id, released) in orderedTranslations.complete(sequenceID, outcome) {
            persistOutcome(released, sequenceID: id)
        }

        // Idle back down when the last in-flight translation has landed.
        if orderedTranslations.depth == 0 {
            switch state.phase {
            case .transcribing, .translating, .speechDetected:
                state.phase = isNetworkAvailable ? .listening : .networkOffline
            default:
                break
            }
        }
    }

    private func persistOutcome(_ outcome: TranslationOutcome, sequenceID: Int) {
        if let entryID = entryIDBySequence[sequenceID], let repository {
            if let text = outcome.text, !text.isEmpty {
                try? repository.updateTranslation(
                    entryID: entryID, text: text,
                    latency: outcome.latency, status: .completed
                )
            } else {
                // A user-skipped entry persists as `.skipped` — an intent,
                // not an error; it is excluded from failure counts and from
                // the automatic retry set. Everything else without text is
                // a real failure.
                let skipped = entries.first { $0.sequenceID == sequenceID }?
                    .translationStatus == .skipped
                try? repository.updateTranslation(
                    entryID: entryID, text: "",
                    latency: outcome.latency, status: skipped ? .skipped : .failed
                )
            }
        }
        // Context history follows utterance order, so snapshotting at
        // dispatch time always sees a consistent prefix.
        if let text = outcome.text, !text.isEmpty,
           let index = entries.firstIndex(where: { $0.sequenceID == sequenceID }) {
            history.append((entries[index].originalText, text))
            let contextTurns = max(0, min(10, settings.contextTurns))
            if history.count > contextTurns {
                history.removeFirst(history.count - contextTurns)
            }
        }
    }

    // MARK: - Retry failed translations

    /// Re-enqueue failed-but-retryable translations (user action, or
    /// automatic on network recovery).
    func retryFailedTranslations() {
        for item in entries where item.translationStatus == .failed && item.isRetryableTranslation {
            guard let index = entries.firstIndex(where: { $0.id == item.id }) else { continue }
            entries[index].translationStatus = .pending
            translationContinuation?.yield(
                PendingTranslation(sequenceID: item.sequenceID, attempt: 0)
            )
        }
    }

    /// Retry a single entry (subtitle card action).
    func retryTranslation(sequenceID: Int) {
        guard let index = entries.firstIndex(where: { $0.sequenceID == sequenceID }),
              entries[index].translationStatus == .failed else { return }
        entries[index].translationStatus = .pending
        translationContinuation?.yield(PendingTranslation(sequenceID: sequenceID, attempt: 0))
    }

    // MARK: - Network

    private func startNetworkMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasAvailable = self.isNetworkAvailable
                self.isNetworkAvailable = available
                if wasAvailable && !available {
                    // ASR is local and keeps running; only translation dies.
                    if self.state.phase == .listening || self.state.phase == .speechDetected {
                        self.state.phase = .networkOffline
                    }
                } else if !wasAvailable && available {
                    if self.state.phase == .networkOffline {
                        self.state.phase = .listening
                    }
                    // Network is back: retry what failed while offline.
                    self.retryFailedTranslations()
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.livetranslate.ios.network"))
    }

    // MARK: - Misc

    private func tickElapsed() {
        guard isRunning else { return }
        state.elapsed = elapsedClassroomTime
    }

    private var elapsedClassroomTime: TimeInterval {
        let paused = pausedSeconds + (pauseStartedAt.map { Date().timeIntervalSince($0) } ?? 0)
        return Date().timeIntervalSince(sessionStart) - paused
    }

    private func translationProvider() -> (any TranslationService)? {
        translationServiceProvider()
    }

    static func timestamp(for offset: TimeInterval) -> String {
        let total = Int(offset.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private static func defaultTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func sessionsDirectory() -> URL {
        // Shared with the repository (which deletes recordings together
        // with their session) — see SessionRecordings.
        SessionRecordings.rootDirectory
    }
}

// MARK: - Atomic flag

/// Lock-protected boolean shared between the main actor and the detached
/// audio processing loop.
final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func set(_ newValue: Bool) {
        lock.lock(); defer { lock.unlock() }
        flag = newValue
    }

    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }
}
