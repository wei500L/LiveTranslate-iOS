import Foundation
import OSLog

/// The unified multimodal model service: image understanding (附件分析),
/// PDF scanned-page understanding and visual Q&A all ride this ONE
/// protocol and its ONE OpenAI-compatible implementation. A separate
/// domain from both the live translator and the study-review service:
/// image requests carry content parts, have their own payload budget,
/// and must never share configuration assumptions with the real-time
/// pipeline. It reuses the OpenAI-compatible transport primitives
/// (base-URL normalization, status classification, response extraction)
/// — but composes its own request shape.
protocol AttachmentAnalysisModelService: Sendable {
    /// Synchronous configuration check (base + model resolved; the key is
    /// never exposed).
    var isConfiguredNow: Bool { get }

    /// The configured model's name (for answer provenance; nil when the
    /// conformer cannot report it).
    var modelName: String? { get }

    /// One non-streaming multimodal chat completion: text prompt + one
    /// JPEG payload. The image bytes are base64-embedded for the request
    /// ONLY — never persisted in that form.
    func complete(
        systemPrompt: String, userPrompt: String,
        imageData: Data, imageMIME: String, maxTokens: Int
    ) async throws -> String

    /// Multi-image completion (visual Q&A, page comparison): the text
    /// prompt plus an ordered list of image payloads. Images ride as
    /// content parts in the given order; labeled payloads get a
    /// `label` text part emitted before the image so answers can
    /// reference 图片 1 / 图片 2.
    func complete(
        systemPrompt: String, userPrompt: String,
        images: [ModelImagePayload], maxTokens: Int
    ) async throws -> String
}

/// One image riding a multimodal request. Bytes exist for the request
/// lifecycle only.
struct ModelImagePayload: Sendable, Equatable {
    var data: Data
    var mimeType: String
    /// Optional marker part emitted before the image (e.g. "[图片 1]").
    var label: String?

    init(data: Data, mimeType: String = "image/jpeg", label: String? = nil) {
        self.data = data
        self.mimeType = mimeType
        self.label = label
    }
}

extension AttachmentAnalysisModelService {
    var modelName: String? { nil }

    /// Default multi-image transport: falls back to the single-image
    /// method with the first image, so existing conformers (and test
    /// doubles) keep working without knowing about lists.
    func complete(
        systemPrompt: String, userPrompt: String,
        images: [ModelImagePayload], maxTokens: Int
    ) async throws -> String {
        guard let first = images.first else {
            throw TranslationError.fatal("多模态请求缺少图片。")
        }
        return try await complete(
            systemPrompt: systemPrompt, userPrompt: userPrompt,
            imageData: first.data, imageMIME: first.mimeType,
            maxTokens: maxTokens
        )
    }
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

    var modelName: String? { config.model }

    func complete(
        systemPrompt: String, userPrompt: String,
        imageData: Data, imageMIME: String, maxTokens: Int
    ) async throws -> String {
        // The single-image request is a one-element multi-image request —
        // ONE transport path, not a second client.
        try await complete(
            systemPrompt: systemPrompt, userPrompt: userPrompt,
            images: [ModelImagePayload(data: imageData, mimeType: imageMIME)],
            maxTokens: maxTokens
        )
    }

    func complete(
        systemPrompt: String, userPrompt: String,
        images: [ModelImagePayload], maxTokens: Int
    ) async throws -> String {
        guard config.isConfigured else { throw TranslationError.notConfigured }
        // Round 17: the local AI activity ledger — metadata only (image
        // count + text volume + host + outcome; never image bytes or
        // prompts).
        let activityHost = URL(string: OpenAICompatibleTranslator.normalizeAPIBase(config.apiBase) ?? "")?.host ?? ""
        let activityChars = systemPrompt.count + userPrompt.count
        let imageCount = images.count
        do {
            let result = try await completeWithRetry(
                systemPrompt: systemPrompt, userPrompt: userPrompt,
                images: images, maxTokens: maxTokens
            )
            await AIActivityLog.recordTransport(
                characterCount: activityChars, imageCount: imageCount,
                outcome: .success, host: activityHost
            )
            return result
        } catch is CancellationError {
            await AIActivityLog.recordTransport(
                characterCount: activityChars, imageCount: imageCount,
                outcome: .cancelled, host: activityHost
            )
            throw CancellationError()
        } catch {
            await AIActivityLog.recordTransport(
                characterCount: activityChars, imageCount: imageCount,
                outcome: .failed, host: activityHost
            )
            throw error
        }
    }

    private func completeWithRetry(
        systemPrompt: String, userPrompt: String,
        images: [ModelImagePayload], maxTokens: Int
    ) async throws -> String {
        do {
            return try await completeOnce(
                systemPrompt: systemPrompt, userPrompt: userPrompt,
                images: images, maxTokens: maxTokens
            )
        } catch let error as TranslationError where TranslationRetryPolicy.shouldRetry(error) {
            // One bounded retry for network-class failures only.
            Self.logger.notice("Retryable image request failure, retrying once: \(error.errorDescription ?? "", privacy: .public)")
            try? await Task.sleep(nanoseconds: 750_000_000)
            return try await completeOnce(
                systemPrompt: systemPrompt, userPrompt: userPrompt,
                images: images, maxTokens: maxTokens
            )
        }
    }

    private func completeOnce(
        systemPrompt: String, userPrompt: String,
        images: [ModelImagePayload], maxTokens: Int
    ) async throws -> String {
        // Content parts: the prompt text first, then each labeled image
        // (marker part + image part) so multi-image answers can say
        // 图片 1 / 图片 2 unambiguously.
        var userParts: [[String: Any]] = [["type": "text", "text": userPrompt]]
        for image in images {
            if let label = image.label, !label.isEmpty {
                userParts.append(["type": "text", "text": label])
            }
            let dataURL = "data:\(image.mimeType);base64,\(image.data.base64EncodedString())"
            userParts.append([
                "type": "image_url",
                "image_url": ["url": dataURL],
            ])
        }
        let body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userParts],
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
