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
    var isLoaded = false
    var isRetranslating = false
    var displayMode: DisplayMode = .bilingual
    var searchQuery = ""
    var showBookmarksOnly = false

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
            isLoaded = true
            return
        }
        self.session = session
        entries = (try? environment.repository.entries(for: session)) ?? []
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
            entry.originalText.localizedCaseInsensitiveContains(query)
                || (entry.translatedText ?? "").localizedCaseInsensitiveContains(query)
        }
        .map(\.sequenceID)
        currentMatchIndex = matchIDs.isEmpty ? 0 : min(currentMatchIndex, matchIDs.count - 1)
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
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        session.title = trimmed
        session.updatedAt = .now
    }

    func copyTranscript() {
        guard let session else { return }
        let ordered = entries.sorted { $0.sequenceID < $1.sequenceID }
        let text = ordered.map { entry -> String in
            let time = TranscriptExporter.mmss(entry.startOffset)
            var line = "[\(time)] \(entry.originalText)"
            if let translated = entry.translatedText, !translated.isEmpty {
                line += "\n\(translated)"
            }
            return line
        }
        .joined(separator: "\n\n")
        UIPasteboard.general.string = text.isEmpty ? nil : text
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
            let outcome = await environment.translationService.translate(request)
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
            .map { ($0.originalText, $0.translatedText ?? "") }
    }

    func exportURL(format: ExportFormat) async -> URL? {
        guard let session, let environment else { return nil }
        return await SessionExport.writeTemporaryFile(
            session: session,
            entries: entries,
            format: format,
            fallbackBackend: environment.settings.preferredBackend
        )
    }
}
