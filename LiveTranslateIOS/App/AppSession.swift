import Foundation
import OSLog

/// Owns the active profile and the `AppEnvironment` built for it. All
/// fresh sign-ins run through here on a TRANSIENT unscoped
/// `ServerAuthSession` (the account's identity — and therefore its storage
/// scope — is only known after the server answers), then the tokens are
/// moved into the account's keychain scope and the environment is rebuilt.
///
/// Isolation contract (§6): the guest store and every account's store are
/// fully separate — SwiftData file, sync outbox, cursors, bookmarks and
/// tokens. Switching tears the whole view tree down; nothing of one
/// profile is reachable from another.
@MainActor
@Observable
final class AppSession {
    private static let logger = Logger(
        subsystem: "com.livetranslate.ios", category: "app-session"
    )

    let accounts: AccountStore
    private(set) var environment: AppEnvironment
    /// Debug UI-demo mode assembles a fixed environment; switching is off.
    private let isDemoMode: Bool

    private let keychain: KeychainStore

    /// Stable identity for `.id()` view resets.
    var profileKey: String {
        isDemoMode ? "demo" : accounts.activeProfile.key
    }

    init() {
        let keychain = KeychainStore()
        self.keychain = keychain
        let accounts = AccountStore()
        self.accounts = accounts
        #if DEBUG
        if DemoLaunchOptions.parse() != nil {
            isDemoMode = true
            environment = AppEnvironment.makeForLaunch()
            return
        }
        #endif
        isDemoMode = false
        // One-time: fold the legacy single-account state (Apple/dev login
        // era) into the multi-account layout.
        LegacyAccountMigrator.runIfNeeded(accountStore: accounts, keychain: keychain)
        environment = AppEnvironment(profile: accounts.activeProfile)
    }

    // MARK: - Profile switching

    /// Switch to a known local account (or back to the guest/local-only
    /// profile). Rebuilds the environment; the view tree resets.
    func switchTo(profile: LocalProfile) {
        guard !isDemoMode else { return }
        environment.cloudSync?.shutdown()
        switch profile {
        case .guest:
            accounts.setActive(nil)
        case .account(let account):
            accounts.setActive(account.id)
        }
        environment = AppEnvironment(profile: profile)
        Self.logger.info("profile switched: \(profile.key, privacy: .public)")
    }

    func switchToGuest() {
        switchTo(profile: .guest)
    }

    func switchToAccount(_ id: UUID) {
        guard let account = accounts.account(id: id) else { return }
        switchTo(profile: .account(account))
    }

    /// Sign the CURRENT account out server-side; its local data stays so
    /// switching back (after re-login) restores it.
    func signOutCurrentAccount() async {
        guard case .account(let account) = accounts.activeProfile else { return }
        await environment.cloudSync?.signOut()
        _ = account // local data intentionally kept
    }

    /// Remove an account from this device entirely: revoke its tokens and
    /// hard-delete its isolated local data. Cloud data is untouched.
    func removeAccount(_ id: UUID, revokeTokens: Bool) async {
        guard !isDemoMode else { return }
        if revokeTokens, id == accounts.activeAccountID {
            await environment.cloudSync?.signOut()
        } else {
            // Not the active profile: revoke via a scoped transient session.
            if let baseURL = ServerConfiguration.baseURL {
                let api = SyncAPIClient(baseURL: baseURL)
                let scope = "cloudsync.account.\(id.uuidString)"
                let session = ServerAuthSession(api: api, keychain: keychain, scope: scope)
                await session.signOut()
            }
        }
        let wasActive = accounts.activeAccountID == id
        accounts.deleteLocalData(accountID: id)
        accounts.remove(id: id)
        if wasActive {
            environment.cloudSync?.shutdown()
            environment = AppEnvironment(profile: accounts.activeProfile)
        }
    }

    /// After the server confirmed account deletion (DELETE /v1/account):
    /// drop the account's local profile and fall back to guest.
    func handleServerAccountDeleted() async {
        guard !isDemoMode, let id = accounts.activeAccountID else { return }
        accounts.deleteLocalData(accountID: id)
        accounts.remove(id: id)
        environment.cloudSync?.shutdown()
        environment = AppEnvironment(profile: accounts.activeProfile)
    }

    // MARK: - Fresh sign-ins (transient unscoped session)

    /// Runs a sign-in flow on a transient session whose tokens land in the
    /// legacy unscoped keys, then hands them off to the account's scope and
    /// rebuilds. `label` seeds the account list entry (the email for email
    /// accounts; Apple accounts get their label fetched after rebuild).
    @discardableResult
    func signIn(
        label: String,
        provider: String,
        _ operation: @escaping @Sendable (ServerAuthSession) async throws -> SyncTokenPairDTO
    ) async throws -> UUID {
        guard !isDemoMode else { throw SyncAPIError.notConfigured }
        guard let baseURL = ServerConfiguration.baseURL else {
            throw SyncAPIError.notConfigured
        }
        // Fresh sign-in runs in the background while the CURRENT profile's
        // service keeps working; nothing moves until the server accepts.
        let api = SyncAPIClient(baseURL: baseURL)
        let session = ServerAuthSession(api: api, keychain: keychain)
        let pair = try await operation(session)

        let accountID = pair.userId
        // Handoff: unscoped → account scope.
        for mapping in ServerAuthSession.scopedKeyMapping(accountID: accountID) {
            if let value = try? keychain.get(forKey: mapping.legacy) {
                try? keychain.set(value, forKey: mapping.scoped)
            }
            try? keychain.delete(forKey: mapping.legacy)
        }
        // Seed the label; the post-sign-in me-fetch refreshes it.
        if let existing = accounts.account(id: accountID) {
            accounts.upsert(existing)
        } else {
            accounts.upsert(LocalAccount(id: accountID, label: label, provider: provider))
        }
        accounts.setActive(accountID)
        rebuildAfterSignIn()
        Self.logger.info(
            "signed in, account=\(accountID.uuidString, privacy: .public)"
        )
        return accountID
    }

    /// Register a pending account (no tokens yet — nothing is handed off,
    /// no profile switch). The verify step performs the actual sign-in.
    func register(
        email: String, password: String, displayName: String
    ) async throws {
        guard let baseURL = ServerConfiguration.baseURL else {
            throw SyncAPIError.notConfigured
        }
        let api = SyncAPIClient(baseURL: baseURL)
        let session = ServerAuthSession(api: api, keychain: keychain)
        try await session.register(email: email, password: password, displayName: displayName)
    }

    /// Request a new verification code for a pending registration.
    func resendCode(email: String) async throws {
        guard let baseURL = ServerConfiguration.baseURL else {
            throw SyncAPIError.notConfigured
        }
        let api = SyncAPIClient(baseURL: baseURL)
        let session = ServerAuthSession(api: api, keychain: keychain)
        try await session.resendVerificationCode(email: email)
    }

    // MARK: - Rebuild

    private func rebuildAfterSignIn() {
        environment.cloudSync?.shutdown()
        environment = AppEnvironment(profile: accounts.activeProfile)
        // Post-sign-in bookkeeping on the NEW service: label fetch, first
        // upload scheduling, first sync.
        Task {
            await environment.cloudSync?.completeSignIn()
        }
    }
}
