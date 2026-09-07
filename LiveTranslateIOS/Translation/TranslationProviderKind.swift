import Foundation
import OSLog

/// Translation provider selection: ONE resolved provider per user setting,
/// with the fallback chain the product requires:
///
/// 1. `.hyMT2` (default) / `.milmmt46` — the offline GGUF engine. Selected
///    model missing or failing → request falls back to Apple system
///    translation (marked), never to silent no-translation.
/// 2. `.cloud` — the OpenAI-compatible cloud translator (previous default;
///    unchanged behavior when chosen).
/// 3. `.apple` — system translation only (for devices that cannot run the
///    local models).
///
/// Selection is a user setting (`translationProviderKind`); switching it
/// rebuilds the service through the existing `TranslationServiceBox`, so
/// the coordinator picks up the change per request without any pipeline
/// modification. Classroom record integrity under switching: the session
/// pins the LOCAL model at session start (`beginSessionPin`), and
/// translation results are always persisted per-entry with the session's
/// own model version — old tasks never write into a new model's session.
enum TranslationProviderKind: String, CaseIterable, Identifiable, Sendable, Equatable {
    case hyMT2
    case milmmt46
    case cloud
    case apple

    var id: String { rawValue }

    var userTitle: String {
        switch self {
        case .hyMT2: return String(localized: "离线 · 标准画质")
        case .milmmt46: return String(localized: "离线 · 省电模式")
        case .cloud: return String(localized: "云端 API")
        case .apple: return String(localized: "系统翻译")
        }
    }

    var userSubtitle: String {
        switch self {
        case .hyMT2: return String(localized: "Hy-MT2 本地模型（需先下载），默认，完全离线")
        case .milmmt46: return String(localized: "MiLMMT 省电本地模型（需先下载），完全离线")
        case .cloud: return String(localized: "OpenAI 兼容接口（DeepSeek / Qwen / 局域网服务器）")
        case .apple: return String(localized: "Apple 系统翻译（iOS 18+，适合无法运行本地模型的设备）")
        }
    }

    var localModelKind: LocalAIModelKind? {
        switch self {
        case .hyMT2: return .hyMT2
        case .milmmt46: return .milmmt46
        case .cloud, .apple: return nil
        }
    }
}

/// The resolved provider handed to the pipeline. Wraps the primary
/// engine; local-model failures fall back to the system translator for
/// THAT request (marked retryable so the pipeline's honest-failure UI
/// still shows what happened — the fallback's own outcome reports it).
struct ResolvedTranslationService: TranslationService {
    static let logger = Logger(subsystem: "com.livetranslate.ios", category: "translation-provider")

    let primary: any TranslationService
    /// Fallback for local-model failure paths (nil when the primary IS the
    /// fallback or the cloud engine — a cloud failure must not silently
    /// route to system translation: the user chose an endpoint).
    let fallback: (any TranslationService)?
    /// Whether the primary is a LOCAL engine whose runtime failures may
    /// degrade to the fallback (structural: true only for
    /// `LocalLLMTranslationEngine` primaries).
    let primaryIsLocalEngine: Bool

    init(
        primary: any TranslationService,
        fallback: (any TranslationService)? = nil,
        primaryIsLocalEngine: Bool = false
    ) {
        self.primary = primary
        self.fallback = fallback
        self.primaryIsLocalEngine = primaryIsLocalEngine
    }

    var isConfigured: Bool {
        get async { await primary.isConfigured }
    }

    var isConfiguredNow: Bool { primary.isConfiguredNow }

    func translate(_ request: TranslationRequest) async -> TranslationOutcome {
        let outcome = await primary.translate(request)
        if outcome.text != nil { return outcome }
        // Fall back only for local-engine RUNTIME failure (retryable
        // outcome) — not for cloud, not for cancellation, not for
        // notConfigured (the user deliberately chose nothing).
        if let fallback, outcome.isRetryable, primaryIsLocalEngine {
            Self.logger.notice("Local model failed; using system translation fallback")
            let fallbackOutcome = await fallback.translate(request)
            if fallbackOutcome.text != nil {
                await AIActivityLog.recordTransport(
                    characterCount: request.text.count, imageCount: 0,
                    outcome: .success, host: "system-fallback"
                )
                return fallbackOutcome
            }
        }
        return outcome
    }

    func testConnection() async -> Result<String, TranslationError> {
        await primary.testConnection()
    }
}
