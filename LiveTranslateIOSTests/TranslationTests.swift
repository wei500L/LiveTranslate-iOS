import XCTest
@testable import LiveTranslateIOS

final class TranslationTests: XCTestCase {
    // MARK: - URL normalization

    func testNormalizeAddsSchemeAndV1() {
        XCTAssertEqual(
            OpenAICompatibleTranslator.normalizeAPIBase("api.openai.com"),
            "https://api.openai.com/v1"
        )
        XCTAssertEqual(
            OpenAICompatibleTranslator.normalizeAPIBase("api.deepseek.com/"),
            "https://api.deepseek.com/v1"
        )
        XCTAssertEqual(
            OpenAICompatibleTranslator.normalizeAPIBase("https://api.openai.com"),
            "https://api.openai.com/v1"
        )
    }

    func testNormalizeKeepsExistingV1() {
        XCTAssertEqual(
            OpenAICompatibleTranslator.normalizeAPIBase("https://api.openai.com/v1"),
            "https://api.openai.com/v1"
        )
        XCTAssertEqual(
            OpenAICompatibleTranslator.normalizeAPIBase("https://api.openai.com/v1/"),
            "https://api.openai.com/v1"
        )
        XCTAssertEqual(
            OpenAICompatibleTranslator.normalizeAPIBase("https://host.example/api/v1/"),
            "https://host.example/api/v1"
        )
    }

    func testNormalizeLocalHTTPIsAllowed() {
        XCTAssertEqual(
            OpenAICompatibleTranslator.normalizeAPIBase("http://localhost:11434"),
            "http://localhost:11434/v1"
        )
        XCTAssertEqual(
            OpenAICompatibleTranslator.normalizeAPIBase("http://127.0.0.1:1234/"),
            "http://127.0.0.1:1234/v1"
        )
        XCTAssertEqual(
            OpenAICompatibleTranslator.normalizeAPIBase("http://192.168.1.10:8080"),
            "http://192.168.1.10:8080/v1"
        )
        XCTAssertEqual(
            OpenAICompatibleTranslator.normalizeAPIBase("http://mac-studio.local:8000"),
            "http://mac-studio.local:8000/v1"
        )
    }

    func testNormalizeRemoteHTTPIsRejected() {
        XCTAssertNil(OpenAICompatibleTranslator.normalizeAPIBase("http://api.openai.com"))
        XCTAssertNil(OpenAICompatibleTranslator.normalizeAPIBase("http://example.com/v1"))
        XCTAssertNil(OpenAICompatibleTranslator.normalizeAPIBase(""))
        XCTAssertNil(OpenAICompatibleTranslator.normalizeAPIBase("   "))
        XCTAssertNil(OpenAICompatibleTranslator.normalizeAPIBase("not a url"))
    }

    func testIsLocalHost() {
        XCTAssertTrue(OpenAICompatibleTranslator.isLocalHost("localhost"))
        XCTAssertTrue(OpenAICompatibleTranslator.isLocalHost("LOCALHOST"))
        XCTAssertTrue(OpenAICompatibleTranslator.isLocalHost("127.0.0.1"))
        XCTAssertTrue(OpenAICompatibleTranslator.isLocalHost("192.168.0.5"))
        XCTAssertTrue(OpenAICompatibleTranslator.isLocalHost("10.0.0.2"))
        XCTAssertTrue(OpenAICompatibleTranslator.isLocalHost("studio.local"))
        XCTAssertFalse(OpenAICompatibleTranslator.isLocalHost("api.openai.com"))
        XCTAssertFalse(OpenAICompatibleTranslator.isLocalHost("999.999.999.999"))
        XCTAssertFalse(OpenAICompatibleTranslator.isLocalHost("1.2.3"))
    }

    // MARK: - Retry classification

    func testRetryableURLErrors() {
        XCTAssertTrue(TranslationRetryPolicy.classify(URLError(.timedOut)).isRetryable)
        XCTAssertTrue(TranslationRetryPolicy.classify(URLError(.networkConnectionLost)).isRetryable)
        XCTAssertTrue(TranslationRetryPolicy.classify(URLError(.notConnectedToInternet)).isRetryable)
        XCTAssertTrue(TranslationRetryPolicy.classify(URLError(.cannotConnectToHost)).isRetryable)
        // Wrong request shape, not a network failure.
        XCTAssertFalse(TranslationRetryPolicy.classify(URLError(.badURL)).isRetryable)
    }

