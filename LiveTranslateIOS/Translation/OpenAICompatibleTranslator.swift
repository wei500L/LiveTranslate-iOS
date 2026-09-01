import Foundation
import OSLog

/// Configuration for the OpenAI-compatible translator. The API key is read
/// from the Keychain by the caller and passed in; it is never persisted
/// anywhere else and never logged.
struct TranslatorConfig: Sendable, Equatable {
    var apiBase: String
    /// Plain API key, or nil/empty for local servers that ignore it.
    var apiKey: String?
    var model: String
    var streaming: Bool = true
    var contextTurns: Int = 4
    var temperature: Double = 0.3
    var maxTokens: Int = 256
    var timeout: TimeInterval = 30
    var thinkingStyle: ThinkingStyle = .auto
    var customSystemPrompt: String = ""
    var sourceLanguage: String = "ru"
    var targetLanguage: String = "zh-CN"

    var isConfigured: Bool {
        !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && OpenAICompatibleTranslator.normalizeAPIBase(apiBase) != nil
    }
}

/// OpenAI-compatible chat-completions translator.
///
/// Behavior inherited from the reference project's `translator.py`:
/// classroom system prompt with embedded context, provider-specific
/// thinking-disable parameters, streaming SSE with a total deadline, and a
/// strict retry policy — auth/parameter errors are never blindly retried.
struct OpenAICompatibleTranslator: TranslationService {
    static let logger = Logger(subsystem: "com.livetranslate.ios", category: "translation")

    let config: TranslatorConfig
    /// Placeholder the request sends when no key is configured — local
    /// servers (LM Studio, Ollama /v1, mlx server) ignore it; real
    /// providers reject it with a clear 401 instead of a crash.
    private static let localAPIKeyPlaceholder = "local"
    /// Backoff before the single retry of a retryable failure.
    private static let retryBackoff: TimeInterval = 0.75

    init(config: TranslatorConfig) {
        self.config = config
    }

    var isConfigured: Bool { config.isConfigured }

    // MARK: - TranslationService

    func translate(_ request: TranslationRequest) async -> TranslationOutcome {
        let started = Date()
        guard config.isConfigured else {
            return TranslationOutcome(
                sequenceID: request.sequenceID, text: nil,
                latency: Date().timeIntervalSince(started),
                isRetryable: false,
                errorDescription: TranslationError.notConfigured.errorDescription
            )
        }
        do {
            let text = try await translateWithRetry(request)
            return TranslationOutcome(
                sequenceID: request.sequenceID, text: text,
                latency: Date().timeIntervalSince(started),
                isRetryable: false, errorDescription: nil
            )
        } catch let error as TranslationError {
            return TranslationOutcome(
                sequenceID: request.sequenceID, text: nil,
                latency: Date().timeIntervalSince(started),
                isRetryable: error.isRetryable,
                errorDescription: error.errorDescription
            )
        } catch {
            return TranslationOutcome(
                sequenceID: request.sequenceID, text: nil,
                latency: Date().timeIntervalSince(started),
                isRetryable: false,
                errorDescription: error.localizedDescription
            )
        }
    }

    func testConnection() async -> Result<String, TranslationError> {
        guard config.isConfigured else { return .failure(.notConfigured) }
        var probe = config
        probe.maxTokens = 8
        probe.temperature = 0
        let request = TranslationRequest(
            id: 0,
            sequenceID: 0,
            text: "Reply with exactly: OK",
            sourceLanguage: config.sourceLanguage,
            targetLanguage: config.targetLanguage,
            history: []
        )
        let translator = OpenAICompatibleTranslator(config: probe)
        do {
            let text = try await translator.translateOnce(request)
            return .success(text)
        } catch let error as TranslationError {
            return .failure(error)
        } catch {
            return .failure(.fatal(error.localizedDescription))
        }
    }

    // MARK: - Request pipeline

    private func translateWithRetry(_ request: TranslationRequest) async throws -> String {
        do {
            return try await translateOnce(request)
        } catch let error as TranslationError where TranslationRetryPolicy.shouldRetry(error) {
            // One bounded retry for network-class failures only.
            Self.logger.notice("Retryable translation failure, retrying once: \(error.errorDescription ?? "", privacy: .public)")
            try? await Task.sleep(nanoseconds: UInt64(Self.retryBackoff * 1_000_000_000))
            return try await translateOnce(request)
        }
    }

