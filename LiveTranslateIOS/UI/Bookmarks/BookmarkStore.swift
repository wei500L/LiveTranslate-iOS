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
/// keys (full text snapshots) migrate through an explicit, resumable state
/// machine — a record is only dropped once its session/entry is
/// *confirmed* gone (a successful fetch that no longer contains it),
/// never merely because the repository could not be read yet.
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

    /// Resumable progress of the v1 → v2 migration, persisted alongside the
    /// v2 record so an interrupted or repository-blocked migration retries
    /// on the next launch (or the next `retryLegacyMigration()` call)
    /// instead of silently dropping records it could not resolve yet.
    struct MigrationProgress: Codable, Equatable {
        enum State: String, Codable {
            case notStarted
            /// The repository could not be read (e.g. cold-start store not
            /// ready). Nothing was dropped; retry later.
            case waitingForRepository
            /// Some records resolved, others are still waiting on the
            /// repository. Retry later.
            case partiallyMigrated
            /// Every legacy record either migrated to a v2 ID bookmark or
            /// was confirmed to reference data that no longer exists.
            case completed
        }

        var state: State
        /// Legacy records still awaiting resolution (kept verbatim; they
        /// key on `(sessionID, sequenceID)` and cannot become v2 IDs until
        /// the repository answers).
        var pending: [LegacyEntryBookmark] = []
    }

    /// Versioned on-disk record (v2: IDs only). `migration` is nil for
    /// records written before the resumable migration existed — those
    /// stores already ran the one-shot migration, so they count as
    /// completed. `*Versions` (added with the cloud sync) default to
    /// empty when absent, so older records decode unchanged.
    private struct StoreRecord: Codable {
        var version = 2
        var entryBookmarks: [EntryBookmark] = []
        var favoriteSessionIDs: [UUID] = []
        var migration: MigrationProgress?
        var bookmarkVersions: [String: Int] = [:]
        var favoriteVersions: [String: Int] = [:]

        enum CodingKeys: String, CodingKey {
            case version, entryBookmarks, favoriteSessionIDs, migration
            case bookmarkVersions, favoriteVersions
        }

        init(
            entryBookmarks: [EntryBookmark] = [],
            favoriteSessionIDs: [UUID] = [],
            migration: MigrationProgress? = nil,
            bookmarkVersions: [String: Int] = [:],
            favoriteVersions: [String: Int] = [:]
        ) {
            self.entryBookmarks = entryBookmarks
            self.favoriteSessionIDs = favoriteSessionIDs
            self.migration = migration
            self.bookmarkVersions = bookmarkVersions
            self.favoriteVersions = favoriteVersions
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 2
            entryBookmarks = try container.decodeIfPresent([EntryBookmark].self, forKey: .entryBookmarks) ?? []
            favoriteSessionIDs = try container.decodeIfPresent([UUID].self, forKey: .favoriteSessionIDs) ?? []
            migration = try container.decodeIfPresent(MigrationProgress.self, forKey: .migration)
            bookmarkVersions = try container.decodeIfPresent([String: Int].self, forKey: .bookmarkVersions) ?? [:]
            favoriteVersions = try container.decodeIfPresent([String: Int].self, forKey: .favoriteVersions) ?? [:]
        }
    }

    /// Legacy v1 record — decode-only, for the resumable migration below.
    /// The v1 format also stored original/translated text and a session
    /// title snapshot; those fields are deliberately ignored (IDs make them
    /// redundant).
    struct LegacyEntryBookmark: Codable, Equatable {
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
    /// Observable so screens can retry a blocked migration once their own
    /// repository reads succeed (e.g. the Bookmarks tab reload).
    private(set) var legacyMigration: MigrationProgress?

    // MARK: Cloud sync

    /// A local toggle the sync service should upload. The payload carries
    /// the server version of the target row (0 = never synced).
    enum SyncChange {
        case bookmark(sessionID: UUID, entryID: UUID, isBookmarked: Bool, version: Int)
        case favorite(sessionID: UUID, isFavorite: Bool, version: Int)
    }

    /// Cloud-sync hook: fires on user-driven bookmark/favorite changes.
    /// Remote-applied changes (below) do NOT fire it.
    var syncObserver: ((SyncChange) -> Void)?
    /// True while remote changes are being applied (re-entrancy guard for
    /// `syncObserver`).
    var isApplyingRemote = false
    /// Last acknowledged server version per bookmarked entry / favorited
    /// session (drives push baseVersions).
    private var bookmarkVersions: [UUID: Int] = [:]
    private var favoriteVersions: [UUID: Int] = [:]

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
            legacyMigration = record.migration ?? MigrationProgress(state: .completed)
            bookmarkVersions = record.bookmarkVersions.reduce(into: [:]) { dict, pair in
                if let id = UUID(uuidString: pair.key) { dict[id] = pair.value }
            }
            favoriteVersions = record.favoriteVersions.reduce(into: [:]) { dict, pair in
                if let id = UUID(uuidString: pair.key) { dict[id] = pair.value }
            }
        } else {
            // No v2 record yet: favorites migrate one-shot (a plain string
            // array that cannot fail partially); entry bookmarks start the
            // resumable migration from scratch.
            let legacyFavorites = defaults.stringArray(forKey: Self.legacyFavoritesKey) ?? []
            favoriteSessionIDs = Set(legacyFavorites.compactMap(UUID.init(uuidString:)))
            legacyMigration = MigrationProgress(state: .notStarted)
        }
        resumeLegacyMigration()
    }

    /// TEMPORARY v1 → v2 migration (resumable). v1 keyed bookmarks by
    /// (sessionID, sequenceID) and stored full text snapshots; v2 stores
    /// the persisted entry's stable UUID. Resolution rules:
    ///
    /// - repository read *throws* → the record stays pending (state
    ///   `waitingForRepository` / `partiallyMigrated`) and is retried on
    ///   the next launch or `retryLegacyMigration()`;
    /// - fetch succeeds and the session/entry is absent → confirmed
    ///   orphan, dropped;
    /// - fetch succeeds and the entry exists → converted to a v2 ID
    ///   bookmark; the progress record persists with each pass.
    ///
    /// Unparseable legacy data decodes to nil and ends the migration
    /// (nothing more can ever be done with it) without crashing. The
    /// legacy keys stay on disk; only the v2 key is written.
    private func resumeLegacyMigration() {
        guard legacyMigration?.state != .completed else { return }
        guard let data = defaults.data(forKey: Self.legacyBookmarksKey) else {
            legacyMigration = MigrationProgress(state: .completed)
            persist()
            return
        }
        // An unparseable legacy payload ends the migration rather than
        // crashing or retrying forever.
        guard let legacy = try? JSONDecoder().decode([LegacyEntryBookmark].self, from: data) else {
            legacyMigration = MigrationProgress(state: .completed)
            persist()
            return
        }

        // Resume a partially migrated pass from its pending list.
        let pending = (legacyMigration?.pending.isEmpty == false)
            ? legacyMigration!.pending
            : legacy
        guard let repository else {
            legacyMigration = MigrationProgress(state: .waitingForRepository, pending: pending)
            persist()
            return
        }

        // A *thrown* fetch means "not readable yet" — retry later. A
        // successful-but-absent lookup means the data is really gone.
        let sessions: [ClassroomSession]
        do {
            sessions = try repository.sessions(matching: "")
        } catch {
            legacyMigration = MigrationProgress(state: .waitingForRepository, pending: pending)
            persist()
            return
        }
        let sessionsByID = Dictionary(
            sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )

        var migrated = entryBookmarks
        var stillPending: [LegacyEntryBookmark] = []
        for record in pending {
            guard let session = sessionsByID[record.sessionID] else {
                continue // confirmed orphan: session permanently deleted
            }
            let entries: [TranscriptEntry]
            do {
                entries = try repository.entries(for: session)
            } catch {
                stillPending.append(record) // not readable yet — retry later
                continue
            }
            // sequenceID is unique within a session (monotonic per
            // utterance), so this lookup is unambiguous.
            guard let entry = entries.first(where: { $0.sequenceID == record.sequenceID }) else {
                continue // confirmed orphan: entry permanently deleted
            }
            migrated.append(EntryBookmark(
                sessionID: record.sessionID,
                entryID: entry.id,
                createdAt: record.createdAt ?? .now
            ))
        }
        entryBookmarks = migrated
        entryBookmarks.sort { $0.createdAt < $1.createdAt }
        legacyMigration = MigrationProgress(
            state: stillPending.isEmpty ? .completed : .partiallyMigrated,
            pending: stillPending
        )
        persist()
    }

    /// Re-entry for screens whose repository access succeeded after launch
    /// (e.g. the Bookmarks tab reload): keeps retrying a blocked or
    /// partial migration without waiting for the next launch.
    func retryLegacyMigration() {
        resumeLegacyMigration()
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
        let newState: Bool
        if let index = entryBookmarks.firstIndex(where: { $0.entryID == entryID }) {
            entryBookmarks.remove(at: index)
            newState = false
        } else {
            entryBookmarks.append(EntryBookmark(sessionID: sessionID, entryID: entryID))
            entryBookmarks.sort { $0.createdAt < $1.createdAt }
            newState = true
        }
        persist()
        syncObserver?(.bookmark(
            sessionID: sessionID, entryID: entryID,
            isBookmarked: newState, version: bookmarkVersions[entryID] ?? 0
        ))
        return newState
    }

    /// Remove a bookmark by record (bookmarks list action).
    func removeBookmark(_ bookmark: EntryBookmark) {
        entryBookmarks.removeAll { $0.id == bookmark.id }
        persist()
    }

    // MARK: - Session favorites

    func isFavorite(_ sessionID: UUID) -> Bool {
        favoriteSessionIDs.contains(sessionID)
    }

    /// Toggle favorite; returns the new state.
    @discardableResult
    func toggleFavorite(_ sessionID: UUID) -> Bool {
        let newState: Bool
        if favoriteSessionIDs.contains(sessionID) {
            favoriteSessionIDs.remove(sessionID)
            newState = false
        } else {
            favoriteSessionIDs.insert(sessionID)
            newState = true
        }
        persist()
        syncObserver?(.favorite(
            sessionID: sessionID, isFavorite: newState,
            version: favoriteVersions[sessionID] ?? 0
        ))
        return newState
    }

    // MARK: - Cloud sync (remote apply + version bookkeeping)

    /// Applies a remotely-synced bookmark state. Guarded by
    /// `isApplyingRemote` so it never re-enters the sync observer. A
    /// bookmark whose owning session cannot be determined (`sessionID`
    /// nil — only possible for orphaned server records) is skipped: the
    /// record-keyed UI cannot place it, and the version is still recorded
    /// so a later local toggle pushes the right base version.
    func applyRemoteBookmark(
        sessionID: UUID?, entryID: UUID, isBookmarked: Bool, version: Int
    ) {
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        let had = entryBookmarks.contains { $0.entryID == entryID }
        if isBookmarked, !had, let sessionID {
            entryBookmarks.append(EntryBookmark(sessionID: sessionID, entryID: entryID))
            entryBookmarks.sort { $0.createdAt < $1.createdAt }
        } else if !isBookmarked && had {
            entryBookmarks.removeAll { $0.entryID == entryID }
        }
        if version > 0 { bookmarkVersions[entryID] = version }
        persist()
    }

    /// Applies a remotely-synced favorite state.
    func applyRemoteFavorite(sessionID: UUID, isFavorite: Bool, version: Int) {
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        if isFavorite {
            favoriteSessionIDs.insert(sessionID)
        } else {
            favoriteSessionIDs.remove(sessionID)
        }
        if version > 0 { favoriteVersions[sessionID] = version }
        persist()
    }

    /// Records the server version acknowledged for a pushed bookmark.
    func recordRemoteVersion(entryID: UUID, version: Int) {
        bookmarkVersions[entryID] = version
        persist()
    }

    func recordRemoteFavoriteVersion(sessionID: UUID, version: Int) {
        favoriteVersions[sessionID] = version
        persist()
    }

    /// Server version backing the next push of this bookmark (0 = new).
    func serverVersion(forBookmark entryID: UUID) -> Int {
        bookmarkVersions[entryID] ?? 0
    }

    func serverVersion(forFavorite sessionID: UUID) -> Int {
        favoriteVersions[sessionID] ?? 0
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
                .sorted { $0.uuidString < $1.uuidString },
            migration: legacyMigration,
            bookmarkVersions: Dictionary(
                uniqueKeysWithValues: bookmarkVersions.map { ($0.key.uuidString, $0.value) }
            ),
            favoriteVersions: Dictionary(
                uniqueKeysWithValues: favoriteVersions.map { ($0.key.uuidString, $0.value) }
            )
        )
        if let data = try? JSONEncoder().encode(record) {
            defaults.set(data, forKey: Self.storeKey)
        }
    }
}
