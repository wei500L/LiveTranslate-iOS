import Foundation
import OSLog

/// App Link routing: password-reset deep links arrive either as Universal
/// Links (https://host/reset-password?token=…, requires the associated
/// domain + AASA to be configured — see the server's
/// /.well-known/apple-app-site-association and docs/ENVIRONMENTS.md) or via
/// the custom scheme (livetranslate://reset-password?token=…, works without
/// any entitlement; the web fallback page bridges to it).
///
/// SECURITY: the token is held ONLY in short-lived in-memory state on
/// `AppSession` and the destination view's @State. It is never written to
/// UserDefaults, SwiftData, the Keychain, logs, analytics or exports, and
/// it is cleared the moment the flow finishes or the user cancels.
enum AppLinkRouter {
    private static let logger = Logger(
        subsystem: "com.livetranslate.ios", category: "app-links"
    )

    /// Supported scheme (must match CFBundleURLTypes in Info.plist and the
    /// web fallback page's bridge link).
    static let customScheme = "livetranslate"
    /// Supported universal-link path (must match the server's AASA
    /// component declaration and PASSWORD_RESET_PATH).
    static let resetPasswordPath = "/reset-password"

    /// A parsed deep link. The associated value carries the raw token —
    /// keep it confined to @State/properties, never persistence.
    enum AppLink: Equatable {
        case passwordReset(token: String)
    }

    /// Parse an incoming URL. Returns nil (and logs, WITHOUT the token)
    /// when the link is not one of ours or is malformed.
    static func parse(_ url: URL) -> AppLink? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let path = components.path
        switch components.scheme?.lowercased() {
        case "https", "http":
            // Universal link: https://<api-host>/reset-password?token=…
            guard path == resetPasswordPath else { return nil }
        case customScheme:
            // Custom scheme: livetranslate://reset-password?token=…
            // URLComponents.path handles host-less scheme URLs; some
            // parsers put "reset-password" in host instead — accept both.
            guard path == resetPasswordPath || components.host == String(resetPasswordPath.dropFirst()) else {
                return nil
            }
        default:
            return nil
        }
        guard let token = components.queryItems?.first(where: { $0.name == "token" })?.value,
              !token.isEmpty else {
            Self.logger.info("reset link without token ignored")
            return nil
        }
        return .passwordReset(token: token)
    }
}
