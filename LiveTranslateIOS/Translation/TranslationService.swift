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
    /// The request was cancelled (round 17: distinct from failure so
    /// cancellation is never recorded as a model failure).
    case cancelled

    var errorDescription: String? {
        switch self {
        case .retryable(let reason): return reason
        case .fatal(let reason): return reason
        case .notConfigured: return String(localized: "Translation API is not configured.")
        case .emptyResponse: return String(localized: "The translation model returned an empty response.")
        case .cancelled: return String(localized: "Request cancelled.")
        }
    }

    var isRetryable: Bool {
        switch self {
        case .retryable: return true
        default: return false
        }
    }

    /// Stable, actionable summary for RUNTIME surfaces (interpreter,
    /// analysis failures — round 17). The provider's raw message text
    /// never reaches these screens; it remains visible only in the
    /// settings "test connection" flow, where the user is debugging
    /// their own endpoint.
    var userActionableSummary: String {
        switch self {
        case .retryable:
            return String(localized: "网络不稳定，请稍后重试或检查网络连接")
        case .fatal:
            return String(localized: "请求被服务方拒绝，请在设置中检查 API 地址、密钥与模型名")
        case .notConfigured:
            return errorDescription ?? ""
        case .emptyResponse:
            return String(localized: "模型返回了空结果，请重试")
        case .cancelled:
            return errorDescription ?? ""
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
