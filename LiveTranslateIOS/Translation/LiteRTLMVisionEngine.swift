import Foundation
import OSLog
import CLiteRTLM

/// On-device image-understanding engine: Google's LiteRT-LM runtime (the
/// `CLiteRTLM` module from `ThirdParty/LiteRTLM.xcframework`) running the
/// Gemma 4 E2B `.litertlm` model.
///
/// Lifecycle contract (the "安全、清楚的资源生命周期" between the image
/// model and the live-classroom translation model):
/// - The engine loads ONLY while image requests are in flight; `unload()`
///   is called right after the request completes (or fails). Loading is
///   serialized through the manager; a translation model being loaded
///   takes precedence (translation is the real-time path).
/// - All C calls run on one serial dispatch queue (the C API is not
///   documented thread-safe); the class is @unchecked Sendable because
///   the opaque pointers are only touched on that queue.
///
/// The upstream C API surface used here (engine.h):
///   litert_lm_engine_settings_create / _set_max_num_tokens /
///   _set_cache_dir / _delete, litert_lm_engine_create / _delete,
///   litert_lm_conversation_create / _delete,
///   litert_lm_conversation_send_message,
///   litert_lm_json_response_get_string / _delete.
final class LiteRTLMVisionEngine: @unchecked Sendable {
    static let logger = Logger(subsystem: "com.livestranslate.ios", category: "litert-lm")

    enum EngineError: LocalizedError {
        case modelNotFound(String)
        case engineCreationFailed
        case inferenceFailed(String)
        case notLoaded
        case unloadFailed

        var errorDescription: String? {
            switch self {
            case .modelNotFound(let path):
                return String(localized: "模型文件不存在：\(path)")
            case .engineCreationFailed:
                return String(localized: "图片理解引擎初始化失败。")
            case .inferenceFailed(let underlying):
                return String(localized: "图片理解推理失败：\(underlying)")
            case .notLoaded:
                return String(localized: "图片理解模型尚未加载。")
            case .unloadFailed:
                return String(localized: "图片理解模型释放失败。")
            }
        }
    }

    private let queue = DispatchQueue(label: "com.livetranslate.ios.litertlm", qos: .userInitiated)
    private var engine: OpaquePointer?
    private var loadedModelPath: String?

    /// 4 k context: classroom photo prompts + answer comfortably fit;
    /// larger caches only cost memory on 2–3 GB devices.
    private static let maxTokens: Int32 = 4096

    deinit {
        // Best-effort synchronous teardown on the queue (blocking is
        // acceptable in deinit — the engine is being discarded).
        if let engine { queue.sync { litert_lm_engine_delete(engine) } }
    }

    private var inFlightRequests = 0
    private let stateLock = NSLock()

    var isLoaded: Bool { engine != nil }

    /// Reference-counted load: the FIRST concurrent request loads the
    /// model; overlapping requests share it; the LAST release unloads.
    /// Without this, back-to-back attachment analyses would re-load the
    /// 2.59 GB model per image, and concurrent requests would unload the
    /// model out from under each other.
    func acquireLoad(modelPath: String) throws {
        stateLock.lock()
        inFlightRequests += 1
        let needsLoad = engine == nil || loadedModelPath != modelPath
        stateLock.unlock()
        guard needsLoad else { return }
        do {
            try load(modelPath: modelPath)
        } catch {
            // Any load failure must roll the count back — otherwise a
            // failed acquire would pin the model (or a stale count would
            // unload it under a live request later).
            stateLock.lock()
            inFlightRequests = max(0, inFlightRequests - 1)
            stateLock.unlock()
            throw error
        }
    }

    /// Release one acquire. Unloads only when no requests remain in
    /// flight — the model never stays resident after the last request.
    func release() {
        stateLock.lock()
        inFlightRequests = max(0, inFlightRequests - 1)
        let shouldUnload = inFlightRequests == 0
        stateLock.unlock()
        guard shouldUnload else { return }
        try? unload()
    }

    /// Load the `.litertlm` model. A previously loaded model is fully
    /// released first — the engine holds ONE model at a time.
    /// Must be called from a background context (the C create call
    /// performs graph compilation and can take seconds).
    func load(modelPath: String) throws {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw EngineError.modelNotFound(modelPath)
        }
        try unload()

        try queue.sync {
            litert_lm_set_min_log_level(1)
            guard let settings = litert_lm_engine_settings_create(
                modelPath, "gpu", "gpu", "gpu"
            ) else {
                throw EngineError.engineCreationFailed
            }
            litert_lm_engine_settings_set_max_num_tokens(settings, Self.maxTokens)
            // Cache dir for the runtime's internal KV/prefix cache.
            let cacheDir = FileManager.default.urls(
                for: .cachesDirectory, in: .userDomainMask
            ).first!.appendingPathComponent("litertlm_cache").path
            try? FileManager.default.createDirectory(
                atPath: cacheDir, withIntermediateDirectories: true
            )
            litert_lm_engine_settings_set_cache_dir(settings, cacheDir)
            guard let created = litert_lm_engine_create(settings) else {
                litert_lm_engine_settings_delete(settings)
                throw EngineError.engineCreationFailed
            }
            litert_lm_engine_settings_delete(settings)
            self.engine = created
            self.loadedModelPath = modelPath
        }
        Self.logger.info("LiteRT-LM model loaded: \(URL(fileURLWithPath: modelPath).lastPathComponent, privacy: .public)")
    }

    /// Fully release the engine + model.
    func unload() throws {
        guard let engine else {
            loadedModelPath = nil
            return
        }
        queue.sync {
            litert_lm_engine_delete(engine)
        }
        self.engine = nil
        loadedModelPath = nil
    }

    // MARK: - Inference

    /// One multimodal (image+text) completion. `imagePaths` are JPEG
    /// files on disk (the C API takes paths, not bytes); the caller owns
    /// their lifecycle — this method only reads them during the call.
    func complete(prompt: String, imagePaths: [String]) throws -> String {
        guard engine != nil else { throw EngineError.notLoaded }
        // OpenAI-conversation-style JSON content parts (the runtime's
        // documented message shape): image parts then the text part.
        var content: [[String: Any]] = imagePaths.map { ["type": "image", "path": $0] }
        content.append(["type": "text", "text": prompt])
        let message: [String: Any] = ["role": "user", "content": content]
        guard let messageData = try? JSONSerialization.data(withJSONObject: message),
              let messageJSON = String(data: messageData, encoding: .utf8) else {
            throw EngineError.inferenceFailed("message JSON encoding")
        }

        var resultJSON: String?
        try queue.sync {
            guard let conversation = litert_lm_conversation_create(engine, nil) else {
                throw EngineError.inferenceFailed("conversation create")
            }
            defer { litert_lm_conversation_delete(conversation) }
            guard let response = litert_lm_conversation_send_message(
                conversation, messageJSON, nil
            ) else {
                throw EngineError.inferenceFailed("send message")
            }
            defer { litert_lm_json_response_delete(response) }
            if let raw = litert_lm_json_response_get_string(response) {
                resultJSON = String(cString: raw)
            }
        }
        guard let resultJSON else {
            throw EngineError.inferenceFailed("empty response")
        }
        return Self.extractText(fromConversationResponse: resultJSON)
    }

    /// Parse the runtime's conversation response JSON
    /// (`{"response": "…", "benchmark": …}` shape) into plain text.
    static func extractText(fromConversationResponse json: String) -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return json }
        if let text = object["response"] as? String { return text }
        if let text = object["text"] as? String { return text }
        if let content = object["content"] as? String { return content }
        return json
    }
}
