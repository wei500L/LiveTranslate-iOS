import Foundation
import Observation

/// UI-layer bookmark and favorite store.
///
/// Persists **stable IDs only** — never content snapshots: session
/// favorites are `ClassroomSession.id`s and entry bookmarks are
/// (`sessionID`, `TranscriptEntry.id`) pairs. Screens resolve the current
/// title/text through the repository at display time, so re-translated
/// entries and renamed sessions always show their latest content, and
/// text bulk never accumulates in UserDefaults.
///
/// Storage is versioned: `ui.bookmarks.v2` holds everything. The legacy v1
/// keys (full text snapshots) are migrated once at init and then left in
/// place until a later, verified release removes them.
@MainActor
@Observable
final class BookmarkStore {
    /// One bookmarked transcript entry, identified by the persisted
    /// `TranscriptEntry` stable UUID.
    struct EntryBookmark: Identifiable, Codable, Equatable {
        let id: UUID
        let sessionID: UUID
        let entryID: UUID
        let createdAt: Date

        init(
            id: UUID = UUID(),
            sessionID: UUID,
            entryID: UUID,
            createdAt: Date = .now
        ) {
            self.id = id
            self.sessionID = sessionID
            self.entryID = entryID
            self.createdAt = createdAt
        }
    }

    /// Versioned on-disk record (v2: IDs only).
    private struct StoreRecord: Codable {
        var version = 2
        var entryBookmarks: [EntryBookmark] = []
        var favoriteSessionIDs: [UUID] = []
    }

    /// Legacy v1 record — decode-only, for the one-shot migration below.
    /// The v1 format also stored original/translated text and a session
    /// title snapshot; those fields are deliberately ignored (IDs make them
    /// redundant).
    private struct LegacyEntryBookmark: Codable {
        let sessionID: UUID
        let sequenceID: Int
        let createdAt: Date?
    }

    private static let storeKey = "ui.bookmarks.v2"
    // v1 keys — TEMPORARY: kept intact (not deleted) until a verified
    // release confirms the v2 migration, so a downgrade never loses data.
    private static let legacyBookmarksKey = "ui.bookmarks.entries"
    private static let legacyFavoritesKey = "ui.bookmarks.favoriteSessions"

    private let defaults: UserDefaults
    private let repository: (any ClassroomRepositoryProtocol)?

    private(set) var entryBookmarks: [EntryBookmark] = []
    private(set) var favoriteSessionIDs: Set<UUID> = []

    init(
        defaults: UserDefaults = .standard,
        repository: (any ClassroomRepositoryProtocol)? = nil
    ) {
        self.defaults = defaults
        self.repository = repository
        load()
    }

    // MARK: - Loading / migration

    private func load() {
        if let data = defaults.data(forKey: Self.storeKey),
           let record = try? JSONDecoder().decode(StoreRecord.self, from: data) {
            entryBookmarks = record.entryBookmarks
            favoriteSessionIDs = Set(record.favoriteSessionIDs)
            return
        }
        migrateLegacyStoreIfNeeded()
    }

    /// TEMPORARY v1 → v2 migration (runs once, when no v2 record exists).
    /// v1 keyed bookmarks by (sessionID, sequenceID) and stored full text
    /// snapshots; v2 stores the persisted entry's stable UUID. Each legacy
    /// record is resolved through the repository: records whose session or
    /// entry no longer exists are dropped (they were already invisible in
    /// v1's pruned view). Unparseable legacy data decodes to nil and is
    /// skipped — it must never crash the launch path. The legacy keys stay
    /// on disk; only the new v2 key is written.
    private func migrateLegacyStoreIfNeeded() {
        let legacyFavorites = defaults.stringArray(forKey: Self.legacyFavoritesKey) ?? []
        favoriteSessionIDs = Set(legacyFavorites.compactMap(UUID.init(uuidString:)))

        guard let data = defaults.data(forKey: Self.legacyBookmarksKey),
              let legacy = try? JSONDecoder().decode([LegacyEntryBookmark].self, from: data) else {
            // Favorites migrate independently of entry bookmarks; only
            // persist when there is something to carry over.
            if !favoriteSessionIDs.isEmpty { persist() }
            return
        }
        guard let repository else { return }

        let sessions = (try? repository.sessions(matching: "")) ?? []
        let sessionsByID = Dictionary(
            sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        var migrated: [EntryBookmark] = []
        for record in legacy {
            guard let session = sessionsByID[record.sessionID] else { continue }
            let entries = (try? repository.entries(for: session)) ?? []
            // sequenceID is unique within a session (monotonic per
            // utterance), so this lookup is unambiguous.
            guard let entry = entries.first(where: { $0.sequenceID == record.sequenceID }) else {
                continue
            }
            migrated.append(EntryBookmark(
                sessionID: record.sessionID,
                entryID: entry.id,
                createdAt: record.createdAt ?? .now
            ))
        }
        entryBookmarks = migrated
        persist()
    }

    // MARK: - Entry bookmarks

    func isBookmarked(entryID: UUID) -> Bool {
        entryBookmarks.contains { $0.entryID == entryID }
    }

    func bookmarks(in sessionID: UUID) -> [EntryBookmark] {
        entryBookmarks
            .filter { $0.sessionID == sessionID }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Toggle a bookmark by stable entry ID; returns the new state.
    @discardableResult
    func toggleBookmark(sessionID: UUID, entryID: UUID) -> Bool {
        if let index = entryBookmarks.firstIndex(where: { $0.entryID == entryID }) {
            entryBookmarks.remove(at: index)
            persist()
            return false
        }
        entryBookmarks.append(EntryBookmark(sessionID: sessionID, entryID: entryID))
        entryBookmarks.sort { $0.createdAt < $1.createdAt }
        persist()
        return true
    }

    // MARK: - Session favorites

    func isFavorite(_ sessionID: UUID) -> Bool {
        favoriteSessionIDs.contains(sessionID)
    }

    /// Toggle favorite; returns the new state.
    @discardableResult
    func toggleFavorite(_ sessionID: UUID) -> Bool {
        if favoriteSessionIDs.contains(sessionID) {
            favoriteSessionIDs.remove(sessionID)
            persist()
            return false
        }
        favoriteSessionIDs.insert(sessionID)
        persist()
        return true
    }

    // MARK: - Maintenance

    /// Drop bookmarks/favorites referencing sessions that no longer exist
    /// (called after deletion from the records list).
    func pruneSessions(_ existingIDs: Set<UUID>) {
        let previousCount = entryBookmarks.count + favoriteSessionIDs.count
        entryBookmarks.removeAll { !existingIDs.contains($0.sessionID) }
        favoriteSessionIDs.formIntersection(existingIDs)
        if entryBookmarks.count + favoriteSessionIDs.count != previousCount {
            persist()
        }
    }

    /// Drop entry bookmarks whose entry no longer exists in its session,
    /// so orphaned IDs never linger in the store.
    func pruneEntries(in sessionID: UUID, existingEntryIDs: Set<UUID>) {
        let previousCount = entryBookmarks.count
        entryBookmarks.removeAll {
            $0.sessionID == sessionID && !existingEntryIDs.contains($0.entryID)
        }
        if entryBookmarks.count != previousCount {
            persist()
        }
    }

    private func persist() {
        let record = StoreRecord(
            entryBookmarks: entryBookmarks,
            favoriteSessionIDs: favoriteSessionIDs
                .sorted { $0.uuidString < $1.uuidString }
        )
        if let data = try? JSONEncoder().encode(record) {
            defaults.set(data, forKey: Self.storeKey)
        }
    }
}
