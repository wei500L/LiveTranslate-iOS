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

    // MARK: - Deep links (App Link router)

    /// A password-reset token received via an HTTPS Universal Link (the
    /// only accepted deep-link form; custom schemes are rejected by the
    /// router). IN-MEMORY ONLY: never persisted, never logged — the
    /// destination sheet consumes it and clears it. Non-nil means "present
    /// the reset flow with this token".
    private(set) var pendingResetToken: String?

    /// UserDefaults key holding a registration whose verification step was
    /// interrupted (App closed mid-flow). Only the EMAIL is stored — codes
    /// and passwords never touch persistence.
    private static let pendingVerificationKey = "auth.pendingVerificationEmail"

    // MARK: - Profile switching

    /// Reasons a profile switch may be refused. The UI surfaces these as a
    /// plain explanation instead of silently doing nothing.
    enum SwitchBlock: Equatable {
        case classroomActive
        case guestMigrationInProgress
    }

    /// Whether switching profiles is currently allowed (a live classroom or
    /// an in-flight guest-data migration blocks it).
    func switchBlocker() -> SwitchBlock? {
        if environment.coordinator.isRunning || environment.liveViewModel != nil {
            return .classroomActive
        }
        if environment.guestMigration?.isRunning == true {
            return .guestMigrationInProgress
        }
        return nil
    }

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
        // The scope marker goes out BEFORE the environment build (the
        // coordinator snapshots it at init — a fresh environment must
        // never read a stale scope).
        publishInboxScope()
        environment = AppEnvironment(profile: accounts.activeProfile)
    }

    // MARK: - Shared-inbox scope (Share Extension attribution)

    /// Publishes the ACTIVE profile's non-sensitive scope marker into the
    /// App Group defaults. The Share Extension reads ONLY this key to
    /// attribute new shares (never the keychain, never labels) — a share
    /// belongs to the profile that was active when it arrived, and
    /// switching profiles never moves existing items.
    private func publishInboxScope() {
        guard !isDemoMode else { return }
        guard let defaults = UserDefaults(suiteName: SharedInboxStore.appGroupIdentifier) else {
            return
        }
        switch accounts.activeProfile {
        case .guest:
            SharedInboxScopeStore.writeActiveScope(
                SharedInboxScopeStore.guestScope, defaults: defaults
            )
        case .account(let account):
            SharedInboxScopeStore.writeActiveScope(
                account.id.uuidString, defaults: defaults
            )
        }
    }

    // MARK: - Profile switching

    /// Switch to a known local account (or back to the guest/local-only
    /// profile). Rebuilds the environment; the view tree resets. Refused
    /// (returns false) while a classroom is running or a guest-data
    /// migration is in flight — the caller surfaces the reason.
    @discardableResult
    func switchTo(profile: LocalProfile) -> Bool {
        guard !isDemoMode else { return false }
        if let blocker = switchBlocker() {
            switch blocker {
            case .classroomActive:
                Self.logger.info("profile switch refused: classroom active")
            case .guestMigrationInProgress:
                Self.logger.info("profile switch refused: guest migration in progress")
            }
            return false
        }
        environment.cloudSync?.shutdown()
        // Class reminders live in the system notification center (global
        // across accounts): the previous profile's pending notifications
        // are cancelled; the new profile's window re-arms on its launch
        // task (refreshClassReminders reads the new account's schedules).
        environment.classReminders.cancelAll()
        // Exam-center reminders follow the same rule; the learning timer
        // checkpoints (its minutes belong to the old account's history
        // and already live in its rows) and the reminder state rebuilds
        // with the new profile.
        environment.examReminders.cancelAll()
        environment.studyActivityTracker.checkpoint()
        switch profile {
        case .guest:
            accounts.setActive(nil)
        case .account(let account):
            accounts.setActive(account.id)
        }
        // The scope marker goes out BEFORE the environment build (the
        // coordinator snapshots it at init — a fresh environment must
        // never read a stale scope).
        publishInboxScope()
        environment = AppEnvironment(profile: profile)
        Self.logger.info("profile switched: \(profile.key, privacy: .public)")
        return true
    }

    @discardableResult
    func switchToGuest() -> Bool {
        switchTo(profile: .guest)
    }

    @discardableResult
    func switchToAccount(_ id: UUID) -> Bool {
        guard let account = accounts.account(id: id) else { return false }
        return switchTo(profile: .account(account))
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
                let scope = AccountScope.keychainScope(accountID: id)
                let session = ServerAuthSession(api: api, keychain: keychain, scope: scope)
                await session.signOut()
            }
        }
        let wasActive = accounts.activeAccountID == id
        // The account's shared-inbox items belong to its scope — they go
        // with the profile removal (formal entities already live their
        // own lives in the profile's store, which deleteLocalData drops).
        SharedInboxStore()?.removeItems(scopeKey: id.uuidString)
        accounts.deleteLocalData(accountID: id)
        accounts.remove(id: id)
        if wasActive {
            environment.cloudSync?.shutdown()
            environment = AppEnvironment(profile: accounts.activeProfile)
            publishInboxScope()
        }
    }

    /// After the server confirmed account deletion (DELETE /v1/account):
    /// drop the account's local profile and fall back to guest.
    func handleServerAccountDeleted() async {
        guard !isDemoMode, let id = accounts.activeAccountID else { return }
        SharedInboxStore()?.removeItems(scopeKey: id.uuidString)
        accounts.deleteLocalData(accountID: id)
        accounts.remove(id: id)
        environment.cloudSync?.shutdown()
        environment = AppEnvironment(profile: accounts.activeProfile)
        publishInboxScope()
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
    /// The email is remembered so an interrupted registration can resume at
    /// the verification step the next time the sheet opens.
    func register(
        email: String, password: String, displayName: String, invitationCode: String = ""
    ) async throws {
        guard let baseURL = ServerConfiguration.baseURL else {
            throw SyncAPIError.notConfigured
        }
        let api = SyncAPIClient(baseURL: baseURL)
        let session = ServerAuthSession(api: api, keychain: keychain)
        try await session.register(
            email: email, password: password, displayName: displayName,
            invitationCode: invitationCode
        )
        UserDefaults.standard.set(email, forKey: Self.pendingVerificationKey)
    }

    /// Explicit alias for the UI's register path (carries the invitation
    /// code); keeps call sites self-describing.
    func registerWithInvitation(
        email: String, password: String, displayName: String, invitationCode: String
    ) async throws {
        try await register(
            email: email, password: password, displayName: displayName,
            invitationCode: invitationCode
        )
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

    // MARK: - Interrupted-registration resume (email only, never codes)

    /// The email of a registration awaiting verification, when the flow was
    /// interrupted (sheet closed / app terminated). nil when none.
    var pendingVerificationEmail: String? {
        UserDefaults.standard.string(forKey: Self.pendingVerificationKey)
    }

    /// Called when verification SUCCEEDED (account activated — the flow is
    /// over) or the user explicitly abandons the registration.
    func clearPendingVerification() {
        UserDefaults.standard.removeObject(forKey: Self.pendingVerificationKey)
    }

    // MARK: - Deep links

    /// Entry point for `.onOpenURL`. HTTPS-only Universal Links are the
    /// single trusted path (host must match the configured sync server);
    /// custom schemes are rejected by the router. The token parks in
    /// memory for the UI to present — never logged, never persisted;
    /// `consumeResetToken()` clears it.
    func handleDeepLink(_ url: URL) {
        // Demo mode never touches real auth surfaces.
        guard !isDemoMode else { return }
        guard let link = AppLinkRouter.parse(url, allowedHost: ServerConfiguration.baseURL?.host) else {
            Self.logger.info("unrecognized app link ignored")
            return
        }
        switch link {
        case .passwordReset(let token):
            pendingResetToken = token
            Self.logger.info("password-reset link received")
            // Steer the user to the settings tab where the reset sheet can
            // present; the sheet itself lives in RootTabView.
            environment.flow.selectedTab = .profile
        }
    }

    /// The reset flow consumed the token (or the user dismissed it) — clear
    /// it from memory immediately.
    func consumeResetToken() {
        pendingResetToken = nil
    }

    // MARK: - Rebuild

    private func rebuildAfterSignIn() {
        environment.cloudSync?.shutdown()
        // The scope marker goes out BEFORE the environment build (the
        // coordinator snapshots it at init — a fresh environment must
        // never read a stale scope).
        publishInboxScope()
        environment = AppEnvironment(profile: accounts.activeProfile)
        // Post-sign-in bookkeeping on the NEW service: label fetch, first
        // upload scheduling, first sync.
        Task {
            await environment.cloudSync?.completeSignIn()
        }
    }
}
