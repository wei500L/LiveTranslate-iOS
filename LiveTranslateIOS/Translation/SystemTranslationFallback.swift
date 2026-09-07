import Foundation
import OSLog
#if canImport(Translation)
import Translation
#endif

/// Apple system Translation framework fallback: the LAST-RESORT translator
/// when the device cannot run local models (model missing, load failure,
/// repeated inference failure). It never replaces the default local model —
/// it exists so "model unavailable" degrades to working translation instead
/// of silence.
///
/// Availability (verified against the iOS 26.5 SDK interface): the
/// framework itself exists from iOS 18, but a pipeline-usable
/// `TranslationSession` can only be created programmatically from iOS 26
/// (`init(installedSource:target:)` — synchronous, non-throwing, uses the
/// languages already downloaded on this device and never prompts). On
/// iOS 17–25 the adapter reports not-configured — honest, not a crash.
final class SystemTranslationFallback: TranslationService, @unchecked Sendable {
    static let logger = Logger(subsystem: "com.livetranslate.ios", category: "system-translation")

    /// Whether a programmatically usable TranslationSession exists on this
    /// OS (iOS 26+; below that, session creation requires the SwiftUI
    /// `.translationTask` UI flow, which a background pipeline must not
    /// drive).
    private static var sessionAvailable: Bool {
        #if canImport(Translation)
        if #available(iOS 26.0, *) { return true }
        return false
        #else
        return false
        #endif
    }

    init() {}

    var isConfigured: Bool { isConfiguredNow }

    var isConfiguredNow: Bool {
        // Never depends on user configuration — availability is the whole
        // story (per-language failure surfaces as a retryable translate
        // outcome).
        Self.sessionAvailable
    }

    func translate(_ request: TranslationRequest) async -> TranslationOutcome {
        await Self.translateOnMain(request)
    }

    func testConnection() async -> Result<String, TranslationError> {
        guard isConfiguredNow else { return .failure(.notConfigured) }
        let outcome = await translate(TranslationRequest(
            id: 0, sequenceID: 0, text: "Привет",
            sourceLanguage: "ru", targetLanguage: "zh-CN", history: []
        ))
        if let text = outcome.text { return .success(text) }
        return .failure(.fatal(outcome.errorDescription ?? "unknown"))
    }

    // MARK: - Internals

    private static func translateOnMain(_ request: TranslationRequest) async -> TranslationOutcome {
        let started = Date()
        guard sessionAvailable else {
            return TranslationOutcome(
                sequenceID: request.sequenceID, text: nil,
                latency: 0, isRetryable: false,
                errorDescription: TranslationError.notConfigured.errorDescription
            )
        }
        #if canImport(Translation)
        if #available(iOS 26.0, *) {
            let sourceLanguage = Locale.Language(identifier: Self.localeIdentifier(request.sourceLanguage))
            let targetLanguage = Locale.Language(identifier: Self.localeIdentifier(request.targetLanguage))
            // installedSource/target: run with the languages already
            // downloaded on this device — never trigger an interactive
            // download prompt from a background pipeline request.
            let session = TranslationSession(
                installedSource: sourceLanguage,
                target: targetLanguage
            )
            do {
                let response = try await session.translate(request.text)
                return TranslationOutcome(
                    sequenceID: request.sequenceID, text: response.targetText,
                    latency: Date().timeIntervalSince(started),
                    isRetryable: false, errorDescription: nil
                )
            } catch is CancellationError {
                return TranslationOutcome(
                    sequenceID: request.sequenceID, text: nil,
                    latency: Date().timeIntervalSince(started),
                    isRetryable: false,
                    errorDescription: TranslationError.cancelled.errorDescription
                )
            } catch {
                logger.error("System translation failed: \(String(describing: error), privacy: .public)")
                return TranslationOutcome(
                    sequenceID: request.sequenceID, text: nil,
                    latency: Date().timeIntervalSince(started),
                    isRetryable: true,
                    errorDescription: TranslationError.retryable(
                        String(localized: "系统翻译暂不可用，请稍后重试。")
                    ).errorDescription
                )
            }
        }
        #endif
        return TranslationOutcome(
            sequenceID: request.sequenceID, text: nil,
            latency: Date().timeIntervalSince(started),
            isRetryable: false,
            errorDescription: TranslationError.notConfigured.errorDescription
        )
    }

    /// Map the pipeline's language codes to Translation-framework locale
    /// identifiers.
    private static func localeIdentifier(_ code: String) -> String {
        switch code.lowercased() {
        case "ru": return "ru_RU"
        case "zh", "zh-cn", "zh-hans": return "zh_CN"
        case "zh-tw", "zh-hant": return "zh_TW"
        default: return code
        }
    }
}
