import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

/// On-device image-understanding service: the Gemma 4 E2B `.litertlm`
/// model through `LiteRTLMVisionEngine`, conforming to the SAME
/// `AttachmentAnalysisModelService` protocol as the cloud multimodal
/// service — image understanding, PDF-page understanding and visual Q&A
/// call sites work unchanged, offline.
///
/// Resource lifecycle (the contract between this and the live-classroom
/// translation model):
/// - The Gemma model loads on the FIRST request and unloads right after
///   the request completes — it never stays resident. Back-to-back
///   requests share the load via a reference-counted hold; the last
///   release unloads.
/// - Loading is serialized through `LocalAIModelManager` (which refuses
///   to start a Gemma load while a GGUF translation model load is in
///   flight — the classroom path wins contention).
/// - The translation model stays resident across a classroom session;
///   Gemma is transient by design. Both never exceed their own memory
///   budgets at the same time for more than one request.
struct LocalVisionModelService: AttachmentAnalysisModelService {
    static let logger = Logger(subsystem: "com.livetranslate.ios", category: "local-vision")

    /// Shared engine instance per service build (the manager's single
    /// LiteRT-LM engine; loading is exclusive).
    private let engine = LiteRTLMVisionEngine()
    private let manager: LocalAIModelManager

    init(manager: LocalAIModelManager) {
        self.manager = manager
    }

    var isConfiguredNow: Bool {
        // Same synchronous presence check as the local translator.
        let installRoot = try? ModelPaths.aiModelRoot(.gemmaE2B)
        guard let installRoot else { return false }
        let contents = try? FileManager.default.contentsOfDirectory(
            atPath: installRoot.path
        )
        return !(contents ?? []).isEmpty
    }

    var modelName: String? { "gemma-4-E2B-it (on-device)" }

    // MARK: - AttachmentAnalysisModelService

    func complete(
        systemPrompt: String,
        userPrompt: String,
        imageData: Data,
        imageMIME: String,
        maxTokens: Int
    ) async throws -> String {
        try await complete(
            systemPrompt: systemPrompt, userPrompt: userPrompt,
            images: [ModelImagePayload(data: imageData, mimeType: imageMIME)],
            maxTokens: maxTokens
        )
    }

    func complete(
        systemPrompt: String,
        userPrompt: String,
        images: [ModelImagePayload],
        maxTokens: Int
    ) async throws -> String {
        guard isConfiguredNow else {
            throw TranslationError.notConfigured
        }
        // Resolve the model file path on the main actor (the manager owns
        // install knowledge), then run the engine off-main.
        let modelPath = try await MainActor.run {
            try LocalVisionModelService.gemmaModelPath(manager: manager)
        }

        // Prompt: Gemma has no separate system role in the conversation
        // API; the system text rides as a leading user instruction.
        let prompt = systemPrompt.isEmpty
            ? userPrompt
            : "\(systemPrompt)\n\n\(userPrompt)"

        // Stage images as temp JPEG files (the C API takes paths). The
        // caller's bytes are re-encoded when not already JPEG.
        let staged = try images.map { try Self.stageImage($0) }
        defer { staged.forEach { try? FileManager.default.removeItem(at: $0) } }

        // Inference runs OFF the main actor (the engine serializes C calls
        // on its own queue). Record the AI activity ledger entry.
        let activityChars = systemPrompt.count + userPrompt.count
        let imageCount = images.count
        do {
            try engine.acquireLoad(modelPath: modelPath)
            defer { engine.release() }
            let text = try engine.complete(
                prompt: prompt, imagePaths: staged.map(\.path)
            )
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw TranslationError.emptyResponse }
            await AIActivityLog.recordTransport(
                characterCount: activityChars, imageCount: imageCount,
                outcome: .success, host: "on-device"
            )
            return trimmed
        } catch is CancellationError {
            await AIActivityLog.recordTransport(
                characterCount: activityChars, imageCount: imageCount,
                outcome: .cancelled, host: "on-device"
            )
            throw CancellationError()
        } catch {
            await AIActivityLog.recordTransport(
                characterCount: activityChars, imageCount: imageCount,
                outcome: .failed, host: "on-device"
            )
            throw error
        }
    }

    // MARK: - Internals

    /// Resolve the installed Gemma model file path (main-actor: the
    /// manager owns the manifest).
    @MainActor
    private static func gemmaModelPath(manager: LocalAIModelManager) throws -> String {
        guard let info = manager.modelInfo(.gemmaE2B) else {
            throw LocalAIModelManager.ManagerError.modelNotInstalled(.gemmaE2B)
        }
        let root = try ModelPaths.aiModelRoot(.gemmaE2B)
        let file = root.appendingPathComponent(info.files[0].path)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw LocalAIModelManager.ManagerError.modelNotInstalled(.gemmaE2B)
        }
        return file.path
    }

    /// Write one image payload to a temp JPEG file for the C API.
    private static func stageImage(_ payload: ModelImagePayload) throws -> URL {
        let data: Data
        if payload.mimeType == "image/jpeg" {
            data = payload.data
        } else {
            // Re-encode through ImageIO (any source format → JPEG).
            guard let source = CGImageSourceCreateWithData(
                payload.data as CFData, nil
            ), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw TranslationError.fatal("图片解码失败。")
            }
            let outURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("litertlm-\(UUID().uuidString).jpg")
            guard let dest = CGImageDestinationCreateWithURL(
                outURL as CFURL, "public.jpeg" as CFString, 1, nil
            ) else {
                throw TranslationError.fatal("图片暂存失败。")
            }
            CGImageDestinationAddImage(dest, image, nil)
            guard CGImageDestinationFinalize(dest) else {
                throw TranslationError.fatal("图片暂存失败。")
            }
            return outURL
        }
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("litertlm-\(UUID().uuidString).jpg")
        try data.write(to: outURL)
        return outURL
    }
}
