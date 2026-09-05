import SwiftUI
import Observation

/// View model for the classroom detail screen (reference image 5).
/// Presentation only: display modes, in-session search with highlight,
/// bookmarks, export and failed-translation retry on top of the existing
/// repository/translation services.
@MainActor
@Observable
final class SessionDetailViewModel {
    enum DisplayMode: String, CaseIterable, Identifiable {
        case bilingual, chinese, russian

        var id: String { rawValue }

        var title: String {
            switch self {
            case .bilingual: return "双语"
            case .chinese: return "仅中文"
            case .russian: return "仅俄语"
            }
        }
    }

    private var environment: AppEnvironment?
    private(set) var session: ClassroomSession?

    var entries: [TranscriptEntry] = []
    var notes: [SessionNote] = []
    var attachments: [SessionAttachment] = []
    /// Materials linked to this class (本堂课资料; read-only list).
    var sessionMaterials: [CourseMaterial] = []
    /// Entry id → correction (effective-text lookups; nil = model only).
    var correctionsByEntryID: [UUID: TranscriptCorrection] = [:]
    private(set) var review: StudyReview?
    /// The session's recording metadata (nil = never recorded).
    private(set) var recording: SessionRecording?
    var isLoaded = false
    var isRetranslating = false
    var displayMode: DisplayMode = .bilingual
    var searchQuery = ""
    var showBookmarksOnly = false
    /// SequenceID the view should scroll to (a tapped note's anchor);
    /// consumed by the view's scroll reader.
    var pendingScrollTarget: Int?

    /// Matching sequenceIDs in reading order + the focused match index.
    private(set) var matchIDs: [Int] = []
    private(set) var currentMatchIndex = 0

    // MARK: - Lifecycle

    func attach(_ environment: AppEnvironment) {
        self.environment = environment
    }

    func load(sessionID: UUID) {
        guard let environment else { return }
        let all = (try? environment.repository.sessions(matching: "")) ?? []
        guard let session = all.first(where: { $0.id == sessionID }) else {
            self.session = nil
            entries = []
            notes = []
            attachments = []
            correctionsByEntryID = [:]
            recording = nil
            review = nil
            isLoaded = true
            return
        }
        self.session = session
        entries = (try? environment.repository.entries(for: session)) ?? []
        notes = (try? environment.repository.notes(forSessionID: sessionID)) ?? []
        attachments = (try? environment.repository.attachments(forSessionID: sessionID)) ?? []
        sessionMaterials = ((try? environment.repository.materials(courseID: nil)) ?? [])
            .filter { $0.sessionID == sessionID }
        let corrections = (try? environment.repository.corrections(forSessionID: sessionID)) ?? []
        correctionsByEntryID = Dictionary(
            corrections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        recording = try? environment.repository.recording(sessionID: sessionID)
        review = try? environment.repository.studyReview(forSessionID: sessionID)
        // Keep bookmark IDs honest: entries deleted upstream drop their
        // bookmarks instead of lingering as orphans.
        environment.bookmarks.pruneEntries(in: sessionID, existingEntryIDs: Set(entries.map(\.id)))
        updateMatches()
        isLoaded = true
    }

    func reload() {
        if let id = session?.id {
            load(sessionID: id)
        }
    }

    // MARK: - Search

    func searchDidChange() {
        updateMatches()
    }

    private func updateMatches() {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            matchIDs = []
            currentMatchIndex = 0
            return
        }
        matchIDs = entries.filter { entry in
            effectiveRussian(entry).localizedCaseInsensitiveContains(query)
                || (effectiveChinese(entry) ?? "").localizedCaseInsensitiveContains(query)
        }
        .map(\.sequenceID)
        currentMatchIndex = matchIDs.isEmpty ? 0 : min(currentMatchIndex, matchIDs.count - 1)
    }

    // MARK: - Effective text (correction-aware reads)

    func effectiveRussian(_ entry: TranscriptEntry) -> String {
        entry.effectiveRussianText(correction: correctionsByEntryID[entry.id])
    }

    func effectiveChinese(_ entry: TranscriptEntry) -> String? {
        entry.effectiveChineseText(correction: correctionsByEntryID[entry.id])
    }

    func isCorrected(_ entry: TranscriptEntry) -> Bool {
        entry.isCorrected(correction: correctionsByEntryID[entry.id])
    }

    var matchCount: Int { matchIDs.count }

    var isMatchFocused: (TranscriptEntry) -> Bool {
        { entry in
            self.matchIDs.indices.contains(self.currentMatchIndex)
                && self.matchIDs[self.currentMatchIndex] == entry.sequenceID
        }
    }

    var isMatch: (TranscriptEntry) -> Bool {
        { entry in self.matchIDs.contains(entry.sequenceID) }
    }

