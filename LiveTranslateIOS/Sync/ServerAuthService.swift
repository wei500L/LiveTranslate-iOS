import Foundation
import OSLog

/// Account-facing surface used by UI and the sync service. The production
/// implementation is `CloudSyncService` (which owns a `ServerAuthSession`);
/// the Debug demo environment substitutes a no-op (see DemoMode.swift).
///
/// Fresh sign-ins (Apple, email/password, register+verify) do NOT go
/// through this protocol: they run on a transient unscoped
/// `ServerAuthSession` owned by `AppSession`, which moves the resulting
/// tokens into the account's keychain scope and rebuilds the environment.
@MainActor
protocol AuthenticationService: AnyObject {
    /// Whether a token pair exists locally (does not prove it is still
    /// valid — the next request verifies that).
    var isSignedIn: Bool { get }
    /// Display label of the signed-in account, when known.
    var accountLabel: String? { get }

    func signOut() async
}

/// Manages the token lifecycle against the private sync server:
///
/// - access + refresh tokens live exclusively in the Keychain, SCOPED per
///   account (multi-account isolation; the legacy unscoped keys exist only
///   for the one-time migration in `LegacyAccountMigrator`);
/// - `authorize` wraps requests with single-flight 401 → refresh → retry;
/// - a refresh failure (revoked/reused/expired) signs the account out and
///   surfaces `SyncAPIError.authExpired`.
actor ServerAuthSession {
    private static let logger = Logger(
        subsystem: "com.livetranslate.ios", category: "sync-auth"
    )

    static let accessTokenKey = "cloudsync.accessToken"
    static let refreshTokenKey = "cloudsync.refreshToken"
    static let userIdKey = "cloudsync.userId"
    static let accountLabelKey = "cloudsync.accountLabel"

    /// The scope this session's keychain keys live under. Empty for the
    /// legacy single-account layout (kept so the migration can read it);
    /// "account.<uuid>" for a signed-in account. Keys become
    /// "cloudsync.account.<uuid>.accessToken" etc. — the exact shape of
    /// `scopedKeyMapping`.
    private let scope: String

    private let api: SyncAPIClient
    private let keychain: any KeychainStoring
    /// Serializes refresh attempts so a burst of 401s triggers exactly one
    /// rotation (the server's reuse detection would kill the device
    /// otherwise).
    private var refreshInFlight: Task<String, Error>?

    init(api: SyncAPIClient, keychain: any KeychainStoring, scope: String = "") {
        self.api = api
        self.keychain = keychain
        self.scope = scope
    }

    /// Canonical per-account key form, shared by every caller (session
    /// storage, the AppSession handoff, the legacy migration):
    /// "cloudsync.account.<uuid>.accessToken" etc.
    nonisolated private static func scopedKey(_ base: String, scope: String) -> String {
        guard !scope.isEmpty else { return base }
        let suffix = base.hasPrefix("cloudsync.")
            ? String(base.dropFirst("cloudsync.".count))
            : base
        return "\(scope).\(suffix)"
    }

    /// Legacy → scoped key mapping used by the one-time migration and the
    /// AppSession sign-in handoff.
    nonisolated static func scopedKeyMapping(accountID: UUID) -> [(legacy: String, scoped: String)] {
        let prefix = "cloudsync.account.\(accountID.uuidString)"
        return [
            (accessTokenKey, "\(prefix).accessToken"),
            (refreshTokenKey, "\(prefix).refreshToken"),
            (userIdKey, "\(prefix).userId"),
            (accountLabelKey, "\(prefix).accountLabel"),
        ]
    }

    private var accessTokenKey: String { Self.scopedKey(Self.accessTokenKey, scope: scope) }
    private var refreshTokenKey: String { Self.scopedKey(Self.refreshTokenKey, scope: scope) }
    private var userIdKeyValue: String { Self.scopedKey(Self.userIdKey, scope: scope) }

    private func scoped(_ key: String) -> String {
        Self.scopedKey(key, scope: scope)
    }

    var hasTokens: Bool {
        (try? keychain.get(forKey: accessTokenKey))?.isEmpty == false
            && (try? keychain.get(forKey: refreshTokenKey))?.isEmpty == false
    }

    func storedAccessToken() -> String? {
        try? keychain.get(forKey: accessTokenKey)
    }

    func storedRefreshToken() -> String? {
        try? keychain.get(forKey: refreshTokenKey)
    }

    /// Server user id bound to this session's stored tokens (the local
    /// account identity).
    func storedUserID() -> UUID? {
        (try? keychain.get(forKey: userIdKeyValue)).flatMap(UUID.init)
    }

    // MARK: - Sign in / out

    private func makeDevice() -> SyncDeviceDTO {
        SyncDeviceDTO(
            clientDeviceId: ServerConfiguration.clientDeviceId(),
            displayName: ServerConfiguration.deviceDisplayName,
            appVersion: ServerConfiguration.appVersion
        )
    }

    func signInWithApple(identityToken: String) async throws -> SyncTokenPairDTO {
        let pair = try await api.appleLogin(identityToken: identityToken, device: makeDevice())
        try store(pair: pair)
        Self.logger.info("signed in (apple), user=\(pair.userId.uuidString, privacy: .public)")
        return pair
    }

    /// Email + password login. Tokens land in this session's scope.
    func signIn(email: String, password: String) async throws -> SyncTokenPairDTO {
        let pair = try await api.emailLogin(
            email: email, password: password, device: makeDevice()
        )
        try store(pair: pair)
        try? keychain.set(email, forKey: scoped(Self.accountLabelKey))
        Self.logger.info("signed in (email), user=\(pair.userId.uuidString, privacy: .public)")
        return pair
    }

    /// Register a pending account (no tokens until verified). The server's
    /// response is deliberately uniform for fresh and taken emails.
    func register(email: String, password: String, displayName: String) async throws {
        try await api.emailRegister(
            email: email, password: password, displayName: displayName, device: makeDevice()
        )
    }

    /// Consume the emailed code — activates the account, stores the first
    /// token pair.
    func verifyEmail(email: String, code: String) async throws -> SyncTokenPairDTO {
        let pair = try await api.emailVerify(email: email, code: code, device: makeDevice())
        try store(pair: pair)
        try? keychain.set(email, forKey: scoped(Self.accountLabelKey))
        Self.logger.info("signed in (email verify), user=\(pair.userId.uuidString, privacy: .public)")
        return pair
    }

    func resendVerificationCode(email: String) async throws {
        try await api.emailResendCode(email: email)
    }

    /// Change the signed-in account's password. The server revokes every
    /// OTHER device; this device keeps working (its refresh chain rolls on).
    func changePassword(current: String, new: String) async throws {
        try await authorize { [api] token in
            try await api.changePassword(current: current, new: new, accessToken: token)
        }
    }

    #if DEBUG
    /// Debug-only development login. Never compiled into Release builds.
    func devSignIn(devName: String) async throws -> SyncTokenPairDTO {
        let pair = try await api.devLogin(devName: devName, device: makeDevice())
        try store(pair: pair)
        Self.logger.info("signed in (dev), user=\(pair.userId.uuidString, privacy: .public)")
        return pair
    }
    #endif

    func signOut() async {
        // Best-effort server-side revoke; local state clears regardless.
        if let refresh = storedRefreshToken() {
            try? await api.logout(refreshToken: refresh)
        }
        clear()
    }

    func clear() {
        try? keychain.delete(forKey: accessTokenKey)
        try? keychain.delete(forKey: refreshTokenKey)
        try? keychain.delete(forKey: userIdKeyValue)
        try? keychain.delete(forKey: scoped(Self.accountLabelKey))
    }

    private func store(pair: SyncTokenPairDTO) {
        try? keychain.set(pair.accessToken, forKey: accessTokenKey)
        try? keychain.set(pair.refreshToken, forKey: refreshTokenKey)
        try? keychain.set(pair.userId.uuidString, forKey: userIdKeyValue)
    }

    // MARK: - Authorized requests

    /// Runs `request` with the stored access token. On 401: refresh once
    /// (single-flight across concurrent callers) and retry once.
    func authorize<R: Sendable>(
        _ request: @Sendable (_ accessToken: String) async throws -> R
    ) async throws -> R {
        guard let access = storedAccessToken() else {
            throw SyncAPIError.authExpired
        }
        do {
            return try await request(access)
        } catch let error as SyncAPIError {
            // 401 from the endpoint: rotate once and replay. Any other
            // error propagates unchanged.
            if case .authExpired = error {
                let fresh = try await refreshedAccessToken()
                return try await request(fresh)
            }
            throw error
        }
    }

    private func refreshedAccessToken() async throws -> String {
        if let inFlight = refreshInFlight {
            return try await inFlight.value
        }
        // The Task's @Sendable closure does not inherit actor isolation;
        // it only hops back in through `performRefresh()`.
        let task = Task<String, Error> { [weak self] in
            guard let self else { throw SyncAPIError.authExpired }
            return try await self.performRefresh()
        }
        refreshInFlight = task
        defer { refreshInFlight = nil }
        return try await task.value
    }

    private func performRefresh() async throws -> String {
        guard let refresh = storedRefreshToken() else {
            throw SyncAPIError.authExpired
        }
        do {
            let pair = try await api.refreshTokens(refresh)
            store(pair: pair)
            Self.logger.info("access token refreshed")
            return pair.accessToken
        } catch let error as SyncAPIError {
            // Refresh itself was rejected (expired, revoked, reused):
            // the session is gone. Drop local credentials.
            if case .authExpired = error {
                clear()
            }
            throw error
        }
    }
}
