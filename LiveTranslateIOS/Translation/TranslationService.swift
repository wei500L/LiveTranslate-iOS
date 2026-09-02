import Foundation

/// One translation request/response flowing through the pipeline.
struct TranslationRequest: Sendable, Identifiable {
    let id: Int
    let sequenceID: Int
    let text: String
    let sourceLanguage: String
    let targetLanguage: String
    /// History snapshot (oldest first) for context turns.
    let history: [(source: String, translation: String)]

    var stableID: String { "\(sequenceID)" }
}

struct TranslationOutcome: Sendable {
    let sequenceID: Int
    let text: String?
    let latency: TimeInterval
    let isRetryable: Bool
    let errorDescription: String?
}

enum TranslationError: LocalizedError, Sendable, Equatable {
    /// Network unreachable, timeout, 429, 5xx — retry later.
    case retryable(String)
    /// 401/403/400 — fixing requires user action, do not retry blindly.
    case fatal(String)
    case notConfigured
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .retryable(let reason): return reason
        case .fatal(let reason): return reason
        case .notConfigured: return String(localized: "Translation API is not configured.")
        case .emptyResponse: return String(localized: "The translation model returned an empty response.")
        }
    }

    var isRetryable: Bool {
        switch self {
        case .retryable: return true
        default: return false
        }
    }
}

/// Translation service abstraction. Implementations talk to an
/// OpenAI-compatible chat completions endpoint (OpenAI, DeepSeek, Qwen,
/// Grok, Ollama, vLLM, LM Studio, self-hosted HY-MT servers).
protocol TranslationService: Sendable {
    /// Whether an endpoint + model + key are configured.
    var isConfigured: Bool { get async }

    /// Synchronous, I/O-free configuration check. The **single source of
    /// truth** for "a usable service is configured": presentation adapters
    /// (home readiness, live-classroom banner, the pipeline's dispatch-time
    /// triage) all consult this, so they can never disagree with each other
    /// when settings change. The API key itself stays inside the service —
    /// views only ever see this Bool.
    var isConfiguredNow: Bool { get }

    /// Translate one request. Network failures, timeouts, 429 and 5xx come
    /// back as `.retryable`; auth and request-shape errors as `.fatal`.
    func translate(_ request: TranslationRequest) async -> TranslationOutcome

    /// Short connectivity probe used by "Test connection" in Settings.
    func testConnection() async -> Result<String, TranslationError>
}
