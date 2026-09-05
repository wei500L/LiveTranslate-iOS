import Foundation
import LocalAuthentication
import OSLog

/// Device-local biometric privacy lock (round 17). Face ID / Touch ID /
/// the system passcode via LocalAuthentication — NO custom PIN database,
/// NO secrets stored: the only persisted state is the on/off flag and the
/// grace period (SettingsStore, device-level, never synced, never
/// per-account).
///
/// Lock semantics:
///   - armed (default OFF) + the app left the foreground longer than the
///     grace period → the UI is covered by the privacy shield until the
///     system authentication succeeds;
///   - the shield is rendered by the root view BEFORE any content (no
///     one-frame flash: `requiresUnlock` is computed synchronously in the
///     view body from `leftForegroundAt`);
///   - data keeps flowing while locked — sync results land, a background
///     classroom keeps recording; the lock gates the UI only and never
///     re-initializes the store, ASR or account environment;
///   - profile switches and explicit locks reset the unlock state — the
///     next profile NEVER inherits the previous one's authorization.
///
/// Failure honesty (nothing is faked):
///   - biometry unavailable → the system falls back to the passcode
///     (deviceOwnerAuthentication); if neither can run, the lock
///     surface says so and offers Retry / open the lock settings;
///   - user cancel / system cancel keep the shield with a Retry button;
///   - LAError details are logged as STABLE CODES only — never the
///     context payload (which can carry user info).
@MainActor
@Observable
final class PrivacyLockController {
    private static let logger = Logger(
        subsystem: "com.livetranslate.ios", category: "privacy-lock"
    )

    /// Injectable authentication for tests and the Debug demo (a fake
    /// LAContext result — the demo never touches real biometry).
    struct AuthenticationResult: Sendable, Equatable {
        var success: Bool
        /// Stable LAError code (raw Int) when the system failed.
        var errorCode: Int?
    }

    private let settings: SettingsStore
    private let authenticate: @MainActor () async -> AuthenticationResult

    /// When the app last left the foreground (nil = active now).
    private(set) var leftForegroundAt: Date?
    /// Whether the CURRENT unlock authorization is valid (nil until the
    /// first successful authentication when armed).
    private(set) var isUnlocked: Bool
    /// True while an authentication attempt is in flight (the shield
    /// shows progress, not a dead button).
    private(set) var isAuthenticating = false
    /// The last failure's stable state (drives the shield copy honestly).
    private(set) var lastFailure: FailureState?

    enum FailureState: Equatable, Sendable {
        case userCancelled
        case systemCancelled
        case biometryUnavailable
        case notEnrolled
        case lockedOut
        case generic
    }

    init(
        settings: SettingsStore = .shared,
        authenticate: (@MainActor () async -> AuthenticationResult)? = nil
    ) {
        self.settings = settings
        // Self cannot be referenced in a default argument — resolve the
        // system authenticator here instead.
        self.authenticate = authenticate ?? Self.systemAuthenticate
        // A launch starts LOCKED when the feature is armed — a relaunch
        // is indistinguishable from a fresh entry and must not inherit a
        // previous session's authorization.
        self.isUnlocked = !settings.privacyLockEnabled
    }

    // MARK: - Shield decision (synchronous — the root view reads this
    // directly in body, so the shield can never lag a frame behind)

    /// Whether the privacy shield must cover the UI right now.
    var requiresUnlock: Bool {
        guard settings.privacyLockEnabled, !isUnlocked else { return false }
        return true
    }

    /// Whether the grace period has elapsed for the current background
    /// stretch (the caller arms `isUnlocked = false` when it has).
    /// Called synchronously on foreground transitions.
    func graceElapsed(asOf now: Date = .now) -> Bool {
        guard let leftForegroundAt else {
            // Left-foreground timestamp lost (e.g. launch): already
            // locked at init when armed — treat as elapsed.
            return true
        }
        let grace = TimeInterval(max(0, settings.privacyLockGraceSeconds))
        return now.timeIntervalSince(leftForegroundAt) >= grace
    }

    // MARK: - Scene-phase bridge

    /// scenePhase left .active (inactive OR background): record when.
    func trackLeftForeground(at date: Date = .now) {
        if leftForegroundAt == nil {
            leftForegroundAt = date
        }
    }

    /// scenePhase became .active: re-arm the lock when the grace period
    /// elapsed. Returns whether the caller should start an authentication
    /// attempt (shield is up either way — no content frame shows first).
    func handleForegroundEntry() -> Bool {
        guard settings.privacyLockEnabled else {
            isUnlocked = true
            leftForegroundAt = nil
            return false
        }
        let shouldLock = graceElapsed()
        if shouldLock {
            isUnlocked = false
        }
        leftForegroundAt = nil
        lastFailure = nil
        return !isUnlocked
    }

    // MARK: - Explicit state changes

    /// Immediate lock + revoke authorization (profile switch, manual
    /// lock). The next foreground requires a fresh authentication.
    func lockNow() {
        guard settings.privacyLockEnabled else { return }
        isUnlocked = false
        lastFailure = nil
    }

    /// Turning the feature OFF immediately clears any lock.
    func disable() {
        settings.privacyLockEnabled = false
        isUnlocked = true
        leftForegroundAt = nil
        lastFailure = nil
    }

    // MARK: - Authentication

    /// Runs the system authentication. Returns true when the shield may
    /// lift. Errors map to honest UI states; nothing is logged beyond
    /// stable codes.
    @discardableResult
    func attemptUnlock() async -> Bool {
        guard !isUnlocked else { return true }
        guard !isAuthenticating else { return false }
        isAuthenticating = true
        defer { isAuthenticating = false }
        let result = await authenticate()
        if result.success {
            isUnlocked = true
            lastFailure = nil
            Self.logger.info("privacy lock unlocked")
            return true
        }
        lastFailure = Self.failureState(for: result.errorCode)
        // Stable code only — the LAError userInfo can carry context
        // strings; it never reaches the log.
        Self.logger.info(
            "privacy lock auth failed (code \(result.errorCode.map(String.init) ?? "nil", privacy: .public))"
        )
        return false
    }

    // MARK: - Error mapping

    static func failureState(for code: Int?) -> FailureState {
        switch code {
        case LAError.userCancel.rawValue:
            return .userCancelled
        case LAError.systemCancel.rawValue:
            return .systemCancelled
        case LAError.biometryNotAvailable.rawValue:
            return .biometryUnavailable
        case LAError.biometryNotEnrolled.rawValue:
            return .notEnrolled
        case LAError.biometryLockout.rawValue:
            return .lockedOut
        default:
            return .generic
        }
    }

    /// The real system authentication (Face ID / Touch ID / passcode).
    /// The passcode fallback is part of deviceOwnerAuthentication — no
    /// custom PIN ever exists.
    @MainActor
    private static func systemAuthenticate() async -> AuthenticationResult {
        await systemAuthenticateImpl()
    }

    @MainActor
    private static func systemAuthenticateImpl() async -> AuthenticationResult {
        let context = LAContext()
        // Fall back to the passcode when biometry is missing/locked out.
        context.localizedFallbackTitle = String(localized: "使用密码")
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: String(localized: "解锁 LiveTranslate")
            )
            return AuthenticationResult(success: success, errorCode: nil)
        } catch let error as LAError {
            return AuthenticationResult(success: false, errorCode: error.code.rawValue)
        } catch {
            return AuthenticationResult(success: false, errorCode: nil)
        }
    }
}
