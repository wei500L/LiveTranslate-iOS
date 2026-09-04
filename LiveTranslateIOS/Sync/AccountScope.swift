import Foundation

/// Single source of truth for every per-account storage location.
///
/// Invariants (enforced by construction — nothing else in the app derives
/// these strings or paths by hand):
///
/// 1. The **server user ID is the stable account identity**. The login
///    email is a mutable identifier: changing it (账号与安全 → 修改登录邮箱)
///    updates labels only and NEVER creates a new local namespace.
/// 2. All per-account state hangs off the account ID: the SwiftData store
///    (`Accounts/<uuid>/LiveTranslate.sqlite`), the sync outbox file, the
///    UserDefaults suite (cursor / sync flags / migration record), the
///    bookmark storage key and the Keychain scope
///    (`cloudsync.account.<uuid>.*`).
/// 3. Token updates (login, refresh rotation, email-change adoption) only
///    replace the Keychain pair — the sync cursor and outbox are untouched.
/// 4. Switching accounts rebuilds the whole environment; no repository,
///    outbox, cursor or in-memory service is shared across profiles.
/// 5. Signing out removes tokens only. Local and cloud data survive unless
///    the user explicitly confirms 删除云端副本 / 删除账号 / 删除本机副本.
/// 6. The guest profile (never signed in) keeps the legacy global paths —
///    its constants live here too, so the guest/account distinction is
///    visible in one place.
enum AccountScope {
    // MARK: - Keychain

    /// Keychain scope prefix under which one account's tokens live.
    /// ServerAuthSession composes "<scope>.accessToken" etc. from this.
    static func keychainScope(accountID: UUID) -> String {
        "cloudsync.account.\(accountID.uuidString)"
    }

    // MARK: - UserDefaults

    static func defaultsSuiteName(accountID: UUID) -> String {
        keychainScope(accountID: accountID)
    }

    /// UserDefaults suite isolating one account's sync bookkeeping
    /// (cursor, last-sync, sync-enabled, cloudDeletedAt, initialUpload,
    /// guest-migration record).
    static func defaultsSuite(accountID: UUID) -> UserDefaults {
        UserDefaults(suiteName: defaultsSuiteName(accountID: accountID)) ?? .standard
    }

    /// Bookmark storage key (guest keeps the legacy key).
    static func bookmarkKey(accountID: UUID?) -> String {
        guard let accountID else { return "ui.bookmarks.v2" }
        return "ui.bookmarks.v2.\(accountID.uuidString)"
    }

    // MARK: - Filesystem

    /// Directory holding one account's SwiftData store + sync outbox.
    static func accountDirectory(accountID: UUID) -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = support.appendingPathComponent("Accounts/\(accountID.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static let databaseFileName = "LiveTranslate.sqlite"
    static let outboxFileName = "SyncOutbox.json"
    static let attachmentsDirectoryName = "Attachments"
    static let materialsDirectoryName = "Materials"

    /// SwiftData store for a profile: the guest global file, or one
    /// account's isolated store.
    static func databaseURL(accountID: UUID?) -> URL {
        guard let accountID else { return guestDatabaseURL }
        return accountDirectory(accountID: accountID)
            .appendingPathComponent(databaseFileName)
    }

    /// Sync outbox file for a profile (guest: the legacy global file).
    static func outboxURL(accountID: UUID?) -> URL {
        guard let accountID else { return guestOutboxURL }
        return accountDirectory(accountID: accountID)
            .appendingPathComponent(outboxFileName)
    }

    /// Root directory for a profile's attachment image files. Guest keeps
    /// the legacy global Sessions sibling; accounts are isolated under
    /// their own directory (多账号之间不能共享附件目录).
    static func attachmentsRoot(accountID: UUID?) -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        guard let accountID else {
            return support.appendingPathComponent("Attachments", isDirectory: true)
        }
        return accountDirectory(accountID: accountID)
            .appendingPathComponent(attachmentsDirectoryName, isDirectory: true)
    }

    /// Root directory for a profile's course-material files (PDF 附件、
    /// 讲义原文件与派生页面缓存). Same isolation rule as attachments —
    /// one root per account, derived ONLY here (no second path rule).
    static func materialsRoot(accountID: UUID?) -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        guard let accountID else {
            return support.appendingPathComponent("Materials", isDirectory: true)
        }
        return accountDirectory(accountID: accountID)
            .appendingPathComponent(materialsDirectoryName, isDirectory: true)
    }

    // MARK: - Guest (legacy global) paths

    static var guestDatabaseURL: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return support.appendingPathComponent(databaseFileName)
    }

    static var guestOutboxURL: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return support.appendingPathComponent(outboxFileName)
    }
}
