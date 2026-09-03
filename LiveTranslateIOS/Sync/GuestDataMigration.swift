import Foundation
import OSLog
import SwiftData

/// Resumable migration of GUEST (local-only) classroom data into a signed-in
/// account's store. Runs after the first sign-in, on explicit user consent —
/// history is NEVER auto-uploaded.
///
/// State machine (persisted in the ACCOUNT's defaults suite so it survives
/// restarts and stays per-account):
///
///     waiting → preparing → moving → queuedForUpload → completed
///                                     ↘ partiallyFailed
///
/// Guarantees:
///   - the ORIGINAL session/entry UUIDs are preserved (no duplicates: a
///     re-run skips ids already present in the account store);
///   - the guest store is only ever READ here — deleting the guest copy is
///     a separate, explicit user action;
///   - any interruption leaves the guest data intact; the state machine
///     resumes from `moving` on relaunch;
///   - errors mark `partiallyFailed` and keep the already-copied rows.
@MainActor
@Observable
final class GuestDataMigration {
    private static let logger = Logger(
        subsystem: "com.livetranslate.ios", category: "guest-migration"
    )

    enum Phase: String, Codable {
        case waiting
        case preparing
        case moving
        case queuedForUpload
        case completed
        case partiallyFailed
        /// The user chose to keep the data local-only; nothing was copied.
        case declined
    }

    /// Persisted record (per account).
    struct Record: Codable {
        var phase: Phase = .waiting
        var totalSessions: Int = 0
        var movedSessions: Int = 0
        var movedEntries: Int = 0
        var startedAt: Date?
        var finishedAt: Date?
    }

    private(set) var record: Record {
        didSet { persist() }
    }

    /// True while a migration pass is executing (blocks profile switches).
    var isRunning: Bool {
        record.phase == .preparing || record.phase == .moving
    }

    private let accountID: UUID
    private let defaults: UserDefaults
    private let repository: any ClassroomRepositoryProtocol
    private let bookmarks: BookmarkStore
    private let sync: CloudSyncService?

    private static let recordKey = "guestMigration.record"

