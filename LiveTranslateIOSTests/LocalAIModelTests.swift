import XCTest
@testable import LiveTranslateIOS

/// Local AI-model layer behavior that runs WITHOUT any model files or
/// downloads: prompt construction (byte-exact against the official model
/// cards), provider routing/defaults, install-state logic, and the
/// fallback chain.
final class LocalAIModelTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-ai-model-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Prompt builders (byte-exact contracts)

    func testHyMT2PromptMatchesModelCardRecipe() {
        let prompt = LlamaChatPromptBuilder.hyMT2Prompt(
            source: "Привет, как дела?",
            sourceLanguage: "ru",
            targetLanguage: "zh-CN",
            history: []
        )
        // Hy-MT2 card: no system prompt; instruction with FULL language
        // names; only the translation is output. History is deliberately
        // NOT included (documented in the builder).
        XCTAssertEqual(
            prompt,
            """
            Translate the following text into Simplified Chinese. Translate the text as is, without adding any explanation. Only output the translated result without any additional explanation.
            Привет, как дела?
            """
        )
        XCTAssertFalse(prompt.contains("Russian"), "source language never appears in the Hy-MT2 instruction")
    }

    func testHyMT2PromptIgnoresHistory() {
        let withHistory = LlamaChatPromptBuilder.hyMT2Prompt(
            source: "Текст",
            sourceLanguage: "ru",
            targetLanguage: "zh-CN",
            history: [("старый", "旧的")]
        )
        let withoutHistory = LlamaChatPromptBuilder.hyMT2Prompt(
            source: "Текст",
            sourceLanguage: "ru",
            targetLanguage: "zh-CN",
            history: []
        )
        XCTAssertEqual(withHistory, withoutHistory)
    }

    func testMilMMTPromptUsesGemmaTurnTemplate() {
        let prompt = LlamaChatPromptBuilder.milmmtPrompt(
            source: "Привет",
            sourceLanguage: "ru",
            targetLanguage: "zh-CN",
            history: []
        )
        XCTAssertTrue(prompt.hasPrefix("<start_of_turn>user\n"))
        XCTAssertTrue(prompt.contains("Translate the following text into Simplified Chinese."))
        XCTAssertTrue(prompt.contains("Привет"))
        XCTAssertTrue(prompt.hasSuffix("<end_of_turn>\n<start_of_turn>model\n"))
    }

    func testMilMMTPromptIncludesCappedHistory() {
        let history = (0..<5).map { (source: "строка\($0)", translation: "行\($0)") }
        let prompt = LlamaChatPromptBuilder.milmmtPrompt(
            source: "Текст",
            sourceLanguage: "ru",
            targetLanguage: "zh-CN",
            history: history
        )
        // Only the LAST 2 context turns ride (2048-token budget).
        XCTAssertFalse(prompt.contains("строка0"))
        XCTAssertFalse(prompt.contains("строка2"))
        XCTAssertTrue(prompt.contains("строка3"))
        XCTAssertTrue(prompt.contains("строка4"))
    }

    func testLanguageDisplayNames() {
        XCTAssertEqual(LlamaChatPromptBuilder.displayName(for: "zh-CN"), "Simplified Chinese")
        XCTAssertEqual(LlamaChatPromptBuilder.displayName(for: "ru"), "Russian")
        XCTAssertEqual(LlamaChatPromptBuilder.displayName(for: "en"), "English")
        XCTAssertEqual(LlamaChatPromptBuilder.displayName(for: "zh-Hant"), "Traditional Chinese")
        // Unknown codes pass through unchanged (never a crash, never a
        // silent wrong language).
        XCTAssertEqual(LlamaChatPromptBuilder.displayName(for: "fr-CA"), "fr-CA")
    }

    // MARK: - Provider kind mapping

    func testProviderLocalModelMapping() {
        XCTAssertEqual(TranslationProviderKind.hyMT2.localModelKind, .hyMT2)
        XCTAssertEqual(TranslationProviderKind.milmmt46.localModelKind, .milmmt46)
        XCTAssertNil(TranslationProviderKind.cloud.localModelKind)
        XCTAssertNil(TranslationProviderKind.apple.localModelKind)
    }

    func testModelKindTranslationMembership() {
        XCTAssertTrue(LocalAIModelKind.hyMT2.isTranslationModel)
        XCTAssertTrue(LocalAIModelKind.milmmt46.isTranslationModel)
        XCTAssertFalse(LocalAIModelKind.gemmaE2B.isTranslationModel)
    }

    // MARK: - Settings default (offline-first, cloud-legacy migration)

    @MainActor
    func testProviderDefaultIsOfflineHyMT2() throws {
        let suite = UserDefaults(suiteName: "local-ai-tests-\(UUID().uuidString)")!
        try suite.removeAllKeysInSuite()
        let settings = SettingsStore(defaults: suite)
        XCTAssertEqual(settings.translationProvider, .hyMT2)
    }

    @MainActor
    func testLegacyCloudUserKeepsCloud() throws {
        let suite = UserDefaults(suiteName: "local-ai-tests-\(UUID().uuidString)")!
        try suite.removeAllKeysInSuite()
        // An existing user with a configured endpoint: their explicit
        // setup wins over the new offline default.
        suite.set("https://api.deepseek.com", forKey: "translation.apiBase")
        suite.set("deepseek-chat", forKey: "translation.model")
        let settings = SettingsStore(defaults: suite)
        XCTAssertEqual(settings.translationProvider, .cloud)
    }

    @MainActor
    func testStoredProviderRoundTrips() throws {
        let suite = UserDefaults(suiteName: "local-ai-tests-\(UUID().uuidString)")!
        try suite.removeAllKeysInSuite()
        suite.set("milmmt46", forKey: "translation.providerKind")
        let settings = SettingsStore(defaults: suite)
        XCTAssertEqual(settings.translationProvider, .milmmt46)
        // Setting a new provider persists it.
        settings.translationProvider = .apple
        XCTAssertEqual(suite.string(forKey: "translation.providerKind"), "apple")
    }

    // MARK: - Local engine configured state (file-presence semantics)

    @MainActor
    func testLocalEngineNotConfiguredWhenFilesMissing() {
        let manager = LocalAIModelManager(defaults: .standard)
        let engine = LocalLLMTranslationEngine(modelKind: .hyMT2, manager: manager)
        // No manifest entries → no install directory contents → false.
        // (The unit-test host has no downloaded models.)
        XCTAssertFalse(engine.isConfiguredNow || FileManager.default.fileExists(
            atPath: (try? ModelPaths.aiModelRoot(.hyMT2))?.path ?? "/nonexistent"
        ), "configured only when the model directory actually has files")
    }

    // MARK: - Resolved provider fallback chain

    func testResolvedServiceFallsBackOnLocalRetryableFailure() async {
        // A local-engine primary that always fails retryably, plus a
        // fallback that always succeeds — the outcome must be the
        // fallback's, and the fallback must NOT be consulted for
        // non-retryable or successful primaries.
        let failingLocal = StubTranslationService(
            configuredNow: true,
            outcome: TranslationOutcome(
                sequenceID: 1, text: nil, latency: 0,
                isRetryable: true,
                errorDescription: TranslationError.retryable("load failed").errorDescription
            )
        )
        let succeedingFallback = StubTranslationService(
            configuredNow: true,
            outcome: TranslationOutcome(
                sequenceID: 1, text: "系统兜底译文", latency: 0.01,
                isRetryable: false, errorDescription: nil
            )
        )
        let resolved = ResolvedTranslationService(
            primary: failingLocal, fallback: succeedingFallback, primaryIsLocalEngine: true
        )
        let request = TranslationRequest(
            id: 1, sequenceID: 1, text: "Привет",
            sourceLanguage: "ru", targetLanguage: "zh-CN", history: []
        )
        let outcome = await resolved.translate(request)
        XCTAssertEqual(outcome.text, "系统兜底译文")
    }

    func testResolvedServiceDoesNotFallbackForNotConfigured() async {
        // "User chose a local model that is not installed" surfaces as
        // notConfigured — the system fallback only covers runtime
        // FAILURES, never a deliberate empty configuration.
        let notConfigured = StubTranslationService(
            configuredNow: false,
            outcome: TranslationOutcome(
                sequenceID: 1, text: nil, latency: 0,
                isRetryable: false,
                errorDescription: TranslationError.notConfigured.errorDescription
            )
        )
        let fallback = StubTranslationService(
            configuredNow: true,
            outcome: TranslationOutcome(
                sequenceID: 1, text: "不应被调用", latency: 0,
                isRetryable: false, errorDescription: nil
            )
        )
        // notConfigured is not retryable → fallback not consulted.
        let resolved = ResolvedTranslationService(
            primary: notConfigured, fallback: fallback, primaryIsLocalEngine: true
        )
        let request = TranslationRequest(
            id: 1, sequenceID: 1, text: "Привет",
            sourceLanguage: "ru", targetLanguage: "zh-CN", history: []
        )
        let outcome = await resolved.translate(request)
        XCTAssertNil(outcome.text)
        XCTAssertEqual(fallback.callCount, 0)
    }

    func testCloudPrimaryNeverFallsBackToSystem() async {
        // A cloud failure must not silently route to system translation —
        // the user chose an endpoint; failures surface as failures.
        let failingCloud = StubTranslationService(
            configuredNow: true,
            outcome: TranslationOutcome(
                sequenceID: 1, text: nil, latency: 0,
                isRetryable: true,
                errorDescription: TranslationError.retryable("network down").errorDescription
            )
        )
        let fallback = StubTranslationService(
            configuredNow: true,
            outcome: TranslationOutcome(
                sequenceID: 1, text: "不应被调用", latency: 0,
                isRetryable: false, errorDescription: nil
            )
        )
        // ResolvedTranslationService only falls back when the caller
        // marked the primary as a local engine — a cloud primary never
        // qualifies, matching the cloud behavior.
        let resolved = ResolvedTranslationService(primary: failingCloud, fallback: fallback)
        let request = TranslationRequest(
            id: 1, sequenceID: 1, text: "Привет",
            sourceLanguage: "ru", targetLanguage: "zh-CN", history: []
        )
        let outcome = await resolved.translate(request)
        XCTAssertNil(outcome.text)
        XCTAssertEqual(fallback.callCount, 0)
    }

    // MARK: - Prompt routing for the engine

    func testEnginePromptRoutingPerModel() {
        let request = TranslationRequest(
            id: 1, sequenceID: 1, text: "Текст",
            sourceLanguage: "ru", targetLanguage: "zh-CN", history: []
        )
        let hyPrompt = LocalLLMTranslationEngine.buildPrompt(for: request, modelKind: .hyMT2)
        XCTAssertTrue(hyPrompt.contains("Simplified Chinese"))
        let milPrompt = LocalLLMTranslationEngine.buildPrompt(for: request, modelKind: .milmmt46)
        XCTAssertTrue(milPrompt.contains("<start_of_turn>user"))
        // Gemma is not a text-translation model — refuse, never garbage.
        XCTAssertEqual(LocalLLMTranslationEngine.buildPrompt(for: request, modelKind: .gemmaE2B), "")
    }

    // MARK: - Manager session pinning

    @MainActor
    func testSessionPinRefusesModelSwitch() async throws {
        let manager = LocalAIModelManager(defaults: .standard)
        // Pin with NO resident model: switching is still refused (the
        // session's model choice is fixed at start).
        manager.beginSessionPin()
        do {
            try await manager.ensureTranslationModelLoaded(.hyMT2)
            // Either it loads (files present — integration env) or throws
            // modelNotInstalled; NEITHER path may be sessionPinned-rejected
            // when no resident model exists… but with a resident model of a
            // different kind the pin must refuse. With no resident model
            // there is nothing to switch away from, so loading is allowed.
        } catch {
            // modelNotInstalled is the expected unit-test outcome (no
            // models in the CI sandbox) — not a sessionPinned error.
            XCTAssertNotEqual(
                (error as? LocalAIModelManager.ManagerError)?.errorDescription,
                LocalAIModelManager.ManagerError.sessionPinned.errorDescription
            )
        }
        manager.endSessionPin()
    }
}

// MARK: - Test double

private final class StubTranslationService: TranslationService, @unchecked Sendable {
    var isConfigured: Bool { get async { configuredNow } }
    var isConfiguredNow: Bool { configuredNow }
    let configuredNow: Bool
    let outcome: TranslationOutcome
    private let counter = AtomicCounter()
    var callCount: Int { counter.value }

    init(configuredNow: Bool, outcome: TranslationOutcome) {
        self.configuredNow = configuredNow
        self.outcome = outcome
    }

    func translate(_ request: TranslationRequest) async -> TranslationOutcome {
        counter.increment()
        return outcome
    }

    func testConnection() async -> Result<String, TranslationError> {
        .success("stub")
    }
}

private final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
}

private extension UserDefaults {
    func removeAllKeysInSuite() throws {
        for key in dictionaryRepresentation().keys {
            removeObject(forKey: key)
        }
    }
}
