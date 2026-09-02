import XCTest
@testable import LiveTranslateIOS

/// Sync-layer unit tests: outbox merge/retry/persistence semantics,
/// conflict merge rules, and the BookmarkStore sync plumbing. These run
/// on the simulator with no models or network — they verify the sync
/// link's local invariants only.
final class SyncOutboxTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncOutboxTests-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    private func upsert(
        entityType: SyncEntityType = .entry,
        entityID: UUID,
        russian: String = "привет",
        version: Int = 0
    ) -> SyncOutboxItem {
        SyncOutboxItem(
            entityType: entityType,
            entityID: entityID,
            operation: .upsert,
            baseServerVersion: version,
            payload: SyncPushPayloadDTO(russianText: russian)
        )
    }

    // MARK: - Merge rules

    func testConsecutiveUpsertsOfSameEntityMerge() async {
        let store = SyncOutboxStore(fileURL: fileURL)
        let entryID = UUID()
        await store.enqueue(upsert(entityID: entryID, russian: "один"))
        await store.enqueue(upsert(entityID: entryID, russian: "два"))
        let count = await store.pendingCount
        XCTAssertEqual(count, 1, "second upsert must replace the first")
        let due = await store.dueItems(limit: 10)
        XCTAssertEqual(due.first?.payload.russianText, "два")
        XCTAssertNotEqual(due.first?.operationID, UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
    }

    func testUpsertsOfDifferentEntitiesQueueSeparately() async {
        let store = SyncOutboxStore(fileURL: fileURL)
        await store.enqueue(upsert(entityID: UUID()))
        await store.enqueue(upsert(entityID: UUID()))
        let count = await store.pendingCount
        XCTAssertEqual(count, 2)
    }

    func testPendingDeleteBlocksLaterUpsert() async {
        let store = SyncOutboxStore(fileURL: fileURL)
        let sessionID = UUID()
        await store.enqueue(SyncOutboxItem(
            entityType: .session,
            entityID: sessionID,
            operation: .delete,
            baseServerVersion: 0,
            payload: SyncPushPayloadDTO()
        ))
        await store.enqueue(upsert(entityType: .session, entityID: sessionID))
        let count = await store.pendingCount
        XCTAssertEqual(count, 1, "an upsert after a pending delete must be dropped (no resurrection)")
        let due = await store.dueItems(limit: 10)
        XCTAssertEqual(due.first?.operation, .delete)
    }

    func testDeleteAfterUpsertKeepsBoth() async {
        // Edit-then-delete: the upsert still uploads (server keeps the
        // full history) and the delete then wins server-side.
        let store = SyncOutboxStore(fileURL: fileURL)
        let sessionID = UUID()
        await store.enqueue(upsert(entityID: sessionID))
        await store.enqueue(SyncOutboxItem(
            entityType: .session,
            entityID: sessionID,
            operation: .delete,
            baseServerVersion: 0,
            payload: SyncPushPayloadDTO()
        ))
        let count = await store.pendingCount
        XCTAssertEqual(count, 2)
    }

    // MARK: - Retry scheduling

    func testRetrySchedulesFutureAttempt() async {
        let store = SyncOutboxStore(fileURL: fileURL)
        let item = upsert(entityID: UUID())
        await store.enqueue(item)
        let scheduled = await store.scheduleRetry(
            operationID: item.operationID, serverRetryAfter: nil
        )
        XCTAssertTrue(scheduled)
        let dueNow = await store.dueItems(limit: 10)
        XCTAssertTrue(dueNow.isEmpty, "a retried item must not be immediately due")
        let dueLater = await store.dueItems(
            limit: 10, asOf: .now.addingTimeInterval(620)
        )
        XCTAssertEqual(dueLater.count, 1, "the item becomes due after the backoff window")
    }

    func testRetryBudgetIsBounded() async {
        let store = SyncOutboxStore(fileURL: fileURL)
        let item = upsert(entityID: UUID())
        await store.enqueue(item)
        for _ in 0..<8 {
            _ = await store.scheduleRetry(
                operationID: item.operationID, serverRetryAfter: nil
            )
        }
        let exhausted = await store.scheduleRetry(
            operationID: item.operationID, serverRetryAfter: nil
        )
        XCTAssertFalse(exhausted, "retry budget must be exhausted after maxRetries")
    }

    // MARK: - Rebase (conflict re-submission)

    func testRebaseReplacesBaseVersionAndPayload() async {
        let store = SyncOutboxStore(fileURL: fileURL)
        let item = upsert(entityID: UUID())
        await store.enqueue(item)
        var merged = item.payload
        merged.chineseText = "你好"
        await store.rebase(
            operationID: item.operationID, baseVersion: 3, payload: merged
        )
        let due = await store.dueItems(limit: 10)
        XCTAssertEqual(due.count, 1)
        XCTAssertEqual(due.first?.baseServerVersion, 3)
        XCTAssertEqual(due.first?.payload.chineseText, "你好")
    }

    // MARK: - Durability

    func testOutboxSurvivesRestart() async {
        let entryID = UUID()
        let store = SyncOutboxStore(fileURL: fileURL)
        await store.enqueue(upsert(entityID: entryID, russian: "перезагрузка"))
        let reloaded = SyncOutboxStore(fileURL: fileURL)
        let count = await reloaded.pendingCount
        XCTAssertEqual(count, 1)
        let due = await reloaded.dueItems(limit: 10)
        XCTAssertEqual(due.first?.entityID, entryID)
        XCTAssertEqual(due.first?.payload.russianText, "перезагрузка")
    }

    func testDropAllUpsertsKeepsDeletes() async {
        let store = SyncOutboxStore(fileURL: fileURL)
        await store.enqueue(upsert(entityID: UUID()))
        await store.enqueue(SyncOutboxItem(
            entityType: .session,
            entityID: UUID(),
            operation: .delete,
            baseServerVersion: 0,
            payload: SyncPushPayloadDTO()
        ))
        await store.dropAllUpserts()
        let due = await store.dueItems(limit: 10)
        XCTAssertEqual(due.count, 1)
        XCTAssertEqual(due.first?.operation, .delete)
    }
}

