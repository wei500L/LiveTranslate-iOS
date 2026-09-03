import Foundation
import OSLog

/// App Link routing for the password-reset flow.
///
/// The ONLY trusted path into the app is the HTTPS Universal Link
/// (`https://<api-host>/reset-password?token=…`, delivered once the
/// associated-domain entitlement and the server's AASA are configured).
/// Custom URL schemes are deliberately NOT supported: scheme links are
/// spoofable by any other app on the device and must never carry secrets.
///
/// Acceptance rules (all must hold):
///   - scheme is exactly `https` (no http, no custom scheme);
///   - host equals the CONFIGURED sync server host (case-insensitive) —
///     a link from any other domain is ignored;
///   - path is exactly the reset path;
///   - the query carries exactly one parameter, `token`;
///   - the token matches the server's token shape (hex, 32–128 chars) —
///     longer payloads are rejected before anything sees them.
///
/// SECURITY: the token is held ONLY in short-lived in-memory state on
/// `AppSession` and the destination view's @State. It is never written to
/// UserDefaults, SwiftData, the Keychain, logs, analytics or exports, and
/// it is cleared the moment the flow finishes or the user cancels.
enum AppLinkRouter {
    private static let logger = Logger(
        subsystem: "com.livetranslate.ios", category: "app-links"
    )

    /// Supported universal-link path (must match the server's AASA
    /// component declaration and PASSWORD_RESET_PATH).
    static let resetPasswordPath = "/reset-password"

    /// The server's reset tokens are 64 hex chars; accept a bounded range
    /// for forward compatibility and reject anything else up front.
    static let maxTokenLength = 128
    static let minTokenLength = 32

    /// A parsed deep link. The associated value carries the raw token —
    /// keep it confined to @State/properties, never persistence.
    enum AppLink: Equatable {
        case passwordReset(token: String)
    }

    /// Parse an incoming URL. `allowedHost` is the configured sync server
    /// host (from ServerConfiguration); a nil/empty host disables deep
    /// links entirely (fail closed). Returns nil (and logs, WITHOUT the
    /// token) when the link is not one of ours or is malformed.
    static func parse(_ url: URL, allowedHost: String?) -> AppLink? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        // HTTPS only — no http, no custom schemes.
        guard components.scheme?.lowercased() == "https" else {
            return nil
        }
        // Only the configured API host may route into the app.
        guard let allowedHost, !allowedHost.isEmpty,
              let host = components.host, host.caseInsensitiveCompare(allowedHost) == .orderedSame else {
            Self.logger.info("reset link from unconfigured host ignored")
            return nil
        }
        // Exact path.
        guard components.path == resetPasswordPath else {
            return nil
        }
        // Exactly one controlled parameter: token. Anything else (extra
        // params, fragments) is rejected — controlled input only.
        let items = components.queryItems ?? []
        guard items.count == 1, items[0].name == "token" else {
            Self.logger.info("reset link with unexpected query shape ignored")
            return nil
        }
        guard let token = items[0].value, isTokenShaped(token) else {
            Self.logger.info("reset link without a valid token ignored")
            return nil
        }
        return .passwordReset(token: token)
    }

    /// Hex-only, bounded length — matches the server's opaque-token shape
    /// (64 hex chars today).
    static func isTokenShaped(_ raw: String) -> Bool {
        let count = raw.count
        guard count >= minTokenLength, count <= maxTokenLength else { return false }
        return raw.allSatisfy { c in
            (c >= "0" && c <= "9") || (c >= "a" && c <= "f") || (c >= "A" && c <= "F")
        }
    }
}
