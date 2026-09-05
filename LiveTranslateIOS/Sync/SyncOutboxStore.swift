import Foundation
import OSLog

/// A pending outbox operation. Persisted as JSON so the queue survives
/// app restarts; the store merges consecutive modifications of the same
/// entity (newest payload wins, fresh operationId).
struct SyncOutboxItem: Codable, Sendable, Identifiable, Equatable {
    var id: UUID { operationID }
    var operationID: UUID
    var entityType: SyncEntityType
    var entityID: UUID
    var operation: SyncOperation
    var baseServerVersion: Int
    var payload: SyncPushPayloadDTO
    var createdAt: Date
    var retryCount: Int = 0
    var nextRetryAt: Date? = nil
    var lastErrorCategory: String? = nil

    init(
        operationID: UUID = UUID(),
        entityType: SyncEntityType,
        entityID: UUID,
        operation: SyncOperation,
        baseServerVersion: Int,
        payload: SyncPushPayloadDTO,
        createdAt: Date = .now
    ) {
        self.operationID = operationID
        self.entityType = entityType
        self.entityID = entityID
        self.operation = operation
        self.baseServerVersion = baseServerVersion
        self.payload = payload
        self.createdAt = createdAt
    }
}

/// File-backed persistent outbox. An actor: writes are atomic
/// (temp-file + rename) JSON, reads are whole-file decodes. The queue is
/// small (thousands of items at most) and every mutation is O(queue), which
/// is fine for a text-metadata outbox — the point is durability and crash
/// safety, not throughput.
///
/// Merge rule: enqueueing an item for an entity that already has a pending
/// `upsert` replaces that item (newest payload + fresh operationId — the
/// superseded operation was never acknowledged, and even if the server had
/// already processed it and lost the response, the idempotency ledger
/// returns its stored result while the new operation carries the merged
/// state). A pending `delete` is never merged away by a later upsert.
actor SyncOutboxStore {
    private static let logger = Logger(
        subsystem: "com.livetranslate.ios", category: "sync-outbox"
    )

    private let fileURL: URL
    private var items: [SyncOutboxItem]
    private var dirty = false

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!
            self.fileURL = support.appendingPathComponent("SyncOutbox.json")
        }
        // Must mirror persist()'s ISO8601 date strategy, or every reload
        // silently decodes to an empty queue.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: self.fileURL),
           let decoded = try? decoder.decode([SyncOutboxItem].self, from: data) {
            items = decoded
        } else {
            items = []
        }
    }

    // MARK: - Counts (drives UI)

    var pendingCount: Int { items.count }
    var oldestCreatedAt: Date? { items.map(\.createdAt).min() }

    /// Items eligible for upload now (retry time passed), oldest first.
    func dueItems(limit: Int, asOf now: Date = .now) -> [SyncOutboxItem] {
        Array(
            items
                .filter { $0.nextRetryAt == nil || $0.nextRetryAt! <= now }
                .sorted { $0.createdAt < $1.createdAt }
                .prefix(limit)
        )
    }

    // MARK: - Enqueue

    /// Adds an operation, merging with a pending upsert of the same entity.
    func enqueue(_ item: SyncOutboxItem) {
        // A pending delete for the same entity wins over a later upsert
        // (deletion is the terminal local state).
        if item.operation == .upsert,
           items.contains(where: {
               $0.entityType == item.entityType
                   && $0.entityID == item.entityID
                   && $0.operation == .delete
           }) {
            return
        }
        // Merge consecutive upserts: replace the older pending item.
        items.removeAll {
            $0.entityType == item.entityType
                && $0.entityID == item.entityID
                && $0.operation == .upsert
        }
        items.append(item)
        persist()
    }

    /// Adds a whole batch (the initial library upload) with one merge pass
    /// and a single disk write, instead of one persist per item.
    func enqueue(_ batch: [SyncOutboxItem]) {
        guard !batch.isEmpty else { return }
        for item in batch {
            if item.operation == .upsert,
               items.contains(where: {
                   $0.entityType == item.entityType
                       && $0.entityID == item.entityID
                       && $0.operation == .delete
               }) {
                continue
            }
            items.removeAll {
                $0.entityType == item.entityType
                    && $0.entityID == item.entityID
                    && $0.operation == .upsert
            }
            items.append(item)
        }
        persist()
    }

    func remove(operationID: UUID) {
        let before = items.count
        items.removeAll { $0.operationID == operationID }
        if items.count != before {
            persist()
        }
    }

    /// Removes every pending operation for an entity (used after a
    /// rejected delete-resurrection, account switches…).
    func removeAll(for entityType: SyncEntityType, entityID: UUID) {
        let before = items.count
        items.removeAll { $0.entityType == entityType && $0.entityID == entityID }
        if items.count != before {
            persist()
        }
    }

    func removeAll() {
        guard !items.isEmpty else { return }
        items.removeAll()
        persist()
    }

    /// Removes everything EXCEPT delete operations — used after
    /// 删除云端副本: pending upserts would immediately re-upload the
    /// local library, deletes still propagate.
    func dropAllUpserts() {
        let before = items.count
        items.removeAll { $0.operation == .upsert }
        if items.count != before {
            persist()
        }
    }

    // MARK: - Retry bookkeeping

    /// Applies a retryable outcome: bounded exponential backoff with
    /// jitter, honoring a server-provided Retry-After when present.
    /// Returns false when the retry budget is exhausted (the item is then
    /// dropped by the caller and surfaced as a permanent failure).
    @discardableResult
    func scheduleRetry(
        operationID: UUID,
        serverRetryAfter: TimeInterval?,
        maxRetries: Int = 8,
        asOf now: Date = .now
    ) -> Bool {
        guard let index = items.firstIndex(where: { $0.operationID == operationID }) else {
            return false
        }
        guard items[index].retryCount < maxRetries else { return false }
        items[index].retryCount += 1
        items[index].lastErrorCategory = "retryable"
        let attempt = items[index].retryCount
        let base: TimeInterval
        if let serverRetryAfter, serverRetryAfter > 0 {
            base = serverRetryAfter
        } else {
            base = min(600, pow(2.0, Double(attempt)) * 2) // 4s…~10min
        }
        // ±25% jitter to avoid synchronized retry storms.
        let jitter = base * (0.75 + Double.random(in: 0...0.5))
        items[index].nextRetryAt = now.addingTimeInterval(jitter)
        persist()
        return true
    }

    func markError(operationID: UUID, category: String) {
        guard let index = items.firstIndex(where: { $0.operationID == operationID }) else {
            return
        }
        items[index].lastErrorCategory = category
        persist()
    }

    /// Replaces an item's base version + payload (conflict resolution:
    /// the client merged with the server record and re-submits).
    func rebase(
        operationID: UUID, baseVersion: Int, payload: SyncPushPayloadDTO
    ) {
        guard let index = items.firstIndex(where: { $0.operationID == operationID }) else {
            return
        }
        items[index].operationID = UUID() // fresh identity for the re-submission
        items[index].baseServerVersion = baseVersion
        items[index].payload = payload
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(items)
            let tmp = fileURL.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            // Rename is atomic on the same volume; a crash between write
            // and rename at worst re-plays already-processed operations
            // (idempotent server-side).
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            try FileManager.default.moveItem(at: tmp, to: fileURL)
            // classroomWorking: the outbox is written from the locked
            // background (a classroom's turns enqueue while the device is
            // locked) — same class as the store, NOT .complete.
            FileProtection.apply(.classroomWorking, to: fileURL)
        } catch {
            Self.logger.error(
                "outbox persist failed: \(String(describing: error), privacy: .public)"
            )
        }
    }
}
