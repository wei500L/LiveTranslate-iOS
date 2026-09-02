import Foundation

/// Persisted sync bookkeeping: pull cursor, last-success timestamps and
/// the user's sync-enabled preference. UserDefaults is appropriate here —
/// none of this is secret and the values are small.
@MainActor
final class SyncCursorStore: @unchecked Sendable {
    private static let cursorKey = "cloudsync.pullCursor"
    private static let lastSyncKey = "cloudsync.lastSuccessfulSync"
    private static let enabledKey = "cloudsync.syncEnabled"
    private static let cloudDeletedAtKey = "cloudsync.cloudDeletedAt"

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var pullCursor: Int {
        get { lock.lock(); defer { lock.unlock() }; return defaults.integer(forKey: Self.cursorKey) }
        set { lock.lock(); defer { lock.unlock() }; defaults.set(newValue, forKey: Self.cursorKey) }
    }

    func resetCursor() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: Self.cursorKey)
    }

    var lastSuccessfulSync: Date? {
        get { lock.lock(); defer { lock.unlock() }; return defaults.object(forKey: Self.lastSyncKey) as? Date }
        set { lock.lock(); defer { lock.unlock() }; defaults.set(newValue, forKey: Self.lastSyncKey) }
    }

    var isSyncEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return defaults.bool(forKey: Self.enabledKey) }
        set { lock.lock(); defer { lock.unlock() }; defaults.set(newValue, forKey: Self.enabledKey) }
    }

    /// Timestamp of the last 删除云端副本 — while set, local data is NOT
    /// re-uploaded (the user asked for the cloud copy to stay gone); it
    /// clears on the next sign-in.
    var cloudDeletedAt: Date? {
        get { lock.lock(); defer { lock.unlock() }; return defaults.object(forKey: Self.cloudDeletedAtKey) as? Date }
        set { lock.lock(); defer { lock.unlock() }; defaults.set(newValue, forKey: Self.cloudDeletedAtKey) }
    }
}
