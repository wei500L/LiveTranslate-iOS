import Foundation

/// A locally known cloud account. Multiple accounts may coexist on one
/// device; their data (SwiftData store, outbox, cursors, bookmarks,
/// tokens) are fully isolated per account (see `AppSession`).
struct LocalAccount: Codable, Identifiable, Equatable, Sendable {
    /// The server-side user id (token pair `userId`).
    let id: UUID
    /// Display label: email for email accounts, "apple:…" style label else.
    var label: String
    /// Server-side display name (PATCH /v1/me). Optional — accounts from
    /// before the profile feature carry none.
    var displayName: String?
    /// "email" | "apple" | "dev" — drives which settings rows make sense.
    var provider: String
    var addedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, label, displayName, provider, addedAt
    }

    init(id: UUID, label: String, displayName: String? = nil, provider: String, addedAt: Date = .now) {
        self.id = id
        self.label = label
        self.displayName = displayName
        self.provider = provider
        self.addedAt = addedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        provider = try container.decode(String.self, forKey: .provider)
        addedAt = try container.decodeIfPresent(Date.self, forKey: .addedAt) ?? .now
    }

    /// What the account switcher shows: the display name when set, else the
    /// email label.
    var displayTitle: String {
        if let displayName, !displayName.isEmpty { return displayName }
        return label
    }
}

/// Which local data set the app is currently showing: the guest (local
/// only) store, or one signed-in account's isolated store.
enum LocalProfile: Equatable, Sendable {
    case guest
    case account(LocalAccount)

    /// Stable identity for view-tree resets on switch.
    var key: String {
        switch self {
        case .guest: return "guest"
        case .account(let account): return account.id.uuidString
        }
    }
}

/// Persisted list of locally known accounts + the active profile pointer.
/// Stored in UserDefaults (no secrets — tokens live in the Keychain,
/// scoped per account).
@MainActor
@Observable
final class AccountStore {
    private static let listKey = "accounts.list"
    private static let activeKey = "accounts.active"

    private let defaults: UserDefaults

    private(set) var accounts: [LocalAccount]
    /// UUID string of the active account, or nil = guest (local-only).
    private(set) var activeAccountID: UUID?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.listKey),
           let list = try? JSONDecoder().decode([LocalAccount].self, from: data) {
            accounts = list
        } else {
            accounts = []
        }
        activeAccountID = defaults.string(forKey: Self.activeKey).flatMap(UUID.init)
    }

    var activeProfile: LocalProfile {
        if let id = activeAccountID, let account = account(id: id) {
            return .account(account)
        }
        return .guest
    }

    func account(id: UUID) -> LocalAccount? {
        accounts.first { $0.id == id }
    }

    func upsert(_ account: LocalAccount) {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        persist()
    }

    func updateLabel(id: UUID, label: String) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].label = label
        persist()
    }

    func updateDisplayName(id: UUID, displayName: String) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].displayName = displayName
        persist()
    }

    /// Removes the account from the list. The caller is responsible for
    /// deleting its isolated data (`deleteLocalData(account:)`).
    func remove(id: UUID) {
        accounts.removeAll { $0.id == id }
        if activeAccountID == id {
            activeAccountID = nil
        }
        persist()
    }

    func setActive(_ id: UUID?) {
        activeAccountID = id
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(accounts) {
            defaults.set(data, forKey: Self.listKey)
        }
        defaults.set(activeAccountID?.uuidString, forKey: Self.activeKey)
    }

    // MARK: - Per-account storage namespaces

    // All namespace derivations live in `AccountScope` (single source of
    // truth for the account-ID → storage mapping). These thin wrappers
    // keep existing call sites compiling; new code should use AccountScope
    // directly.

    nonisolated static func defaultsSuite(accountID: UUID) -> UserDefaults {
        AccountScope.defaultsSuite(accountID: accountID)
    }

    nonisolated static func bookmarkKey(accountID: UUID?) -> String {
        AccountScope.bookmarkKey(accountID: accountID)
    }

    nonisolated static func accountDirectory(accountID: UUID) -> URL {
        AccountScope.accountDirectory(accountID: accountID)
    }

    /// Hard-deletes an account's local data: SwiftData store, outbox,
    /// cursor suite, bookmarks. Tokens are cleared separately via the
    /// Keychain.
    func deleteLocalData(accountID: UUID) {
        let dir = Self.accountDirectory(accountID: accountID)
        let fm = FileManager.default
        // Store + sidecars + outbox (names from AccountScope — one shape).
        try? fm.removeItem(at: dir.appendingPathComponent(AccountScope.databaseFileName))
        for suffix in ["-wal", "-shm"] {
            try? fm.removeItem(
                at: dir.appendingPathComponent(AccountScope.databaseFileName + suffix)
            )
        }
        try? fm.removeItem(at: dir.appendingPathComponent(AccountScope.outboxFileName))
        let suiteName = AccountScope.defaultsSuiteName(accountID: accountID)
        if let defaults = UserDefaults(suiteName: suiteName) {
            defaults.removePersistentDomain(forName: suiteName)
            defaults.removeObject(forKey: Self.bookmarkKey(accountID: accountID))
        }
        try? fm.removeItem(at: dir)
    }
}

