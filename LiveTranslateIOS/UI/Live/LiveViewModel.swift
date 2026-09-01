import SwiftUI
import Observation

/// View model for the full-screen live classroom (reference image 3).
/// Wraps the pipeline coordinator — it adds no business logic of its own,
/// only presentation state: lyric focus, auto-follow, in-class search and
/// bookmarks.
@MainActor
@Observable
final class LiveViewModel {
    enum LiveTab: String, CaseIterable, Identifiable {
        case transcript, notes, bookmarks, search

        var id: String { rawValue }

        var title: String {
            switch self {
            case .transcript: return "实时转写"
            case .notes: return "课堂笔记"
            case .bookmarks: return "书签列表"
            case .search: return "搜索"
            }
        }
    }

    /// UI-level per-entry presentation state derived from the coordinator's
    /// real data. Translation intent is triaged up front: "user turned
    /// translation off" (skipped — nothing was requested) is a different
    /// state from "service not configured" or "network down", and none of
    /// them is an error.
    enum EntryPhase: Equatable {
        case translating
        case translated
        case failed(retryable: Bool)
        case notConfigured
        /// The user turned live translation off — no request was made.
        case skipped
        /// Translation failed because the network is down. The coordinator
        /// re-enqueues these automatically on recovery, so no manual retry
        /// button is offered.
        case offline
    }

    /// One session bookmark resolved against the live in-memory entries.
    struct ResolvedBookmark: Identifiable {
        let bookmark: BookmarkStore.EntryBookmark
        let entry: LiveTranscriptItem?

        var id: UUID { bookmark.id }
    }

    private var environment: AppEnvironment?

    var selectedTab: LiveTab = .transcript

    /// Auto-follow: true until the user scrolls away from the focus
    /// position; a "回到当前内容" affordance restores it.
    var isFollowing = true
    /// Search query within the live classroom.
    var searchQuery = ""

    // MARK: - Coordinator mirrors

    var state: PipelineState {
        environment?.coordinator.state ?? PipelineState()
    }

    var entries: [LiveTranscriptItem] {
        environment?.coordinator.entries ?? []
    }

    var audioLevels: [Float] {
        environment?.coordinator.audioLevels ?? []
    }

    var sessionTitle: String {
        environment?.coordinator.activeSessionTitle ?? "课堂"
    }

    var activeSessionID: UUID? {
        environment?.coordinator.activeSessionID
    }

    var isRunning: Bool {
        environment?.coordinator.isRunning ?? false
    }

    var isPaused: Bool {
        environment?.coordinator.isPaused ?? false
    }

    var isNetworkAvailable: Bool {
        environment?.coordinator.isNetworkAvailable ?? true
    }

    // MARK: - Lifecycle

    func attach(_ environment: AppEnvironment) {
        self.environment = environment
    }

    // MARK: - Lyric focus

    /// The focused entry: the latest entry still awaiting its translation,
    /// otherwise the newest entry.
    var currentSequenceID: Int? {
        let items = entries
        if let pending = items.last(where: { $0.translationStatus == .pending }) {
            return pending.sequenceID
        }
        return items.last?.sequenceID
    }

    func isCurrent(_ entry: LiveTranscriptItem) -> Bool {
        entry.sequenceID == currentSequenceID
    }

    /// Distance of an entry from the focus position, for progressive
    /// dimming of completed history (0 = current).
    func focusDistance(of entry: LiveTranscriptItem) -> Int? {
        guard let current = currentSequenceID else { return nil }
        let currentIndex = entries.firstIndex { $0.sequenceID == current }
        let entryIndex = entries.firstIndex { $0.sequenceID == entry.sequenceID }
        guard let currentIndex, let entryIndex else { return nil }
        return currentIndex - entryIndex
    }

    /// Opacity for non-focused history: the previous entry dims least, older
    /// entries dim more, floored so text stays readable.
    var historyOpacity: (Int) -> Double {
        { distance in
            switch distance {
            case 0: return 1.0
            case 1: return 0.78
            case 2: return 0.62
            default: return 0.50
            }
        }
    }

    func entryPhase(_ entry: LiveTranscriptItem) -> EntryPhase {
        switch entry.translationStatus {
        case .pending: return .translating
        case .completed: return .translated
        case .failed:
            if !isNetworkAvailable && entry.isRetryableTranslation { return .offline }
            return .failed(retryable: entry.isRetryableTranslation)
        case .notConfigured: return .notConfigured
        case .skipped: return .skipped
        }
    }

    /// The user's live-translation intent for this classroom (the
    /// new-classroom toggle; applies to subsequent segments at dispatch).
    var isTranslationWanted: Bool {
        environment?.settings.liveTranslationEnabled ?? true
    }

    /// Whether a valid translation service is configured (base URL +
    /// model). Only meaningful together with `isTranslationWanted` —
    /// "wants translation but not configured" is what shows the
    /// 前往设置 banner; the disabled case shows nothing.
    var isTranslationConfigured: Bool {
        environment?.settings.isTranslationConfigured ?? false
    }