/// Conflict merge rules mirrored from the server's protocol v1.
final class SyncConflictResolverTests: XCTestCase {
    private func record(_ json: String) throws -> SyncServerRecordDTO {
        try JSONDecoder().decode(SyncServerRecordDTO.self, from: Data(json.utf8))
    }

    func testServerRussianWinsOverLocal() throws {
        var local = SyncPushPayloadDTO()
        local.russianText = "локальная версия"
        let server = try record(#"{"serverVersion": 2, "russianText": "серверная версия"}"#)
        let merged = SyncConflictResolver.mergedPayload(entityType: .entry, local: local, server: server)
        XCTAssertEqual(merged?.russianText, "серверная версия", "the Russian original is immutable after first write")
    }

    func testEmptyServerRussianKeepsLocal() throws {
        var local = SyncPushPayloadDTO()
        local.russianText = "локальная версия"
        let server = try record(#"{"serverVersion": 2, "russianText": ""}"#)
        let merged = SyncConflictResolver.mergedPayload(entityType: .entry, local: local, server: server)
        XCTAssertEqual(merged?.russianText, "локальная версия", "empty server text gap-fills from local")
    }

    func testLocalChineseWinsWhenNonEmpty() throws {
        var local = SyncPushPayloadDTO()
        local.russianText = "текст"
        local.chineseText = "本地较新的翻译"
        let server = try record(#"{"serverVersion": 2, "russianText": "текст", "chineseText": "服务器旧翻译"}"#)
        let merged = SyncConflictResolver.mergedPayload(entityType: .entry, local: local, server: server)
        XCTAssertEqual(merged?.chineseText, "本地较新的翻译")
    }

    func testEmptyLocalChineseTakesServerChinese() throws {
        var local = SyncPushPayloadDTO()
        local.russianText = "текст"
        local.chineseText = nil
        let server = try record(#"{"serverVersion": 2, "russianText": "текст", "chineseText": "服务器翻译"}"#)
        let merged = SyncConflictResolver.mergedPayload(entityType: .entry, local: local, server: server)
        XCTAssertEqual(merged?.chineseText, "服务器翻译")
    }

    func testDeletedServerRecordNeverMerges() throws {
        var local = SyncPushPayloadDTO()
        local.russianText = "текст"
        let server = try record(#"{"serverVersion": 2, "russianText": "текст", "deleted": true}"#)
        let merged = SyncConflictResolver.mergedPayload(entityType: .entry, local: local, server: server)
        XCTAssertNil(merged, "deleted records must not resurrect through merge")
    }

    func testEmptyLocalTitleTakesServerTitle() throws {
        var local = SyncPushPayloadDTO()
        local.title = nil
        let server = try record(#"{"serverVersion": 2, "title": "高等数学 II"}"#)
        let merged = SyncConflictResolver.mergedPayload(entityType: .session, local: local, server: server)
        XCTAssertEqual(merged?.title, "高等数学 II")
    }

    func testBookmarkRecordDecodesEntryAndSessionIDs() throws {
        let server = try record(#"""
        {"serverVersion": 4, "id": "11111111-1111-1111-1111-111111111111",
         "sessionId": "22222222-2222-2222-2222-222222222222",
         "entryId": "33333333-3333-3333-3333-333333333333",
         "isBookmarked": true}
        """#)
        XCTAssertEqual(server.entryId, UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
        XCTAssertEqual(server.sessionId, UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        XCTAssertEqual(server.isBookmarked, true)
    }
}

/// BookmarkStore's sync plumbing: observer events, remote apply guards
/// and server-version bookkeeping.
@MainActor
final class BookmarkSyncTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "bookmark-sync-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testToggleFiresObserverWithBaseVersionZero() {
        let store = BookmarkStore(defaults: defaults)
        var changes: [BookmarkStore.SyncChange] = []
        store.syncObserver = { changes.append($0) }
        let sessionID = UUID()
        let entryID = UUID()

        store.toggleBookmark(sessionID: sessionID, entryID: entryID)
        XCTAssertEqual(changes.count, 1)
        guard case .bookmark(let s, let e, let on, let version) = changes[0] else {
            return XCTFail("expected bookmark change")
        }
        XCTAssertEqual(s, sessionID)
        XCTAssertEqual(e, entryID)
        XCTAssertTrue(on)
        XCTAssertEqual(version, 0, "a never-synced bookmark pushes with base version 0")

        store.toggleFavorite(sessionID)
        guard case .favorite(let fs, let favOn, let favVersion) = changes[1] else {
            return XCTFail("expected favorite change")
        }
        XCTAssertEqual(fs, sessionID)
        XCTAssertTrue(favOn)
        XCTAssertEqual(favVersion, 0)
    }

    func testApplyRemoteBookmarkInsertsAndRemoves() {
        let store = BookmarkStore(defaults: defaults)
        let sessionID = UUID()
        let entryID = UUID()

        store.applyRemoteBookmark(sessionID: sessionID, entryID: entryID, isBookmarked: true, version: 5)
        XCTAssertTrue(store.isBookmarked(entryID: entryID))
        XCTAssertEqual(store.serverVersion(forBookmark: entryID), 5)

        store.applyRemoteBookmark(sessionID: sessionID, entryID: entryID, isBookmarked: false, version: 6)
        XCTAssertFalse(store.isBookmarked(entryID: entryID))
    }

    func testApplyRemoteFavoriteRoundTrip() {
        let store = BookmarkStore(defaults: defaults)
        let sessionID = UUID()
        store.applyRemoteFavorite(sessionID: sessionID, isFavorite: true, version: 2)
        XCTAssertTrue(store.isFavorite(sessionID))
        store.applyRemoteFavorite(sessionID: sessionID, isFavorite: false, version: 3)
        XCTAssertFalse(store.isFavorite(sessionID))
    }

    func testRecordedVersionsSurviveReload() {
        let entryID = UUID()
        let sessionID = UUID()
        let store = BookmarkStore(defaults: defaults)
        store.recordRemoteVersion(entryID: entryID, version: 7)
        store.recordRemoteFavoriteVersion(sessionID: sessionID, version: 4)

        let reloaded = BookmarkStore(defaults: defaults)
        XCTAssertEqual(reloaded.serverVersion(forBookmark: entryID), 7)
        XCTAssertEqual(reloaded.serverVersion(forFavorite: sessionID), 4)
    }

    func testVersionedTogglePushesWithRecordedBase() {
        let store = BookmarkStore(defaults: defaults)
        let sessionID = UUID()
        let entryID = UUID()
        store.applyRemoteBookmark(sessionID: sessionID, entryID: entryID, isBookmarked: true, version: 9)

        var versions: [Int] = []
        store.syncObserver = { change in
            if case .bookmark(_, _, _, let version) = change { versions.append(version) }
        }
        store.toggleBookmark(sessionID: sessionID, entryID: entryID)
        XCTAssertEqual(versions, [9], "the next push must carry the acknowledged server version")
    }
}
