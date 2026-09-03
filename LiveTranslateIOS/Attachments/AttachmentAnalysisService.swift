import Foundation
import OSLog

/// Model service for classroom-image understanding (multimodal). A
/// separate domain from both the live translator and the study-review
/// service: image requests carry content parts, have their own payload
/// budget, and must never share configuration assumptions with the
/// real-time pipeline. It reuses the OpenAI-compatible transport
/// primitives (base-URL normalization, status classification, response
/// extraction) — but composes its own request shape.
protocol AttachmentAnalysisModelService: Sendable {
    /// Synchronous configuration check (base + model resolved; the key is
    /// never exposed).
    var isConfiguredNow: Bool { get }

    /// One non-streaming multimodal chat completion: text prompt + one
    /// JPEG payload. The image bytes are base64-embedded for the request
    /// ONLY — never persisted in that form.
    func complete(
        systemPrompt: String, userPrompt: String,
        imageData: Data, imageMIME: String, maxTokens: Int
    ) async throws -> String
}

/// Configuration assembled from settings: the image-understanding model
/// inherits the translation API base + key, and its model name falls back
/// to the study-review model, then the translation model — the user never
/// re-enters the same key.
struct AttachmentAnalysisModelConfig: Sendable, Equatable {
    var apiBase: String
    var apiKey: String?
    var model: String
    var timeout: TimeInterval = 240

    var isConfigured: Bool {
        !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && OpenAICompatibleTranslator.normalizeAPIBase(apiBase) != nil
    }
}

/// OpenAI-compatible implementation. The user message uses the common
/// content-parts shape (`[{type:"text"}, {type:"image_url"}]`) understood
/// by OpenAI-style multimodal endpoints.
struct OpenAICompatibleAttachmentService: AttachmentAnalysisModelService {
    static let logger = Logger(subsystem: "com.livetranslate.ios", category: "attachment-analysis")

    let config: AttachmentAnalysisModelConfig

    var isConfiguredNow: Bool { config.isConfigured }

    func complete(
        systemPrompt: String, userPrompt: String,
        imageData: Data, imageMIME: String, maxTokens: Int
    ) async throws -> String {
        guard config.isConfigured else { throw TranslationError.notConfigured }
        do {
            return try await completeOnce(
                systemPrompt: systemPrompt, userPrompt: userPrompt,
                imageData: imageData, imageMIME: imageMIME, maxTokens: maxTokens
            )
        } catch let error as TranslationError where TranslationRetryPolicy.shouldRetry(error) {
            // One bounded retry for network-class failures only.
            Self.logger.notice("Retryable image request failure, retrying once: \(error.errorDescription ?? "", privacy: .public)")
            try? await Task.sleep(nanoseconds: 750_000_000)
            return try await completeOnce(
                systemPrompt: systemPrompt, userPrompt: userPrompt,
                imageData: imageData, imageMIME: imageMIME, maxTokens: maxTokens
            )
        }
    }

    private func completeOnce(
        systemPrompt: String, userPrompt: String,
        imageData: Data, imageMIME: String, maxTokens: Int
    ) async throws -> String {
        let dataURL = "data:\(imageMIME);base64,\(imageData.base64EncodedString())"
        let body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": userPrompt],
                        ["type": "image_url", "image_url": ["url": dataURL]],
                    ],
                ],
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