    init(
        accountID: UUID,
        repository: any ClassroomRepositoryProtocol,
        bookmarks: BookmarkStore,
        sync: CloudSyncService?
    ) {
        self.accountID = accountID
        self.defaults = AccountStore.defaultsSuite(accountID: accountID)
        self.repository = repository
        self.bookmarks = bookmarks
        self.sync = sync
        if let data = defaults.data(forKey: Self.recordKey),
           let decoded = try? JSONDecoder().decode(Record.self, from: data) {
            self.record = decoded
        } else {
            self.record = Record()
        }
        // A crash mid-move resumes on next construction.
        if record.phase == .preparing || record.phase == .moving {
            record.phase = .moving
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(record) {
            defaults.set(data, forKey: Self.recordKey)
        }
    }

    /// Whether the "本机记录待归属" prompt should be shown for this account:
    /// a waiting/declined-then-reopened migration AND guest data exists.
    var needsPrompt: Bool {
        record.phase == .waiting && guestStoreHasContent()
    }

    /// True when some guest data is still un-migrated (banner in settings).
    var hasUnclaimedData: Bool {
        (record.phase == .waiting || record.phase == .partiallyFailed)
            && guestStoreHasContent()
    }

    // MARK: - Guest store access (read-only)

    private static let guestSchema = Schema([ClassroomSession.self, TranscriptEntry.self])

    /// Opens the GUEST store (the legacy global SQLite file) READ-ONLY.
    private func guestContainer() throws -> ModelContainer {
        let config = ModelConfiguration(
            "LiveTranslate",
            schema: Self.guestSchema,
            url: AppEnvironment.databaseURL(accountID: nil),
            allowsSave: false
        )
        return try ModelContainer(for: Self.guestSchema, configurations: [config])
    }

    /// Cheap existence probe for the guest store (no copy).
    func guestStoreHasContent() -> Bool {
        guestSessionCount() > 0
    }

    /// Session count in the guest store (cached after the first probe —
    /// opening the read-only container on every render would be wasteful;
    /// @ObservationIgnored: a cache, not UI state).
    @ObservationIgnored private var cachedGuestCount: Int?
    func guestSessionCount() -> Int {
        if let cachedGuestCount { return cachedGuestCount }
        let url = AppEnvironment.databaseURL(accountID: nil)
        guard FileManager.default.fileExists(atPath: url.path) else {
            cachedGuestCount = 0
            return 0
        }
        guard let container = try? guestContainer() else {
            cachedGuestCount = 0
            return 0
        }
        let context = ModelContext(container)
        context.shouldAutosave = false
        let n = (try? context.fetchCount(FetchDescriptor<ClassroomSession>())) ?? 0
        cachedGuestCount = n
        return n
    }

    /// Snapshot of the guest library as plain values (crosses from the
    /// guest container into the account's actor space as data, not models).
    private struct GuestSnapshot {
        struct Entry {
            var id: UUID
            var sequenceID: Int
            var startOffset: TimeInterval
            var endOffset: TimeInterval
            var originalText: String
            var translatedText: String?
            var translationStatus: String
        }

        struct Session {
            var id: UUID
            var title: String
            var startTime: Date
            var endTime: Date?
            var duration: TimeInterval
            var sourceLanguage: String
            var targetLanguage: String
            var abnormalTermination: Bool
            var entries: [Entry]
        }

        var sessions: [Session]
    }

    private func snapshotGuest() throws -> GuestSnapshot {
        let container = try guestContainer()
        let context = ModelContext(container)
        context.shouldAutosave = false
        let sessionRows = try context.fetch(FetchDescriptor<ClassroomSession>())
        var snap = GuestSnapshot(sessions: [])
        for s in sessionRows {
            let entries = s.entries.sorted { $0.sequenceID < $1.sequenceID }.map { e in
                GuestSnapshot.Entry(
                    id: e.id,
                    sequenceID: e.sequenceID,
                    startOffset: e.startOffset,
                    endOffset: e.endOffset,
                    originalText: e.originalText,
                    translatedText: e.translatedText,
                    translationStatus: e.translationStatus
                )
            }
            snap.sessions.append(GuestSnapshot.Session(
                id: s.id, title: s.title, startTime: s.startTime, endTime: s.endTime,
                duration: s.duration, sourceLanguage: s.sourceLanguage,
                targetLanguage: s.targetLanguage, abnormalTermination: s.abnormalTermination,
                entries: entries
            ))
        }
        return snap
    }

    // MARK: - Actions

    /// User chose 继续仅保存在本机 — nothing is copied, ever (unless they
    /// reopen the flow from the settings banner).
    func decline() {
        record.phase = .declined
        record.finishedAt = .now
    }

    /// User chose 上传并加入当前账号. Copy guest rows into the ACCOUNT store
    /// under their original UUIDs (serverVersion 0 so the sync layer treats
    /// them as fresh local data), then hand off to the normal initial-upload
    /// pipeline. The guest store is untouched.
    func beginMigration() {
        guard !isRunning else { return }
        record.phase = .preparing
        record.startedAt = .now
        record.movedSessions = 0
        record.movedEntries = 0
        Task { await run() }
    }

    /// Re-open a declined/partially-failed migration.
    func reopen() {
        record.phase = .waiting
    }

    private func run() async {
        do {
            let snap = try snapshotGuest()
            record.totalSessions = snap.sessions.count
            record.phase = .moving

            var failures = 0
            for session in snap.sessions {
                do {
                    try copySession(session)
                    record.movedSessions += 1
                } catch {
                    failures += 1
                    Self.logger.error(
                        "guest session copy failed: \(String(describing: error), privacy: .public)"
                    )
                }
            }
            mergeGuestBookmarks()

            if failures > 0 && record.movedSessions == 0 {
                record.phase = .partiallyFailed
                record.finishedAt = .now
                return
            }
            // Hand the copied rows to the sync pipeline: reset the account's
            // first-upload flag so the initial upload snapshots them.
            record.phase = .queuedForUpload
            sync?.prepareForGuestMigrationUpload()
            if failures > 0 {
                record.phase = .partiallyFailed
            } else {
                record.phase = .completed
            }
            record.finishedAt = .now
        } catch {
            Self.logger.error(
                "guest migration failed: \(String(describing: error), privacy: .public)"
            )
            record.phase = .partiallyFailed
            record.finishedAt = .now
        }
    }

    /// Copies one session (+entries) into the account store. Sessions whose
    /// id already exists are SKIPPED (idempotent re-run; no duplicates).
    /// The rows ride the repository's remote-apply path (it preserves ids)
    /// with serverVersion 0, so the sync layer treats them as fresh local
    /// data and the initial upload snapshots them.
    private func copySession(_ session: GuestSnapshot.Session) throws {
        if repository.sessionExists(id: session.id) { return }
        let sessionRecord = SyncServerRecordDTO(
            id: session.id,
            title: session.title,
            startedAt: session.startTime,
            endedAt: session.endTime,
            duration: session.duration,
            sessionStatus: session.endTime == nil ? "active" : "finished",
            abnormalTermination: session.abnormalTermination,
            serverVersion: 0
        )
        try repository.applyRemoteSession(record: sessionRecord, serverVersion: 0)

        for entry in session.entries {
            if repository.entryExists(id: entry.id) { continue }
            let entryRecord = SyncServerRecordDTO(
                id: entry.id,
                sessionId: session.id,
                sequenceId: entry.sequenceID,
                startOffset: entry.startOffset,
                endOffset: entry.endOffset,
                russianText: entry.originalText,
                chineseText: entry.translatedText,
                translationStatus: entry.translationStatus,
                serverVersion: 0
            )
            try repository.applyRemoteEntry(record: entryRecord, serverVersion: 0)
            record.movedEntries += 1
        }
    }

    /// Merges the guest bookmark ids into the account's store (union —
    /// existing account bookmarks win). Runs on the account's BookmarkStore.
    private func mergeGuestBookmarks() {
        let guestDefaults = UserDefaults.standard
        let guestKey = AccountStore.bookmarkKey(accountID: nil)
        guard let data = guestDefaults.data(forKey: guestKey) else { return }
        struct GuestRecord: Decodable {
            var entryBookmarks: [GuestBookmark]?
            var favoriteSessionIDs: [UUID]?
            struct GuestBookmark: Decodable {
                var entryID: UUID?
                var sessionID: UUID?
            }
        }
        guard let record = try? JSONDecoder().decode(GuestRecord.self, from: data) else { return }
        for favorite in record.favoriteSessionIDs ?? [] {
            bookmarks.addFavoriteIfMissing(sessionID: favorite)
        }
        for bookmark in record.entryBookmarks ?? [] {
            guard let entryID = bookmark.entryID, let sessionID = bookmark.sessionID else { continue }
            bookmarks.addBookmarkIfMissing(sessionID: sessionID, entryID: entryID)
        }
    }

    /// User explicitly confirmed deleting the guest copy AFTER a completed
    /// migration. Destructive to the GUEST store only; the account store
    /// (and the cloud copy) is untouched.
    func deleteGuestCopy() {
        let url = AppEnvironment.databaseURL(accountID: nil)
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            try? fm.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
        // Clear the guest bookmark record too (its sessions are gone).
        UserDefaults.standard.removeObject(forKey: AccountStore.bookmarkKey(accountID: nil))
        Self.logger.info("guest copy deleted after migration")
    }

    /// Readable status for the settings UI.
    var statusText: String {
        switch record.phase {
        case .waiting: return String(localized: "待处理")
        case .preparing: return String(localized: "准备中…")
        case .moving:
            return String(localized: "正在迁移 \(record.movedSessions)/\(record.totalSessions)")
        case .queuedForUpload: return String(localized: "已加入上传队列")
        case .completed: return String(localized: "已并入当前账号，云端上传进度见「同步状态」")
        case .partiallyFailed: return String(localized: "部分失败")
        case .declined: return String(localized: "仅保存在本机")
        }
    }
}
