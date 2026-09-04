import CryptoKit
import Foundation

/// The App Group file store behind the shared inbox — the ONLY component
/// that knows the on-disk layout, used identically by the Share Extension
/// (receive) and the main app (organize). Views and the extension UI
/// never build inbox paths themselves (the MaterialFileStore rule).
///
/// Layout inside the App Group container:
///
///     SharedInbox/
///       manifest.json          versioned metadata for every item
///       tmp/                   receive-in-progress payloads
///       items/<itemID>/payload.<ext>   atomically staged bytes
///
/// Write contract (receive): payload streams into tmp/ (SHA-256 computed
/// on the fly) → the item directory is created and the file moved in →
/// ONLY THEN does the manifest gain the item. An interrupted receive
/// therefore leaves at most an orphan tmp file (reaped at launch), never
/// a manifest entry without bytes.
///
/// Cross-process safety: every manifest read/write and every items-tree
/// mutation runs under NSFileCoordinator — the extension and the app can
/// both be alive. Manifest writes additionally use write-tmp + replace.
struct SharedInboxStore: Sendable {
    /// Maximum items accepted in ONE share (the extension screens before
    /// receiving; extras are reported, not silently dropped on the floor).
    static let maxItemsPerShare = 10
    /// Hard cap on stored text content (longer share text is kept as a
    /// FILE item instead — never silently truncated).
    static let textByteLimit = 200_000
    /// Manifest schema version.
    static let manifestSchemaVersion = 1

    /// The App Group identifier — derived from the app's bundle ID
    /// prefix (com.livetranslate.ios → group.com.livetranslate.ios). No
    /// team ID is involved in the group name.
    static let appGroupIdentifier = "group.com.livetranslate.ios"

    let root: URL

    // MARK: - Construction

