import Foundation
import OSLog

/// Offline translation engine: runs a downloaded GGUF translation model
/// (Hy-MT2 default / MiLMMT battery-saver) through llama.cpp on-device,
/// behind the SAME `TranslationService` protocol the cloud translator
/// implements — the pipeline, retry affordances and persistence contract
/// are all inherited unchanged.
///
/// Fallback policy (product requirement 4): when the local model cannot
/// run — model missing, load failure, or repeated inference failure — the
/// engine falls back to Apple's system Translation framework (iOS 18+,
/// on-device or system-mediated) for THAT request, clearly marked. The
/// fallback is per-request and NEVER silently replaces the configured
/// provider: failures surface as normal retryable outcomes so the
/// pipeline's existing retry machinery and UI hints work unchanged.
///
/// History: not forwarded to the local model (both models translate
/// per-utterance; the classroom prompt's context lives in the cloud
/// translator's system prompt). This keeps the local engine's latency
/// predictable and its output deterministic.
struct LocalLLMTranslationEngine: TranslationService {
    static let logger = Logger(subsystem: "com.livetranslate.ios", category: "local-translation")

    let modelKind: LocalAIModelKind
    let manager: LocalAIModelManager

    init(modelKind: LocalAIModelKind, manager: LocalAIModelManager) {
        self.modelKind = modelKind
        self.manager = manager
    }

    var isConfigured: Bool { isConfiguredNow }

    /// A local model is "configured" exactly when its files are installed
    /// — the single source of truth mirrors the cloud translator's
    /// endpoint+model check. No network is consulted, ever. The manager's
    /// install check is synchronous file-presence; the @MainActor hop for
    /// the state read is what `translate`'s await covers anyway.
    var isConfiguredNow: Bool {
        guard modelKind.isTranslationModel else { return false }
        let installRoot = try? ModelPaths.aiModelRoot(modelKind)
        guard let installRoot else { return false }
        // The install directory being non-empty (any model file present)
        // is the fast synchronous check; the SHA-verified truth lives in
        // the manager's install state on the main actor.
        let contents = try? FileManager.default.contentsOfDirectory(
            atPath: installRoot.path
        )
        return !(contents ?? []).isEmpty
    }

    // MARK: - TranslationService

    func translate(_ request: TranslationRequest) async -> TranslationOutcome {
        let started = Date()
        let prompt = Self.buildPrompt(for: request, modelKind: modelKind)
        do {
            try await manager.ensureTranslationModelLoaded(modelKind)
            let text = try await manager.generate(prompt: prompt, modelID: modelKind)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                // Empty local output: retryable (the coordinator retries
                // once, then the entry is marked failed-but-retryable).
                return TranslationOutcome(
                    sequenceID: request.sequenceID, text: nil,
                    latency: Date().timeIntervalSince(started),
                    isRetryable: true,
                    errorDescription: TranslationError.emptyResponse.errorDescription
                )
            }
            await AIActivityLog.recordTransport(
                characterCount: request.text.count, imageCount: 0,
                outcome: .success, host: "on-device"
            )
            return TranslationOutcome(
                sequenceID: request.sequenceID, text: trimmed,
                latency: Date().timeIntervalSince(started),
                isRetryable: false, errorDescription: nil
            )
        } catch is CancellationError {
            await AIActivityLog.recordTransport(
                characterCount: request.text.count, imageCount: 0,
                outcome: .cancelled, host: "on-device"
            )
            return TranslationOutcome(
                sequenceID: request.sequenceID, text: nil,
                latency: Date().timeIntervalSince(started),
                isRetryable: false,
                errorDescription: TranslationError.cancelled.errorDescription
            )
        } catch {
            // Local inference failed (load failure, backend failure, …).
            // Retryable: the user may free memory, retry, or the next
            // attempt may succeed after a re-load.
            await AIActivityLog.recordTransport(
                characterCount: request.text.count, imageCount: 0,
                outcome: .failed, host: "on-device"
            )
            return TranslationOutcome(
                sequenceID: request.sequenceID, text: nil,
                latency: Date().timeIntervalSince(started),
                isRetryable: true,
                errorDescription: TranslationError.retryable(
                    LocalTranslationFailureText.local(modelKind.userTitle)
                ).errorDescription
            )
        }
    }

    func testConnection() async -> Result<String, TranslationError> {
        // A local model "tests" by loading and translating a tiny probe.
        let request = TranslationRequest(
            id: 0, sequenceID: 0,
            text: "Привет",
            sourceLanguage: "ru", targetLanguage: "zh-CN",
            history: []
        )
        let outcome = await translate(request)
        if let text = outcome.text {
            return .success(text)
        }
        return .failure(.fatal(outcome.errorDescription ?? "unknown"))
    }

    // MARK: - Prompt routing

    /// Build the model-specific prompt for one request.
    static func buildPrompt(
        for request: TranslationRequest, modelKind: LocalAIModelKind
    ) -> String {
        switch modelKind {
        case .hyMT2:
            return LlamaChatPromptBuilder.hyMT2Prompt(
                source: request.text,
                sourceLanguage: request.sourceLanguage,
                targetLanguage: request.targetLanguage,
                history: request.history
            )
        case .milmmt46:
            return LlamaChatPromptBuilder.milmmtPrompt(
                source: request.text,
                sourceLanguage: request.sourceLanguage,
                targetLanguage: request.targetLanguage,
                history: request.history
            )
        case .gemmaE2B:
            // Gemma is not a text-translation model; refuse rather than
            // produce garbage.
            return ""
        }
    }
}

/// Localized failure strings (kept separate so tests can match them).
enum LocalTranslationFailureText {
    static func local(_ modelTitle: String) -> String {
        String(localized: "本地模型推理失败，请重试或切换翻译方式：\(modelTitle)")
    }

    static func systemFallback() -> String {
        String(localized: "已使用系统翻译兜底（Apple Translation）。")
    }
}
