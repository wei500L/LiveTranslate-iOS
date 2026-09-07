import XCTest
import UIKit
@testable import LiveTranslateIOS

/// Model-dependent integration test for the on-device image-understanding
/// model (Gemma 4 E2B via LiteRT-LM). Runs in the integration plan with
/// `LIVETRANSLATE_MODELS_DIR=$PWD/LocalModels`; skips when the model is
/// unavailable.
///
/// What is verified: a REAL image (rendered on-device, not pre-extracted
/// text) goes through the LiteRT-LM engine and produces a non-empty
/// description — the load → multimodal inference → release lifecycle
/// works end-to-end.
@MainActor
final class GemmaVisionIntegrationTests: XCTestCase {
    func testGemmaDescribesRealImage() async throws {
        #if targetEnvironment(simulator)
        // The vendored LiteRTLM.xcframework's SIMULATOR slice is a
        // non-functional 38 KB stub (links only libSystem; engine create
        // returns NULL). The device slice carries the real 19.9 MB
        // implementation + Gemma constraint provider — run this test on a
        // physical device.
        throw XCTSkip("LiteRTLM simulator slice is a stub — Gemma vision requires a real device.")
        #else
        let manager = LocalAIModelManager(defaults: .standard)
        try await IntegrationModels.requireAIModel(.gemmaE2B, manager: manager)
        let service = LocalVisionModelService(manager: manager)
        XCTAssertTrue(service.isConfiguredNow, "downloaded Gemma must report configured")

        // Render a real image on-device: a red circle and a blue rectangle
        // on white — distinctive shapes the model can genuinely describe.
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512))
        let image = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
            UIColor.red.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 60, y: 60, width: 200, height: 200))
            UIColor.blue.setFill()
            ctx.cgContext.fill(CGRect(x: 260, y: 260, width: 190, height: 190))
        }
        let jpeg = image.jpegData(compressionQuality: 0.9)
        try XCTSkipUnless(try jpeg != nil, "image rendering unavailable")

        // One vision request: system instruction + user prompt, like the
        // attachment-analysis call sites.
        let answer = try await service.complete(
            systemPrompt: "You describe images accurately and briefly.",
            userPrompt: "Describe what shapes and colors you see in this image, in one or two sentences.",
            images: [ModelImagePayload(data: jpeg!, mimeType: "image/jpeg")],
            maxTokens: 256
        )
        XCTAssertFalse(answer.isEmpty, "vision model returned empty output")
        // The answer must mention at least one shape/color word (English or
        // Chinese — the prompt is English so English is expected).
        let lowered = answer.lowercased()
        let mentions = ["red", "circle", "blue", "rectangle", "square", "红色", "圆形", "蓝色", "矩形", "方形"]
        XCTAssertTrue(
            mentions.contains { lowered.contains($0) },
            "answer does not describe the shapes/colors: \(answer)"
        )
        #endif
    }
}
