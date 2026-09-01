import Foundation

/// Maps transport/HTTP failures onto the retry policy:
/// - **retryable**: network unreachable, timeout, connection lost,
///   HTTP 429 and 5xx. The pipeline may re-queue these automatically
///   (bounded) or offer the user a retry.
/// - **fatal**: 400/401/403/422 and malformed endpoints. Retrying cannot
///   succeed until the user fixes configuration.
enum TranslationRetryPolicy {
    /// URLError codes that mean "the network failed", not "the request was
    /// wrong". Everything else (bad URL, TLS policy, unsupported URL) is
    /// fatal — retrying would just burn the same failure twice.
    static let retryableURLErrorCodes: Set<URLError.Code> = [
        .timedOut,
        .networkConnectionLost,
        .cannotConnectToHost,
        .cannotFindHost,
        .dnsLookupFailed,
        .notConnectedToInternet,
        .internationalRoamingOff,
        .dataNotAllowed,
    ]

    static func classify(_ error: URLError) -> TranslationError {
        if retryableURLErrorCodes.contains(error.code) {
            return .retryable("Network error: \(error.localizedDescription)")
        }
        return .fatal("Request error: \(error.localizedDescription)")
    }

    static func classify(status: Int, serverMessage: String?) -> TranslationError {
        switch status {
        case 429:
            return .retryable("Server rate limit (429). \(serverMessage ?? "")".trimmed())
        case 500...599:
            return .retryable("Server error (\(status)). \(serverMessage ?? "")".trimmed())
        case 400, 401, 403, 404, 405, 422:
            return .fatal("Request rejected (\(status)). \(serverMessage ?? "")".trimmed())
        default:
            return .fatal("Unexpected HTTP status \(status). \(serverMessage ?? "")".trimmed())
        }
    }

    static func shouldRetry(_ error: TranslationError) -> Bool {
        error.isRetryable
    }
}

private extension String {
    /// Collapse the double space left when a server message is absent.
    func trimmed() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}
