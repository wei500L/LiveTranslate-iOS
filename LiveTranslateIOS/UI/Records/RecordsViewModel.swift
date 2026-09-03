import SwiftUI
import Observation

/// View model for the classroom-records tab (reference image 4). Reads real
/// SwiftData sessions, aggregates per-session translation outcomes, and
/// owns the debounced search + filter + sort presentation state.
@MainActor
@Observable
final class RecordsViewModel {
    enum Filter: String, CaseIterable, Identifiable {
        case all, favorites, thisWeek, finished, translated

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "全部"
            case .favorites: return "收藏"
            case .thisWeek: return "本周"
            case .finished: return "已完成"
            case .translated: return "已翻译"
            }
        }
    }

    enum SortOrder: String, CaseIterable, Identifiable {
        case recent, oldest, longest, title

        var id: String { rawValue }

        var title: String {
            switch self {
            case .recent: return "最近开始"
            case .oldest: return "最早开始"
            case .longest: return "时长最长"
            case .title: return "名称"
            }
        }
    }

    struct SessionStats: Equatable {
        var totalEntries = 0
        var completedEntries = 0
        var failedEntries = 0
        var pendingEntries = 0
        /// Entries whose translation was never requested (the user turned
        /// live translation off) — an intent, not a failure.
        var skippedEntries = 0

        /// 已翻译 = every entry that needed a translation completed.
        var isFullyTranslated: Bool {
            totalEntries > 0 && failedEntries == 0 && pendingEntries == 0
                && completedEntries == totalEntries
        }

        /// 部分失败 = some translations failed; must never read as 已翻译.
        var hasFailures: Bool { failedEntries > 0 }

        /// Every entry was translation-skipped (classroom recorded with the
        /// live-translation toggle off).
        var isEntirelySkipped: Bool {
            totalEntries > 0 && skippedEntries == totalEntries
        }
    }

    private var environment: AppEnvironment?

    var isLoaded = false
    var sessions: [ClassroomSession] = []
    var statsBySessionID: [UUID: SessionStats] = [:]
    var storageBytes = 0
    /// All courses (active first, most recently used first) — drives the
    /// course chips row; empty until the user creates a course.
    var courses: [Course] = []

    var searchQuery = ""
    var filter: Filter = .all
    var sortOrder: SortOrder = .recent

    /// Debounced, applied query (empty = no filter).
    private(set) var appliedQuery = ""
    private var debounceTask: Task<Void, Never>?

    // MARK: - Lifecycle

    func attach(_ environment: AppEnvironment) {
        self.environment = environment
    }

    func reload() {
        guard let environment else { return }
        sessions = (try? environment.repository.sessions(matching: "")) ?? []
        courses = (try? environment.repository.courses()) ?? []
        storageBytes = environment.repository.storageBytes()

        // Aggregate translation outcomes per session (needed for the
        // 已翻译 / 部分失败 badges and filters).
        var stats: [UUID: SessionStats] = [:]
        stats.reserveCapacity(sessions.count)
        for session in sessions {
            let entries = (try? environment.repository.entries(for: session)) ?? []
            var item = SessionStats()
            item.totalEntries = entries.count
            for entry in entries {
                switch entry.status {
                case .completed: item.completedEntries += 1
                case .failed: item.failedEntries += 1
                case .pending: item.pendingEntries += 1
                case .notConfigured: item.failedEntries += 1
                case .skipped: item.skippedEntries += 1
                }
            }
            stats[session.id] = item
        }
        statsBySessionID = stats
        pruneOrphanedBookmarks()
        isLoaded = true
    }

    /// Drop bookmarks/favorites for sessions that no longer exist.
    private func pruneOrphanedBookmarks() {
        guard let environment else { return }
        environment.bookmarks.pruneSessions(Set(sessions.map(\.id)))
    }

    // MARK: - Search (debounced)

    /// Called on each keystroke; expensive filtering runs only after the
    /// 300 ms debounce settles.
    func searchDidChange() {
        debounceTask?.cancel()
        let query = searchQuery
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            appliedQuery = query
        }
    }

    // MARK: - Derived

    var visibleSessions: [ClassroomSession] {
        var result = sessions

        // Filter.
        let query = appliedQuery.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            result = result.filter { session in
                session.title.localizedCaseInsensitiveContains(query)
                    || session.entries.contains {
                        $0.originalText.localizedCaseInsensitiveContains(query)
                            || ($0.translatedText ?? "").localizedCaseInsensitiveContains(query)
                    }
            }
        }
        switch filter {
        case .all:
            break
        case .favorites:
            guard let environment else { return [] }
            result = result.filter { environment.bookmarks.isFavorite($0.id) }
        case .thisWeek:
            let cutoff = Date.now.addingTimeInterval(-7 * 86_400)
            result = result.filter { $0.startTime >= cutoff }
        case .finished:
            result = result.filter { $0.endTime != nil && !$0.abnormalTermination }
        case .translated:
            result = result.filter { statsBySessionID[$0.id]?.isFullyTranslated == true }
        }

        // Sort.
        switch sortOrder {
        case .recent: break // repository already returns newest first
        case .oldest: result.reverse()
        case .longest: result.sort { $0.duration > $1.duration }
        case .title: result.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
        return result
    }

    func stats(for sessionID: UUID) -> SessionStats {
        statsBySessionID[sessionID] ?? SessionStats()
    }

    /// The course of a session, for the card's course tag (nil when the
    /// session is standalone or its course was deleted).
    func course(for session: ClassroomSession) -> Course? {
        guard let id = session.courseID else { return nil }
        return courses.first { $0.id == id }
    }

    /// The translated-status badge text for a session card. 部分失败 is
    /// never shown as 已翻译, and a translation-disabled classroom is
    /// labeled as such rather than as a failure.
    func translationBadge(for sessionID: UUID) -> (text: String, tint: Color) {
        let stats = stats(for: sessionID)
        if stats.totalEntries == 0 {
            return ("无内容", LTColors.textTertiary)
        }
        if stats.isEntirelySkipped {
            return ("实时翻译已关闭", LTColors.textTertiary)
        }
        if stats.hasFailures {
            return ("部分翻译失败", LTColors.warning)
        }
        if stats.isFullyTranslated {
            return ("已翻译", LTColors.accentGreen)
        }
        return ("翻译未完成", LTColors.accentBlue)
    }

    // MARK: - Actions

    func toggleFavorite(_ sessionID: UUID) {
        environment?.bookmarks.toggleFavorite(sessionID)
    }

    func isFavorite(_ sessionID: UUID) -> Bool {
        environment?.bookmarks.isFavorite(sessionID) ?? false
    }

    func delete(_ session: ClassroomSession) {
        guard let environment else { return }
        try? environment.repository.deleteSession(session)
        reload()
    }
}