    func previousMatch() {
        guard !matchIDs.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex - 1 + matchIDs.count) % matchIDs.count
    }

    func nextMatch() {
        guard !matchIDs.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + 1) % matchIDs.count
    }

    // MARK: - Bookmarks / favorites

    var isFavorite: Bool {
        guard let session else { return false }
        return environment?.bookmarks.isFavorite(session.id) ?? false
    }

    func toggleFavorite() {
        guard let session else { return }
        environment?.bookmarks.toggleFavorite(session.id)
    }

    var isBookmarked: (TranscriptEntry) -> Bool {
        { entry in
            self.environment?.bookmarks.isBookmarked(entryID: entry.id) ?? false
        }
    }

    @discardableResult
    func toggleBookmark(_ entry: TranscriptEntry) -> Bool {
        guard let session else { return false }
        return environment?.bookmarks.toggleBookmark(
            sessionID: session.id, entryID: entry.id
        ) ?? false
    }

    // MARK: - Notes

    /// Notes anchored to one entry, for inline display under the row.
    func notes(anchoredTo entry: TranscriptEntry) -> [SessionNote] {
        notes.filter { $0.anchorEntryID == entry.id }
    }

    /// The entry a note is anchored to (nil when unanchored or the entry
    /// is gone).
    func anchorEntry(for note: SessionNote) -> TranscriptEntry? {
        guard let anchorID = note.anchorEntryID else { return nil }
        return entries.first { $0.id == anchorID }
    }

    /// Session-relative timestamp for a note: its own recorded position
    /// (playback or live time) first, then its anchor's offset, then the
    /// creation time relative to the session start (approximation).
    func noteTimestamp(_ note: SessionNote) -> String {
        if let offset = note.timeOffset {
            return TranscriptExporter.mmss(max(0, offset))
        }
        if let entry = anchorEntry(for: note) {
            return TranscriptExporter.mmss(entry.startOffset)
        }
        let offset = note.createdAt.timeIntervalSince(session?.startTime ?? note.createdAt)
        return TranscriptExporter.mmss(max(0, offset))
    }

    /// The note's best playback position (nil when nothing usable).
    func notePlaybackOffset(_ note: SessionNote) -> TimeInterval? {
        if let offset = note.timeOffset { return max(0, offset) }
        if let entry = anchorEntry(for: note) { return entry.startOffset }
        guard let session else { return nil }
        let offset = note.createdAt.timeIntervalSince(session.startTime)
        return offset >= 0 ? offset : nil
    }

    /// Jump to a note's anchor (scroll target consumed by the view).
    func jumpToAnchor(of note: SessionNote) {
        guard let entry = anchorEntry(for: note) else { return }
        pendingScrollTarget = entry.sequenceID
    }

    func deleteNote(_ note: SessionNote) {
        guard let environment else { return }
        try? environment.repository.deleteNote(note)
        reload()
    }

    /// Clears a note's anchor (the note itself stays and the change syncs
    /// through the mutation observer).
    func detachAnchor(of note: SessionNote) {
        guard let environment else { return }
        try? environment.repository.updateNoteAnchor(note, anchorEntryID: nil)
        reload()
    }

    // MARK: - Study review presentation

    var reviewContent: StudyReviewContent? {
        guard let review, !review.contentJSON.isEmpty else { return nil }
        return StudyReviewContent.decode(review.contentJSON)
    }

    /// Live generation progress, when this classroom is being processed.
    var reviewProgress: StudyReviewGenerator.Progress? {
        guard let session else { return nil }
        return environment?.studyReviewGenerator.progress(for: session.id)
    }

    var reviewStatus: StudyReviewStatus? {
        review.flatMap { StudyReviewStatus(rawValue: $0.status) }
    }

    var isReviewStale: Bool {
        guard let session, let review, let sourceUpdatedAt = review.sourceUpdatedAt else {
            return false
        }
        return session.updatedAt > sourceUpdatedAt
    }

    /// Short status line for the entry card.
    var reviewCardDetail: String {
        if let progress = reviewProgress {
            return progress.label
        }
        if let content = reviewContent, reviewStatus == .completed {
            return content.topic.isEmpty ? "已整理 · 点击阅读" : content.topic
        }
        switch reviewStatus {
        case .partial: return "上次整理未完成 · 可继续"
        case .failed: return reviewContent == nil ? "整理失败 · 可重试" : "已整理（上次重新整理失败）"
        case .generating: return "正在整理…"
        case .completed, .none: return "整理为复习资料 · 转录、翻译与笔记"
        }
    }

    /// Tint for the entry card chip.
    var reviewCardTint: Color {
        if reviewProgress != nil { return LTColors.accentCyan }
        if reviewStatus == .completed, reviewContent != nil { return LTColors.accentGreen }
        if reviewStatus == .partial || reviewStatus == .failed { return LTColors.warning }
        return LTColors.textTertiary
    }

    var hasReviewResult: Bool {
        reviewContent != nil
    }

    // MARK: - Derived presentation

    var visibleEntries: [TranscriptEntry] {
        let ordered = entries.sorted { $0.sequenceID < $1.sequenceID }
        if showBookmarksOnly {
            return ordered.filter { isBookmarked($0) }
        }
        return ordered
    }

    /// Entries with a real translation failure (a configured-but-failed
    /// or never-configured request). Translation-skipped entries (user
    /// turned translation off) are deliberately excluded — they are not
    /// failures and are not batch-retried.
    var failedCount: Int {
        entries.filter { $0.status == .failed || $0.status == .notConfigured }.count
    }

    var skippedCount: Int {
        entries.filter { $0.status == .skipped }.count
    }

    var isEntirelySkipped: Bool {
        !entries.isEmpty && skippedCount == entries.count
    }

    var translatedFraction: Double {
        guard !entries.isEmpty else { return 0 }
        let completed = entries.filter { $0.status == .completed }.count
        return Double(completed) / Double(entries.count)
    }

    // MARK: - Actions

    func rename(to rawTitle: String) {
        guard let session else { return }
        // Through the repository (not direct model mutation) so the write
        // is saved deterministically and the cloud-sync layer is notified.
        try? environment?.repository.renameSession(session, to: rawTitle)
    }

    func copyTranscript() {
        guard let session else { return }
        let ordered = entries.sorted { $0.sequenceID < $1.sequenceID }
        let text = ordered.map { entry -> String in
            let time = TranscriptExporter.mmss(entry.startOffset)
            var line = "[\(time)] \(effectiveRussian(entry))"
            if let translated = effectiveChinese(entry), !translated.isEmpty {
                line += "\n\(translated)"
            }
            return line
        }
        .joined(separator: "\n\n")
        if !text.isEmpty { ClipboardService.shared.copySensitive(text) }
    }

    /// Retranslate failed entries using the real translation service and
    /// repository updates (same flow the previous screen used).
    func retranslateFailed() async {
        guard let environment, let session, !isRetranslating else { return }
        isRetranslating = true
        defer { isRetranslating = false }

        guard let pending = try? environment.repository.entriesNeedingRetry(for: session) else { return }
        let history = completedHistory()
        for entry in pending {
            let request = TranslationRequest(
                id: entry.sequenceID,
                sequenceID: entry.sequenceID,
                text: entry.originalText,
                sourceLanguage: session.sourceLanguage,
                targetLanguage: session.targetLanguage,
                history: history
            )
            let outcome = await AICallScope.with(
                AICallContext(
                    feature: .classroomTranslation, textCategory: .transcript,
                    masked: false, userTriggered: true
                )
            ) {
                await environment.translationService.translate(request)
            }
            if let text = outcome.text, !text.isEmpty {
                try? environment.repository.updateTranslation(
                    entryID: entry.id, text: text,
                    latency: outcome.latency, status: .completed
                )
            } else {
                // Keep the state honest: a request that produced nothing
                // because the API is (still) not configured must not be
                // rewritten into a hard failure — it stays retryable as
                // `.notConfigured` once the user configures the API.
                let notConfigured = outcome.errorDescription
                    == TranslationError.notConfigured.errorDescription
                try? environment.repository.updateTranslation(
                    entryID: entry.id, text: "",
                    latency: outcome.latency,
                    status: notConfigured ? .notConfigured : .failed
                )
            }
        }
        reload()
    }

    /// Recent (source, translation) pairs in utterance order, for context.
    private func completedHistory() -> [(source: String, translation: String)] {
        entries
            .sorted { $0.sequenceID < $1.sequenceID }
            .filter { $0.status == .completed }
            .suffix(environment?.settings.contextTurns ?? 4)
            .map { ($0.effectiveRussianText(correction: correctionsByEntryID[$0.id]),
                    $0.effectiveChineseText(correction: correctionsByEntryID[$0.id]) ?? "") }
    }

    // MARK: - Recording playback

    /// True when a playable recording exists for this session (row + file
    /// + not deleted). Drives the bottom mini player's existence.
    var hasPlayableRecording: Bool {
        guard let recording, !recording.isDeleted else { return false }
        return SessionRecordings.recordingFileExists(sessionID: recording.sessionID)
    }

    /// Loads the recording into the playback engine if not loaded yet.
    /// Returns false when no playable recording exists.
    @discardableResult
    func ensureRecordingLoaded() -> Bool {
        guard let environment, hasPlayableRecording else { return false }
        if environment.playback.sessionID != session?.id || environment.playback.phase == .idle {
            environment.playback.load(recording: (recording)!)
        }
        return true
    }

    /// Play from one entry (context menu 从这里播放 / tapped timestamp).
    @discardableResult
    func playFrom(entry: TranscriptEntry) -> Bool {
        playFrom(offset: max(0, entry.startOffset - 1.5))
    }

    /// Play from an absolute classroom-relative position (notes, markers).
    @discardableResult
    func playFrom(offset: TimeInterval) -> Bool {
        guard let environment, ensureRecordingLoaded() else { return false }
        environment.playback.seek(to: max(0, offset - 1.0))
        environment.playback.play()
        return true
    }

}