    private func translateOnce(_ request: TranslationRequest) async throws -> String {
        do {
            let body = try Self.requestBody(for: request, config: config)
            let url = try Self.endpointURL(apiBase: config.apiBase)
            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "POST"
            urlRequest.httpBody = body
            urlRequest.timeoutInterval = config.timeout + 5
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let bearer = Self.bearerToken(config.apiKey)
            urlRequest.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")

            let session = URLSession.shared
            if config.streaming {
                return try await streamCompletion(urlRequest, session: session)
            }
            return try await syncCompletion(urlRequest, session: session)
        } catch let error as TranslationError {
            throw error
        } catch let error as URLError {
            // Transport failures must be classified so the bounded retry
            // and the UI retry affordances treat them correctly.
            throw TranslationRetryPolicy.classify(error)
        } catch is CancellationError {
            throw TranslationError.retryable("Translation cancelled.")
        }
    }

    /// Placeholder for keyless local servers; real providers reject it with
    /// a clear 401 rather than a crash (matches the reference behavior).
    private static func bearerToken(_ apiKey: String?) -> String {
        guard let apiKey, !apiKey.isEmpty else { return localAPIKeyPlaceholder }
        return apiKey
    }

    private func streamCompletion(_ urlRequest: URLRequest, session: URLSession) async throws -> String {
        let deadline = Date().addingTimeInterval(config.timeout)
        let (bytes, response) = try await session.bytes(for: urlRequest)
        try Self.checkHTTPStatus(response)

        var parser = SSEParser()
        var chunks: [String] = []
        for try await line in bytes.lines {
            if Date() > deadline {
                throw TranslationError.retryable("Translation exceeded \(Int(config.timeout))s total timeout")
            }
            for payload in parser.feed(line + "\n") {
                if payload == "[DONE]" { continue }
                if let delta = Self.extractDeltaContent(payload) {
                    chunks.append(delta)
                }
            }
        }
        for payload in parser.finish() {
            if payload == "[DONE]" { continue }
            if let delta = Self.extractDeltaContent(payload) {
                chunks.append(delta)
            }
        }
        let text = chunks.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranslationError.emptyResponse }
        return text
    }

    private func syncCompletion(_ urlRequest: URLRequest, session: URLSession) async throws -> String {
        let (data, response) = try await session.data(for: urlRequest)
        try Self.checkHTTPStatus(response, body: data)
        let text = Self.extractMessageContent(data) ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranslationError.emptyResponse }
        return trimmed
    }

    // MARK: - URL / body construction (pure, testable)

    /// Normalize a user-entered API base into a full URL string:
    /// - default scheme `https://` when absent
    /// - plain `http://` allowed only for local hosts (localhost,
    ///   127.0.0.1, `*.local`, IP literals) — matches the scoped ATS
    ///   exception; everything else must be HTTPS
    /// - trailing slashes stripped; `/v1` appended when the path does not
    ///   already carry it
    /// Returns nil for input that is unusable or non-local HTTP.
    static func normalizeAPIBase(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if !value.contains("://") {
            value = "https://" + value
        }
        guard let url = URL(string: value), let host = url.host(percentEncoded: false), !host.isEmpty else {
            return nil
        }
        let scheme = url.scheme?.lowercased() ?? "https"
        guard scheme == "https" || (scheme == "http" && Self.isLocalHost(host)) else {
            return nil
        }
        var path = url.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        if path.isEmpty || path == "/" {
            path = "/v1"
        } else if !path.hasSuffix("/v1") && !path.contains("/v1/") {
            path += "/v1"
        }
        var result = "\(scheme)://\(host)"
        if let port = url.port, url.port != Self.defaultPort(for: scheme) {
            result += ":\(port)"
        }
        result += path
        return result
    }

    static func isLocalHost(_ host: String) -> Bool {
        let lowered = host.lowercased()
        if lowered == "localhost" || lowered == "::1" { return true }
        if lowered.hasSuffix(".local") { return true }
        // IPv4 literal: four dot-separated 0-255 octets.
        let octets = lowered.split(separator: ".", omittingEmptySubsequences: false)
        if octets.count == 4 {
            return octets.allSatisfy { octet in
                guard !octet.isEmpty, octet.count <= 3, octet.allSatisfy(\.isNumber) else { return false }
                return (Int(octet) ?? 256) <= 255
            }
        }
        return false
    }

    private static func defaultPort(for scheme: String) -> Int? {
        scheme == "https" ? 443 : 80
    }

    static func endpointURL(apiBase: String) throws -> URL {
        guard let normalized = normalizeAPIBase(apiBase),
              let url = URL(string: normalized + "/chat/completions") else {
            throw TranslationError.fatal("Invalid API base URL.")
        }
        return url
    }

    /// System prompt for one request: the custom template when it carries
    /// only supported placeholders, otherwise the classroom default.
    static func systemPrompt(for request: TranslationRequest, customTemplate: String) -> String {
        let trimmed = customTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && customTemplateHasSupportedPlaceholders(trimmed) {
            let src = ClassroomTranslationPrompt.displayLanguage(request.sourceLanguage)
            let tgt = ClassroomTranslationPrompt.displayLanguage(request.targetLanguage)
            var contextLines: [String] = []
            for pair in request.history {
                contextLines.append("Source: \(pair.source)")
                contextLines.append("Translation: \(pair.translation)")
                contextLines.append("")
            }
            let context = contextLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed
                .replacingOccurrences(of: "{source_lang}", with: src)
                .replacingOccurrences(of: "{target_lang}", with: tgt)
                .replacingOccurrences(of: "{context}", with: context)
        }
        return ClassroomTranslationPrompt.build(
            source: request.sourceLanguage,
            target: request.targetLanguage,
            history: request.history
        )
    }

    private static let supportedPlaceholders: Set<String> = ["source_lang", "target_lang", "context"]

    private static func customTemplateHasSupportedPlaceholders(_ template: String) -> Bool {
        // Mirrors the reference: an unknown {field} would make .format()
        // raise KeyError, which fell back to the default prompt.
        guard let regex = try? NSRegularExpression(pattern: #"\{[a-zA-Z_]+\}"#) else {
            return false
        }
        let range = NSRange(template.startIndex..., in: template)
        for match in regex.matches(in: template, range: range) {
            guard let matchRange = Range(match.range, in: template) else { continue }
            let name = template[matchRange].dropFirst().dropLast()
            if !supportedPlaceholders.contains(String(name)) {
                return false
            }
        }
        return true
    }

    /// Build the chat-completions request body as JSON data.
    static func requestBody(for request: TranslationRequest, config: TranslatorConfig) throws -> Data {
        let system = systemPrompt(for: request, customTemplate: config.customSystemPrompt)
        let messages: [[String: String]] = [
            ["role": "system", "content": system],
            ["role": "user", "content": request.text],
        ]
        var body: [String: Any] = [
            "model": config.model,
            "messages": messages,
            "max_tokens": config.maxTokens,
            "temperature": config.temperature,
        ]
        let resolved = ThinkingStyle.resolve(config.thinkingStyle, apiBase: config.apiBase, model: config.model)
        for (key, value) in resolved.disableBody {
            body[key] = value
        }
        do {
            return try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw TranslationError.fatal("Could not encode request body.")
        }
    }

    // MARK: - Response parsing (pure, testable)

    /// Content delta from one streaming payload. Usage-only frames carry no
    /// choices at all and return nil.
    static func extractDeltaContent(_ payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let choice = choices.first,
              let delta = choice["delta"] as? [String: Any],
              let content = delta["content"] as? String else {
            return nil
        }
        return content
    }

    /// message.content from a non-streaming response body.
    static func extractMessageContent(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let choice = choices.first,
              let message = choice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return nil
        }
        return content
    }

    static func checkHTTPStatus(_ response: URLResponse, body: Data? = nil) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200...299).contains(http.statusCode) else { return }
        throw TranslationRetryPolicy.classify(
            status: http.statusCode,
            serverMessage: serverMessage(from: body)
        )
    }

    /// Short, sanitized server error message. Never contains auth headers
    /// or the request body.
    private static func serverMessage(from data: Data?) -> String? {
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            return String(message.prefix(200))
        }
        if let message = object["message"] as? String {
            return String(message.prefix(200))
        }
        return nil
    }
}