    func testHTTPStatusClassification() {
        XCTAssertTrue(TranslationRetryPolicy.classify(status: 429, serverMessage: nil).isRetryable)
        XCTAssertTrue(TranslationRetryPolicy.classify(status: 500, serverMessage: "boom").isRetryable)
        XCTAssertTrue(TranslationRetryPolicy.classify(status: 503, serverMessage: nil).isRetryable)
        XCTAssertFalse(TranslationRetryPolicy.classify(status: 401, serverMessage: "bad key").isRetryable)
        XCTAssertFalse(TranslationRetryPolicy.classify(status: 403, serverMessage: nil).isRetryable)
        XCTAssertFalse(TranslationRetryPolicy.classify(status: 400, serverMessage: "invalid param").isRetryable)
        XCTAssertFalse(TranslationRetryPolicy.classify(status: 422, serverMessage: nil).isRetryable)
    }

    // MARK: - Request body

    private func makeRequest(history: [(String, String)] = []) -> TranslationRequest {
        TranslationRequest(
            id: 1, sequenceID: 1,
            text: "Здравствуйте, товарищи!",
            sourceLanguage: "ru", targetLanguage: "zh-CN",
            history: history.map { (source: $0.0, translation: $0.1) }
        )
    }

    private func makeConfig(style: ThinkingStyle = .off, customPrompt: String = "") -> TranslatorConfig {
        TranslatorConfig(
            apiBase: "https://api.example.com/v1",
            apiKey: "secret-key",
            model: "test-model",
            streaming: false,
            contextTurns: 4,
            temperature: 0.2,
            maxTokens: 128,
            timeout: 10,
            thinkingStyle: style,
            customSystemPrompt: customPrompt
        )
    }

