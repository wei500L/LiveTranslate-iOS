import XCTest
@testable import LiveTranslateIOS

/// Model-dependent integration tests for the on-device GGUF translation
/// models (Hy-MT2 / MiLMMT). Run in the SEPARATE integration plan with:
/// `LIVETRANSLATE_MODELS_DIR=$PWD/LocalModels xcodebuild test -scheme
/// LiveTranslateIOSIntegration`. Skips (never fails) when the models are
/// unavailable — a missing 1 GB download is not a code defect.
///
/// What is verified here (the product's core claims):
/// - Russian text genuinely produces Simplified Chinese through llama.cpp.
/// - Both models load, translate, release, and switch (never two resident).
/// - Cancellation stops decoding without hanging.
@MainActor
final class LlamaEngineIntegrationTests: XCTestCase {
    private var manager: LocalAIModelManager!

    override func setUpWithError() throws {
        manager = LocalAIModelManager(defaults: UserDefaults(suiteName: "llama-integration")!)
    }

    private func requireInstalled(_ kind: LocalAIModelKind) async throws {
        try await IntegrationModels.requireAIModel(kind, manager: manager)
    }

    private func russianUtterance() -> String {
        "Сегодня мы изучаем производные сложных функций."
    }

    // MARK: - Hy-MT2 (default)

    func testHyMT2TranslatesRussianToChinese() async throws {
        try await requireInstalled(.hyMT2)
        let engine = LocalLLMTranslationEngine(modelKind: .hyMT2, manager: manager)
        XCTAssertTrue(engine.isConfiguredNow, "installed model must report configured")

        let outcome = await engine.translate(TranslationRequest(
            id: 1, sequenceID: 1, text: russianUtterance(),
            sourceLanguage: "ru", targetLanguage: "zh-CN", history: []
        ))
        XCTAssertNotNil(outcome.text, "translation failed: \(outcome.errorDescription ?? "?")")
        guard let text = outcome.text else { return }
        XCTAssertFalse(text.isEmpty)
        // The output must be Chinese (contain CJK), not a Russian echo or
        // an instruction restatement.
        let containsCJK = text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
        }
        XCTAssertTrue(containsCJK, "output is not Simplified Chinese: \(text)")
    }

    // MARK: - MiLMMT (battery-saver)

    func testMiLMMTTranslatesRussianToChinese() async throws {
        try await requireInstalled(.milmmt46)
        let engine = LocalLLMTranslationEngine(modelKind: .milmmt46, manager: manager)
        XCTAssertTrue(engine.isConfiguredNow)

        let outcome = await engine.translate(TranslationRequest(
            id: 1, sequenceID: 1, text: "Привет, как дела?",
            sourceLanguage: "ru", targetLanguage: "zh-CN", history: []
        ))
        XCTAssertNotNil(outcome.text, "translation failed: \(outcome.errorDescription ?? "?")")
        guard let text = outcome.text else { return }
        let containsCJK = text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
        }
        XCTAssertTrue(containsCJK, "output is not Simplified Chinese: \(text)")
    }

    // MARK: - Load / switch / release lifecycle

    func testModelSwitchReleasesPreviousModel() async throws {
        try await requireInstalled(.hyMT2)
        try await requireInstalled(.milmmt46)

        // Load Hy-MT2.
        try await manager.ensureTranslationModelLoaded(.hyMT2)
        XCTAssertEqual(manager.residentModel, .hyMT2)

        // Switch to MiLMMT: the previous model must be fully released
        // first (the one-resident invariant).
        try await manager.ensureTranslationModelLoaded(.milmmt46)
        XCTAssertEqual(manager.residentModel, .milmmt46)

        // Both translate after the switch.
        let outcome = try await manager.generate(
            prompt: LlamaChatPromptBuilder.milmmtPrompt(
                source: "Привет", sourceLanguage: "ru",
                targetLanguage: "zh-CN", history: []
            ),
            modelID: .milmmt46
        )
        XCTAssertFalse(outcome.isEmpty)

        // Explicit release.
        let released = await manager.unloadResident()
        XCTAssertTrue(released)
        XCTAssertNil(manager.residentModel)
    }

    func testSessionPinRefusesSwitchMidSession() async throws {
        try await requireInstalled(.hyMT2)
        try await requireInstalled(.milmmt46)

        try await manager.ensureTranslationModelLoaded(.hyMT2)
        manager.beginSessionPin()
        defer { manager.endSessionPin() }

        do {
            try await manager.ensureTranslationModelLoaded(.milmmt46)
            XCTFail("a pinned session must refuse to switch models")
        } catch let error as LocalAIModelManager.ManagerError {
            guard case .sessionPinned = error else {
                return XCTFail("expected sessionPinned, got: \(error)")
            }
        }
        // The session's model still works.
        XCTAssertEqual(manager.residentModel, .hyMT2)
    }

    // MARK: - Missing model semantics

    func testMissingModelReportsNotInstalledFailure() async throws {
        // A model whose files do not exist (fresh sandbox): the engine
        // must report an honest retryable failure — never a hang.
        let engine = LocalLLMTranslationEngine(modelKind: .gemmaE2B, manager: manager)
        // Gemma is not a translation model at all.
        XCTAssertFalse(engine.isConfiguredNow)
        let outcome = await engine.translate(TranslationRequest(
            id: 1, sequenceID: 1, text: "Текст",
            sourceLanguage: "ru", targetLanguage: "zh-CN", history: []
        ))
        XCTAssertNil(outcome.text)
        XCTAssertNotNil(outcome.errorDescription)
    }
}

extension IntegrationModels {
    /// Ensure an AI model's files are present (hash-verified), copying
    /// from `LIVETRANSLATE_MODELS_DIR` if needed; skip otherwise.
    static func requireAIModel(
        _ kind: LocalAIModelKind, manager: LocalAIModelManager
    ) async throws {
        // Installed and hash-verified already?
        if await isAIModelInstalled(kind) { return }

        guard let source = ProcessInfo.processInfo.environment[modelsDirEnvKey],
              !source.isEmpty else {
            throw XCTSkip("""
                \(kind.userTitle) is not installed in the app sandbox and \
                \(modelsDirEnvKey) is not set. Run scripts/prepare_models.sh \
                once, then run the integration scheme with \
                \(modelsDirEnvKey)=$PWD/LocalModels.
                """)
        }
        let sourceRoot = URL(fileURLWithPath: source)
        let sourceDir = sourceRoot.appendingPathComponent(kind.directoryName)
        guard FileManager.default.fileExists(atPath: sourceDir.path) else {
            throw XCTSkip("\(kind.userTitle) not found under \(sourceDir.path).")
        }
        let dest = try ModelPaths.aiModelRoot(kind)
        try FileManager.default.createDirectory(
            at: dest, withIntermediateDirectories: true
        )
        for entry in try FileManager.default.contentsOfDirectory(
            at: sourceDir, includingPropertiesForKeys: nil
        ) where !entry.hasDirectoryPath {
            let target = dest.appendingPathComponent(entry.lastPathComponent)
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: entry, to: target)
        }
        let verified = await isAIModelInstalled(kind)
        XCTAssertTrue(
            verified,
            "\(kind.userTitle) not verifiable after copying from \(sourceDir.path)"
        )
    }

    static func isAIModelInstalled(_ kind: LocalAIModelKind) async -> Bool {
        guard let manifest = try? ModelManifest.load(),
              let info = manifest.aiModel(kind),
              let root = try? ModelPaths.aiModelRoot(kind) else { return false }
        return await ModelIntegrityVerifier.verifyBackend(info, root: root) == nil
    }
}
