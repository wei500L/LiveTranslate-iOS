import Foundation
import OSLog
import SwiftData

/// Resumable migration of GUEST (local-only) classroom data into a signed-in
/// account's store. Runs after the first sign-in, on explicit user consent —
/// history is NEVER auto-uploaded.
///
/// Concurrency & memory contract:
///   - everything runs on the main actor (SwiftData is main-actor here);
///   - the guest store is read ONLY through `GuestLibraryReader` — a type
///     whose entire API surface is fetch/count (no insert, no delete, no
///     save: writes are structurally impossible through it). The reader
///     additionally opens the store with allowsSave=false; the API boundary
///     is the primary guard, the flag the second;
///   - models never cross contexts or actors: each batch of sessions (plus
///     its entries) is converted to a Sendable value snapshot on the main
///     actor and ONLY the values move on. Batches are bounded
///     (`sessionBatchSize`), so the snapshot working set is bounded.
///
/// State machine (persisted in the ACCOUNT's defaults suite so it survives
/// restarts and stays per-account):
///
///     waiting → preparing → moving → queuedForUpload → completed
///                                     ↘ partiallyFailed
///
///   - `moving` records `copiedSessionIDs` after every confirmed batch, so
///     an interrupted run RESUMES from the last confirmed batch (skipping
///     those sessions) instead of restarting or double-copying;
///   - `partiallyFailed` records `failedSessionIDs` (the retryable scope);
///     a retry re-copies exactly those;
///   - UUID conflicts are COMPARED, never silently skipped or overwritten:
///     an existing account row with the same id must match in ownership
///     (session's own entries) and content, else it is recorded as a
///     conflict in `conflictedSessionIDs` and surfaced.
///
/// The guest store is only ever READ here; deleting the guest copy is a
/// separate, explicitly confirmed action and is only offered after the
/// copy AND the upload hand-off completed.
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

    /// Persisted record (per account). `copiedSessionIDs`/`failedSessionIDs`
    /// are the resume/conflict bookkeeping; they are cleared on completion.
    struct Record: Codable {
        var phase: Phase = .waiting
        var totalSessions: Int = 0
        var copiedSessionIDs: [UUID] = []
        var failedSessionIDs: [UUID] = []
        var conflictedSessionIDs: [UUID] = []
        var movedEntries: Int = 0
        var startedAt: Date?
        var finishedAt: Date?

        var copiedCount: Int { copiedSessionIDs.count }
    }

    private(set) var record: Record {
        didSet { persist() }
    }

    /// True while a migration pass is executing (blocks profile switches).
    var isRunning: Bool {
        record.phase == .preparing || record.phase == .moving
    }

    /// Sessions copied per batch (bounded working set: a session snapshot
    /// plus its entries is a few KB; the batch cap keeps the main-thread
    /// snapshot work short between persists).
    private let sessionBatchSize = 10

    private let accountID: UUID
    private let defaults: UserDefaults
    private let repository: any ClassroomRepositoryProtocol
    private let bookmarks: BookmarkStore
    private let sync: CloudSyncService?
    private let reader = GuestLibraryReader()

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
        // A crash mid-move resumes from the last confirmed batch on the
        // next construction (copiedSessionIDs carries the boundary).
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
    /// a not-yet-decided migration AND guest data exists.
    var needsPrompt: Bool {
        record.phase == .waiting && reader.sessionCount() > 0
    }

    /// True when some guest data is still un-migrated (banner in settings).
    var hasUnclaimedData: Bool {
        (record.phase == .waiting || record.phase == .partiallyFailed)
            && reader.sessionCount() > 0
    }

    /// Session count in the guest store (for the settings banner).
    func guestSessionCount() -> Int {
        reader.sessionCount()
    }

    // MARK: - Actions

    /// User chose 继续仅保存在本机 — nothing is copied, ever (unless they
    /// reopen the flow from the settings banner).
    func decline() {
        record.phase = .declined
        record.finishedAt = .now
    }

    /// User chose 上传并加入当前账号 (or retried a partially-failed run).
    /// Copies guest rows into the ACCOUNT store under their original UUIDs
    /// in bounded batches, then hands off to the normal initial-upload
    /// pipeline. The guest store is untouched.
    func beginMigration() {
        guard !isRunning else { return }
        record.phase = .preparing
        record.startedAt = .now
        record.failedSessionIDs = []
        record.conflictedSessionIDs = []
        Task { await run() }
    }

    /// Re-open a declined/partially-failed migration.
    func reopen() {
        record.phase = .waiting
    }

    private func run() async {
        // Bounded batch loop: read one batch of session snapshots from the
        // guest store (Sendable values only), copy it, persist the batch
        // boundary, then continue. Nothing loads the whole library.
        do {
            // Courses first (add-only union, like bookmarks: an account row
            // with the same id always wins) so session course references
            // resolve during the copy.
            mergeGuestCourses()
            // Notes are session-scoped; collect their ids for the copy
            // after the sessions exist.
            let guestNotes = reader.noteSnapshots()
            let sessionIDs = try reader.sessionIDs(excluding: Set(record.copiedSessionIDs))
            record.totalSessions = record.copiedCount + sessionIDs.count
            record.phase = .moving

            var index = 0
            while index < sessionIDs.count {
                let batchIDs = Array(sessionIDs[index..<min(index + sessionBatchSize, sessionIDs.count)])
                let snapshots = try reader.snapshots(forIDs: batchIDs)
                for snapshot in snapshots {
                    do {
                        switch try copySessionCheckingConflicts(snapshot) {
                        case .copied:
                            record.copiedSessionIDs.append(snapshot.id)
                            record.movedEntries += snapshot.entries.count
                        case .alreadyPresentIdentical:
                            // Our own previous copy (or a re-run): counted,
                            // never duplicated.
                            record.copiedSessionIDs.append(snapshot.id)
                        case .conflict:
                            record.conflictedSessionIDs.append(snapshot.id)
                        }
                    } catch {
                        record.failedSessionIDs.append(snapshot.id)
                        Self.logger.error(
                            "guest session copy failed: \(String(describing: error), privacy: .public)"
                        )
                    }
                }
                // Batch boundary persisted: an interruption resumes here.
                persist()
                index += batchIDs.count
            }
            copyGuestNotes(guestNotes)
            mergeGuestBookmarks()

            if record.copiedCount == 0 && (!record.failedSessionIDs.isEmpty || !record.conflictedSessionIDs.isEmpty) {
                // Nothing moved — either failures or conflicts consumed the
                // whole run; the retry scope is explicit either way.
                record.phase = .partiallyFailed
                record.finishedAt = .now
                return
            }
            // Hand the copied rows to the sync pipeline: reset the
            // account's first-upload flag so the initial upload snapshots
            // them (server-side idempotency + outbox per-entity merge make
            // the re-run of this trigger non-duplicating).
            record.phase = .queuedForUpload
            sync?.prepareForGuestMigrationUpload()
            if !record.failedSessionIDs.isEmpty || !record.conflictedSessionIDs.isEmpty {
                record.phase = .partiallyFailed
            } else {
                record.phase = .completed
                // Bookkeeping has served its purpose; drop the id lists.
                record.copiedSessionIDs = []
                record.failedSessionIDs = []
                record.conflictedSessionIDs = []
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

    enum CopyOutcome {
        case copied
        case alreadyPresentIdentical
        case conflict
    }

    /// Copies one session (+entries) into the account store under its
    /// ORIGINAL id, comparing any pre-existing row instead of skipping it
    /// silently: identical content (a previous copy of this very session)
    /// is treated as done; different content is a conflict, recorded and
    /// never overwritten.
    private func copySessionCheckingConflicts(_ session: GuestLibraryReader.SessionSnapshot) throws -> CopyOutcome {
        if let existing = repository.sessionSummary(id: session.id) {
            // Ownership + content comparison: same title, start time and
            // entry count ⇒ treat as our own prior copy.
            if existing.title == session.title,
               existing.startTime == session.startTime,
               existing.entryCount == session.entries.count {
                return .alreadyPresentIdentical
            }
            return .conflict
        }
        try copySession(session)
        return .copied
    }

    /// Copies the session and its entries through the repository's
    /// remote-apply path (it preserves ids) with serverVersion 0, so the
    /// sync layer treats them as fresh local data. The course reference is
    /// carried verbatim.
    private func copySession(_ session: GuestLibraryReader.SessionSnapshot) throws {
        let sessionRecord = SyncServerRecordDTO(
            id: session.id,
            title: session.title,
            startedAt: session.startTime,
            endedAt: session.endTime,
            duration: session.duration,
            sessionStatus: session.endTime == nil ? "active" : "finished",
            abnormalTermination: session.abnormalTermination,
            courseId: session.courseID,
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
        }
    }

    /// Copies guest courses into the account store (add-only union — an
    /// existing account row with the same id always wins, mirroring the
    /// bookmark merge; locally generated UUIDs make a real collision
    /// practically impossible).
    private func mergeGuestCourses() {
        for course in reader.courseSnapshots() {
            guard (try? repository.course(id: course.id)) ?? nil == nil else { continue }
            let record = SyncServerRecordDTO(
                id: course.id,
                title: course.name,
                teacher: course.teacherName,
                location: course.location,
                colorIndex: course.colorIndex,
                isArchived: course.isArchived,
                serverVersion: 0
            )
            try? repository.applyRemoteCourse(record: record, serverVersion: 0)
        }
    }

    /// Copies guest notes whose session now exists in the account store.
    /// The remote-apply path preserves ids and serverVersion 0.
    private func copyGuestNotes(_ notes: [GuestLibraryReader.NoteSnapshot]) {
        for note in notes {
            let noteRecord = SyncServerRecordDTO(
                id: note.id,
                sessionId: note.sessionID,
                noteText: note.text,
                anchorEntryId: note.anchorEntryID,
                serverVersion: 0
            )
            try? repository.applyRemoteNote(record: noteRecord, serverVersion: 0)
        }
    }

    /// Merges the guest bookmark ids into the account's store (union —
    /// existing account bookmarks win). Runs on the account's BookmarkStore.
    private func mergeGuestBookmarks() {
        let guestDefaults = UserDefaults.standard
        let guestKey = AccountScope.bookmarkKey(accountID: nil)
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
        guard record.phase == .completed else { return }
        let url = AccountScope.guestDatabaseURL
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            try? fm.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
        // Clear the guest bookmark record too (its sessions are gone).
        UserDefaults.standard.removeObject(forKey: AccountScope.bookmarkKey(accountID: nil))
        Self.logger.info("guest copy deleted after migration")
    }

    /// Readable status for the settings UI.
    var statusText: String {
        switch record.phase {
        case .waiting: return String(localized: "待处理")
        case .preparing: return String(localized: "准备中…")
        case .moving:
            return String(localized: "正在迁移 \(record.copiedCount)/\(record.totalSessions)")
        case .queuedForUpload: return String(localized: "已加入上传队列")
        case .completed: return String(localized: "已并入当前账号，云端上传进度见「同步状态」")
        case .partiallyFailed: return String(localized: "部分失败")
        case .declined: return String(localized: "仅保存在本机")
        }
    }
}

// MARK: - Guest library reader (the ONLY guest-store access path)

/// Read-only accessor for the guest (pre-sign-in) SwiftData store.
///
/// The write boundary is structural: this type exposes ONLY count / id /
/// snapshot queries. It performs no inserts, no deletes and no saves — and
/// it opens the store with `allowsSave: false` as a second layer, plus
/// `shouldAutosave = false` on its private context. All returned values
/// are Sendable snapshots; `@Model` objects never leave this type.
@MainActor
struct GuestLibraryReader {
    /// Sendable value snapshot of one guest session (bounded: a session
    /// plus its entries).
    struct SessionSnapshot: Sendable {
        struct Entry: Sendable {
            var id: UUID
            var sequenceID: Int
            var startOffset: TimeInterval
            var endOffset: TimeInterval
            var originalText: String
            var translatedText: String?
            var translationStatus: String
        }

        var id: UUID
        var title: String
        var startTime: Date
        var endTime: Date?
        var duration: TimeInterval
        var abnormalTermination: Bool
        var courseID: UUID?
        var entries: [Entry]
    }

    /// Sendable snapshot of one guest course.
    struct CourseSnapshot: Sendable {
        var id: UUID
        var name: String
        var teacherName: String
        var location: String
        var colorIndex: Int
        var isArchived: Bool
    }

    /// Sendable snapshot of one guest note.
    struct NoteSnapshot: Sendable {
        var id: UUID
        var sessionID: UUID
        var anchorEntryID: UUID?
        var text: String
    }

    private static let schema = Schema([
        ClassroomSession.self, TranscriptEntry.self, Course.self, SessionNote.self
    ])

    private var guestURL: URL { AccountScope.guestDatabaseURL }

    /// Opens the guest store read-only. Returns nil when the guest store
    /// does not exist (never signed in / already deleted).
    ///
    /// Upgrade path: a store written by an older app version lacks newer
    /// tables (courses / notes). A read-only open of such a store fails
    /// (lightweight migration cannot run without save), so on that — and
    /// only that — failure the store is brought forward ONCE through a
    /// normal container: the migration adds the missing tables and columns
    /// without touching any row content, after which the read-only open
    /// is retried.
    private func containerIfPresent() throws -> ModelContainer? {
        guard FileManager.default.fileExists(atPath: guestURL.path) else { return nil }
        if let container = try? Self.readOnlyContainer(url: guestURL) {
            return container
        }
        _ = try ModelContainer(
            for: Self.schema,
            configurations: [
                ModelConfiguration("LiveTranslate", schema: Self.schema, url: guestURL)
            ]
        )
        return try Self.readOnlyContainer(url: guestURL)
    }

    private static func readOnlyContainer(url: URL) throws -> ModelContainer {
        try ModelContainer(
            for: Self.schema,
            configurations: [
                ModelConfiguration(
                    "LiveTranslate", schema: Self.schema, url: url, allowsSave: false
                )
            ]
        )
    }

    /// Session count in the guest store (cheap; used for prompts/banners).
    func sessionCount() -> Int {
        guard let container = try? containerIfPresent() else { return 0 }
        let context = ModelContext(container)
        context.shouldAutosave = false
        return (try? context.fetchCount(FetchDescriptor<ClassroomSession>())) ?? 0
    }

    /// All guest session ids, optionally excluding already-copied ones.
    /// (Ids only — bounded memory regardless of library size.)
    func sessionIDs(excluding done: Set<UUID> = []) throws -> [UUID] {
        guard let container = try containerIfPresent() else { return [] }
        let context = ModelContext(container)
        context.shouldAutosave = false
        let sessions = try context.fetch(FetchDescriptor<ClassroomSession>())
        return sessions.map(\.id).filter { !done.contains($0) }
    }

    /// Snapshots of the GIVEN sessions (one bounded batch), values only.
    func snapshots(forIDs ids: [UUID]) throws -> [SessionSnapshot] {
        guard !ids.isEmpty else { return [] }
        guard let container = try containerIfPresent() else { return [] }
        let context = ModelContext(container)
        context.shouldAutosave = false
        let idSet = Set(ids)
        let sessions = try context.fetch(FetchDescriptor<ClassroomSession>())
        var out: [SessionSnapshot] = []
        out.reserveCapacity(ids.count)
        for s in sessions where idSet.contains(s.id) {
            let entries = s.entries.sorted { $0.sequenceID < $1.sequenceID }.map { e in
                SessionSnapshot.Entry(
                    id: e.id,
                    sequenceID: e.sequenceID,
                    startOffset: e.startOffset,
                    endOffset: e.endOffset,
                    originalText: e.originalText,
                    translatedText: e.translatedText,
                    translationStatus: e.translationStatus
                )
            }
            out.append(SessionSnapshot(
                id: s.id, title: s.title, startTime: s.startTime, endTime: s.endTime,
                duration: s.duration, abnormalTermination: s.abnormalTermination,
                courseID: s.courseID, entries: entries
            ))
        }
        return out
    }

    /// All guest courses, values only.
    func courseSnapshots() -> [CourseSnapshot] {
        guard let container = try? containerIfPresent() else { return [] }
        let context = ModelContext(container)
        context.shouldAutosave = false
        let courses = (try? context.fetch(FetchDescriptor<Course>())) ?? []
        return courses.map { c in
            CourseSnapshot(
                id: c.id, name: c.name, teacherName: c.teacherName,
                location: c.location, colorIndex: c.colorIndex, isArchived: c.isArchived
            )
        }
    }

    /// All guest notes, values only (copied after the sessions exist).
    func noteSnapshots() -> [NoteSnapshot] {
        guard let container = try? containerIfPresent() else { return [] }
        let context = ModelContext(container)
        context.shouldAutosave = false
        let notes = (try? context.fetch(FetchDescriptor<SessionNote>())) ?? []
        return notes.map { n in
            NoteSnapshot(
                id: n.id, sessionID: n.sessionID,
                anchorEntryID: n.anchorEntryID, text: n.text
            )
        }
    }
}