    func testRequestBodyShape() throws {
        let body = try OpenAICompatibleTranslator.requestBody(
            for: makeRequest(), config: makeConfig()
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "test-model")
        XCTAssertEqual(object["max_tokens"] as? Int, 128)
        XCTAssertEqual(object["temperature"] as? Double ?? (object["temperature"] as? NSNumber)?.doubleValue, 0.2)
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[1]["role"] as? String, "user")
        XCTAssertEqual(messages[1]["content"] as? String, "Здравствуйте, товарищи!")
        let system = try XCTUnwrap(messages[0]["content"] as? String)
        XCTAssertTrue(system.contains("Russian"))
        XCTAssertTrue(system.contains("Simplified Chinese"))
        XCTAssertTrue(system.contains("课堂"))
    }

    func testRequestBodyEmbedsContext() throws {
        let request = makeRequest(history: [("первое", "第一句"), ("второе", "第二句")])
        let body = try OpenAICompatibleTranslator.requestBody(for: request, config: makeConfig())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        let system = try XCTUnwrap(messages[0]["content"] as? String)
        XCTAssertTrue(system.contains("Source: первое"))
        XCTAssertTrue(system.contains("Translation: 第一句"))
    }

    func testThinkingDisableBodyPerStyle() throws {
        // "off" sends nothing.
        var body = try OpenAICompatibleTranslator.requestBody(
            for: makeRequest(), config: makeConfig(style: .off)
        )
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(object["enable_thinking"])
        XCTAssertNil(object["thinking"])
        XCTAssertNil(object["reasoning_effort"])

        // "qwen" sends a flat flag.
        body = try OpenAICompatibleTranslator.requestBody(
            for: makeRequest(), config: makeConfig(style: .qwen)
        )
        object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["enable_thinking"] as? Bool, false)

        // "deepseek" nests a dictionary.
        body = try OpenAICompatibleTranslator.requestBody(
            for: makeRequest(), config: makeConfig(style: .deepseek)
        )
        object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let thinking = try XCTUnwrap(object["thinking"] as? [String: Any])
        XCTAssertEqual(thinking["type"] as? String, "disabled")

        // "openai" uses reasoning_effort.
        body = try OpenAICompatibleTranslator.requestBody(
            for: makeRequest(), config: makeConfig(style: .openai)
        )
        object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["reasoning_effort"] as? String, "none")
    }

    func testAutoThinkingStyleResolution() {
        XCTAssertEqual(
            ThinkingStyle.resolve(.auto, apiBase: "https://api.deepseek.com/v1", model: "x"),
            .deepseek
        )
        XCTAssertEqual(
            ThinkingStyle.resolve(.auto, apiBase: "https://api.example.com/v1", model: "glm-4"),
            .deepseek
        )
        XCTAssertEqual(
            ThinkingStyle.resolve(.auto, apiBase: "https://api.openai.com/v1", model: "gpt-5"),
            .off
        )
        XCTAssertEqual(
            ThinkingStyle.resolve(.auto, apiBase: "https://api.example.com/v1", model: "qwen3"),
            .qwen
        )
        XCTAssertEqual(
            ThinkingStyle.resolve(.qwen, apiBase: "https://api.openai.com/v1", model: "gpt-5"),
            .qwen
        )
    }

    // MARK: - Custom prompt

    func testCustomPromptWithPlaceholders() {
        let custom = "Translate {source_lang} to {target_lang}. Context: {context}"
        let request = makeRequest(history: [("hi", "你好")])
        let prompt = OpenAICompatibleTranslator.systemPrompt(for: request, customTemplate: custom)
        XCTAssertTrue(prompt.hasPrefix("Translate Russian to Simplified Chinese."))
        XCTAssertTrue(prompt.contains("Source: hi"))
    }

    func testCustomPromptWithUnknownPlaceholderFallsBack() {
        let custom = "Translate {source_lang} to {target_lang} in {style} mode"
        let prompt = OpenAICompatibleTranslator.systemPrompt(
            for: makeRequest(), customTemplate: custom
        )
        // Unknown {style} would crash .format() in the reference; fall back
        // to the classroom default instead.
        XCTAssertTrue(prompt.contains("课堂"))
    }

    func testEmptyCustomPromptUsesDefault() {
        let prompt = OpenAICompatibleTranslator.systemPrompt(
            for: makeRequest(), customTemplate: "   "
        )
        XCTAssertTrue(prompt.contains("课堂"))
    }

    // MARK: - Response parsing

    func testExtractDeltaContent() {
        XCTAssertEqual(
            OpenAICompatibleTranslator.extractDeltaContent(
                "{\"choices\":[{\"delta\":{\"content\":\"世界\"}}]}"
            ),
            "世界"
        )
        // Usage-only frame: no choices at all.
        XCTAssertNil(
            OpenAICompatibleTranslator.extractDeltaContent(
                "{\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":2}}"
            )
        )
        // Multiple choices: take the first.
        XCTAssertEqual(
            OpenAICompatibleTranslator.extractDeltaContent(
                "{\"choices\":[{\"delta\":{\"content\":\"a\"}},{\"delta\":{\"content\":\"b\"}}]}"
            ),
            "a"
        )
        // Empty delta (role-only first frame).
        XCTAssertNil(
            OpenAICompatibleTranslator.extractDeltaContent(
                "{\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}"
            )
        )
    }

    func testExtractMessageContent() throws {
        let data = Data(
            "{\"choices\":[{\"message\":{\"content\":\"Привет\"}}]}".utf8
        )
        XCTAssertEqual(OpenAICompatibleTranslator.extractMessageContent(data), "Привет")
        let bad = Data("{\"error\":{\"message\":\"nope\"}}".utf8)
        XCTAssertNil(OpenAICompatibleTranslator.extractMessageContent(bad))
    }

    // MARK: - Configured state

    func testIsConfigured() {
        XCTAssertTrue(makeConfig().isConfigured)
        var config = makeConfig()
        config.model = "  "
        XCTAssertFalse(config.isConfigured)
        config = makeConfig()
        config.apiBase = "http://evil.example.com"
        XCTAssertFalse(config.isConfigured)
    }
}