    /// The real store inside the App Group container (returns nil when
    /// the container is unavailable — e.g. entitlement missing).
    init?() {
        guard let base = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) else { return nil }
        self.root = base.appendingPathComponent("SharedInbox", isDirectory: true)
        Self.prepareDirectories(root: root)
    }

    /// Store-internal init for tests and the Debug demo environment (a
    /// throwaway directory — the demo never touches the real App Group).
    init(root: URL) {
        self.root = root
        Self.prepareDirectories(root: root)
    }

    private static func prepareDirectories(root: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(
            at: root.appendingPathComponent("items", isDirectory: true),
            withIntermediateDirectories: true
        )
        try? fm.createDirectory(
            at: root.appendingPathComponent("tmp", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    private var manifestURL: URL { root.appendingPathComponent("manifest.json") }
    private var itemsRoot: URL { root.appendingPathComponent("items", isDirectory: true) }
    private var tmpRoot: URL { root.appendingPathComponent("tmp", isDirectory: true) }
    private var appGroupDefaults: UserDefaults? {
        UserDefaults(suiteName: Self.appGroupIdentifier)
    }

    // MARK: - Manifest

    struct Manifest: Codable, Sendable, Equatable {
        var schemaVersion: Int = SharedInboxStore.manifestSchemaVersion
        var items: [SharedInboxItem] = []
    }

    /// Reads the manifest (empty when absent or unreadable — a corrupt
    /// manifest never crashes the app; the reconcile pass can rebuild).
    /// Coordinated shared read.
    func loadManifest() -> Manifest {
        var data: Data?
        var error: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: manifestURL, options: [], error: &error) { url in
            data = try? Data(contentsOf: url)
        }
        guard let data, !data.isEmpty else { return Manifest() }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            return Manifest()
        }
        return manifest
    }

    /// Replaces the manifest under an exclusive coordinated write
    /// (write-tmp + atomic replace). The manifest is the single source of
    /// truth — item files are never removed before their entry is gone.
    func saveManifest(_ manifest: Manifest) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(manifest) else { return }
        let tmp = root.appendingPathComponent(".manifest-\(UUID().uuidString).json")
        let fm = FileManager.default
        do {
            try data.write(to: tmp, options: .atomic)
            var error: NSError?
            let coordinator = NSFileCoordinator(filePresenter: nil)
            coordinator.coordinate(writingItemAt: manifestURL, options: [.forReplacing], error: &error) { url in
                if fm.fileExists(atPath: url.path) {
                    _ = try? fm.replaceItemAt(url, withItemAt: tmp)
                } else {
                    try? fm.moveItem(at: tmp, to: url)
                }
            }
            try? fm.removeItem(at: tmp)
        } catch {
            // Non-fatal by design: a failed manifest save leaves the
            // previous manifest in place.
        }
    }

    /// Mutates the manifest under one exclusive coordinated
    /// read-modify-write — the only sanctioned mutation path for both the
    /// extension (append received items) and the app (status/ledger
    /// updates). Returns the merged manifest. The mutate closure runs
    /// synchronously inside the coordinated block (NOT @Sendable — it may
    /// capture and mutate caller locals, e.g. the updated item).
    @discardableResult
    func updateManifest(
        _ mutate: (inout Manifest) -> Void
    ) -> Manifest {
        var merged: Manifest?
        var error: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: manifestURL, options: [], error: &error) { url in
            var manifest: Manifest
            if let data = try? Data(contentsOf: url), !data.isEmpty,
               let decoded = try? JSONDecoder().decode(Manifest.self, from: data) {
                manifest = decoded
            } else {
                manifest = Manifest()
            }
            mutate(&manifest)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(manifest) {
                let tmp = root.appendingPathComponent(".manifest-\(UUID().uuidString).json")
                if (try? data.write(to: tmp, options: .atomic)) != nil {
                    if FileManager.default.fileExists(atPath: url.path) {
                        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
                    } else {
                        try? FileManager.default.moveItem(at: tmp, to: url)
                    }
                    try? FileManager.default.removeItem(at: tmp)
                }
            }
            merged = manifest
        }
        return merged ?? loadManifest()
    }

    // MARK: - Payload staging (receive path)

    /// Streams bytes from `source` into the item directory, computing
    /// SHA-256 on the fly (a large PDF never enters memory whole).
    /// Returns the metadata the caller folds into the manifest item.
    struct StagedPayload: Sendable {
        var relativePath: String
        var byteCount: Int64
        var contentHash: String
    }

    func stagePayload(
        itemID: UUID, source: URL, preferredExtension: String
    ) throws -> StagedPayload {
        let fm = FileManager.default
        let ext = preferredExtension.isEmpty ? "bin" : preferredExtension
        let itemDirectory = itemsRoot.appendingPathComponent(itemID.uuidString, isDirectory: true)
        let destination = itemDirectory.appendingPathComponent("payload.\(ext)")
        let tmp = tmpRoot.appendingPathComponent("\(itemID.uuidString).\(ext)")

        do {
            try fm.createDirectory(at: itemDirectory, withIntermediateDirectories: true)
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            guard fm.createFile(atPath: tmp.path, contents: nil) else {
                throw ReceiveError.writeFailed
            }
            let output = try FileHandle(forWritingTo: tmp)
            defer { try? output.close() }
            var hasher = SHA256()
            var total: Int64 = 0
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
                try output.write(contentsOf: chunk)
                total += Int64(chunk.count)
            }
            guard total > 0 else {
                try? fm.removeItem(at: tmp)
                throw ReceiveError.emptyPayload
            }
            // Bytes are complete on disk in tmp — move them into the
            // item directory (same-volume move = atomic rename).
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: destination)
            }
            return StagedPayload(
                relativePath: "items/\(itemID.uuidString)/payload.\(ext)",
                byteCount: total,
                contentHash: hasher.finalize().map { String(format: "%02x", $0) }.joined()
            )
        } catch {
            try? fm.removeItem(at: tmp)
            throw ReceiveError.writeFailed
        }
    }

    /// Writes text bytes (kind .text stores its payload as a file too —
    /// a long share text is real content, not a manifest field).
    func stageTextPayload(itemID: UUID, text: String) throws -> StagedPayload {
        let tmp = tmpRoot.appendingPathComponent("\(itemID.uuidString).txt")
        let fm = FileManager.default
        guard let data = text.data(using: .utf8), !data.isEmpty,
              fm.createFile(atPath: tmp.path, contents: data)
        else { throw ReceiveError.writeFailed }
        do {
            let staged = try finalizeStaged(
                itemID: itemID, tmp: tmp, extensionName: "txt", byteCount: Int64(data.count)
            )
            var hasher = SHA256()
            hasher.update(data: data)
            return StagedPayload(
                relativePath: staged.relativePath,
                byteCount: staged.byteCount,
                contentHash: hasher.finalize().map { String(format: "%02x", $0) }.joined()
            )
        } catch {
            throw ReceiveError.writeFailed
        }
    }

    private func finalizeStaged(
        itemID: UUID, tmp: URL, extensionName: String, byteCount: Int64
    ) throws -> StagedPayload {
        let fm = FileManager.default
        let itemDirectory = itemsRoot.appendingPathComponent(itemID.uuidString, isDirectory: true)
        try fm.createDirectory(at: itemDirectory, withIntermediateDirectories: true)
        let destination = itemDirectory.appendingPathComponent("payload.\(extensionName)")
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: destination)
        }
        return StagedPayload(
            relativePath: "items/\(itemID.uuidString)/payload.\(extensionName)",
            byteCount: byteCount,
            contentHash: ""
        )
    }

    // MARK: - Manifest append (the receive commit point)

    /// Commits a fully-staged item into the manifest. Payload bytes are
    /// already on disk; this call is the last receive step (see the write
    /// contract above). Duplicate receive of the same item id is a no-op.
    func appendReceivedItem(_ item: SharedInboxItem) {
        updateManifest { manifest in
            guard !manifest.items.contains(where: { $0.id == item.id }) else { return }
            manifest.items.append(item)
            manifest.schemaVersion = Self.manifestSchemaVersion
        }
    }

    // MARK: - Payload access (app-side)

    /// Absolute URL of one item's staged payload (nil for text/url items
    /// or when the file is missing). Views never build this path.
    func payloadURL(for item: SharedInboxItem) -> URL? {
        guard !item.relativeFilePath.isEmpty else { return nil }
        return root.appendingPathComponent(item.relativeFilePath)
    }

    func payloadExists(for item: SharedInboxItem) -> Bool {
        guard let url = payloadURL(for: item) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Payload bytes (previews; bounded by file size — large PDF
    /// consumers must use `payloadURL` and stream).
    func payloadData(for item: SharedInboxItem) -> Data? {
        guard let url = payloadURL(for: item) else { return nil }
        return try? Data(contentsOf: url)
    }

    // MARK: - Lifecycle mutations (app-side)

    /// Applies a status/ledger mutation to one item under the manifest
    /// lock. Returns the updated item (nil when the id vanished).
    @discardableResult
    func updateItem(
        id: UUID, _ mutate: (inout SharedInboxItem) -> Void
    ) -> SharedInboxItem? {
        var updated: SharedInboxItem?
        updateManifest { manifest in
            guard let index = manifest.items.firstIndex(where: { $0.id == id }) else { return }
            mutate(&manifest.items[index])
            updated = manifest.items[index]
        }
        return updated
    }

    /// Removes items (manifest entries first, then the payload files —
    /// an interrupted delete leaves an orphan directory, which the launch
    /// reconcile reaps; it can never leave a metadata-only ghost).
    func removeItems(ids: [UUID]) {
        let set = Set(ids)
        var removed: [SharedInboxItem] = []
        updateManifest { manifest in
            removed = manifest.items.filter { set.contains($0.id) }
            manifest.items.removeAll { set.contains($0.id) }
        }
        for item in removed {
            removeItemDirectory(itemID: item.id)
        }
    }

    /// Removes every COMPLETED item but keeps a compact history trail:
    /// the payload files are deleted, and the manifest entries collapse
    /// to a lightweight tombstone-free record is NOT kept (the formal
    /// entities already represent the outcome). This is the 清理已完成
    /// action.
    func removeCompletedItems() {
        var completed: [SharedInboxItem] = []
        updateManifest { manifest in
            completed = manifest.items.filter { $0.status == .completed }
            manifest.items.removeAll { $0.status == .completed }
        }
        for item in completed {
            removeItemDirectory(itemID: item.id)
        }
    }

    /// Deletes every item of one scope (account removal — the items
    /// belong to the removed profile; formal entities live their own
    /// lives in that profile's store, which the caller removes too).
    func removeItems(scopeKey: String) {
        var removed: [SharedInboxItem] = []
        updateManifest { manifest in
            removed = manifest.items.filter { $0.scopeKey == scopeKey }
            manifest.items.removeAll { $0.scopeKey == scopeKey }
        }
        for item in removed {
            removeItemDirectory(itemID: item.id)
        }
    }

    private func removeItemDirectory(itemID: UUID) {
        let dir = itemsRoot.appendingPathComponent(itemID.uuidString, isDirectory: true)
        var error: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: dir, options: [.forDeleting], error: &error) { url in
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Reconcile (launch / foreground)

    /// Reconciles on-disk state after crashes and version changes:
    /// - items stuck in a transient state (inspecting/processing) return
    ///   to a decision point, never silently continue executing actions;
    /// - items whose payload file is missing are marked failed (honest —
    ///   they cannot be imported);
    /// - duplicate ids collapse;
    /// - orphan tmp files and item directories without a manifest entry
    ///   are reaped.
    /// Returns the reconciled manifest.
    @discardableResult
    func reconcile() -> Manifest {
        // Reap orphan tmp files first (they were never committed).
        let fm = FileManager.default
        if let tmps = try? fm.contentsOfDirectory(at: tmpRoot, includingPropertiesForKeys: nil) {
            for tmp in tmps {
                var error: NSError?
                let coordinator = NSFileCoordinator(filePresenter: nil)
                coordinator.coordinate(writingItemAt: tmp, options: [.forDeleting], error: &error) { url in
                    try? fm.removeItem(at: url)
                }
            }
        }

        var orphanedDirectories: [UUID] = []
        var manifest = updateManifest { manifest in
            // Collapse duplicate ids (defensive — append is guarded).
            var seen = Set<UUID>()
            manifest.items.removeAll { !seen.insert($0.id).inserted }
            for index in manifest.items.indices {
                let item = manifest.items[index]
                // A transient state can only have been left by a kill:
                // roll back to the safe decision point.
                switch item.status {
                case .inspecting:
                    manifest.items[index].status = .received
                case .processing:
                    // A kill mid-batch. Actions that already completed
                    // are in the ledger; anything unfinished needs the
                    // user's round again.
                    manifest.items[index].status = item.completedOperations.isEmpty
                        ? .needsConfirmation
                        : .partiallyProcessed
                default:
                    break
                }
                // A file item whose bytes vanished cannot be imported —
                // say so instead of failing mid-import later.
                if item.payloadKind == .file, !item.relativeFilePath.isEmpty,
                   !payloadExists(for: item) {
                    manifest.items[index].status = .failed
                    manifest.items[index].errorSummary = String(
                        localized: "暂存文件缺失", comment: "inbox reconcile"
                    )
                }
            }
        }
        // Reap item directories with no manifest entry.
        if let dirs = try? fm.contentsOfDirectory(at: itemsRoot, includingPropertiesForKeys: nil) {
            let live = Set(manifest.items.map(\.id))
            for dir in dirs {
                guard dir.hasDirectoryPath,
                      let id = UUID(uuidString: dir.lastPathComponent) else { continue }
                if !live.contains(id) { orphanedDirectories.append(id) }
            }
        }
        for id in orphanedDirectories {
            removeItemDirectory(itemID: id)
        }
        return manifest
    }

    // MARK: - Statistics (storage management)

    struct Statistics: Sendable, Equatable {
        var pendingCount = 0
        var failedCount = 0
        var totalCount = 0
        var bytesOnDisk: Int64 = 0
    }

    func statistics() -> Statistics {
        let manifest = loadManifest()
        var stats = Statistics()
        stats.totalCount = manifest.items.count
        for item in manifest.items {
            if item.status.isPending { stats.pendingCount += 1 }
            if item.status == .failed { stats.failedCount += 1 }
        }
        if let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) {
            for case let url as URL in enumerator {
                if let values = try? url.resourceValues(
                    forKeys: [.fileSizeKey, .isRegularFileKey]
                ), values.isRegularFile == true, let size = values.fileSize {
                    stats.bytesOnDisk += Int64(size)
                }
            }
        }
        return stats
    }

    /// Drops left-over files: payload directories that no longer
    /// correspond to a live manifest item (已处理 items were already
    /// reaped at delete time; this sweeps anything else).
    func removeOrphanFiles() {
        _ = reconcile()
    }

    // MARK: - Scope marker

    /// The active-scope marker the Share Extension attributes new items
    /// to (see SharedInboxScopeStore).
    var activeScope: String {
        SharedInboxScopeStore.readActiveScope(defaults: appGroupDefaults)
    }

    // MARK: - Errors

    enum ReceiveError: Error, LocalizedError, Sendable {
        case emptyPayload
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .emptyPayload: return String(localized: "内容为空", comment: "inbox receive")
            case .writeFailed: return String(localized: "无法写入暂存文件", comment: "inbox receive")
            }
        }
    }
}
