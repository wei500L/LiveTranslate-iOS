import Foundation
import OSLog

/// Account-facing surface used by UI and the sync service. The production
/// implementation is `CloudSyncService` (which owns a `ServerAuthSession`);
/// the Debug demo environment substitutes a no-op (see DemoMode.swift).
@MainActor
protocol AuthenticationService: AnyObject {
    /// Whether a token pair exists locally (does not prove it is still
    /// valid — the next request verifies that).
    var isSignedIn: Bool { get }
    /// Display label of the signed-in account, when known.
    var accountLabel: String? { get }

    func signInWithApple(identityToken: String) async throws
    func signOut() async
}

/// Manages the token lifecycle against the private sync server:
///
/// - access + refresh tokens live exclusively in the Keychain;
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

    private let api: SyncAPIClient
    private let keychain: any KeychainStoring
    /// Serializes refresh attempts so a burst of 401s triggers exactly one
    /// rotation (the server's reuse detection would kill the device
    /// otherwise).
    private var refreshInFlight: Task<String, Error>?

    init(api: SyncAPIClient, keychain: any KeychainStoring) {
        self.api = api
        self.keychain = keychain
    }

    var hasTokens: Bool {
        (try? keychain.get(forKey: Self.accessTokenKey))?.isEmpty == false
            && (try? keychain.get(forKey: Self.refreshTokenKey))?.isEmpty == false
    }

    func storedAccessToken() -> String? {
        try? keychain.get(forKey: Self.accessTokenKey)
    }

    func storedRefreshToken() -> String? {
        try? keychain.get(forKey: Self.refreshTokenKey)
    }

    // MARK: - Sign in / out

    func signInWithApple(identityToken: String) async throws -> SyncTokenPairDTO {
        let device = SyncDeviceDTO(
            clientDeviceId: ServerConfiguration.clientDeviceId(),
            displayName: ServerConfiguration.deviceDisplayName,
            appVersion: ServerConfiguration.appVersion
        )
        let pair = try await api.appleLogin(identityToken: identityToken, device: device)
        try store(pair: pair)
        Self.logger.info("signed in (apple), user=\(pair.userId.uuidString, privacy: .public)")
        return pair
    }

    #if DEBUG
    /// Debug-only development login. Never compiled into Release builds.
    func devSignIn(devName: String) async throws -> SyncTokenPairDTO {
        let device = SyncDeviceDTO(
            clientDeviceId: ServerConfiguration.clientDeviceId(),
            displayName: ServerConfiguration.deviceDisplayName,
            appVersion: ServerConfiguration.appVersion
        )
        let pair = try await api.devLogin(devName: devName, device: device)
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
        try? keychain.delete(forKey: Self.accessTokenKey)
        try? keychain.delete(forKey: Self.refreshTokenKey)
        try? keychain.delete(forKey: Self.userIdKey)
        try? keychain.delete(forKey: Self.accountLabelKey)
    }

    private func store(pair: SyncTokenPairDTO) {
        try? keychain.set(pair.accessToken, forKey: Self.accessTokenKey)
        try? keychain.set(pair.refreshToken, forKey: Self.refreshTokenKey)
        try? keychain.set(pair.userId.uuidString, forKey: Self.userIdKey)
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
