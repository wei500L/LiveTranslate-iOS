import Foundation
import OSLog

/// Model service for post-class study reviews. Deliberately separate from
/// `TranslationService`: the live pipeline must never depend on review
/// generation, and review prompts/limits differ (large structured JSON,
/// long timeouts, non-streaming). It reuses the OpenAI-compatible HTTP
/// transport primitives from the translator (base-URL normalization,
/// status classification, response extraction) — but composes its own
/// request shape.
protocol StudyReviewModelService: Sendable {
    /// Synchronous configuration check (base + model resolved; the key is
    /// never exposed).
    var isConfiguredNow: Bool { get }

    /// One non-streaming chat completion. Returns the raw text; parsing is
    /// the caller's (StudyReviewParser) job. Throws `TranslationError`
    /// (`.notConfigured`, `.retryable`, `.fatal`, `.emptyResponse`).
    func complete(systemPrompt: String, userPrompt: String, maxTokens: Int) async throws -> String
}

/// Configuration assembled from settings: the study model inherits the
/// translation API base + key, and its model name unless the user chose a
/// dedicated one.
struct StudyReviewModelConfig: Sendable, Equatable {
    var apiBase: String
    var apiKey: String?
    var model: String
    /// Structured generation is slower than per-utterance translation.
    var timeout: TimeInterval = 180

    var isConfigured: Bool {
        !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && OpenAICompatibleTranslator.normalizeAPIBase(apiBase) != nil
    }
}

/// OpenAI-compatible implementation. Non-streaming by design: the response
/// is a large structured JSON document, and streaming buys nothing for a
/// one-shot parse (the spec explicitly prefers stable parse/recover over
/// visual streaming).
struct OpenAICompatibleStudyService: StudyReviewModelService {
    static let logger = Logger(subsystem: "com.livetranslate.ios", category: "study-review")

    let config: StudyReviewModelConfig

    var isConfiguredNow: Bool { config.isConfigured }

    func complete(systemPrompt: String, userPrompt: String, maxTokens: Int) async throws -> String {
        guard config.isConfigured else { throw TranslationError.notConfigured }
        do {
            return try await completeOnce(
                systemPrompt: systemPrompt, userPrompt: userPrompt, maxTokens: maxTokens
            )
        } catch let error as TranslationError where TranslationRetryPolicy.shouldRetry(error) {
            // One bounded retry for network-class failures only.
            Self.logger.notice("Retryable review request failure, retrying once: \(error.errorDescription ?? "", privacy: .public)")
            try? await Task.sleep(nanoseconds: 750_000_000)
            return try await completeOnce(
                systemPrompt: systemPrompt, userPrompt: userPrompt, maxTokens: maxTokens
            )
        }
    }

    private func completeOnce(systemPrompt: String, userPrompt: String, maxTokens: Int) async throws -> String {
        let body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt],
            ],
            "max_tokens": maxTokens,
            "temperature": 0.2,
        ]
        let bodyData: Data
        do {
            bodyData = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw TranslationError.fatal("Could not encode request body.")
        }
        let url = try OpenAICompatibleTranslator.endpointURL(apiBase: config.apiBase)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.timeoutInterval = config.timeout + 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let bearer = (config.apiKey?.isEmpty == false) ? config.apiKey! : "local"
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try OpenAICompatibleTranslator.checkHTTPStatus(response, body: data)
            let text = OpenAICompatibleTranslator.extractMessageContent(data) ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw TranslationError.emptyResponse }
            return trimmed
        } catch let error as TranslationError {
            throw error
        } catch let error as URLError {
            throw TranslationRetryPolicy.classify(error)
        } catch is CancellationError {
            // Cancellation must propagate untouched — the caller decides
            // how to record it; a cancelled request is never retried.
            throw CancellationError()
        }
    }
}