/// One-time migration: the app used to keep a single global sign-in
/// (Apple/dev login) with global storage. On first launch of the
/// multi-account build, that state is folded into a `LocalAccount` and its
/// data moved into the account's namespace. Guest (never signed-in)
/// devices keep using the global paths unchanged.
enum LegacyAccountMigrator {
    @MainActor
    static func runIfNeeded(accountStore: AccountStore, keychain: any KeychainStoring) {
        guard accountStore.accounts.isEmpty else { return }
        guard let legacyToken = try? keychain.get(forKey: "cloudsync.accessToken"),
              !legacyToken.isEmpty else { return }

        let userID = (try? keychain.get(forKey: "cloudsync.userId")).flatMap(UUID.init)
        let label = (try? keychain.get(forKey: "cloudsync.accountLabel"))
        guard let userID else {
            // Tokens exist but no user id: unusable legacy state. Drop it.
            clearLegacyKeychain(keychain)
            return
        }

        let account = LocalAccount(
            id: userID,
            label: label?.isEmpty == false ? label! : "Apple 账号",
            provider: "apple"
        )

        // Move the global data files into the account directory.
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = AccountStore.accountDirectory(accountID: userID)
        for name in [AccountScope.databaseFileName,
                     AccountScope.databaseFileName + "-wal",
                     AccountScope.databaseFileName + "-shm",
                     AccountScope.outboxFileName] {
            let from = support.appendingPathComponent(name)
            let to = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: from.path) {
                try? fm.moveItem(at: from, to: to)
            }
        }

        // Copy the global cursor/initial-upload keys into the account's
        // suite, then clear the globals.
        let global = UserDefaults.standard
        let suite = AccountStore.defaultsSuite(accountID: userID)
        for key in ["cloudsync.pullCursor", "cloudsync.lastSuccessfulSync",
                    "cloudsync.syncEnabled", "cloudsync.cloudDeletedAt",
                    "cloudsync.initialUploadDone"] {
            if let value = global.object(forKey: key) {
                suite.set(value, forKey: key)
            }
            global.removeObject(forKey: key)
        }
        // Bookmarks: move the record to the account-scoped key.
        if let data = global.data(forKey: "ui.bookmarks.v2") {
            suite.set(data, forKey: AccountStore.bookmarkKey(accountID: userID))
            global.removeObject(forKey: "ui.bookmarks.v2")
        }

        // Keychain: copy tokens under the scoped keys, drop the globals.
        for (legacy, scoped) in ServerAuthSession.scopedKeyMapping(accountID: userID) {
            if let value = try? keychain.get(forKey: legacy) {
                try? keychain.set(value, forKey: scoped)
            }
        }
        clearLegacyKeychain(keychain)

        accountStore.upsert(account)
        accountStore.setActive(userID)
    }

    private static func clearLegacyKeychain(_ keychain: any KeychainStoring) {
        try? keychain.delete(forKey: "cloudsync.accessToken")
        try? keychain.delete(forKey: "cloudsync.refreshToken")
        try? keychain.delete(forKey: "cloudsync.userId")
        try? keychain.delete(forKey: "cloudsync.accountLabel")
    }
}