    /// True while speech is being collected but no entry has landed yet
    /// (spec's "collecting" state).
    var isCollectingSpeech: Bool {
        state.phase == .speechDetected
    }

    // MARK: - Scroll follow

    /// Called from the scroll-bottom marker preference: the value is
    /// ≈0 while the feed end is at the viewport bottom, and increasingly
    /// negative as the user reads history. Within ~150 pt counts as
    /// following; scrolling away breaks follow, and only 回到当前内容
    /// (or the auto-scroll itself) restores it.
    func updateScrollPosition(minY: CGFloat) {
        isFollowing = minY > -150
    }

    func resumeFollowing() {
        isFollowing = true
    }

    // MARK: - Live search

    var searchResults: [LiveTranscriptItem] {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        return entries.filter {
            $0.originalText.localizedCaseInsensitiveContains(query)
                || ($0.translatedText ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    // MARK: - Bookmarks (this session)

    /// This session's bookmarks, resolved against the live entries so the
    /// list always shows the newest translation text.
    var sessionBookmarks: [ResolvedBookmark] {
        guard let sessionID = activeSessionID else { return [] }
        let items = entries
        return (environment?.bookmarks.bookmarks(in: sessionID) ?? []).map { bookmark in
            ResolvedBookmark(
                bookmark: bookmark,
                entry: items.first { $0.entryID == bookmark.entryID }
            )
        }
    }

    func isBookmarked(_ entry: LiveTranscriptItem) -> Bool {
        guard let entryID = entry.entryID else { return false }
        return environment?.bookmarks.isBookmarked(entryID: entryID) ?? false
    }

    /// Bookmark/unbookmark one entry (the row star and the bottom control).
    /// Returns false when the entry has no stable persisted ID yet.
    @discardableResult
    func toggleBookmark(_ entry: LiveTranscriptItem) -> Bool {
        guard let environment, let sessionID = activeSessionID, let entryID = entry.entryID else {
            return false
        }
        return environment.bookmarks.toggleBookmark(sessionID: sessionID, entryID: entryID)
    }

    /// The bottom 书签 control marks the current entry.
    /// Returns false when there is nothing to bookmark yet.
    @discardableResult
    func bookmarkCurrent() -> Bool {
        guard let current = entries.last(where: { $0.sequenceID == currentSequenceID }) else {
            return false
        }
        return toggleBookmark(current)
    }

    /// Remove a bookmark by record (bookmarks list action).
    func removeBookmark(_ bookmark: BookmarkStore.EntryBookmark) {
        environment?.bookmarks.removeBookmark(bookmark)
    }

    // MARK: - Session control (thin pass-throughs to the coordinator)

    func pause() {
        environment?.coordinator.pause()
    }

    func resume() {
        environment?.coordinator.resume()
    }

    func stop() async {
        await environment?.coordinator.stop()
    }

    func retryTranslation(_ sequenceID: Int) {
        environment?.coordinator.retryTranslation(sequenceID: sequenceID)
    }

    func retryFailedTranslations() {
        environment?.coordinator.retryFailedTranslations()
    }

    // MARK: - Error presentation

    var errorBannerText: String? {
        // Deliberately does NOT echo the raw `state.errorMessage`: backend
        // error descriptions carry technical runtime names, which product UI
        // must not surface. The technical detail stays in the os_log; here
        // only phase-derived, user-safe text is shown.
        switch state.phase {
        case .backendError:
            return "识别引擎出错，本次课堂未自动切换后端。俄语原文不受影响。"
        case .modelNotInstalled:
            return "选定的识别模式尚未安装语言资源。"
        case .diskSpaceLow:
            return "磁盘空间不足，无法完成准备。"
        default:
            return nil
        }
    }

    /// True when the error state offers an escape to the other installed
    /// backend (explicit user action only — never an automatic switch).
    var showsSwitchToOtherBackend: Bool {
        guard state.phase == .backendError || state.phase == .modelNotInstalled else { return false }
        return otherInstalledBackend != nil
    }

    private var otherInstalledBackend: ASRBackendKind? {
        guard let environment else { return nil }
        let preferred = environment.settings.preferredBackend
        let other: ASRBackendKind = preferred == .coreMLFP16 ? .sherpaONNXInt8 : .coreMLFP16
        // Whether the other backend is installed is only knowable via the
        // async manifest check; expose the switch whenever an error leaves
        // the classroom unusable and let the action verify.
        return other
    }

    /// Retry starting with the currently preferred backend (after an error
    /// left the classroom unusable). Never switches backends implicitly —
    /// the banner's 切换后端 action is the only path for that.
    func restartSession() async {
        await environment?.coordinator.start(title: sessionTitle)
    }

    /// Switch to the other backend and restart listening. Bound to a
    /// user-initiated button only.
    func switchToOtherInstalledBackend() async {
        guard let environment, let other = otherInstalledBackend else { return }
        let installed = await environment.engineManager.isInstalled(other)
        guard installed else { return }
        environment.settings.preferredBackend = other
        await environment.coordinator.start(title: sessionTitle)
    }
}
