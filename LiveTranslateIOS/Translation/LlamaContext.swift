import Accelerate
import Foundation
import OSLog
import llama

/// Minimal Swift surface over the llama.cpp C API (the `llama` module from
/// `ThirdParty/llama.xcframework`).
///
/// Design mirrors the sherpa-onnx engine: ONE inference context at a time,
/// all C calls serialized inside an actor, explicit `unload` so a switch
/// fully releases the previous model's memory before the next loads (no
/// two GGUF models are ever resident together), and load-once inference
/// afterwards — the model is never re-loaded per segment.
///
/// Sampling: greedy decode with the model card's repetition penalty — the
/// classroom translation task wants determinism, and the 1 B/1.8 B models
/// are fast enough that beam search is not worth the latency.
///
/// Cancellation is cooperative via the injected `isCancelled` closure:
/// a cancelled generation stops decoding at the next token and returns
/// the partial text (partial output beats a hang; the coordinator's stop
/// path drains workers that check cancellation).
actor LlamaContext {
    static let logger = Logger(subsystem: "com.livetranslate.ios", category: "llama")

    enum ContextError: LocalizedError {
        case modelMissing(String)
        case loadFailed(underlying: String)
        case notLoaded
        case contextFull
        case backendFailure(underlying: String)

        var errorDescription: String? {
            switch self {
            case .modelMissing(let path):
                return String(localized: "模型文件不存在：\(path)")
            case .loadFailed(let underlying):
                return String(localized: "本地模型加载失败：\(underlying)")
            case .notLoaded:
                return String(localized: "本地模型尚未加载。")
            case .contextFull:
                return String(localized: "本地模型上下文已满。")
            case .backendFailure(let underlying):
                return String(localized: "本地推理失败：\(underlying)")
            }
        }
    }

    /// Reasonable KV-cache budget for classroom utterances + context:
    /// prompt ≤ ~1 k tokens, answer ≤ 256 → 2048 with headroom. Gemma-class
    /// 1 B models keep the cache small; Hy-MT2's 1.8 B Q4_K_M stays well
    /// inside 2 GB devices with this setting.
    private static let contextLength: UInt32 = 2048
    /// Hard decode cap: one utterance translation never needs more; this
    /// is a runaway-generation guard, not a quality knob.
    private static let maxGenerationTokens = 256
    /// Hy-MT2 model card sampling recipe: repetition penalty 1.05.
    private static let repetitionPenalty: Float = 1.05

    // nonisolated(unsafe): only mutated/read on the actor, but deinit
    // (nonisolated) must free them without an isolation hop — the actor
    // is already gone and nothing else can race with a deinit.
    private nonisolated(unsafe) var model: OpaquePointer?
    private nonisolated(unsafe) var context: OpaquePointer?
    private var vocab: OpaquePointer?
    /// Currently-loaded model identity (manifest model key) — guards
    /// against using one model's context for another model's request.
    private(set) var loadedModelID: String?
    private(set) var loadedModelPath: String?

    private var loadDuration: TimeInterval = 0

    init() {}

    deinit {
        // C ownership: free context before model (see the nonisolated(unsafe)
        // note on the stored properties).
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
    }

    var isLoaded: Bool { model != nil && context != nil }
    var residentModelID: String? { loadedModelID }
    var lastLoadDuration: TimeInterval { loadDuration }

    /// Load a GGUF model file. A previous resident model is fully released
    /// first — never two models in memory at once.
    func load(modelPath: String, modelID: String) throws {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw ContextError.modelMissing(modelPath)
        }
        if isLoaded {
            unload()
        }

        var modelParams = llama_model_default_params()
        // Metal offload for every layer on device (the xcframework embeds
        // the Metal shaders). The iOS SIMULATOR is the exception: ggml's
        // Metal kernels there can silently produce zeroed logits (verified
        // — identical code returns correct logits with the CPU backend on
        // macOS Metal), so the simulator pins CPU for honest results.
        #if targetEnvironment(simulator)
        modelParams.n_gpu_layers = 0
        #else
        modelParams.n_gpu_layers = 99
        #endif

        let started = Date()
        guard let loaded = llama_model_load_from_file(modelPath, modelParams) else {
            throw ContextError.loadFailed(underlying: "llama_model_load_from_file returned nil")
        }
        model = loaded
        vocab = llama_model_get_vocab(loaded)

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = Self.contextLength
        contextParams.n_batch = 512
        contextParams.n_threads = 4
        contextParams.n_threads_batch = 4

        guard let ctx = llama_init_from_model(loaded, contextParams) else {
            llama_model_free(loaded)
            model = nil
            vocab = nil
            throw ContextError.loadFailed(underlying: "llama_init_from_model returned nil")
        }
        context = ctx
        loadedModelID = modelID
        loadedModelPath = modelPath
        loadDuration = Date().timeIntervalSince(started)
        Self.logger.info("llama.cpp model \(modelID, privacy: .public) loaded in \(self.loadDuration, privacy: .public)s")
    }

    /// Release the model + context + KV cache completely.
    func unload() {
        guard isLoaded else { return }
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        context = nil
        model = nil
        vocab = nil
        loadedModelID = nil
        loadedModelPath = nil
        Self.logger.info("llama.cpp model unloaded")
    }

    // MARK: - Generation

    /// Generate a completion for a fully-templated prompt (chat markers
    /// included). Greedy decode with the model card's repetition penalty.
    /// Returns the decoded text (possibly partial when `isCancelled`
    /// flips mid-decode).
    func complete(prompt: String, isCancelled: @Sendable () -> Bool) throws -> String {
        guard let context, let vocab else {
            throw ContextError.notLoaded
        }

        // Tokenize flags (both models verified against their cards):
        // add_special=false — the hunyuan template carries its own BOS
        // marker in the prompt text, and MiLMMT's card mandates
        // add_special_tokens=False; parse_special=true — the hunyuan
        // turn markers must become single special tokens, not literal
        // text. Sizing contract (llama.h): with a null buffer the call
        // returns -(required token count).
        let promptBytes = Array(prompt.utf8)
        let sizing = llama_tokenize(
            vocab, promptBytes, Int32(promptBytes.count), nil, 0, false, true
        )
        // >0 would mean tokens were written into a null buffer (impossible
        // without memory corruption); 0 = empty prompt.
        guard sizing <= 0 else {
            throw ContextError.backendFailure(underlying: "llama_tokenize sizing returned \(sizing)")
        }
        let tokenCount = Int(-sizing)
        guard tokenCount > 0 else { return "" }
        var tokens = [llama_token](repeating: 0, count: tokenCount)
        let written = llama_tokenize(
            vocab, promptBytes, Int32(promptBytes.count), &tokens, Int32(tokenCount), false, true
        )
        guard written == Int32(tokenCount) else {
            throw ContextError.backendFailure(underlying: "llama_tokenize wrote \(written) of \(tokenCount)")
        }
        guard tokenCount < Int(Self.contextLength) - Self.maxGenerationTokens else {
            throw ContextError.contextFull
        }

        // Reset state: one independent completion per request (each
        // utterance is standalone — no cross-request KV reuse).
        llama_memory_seq_rm(llama_get_memory(context), 0, -1, -1)

        var generated: [llama_token] = []
        // Sequence position bookkeeping: the KV cache is position-based —
        // every token must be eval'd at ITS OWN position (prompt at
        // 0..<n, each generated token at n, n+1, …). All-zero positions
        // are an invalid batch (llama_decode rc=-1).
        var nPast = 0

        var batch = llama_batch_init(Int32(tokens.count), 0, 1)
        defer { llama_batch_free(batch) }

        // Prompt eval.
        try Self.eval(tokens: tokens, startPos: 0, context: context, batch: &batch)
        nPast = tokens.count
        // `llama_get_logits_ith` indexes into the LAST decode's batch
        // (i ∈ [0, batch.n_tokens)) — not the absolute sequence position.
        var lastBatchCount = tokens.count

        // EOS/EOT for stop detection (both checked: models differ).
        let eos = llama_vocab_eos(vocab)
        let eot = llama_vocab_eot(vocab)

        // Greedy decode loop.
        for _ in 0..<Self.maxGenerationTokens {
            if isCancelled() { break }
            guard let logitsPtr = llama_get_logits_ith(context, Int32(lastBatchCount - 1)) else {
                throw ContextError.backendFailure(underlying: "llama_get_logits_ith returned nil")
            }
            let nVocab = Int(llama_vocab_n_tokens(vocab))
            var bestToken = llama_token(0)
            var bestScore = -Float.infinity
            // Repetition penalty (Hy-MT2 card: 1.05) over prompt+generated
            // tokens, applied the llama.cpp way: positive logits divided
            // by the penalty. The argmax over ~150k vocab entries runs on
            // a scratch buffer via vDSP (one divide + one max index) —
            // pure-Swift per-token loops would burn the token budget.
            var seen = Set(tokens)
            for t in generated { seen.insert(t) }
            if seen.isEmpty {
                // Fast path: plain argmax over the logits.
                var idx = vDSP_Length(0)
                vDSP_maxvi(logitsPtr, 1, &bestScore, &idx, vDSP_Length(nVocab))
                bestToken = llama_token(idx)
            } else {
                var logitsBuffer = [Float](repeating: 0, count: nVocab)
                for i in 0..<nVocab {
                    logitsBuffer[i] = logitsPtr[i]
                }
                for token in seen where Int(token) < nVocab {
                    let i = Int(token)
                    if logitsBuffer[i] > 0 {
                        logitsBuffer[i] /= Self.repetitionPenalty
                    }
                }
                var idx = vDSP_Length(0)
                vDSP_maxvi(&logitsBuffer, 1, &bestScore, &idx, vDSP_Length(nVocab))
                bestToken = llama_token(idx)
            }
            if bestToken == eos || bestToken == eot { break }
            generated.append(bestToken)

            // Feed the chosen token back at its own position.
            try Self.eval(
                tokens: [bestToken], startPos: nPast,
                context: context, batch: &batch
            )
            nPast += 1
            lastBatchCount = 1
            if nPast >= Int(Self.contextLength) {
                break
            }
        }

        // Detokenize (UTF-8 aware; handles multi-byte CJK splits).
        var pieces: [UInt8] = []
        pieces.reserveCapacity(generated.count * 4)
        for token in generated {
            var buffer = [CChar](repeating: 0, count: 64)
            let n = llama_token_to_piece(vocab, token, &buffer, 64, 0, false)
            if n > 0 {
                pieces.append(contentsOf: buffer.prefix(Int(n)).map { UInt8(bitPattern: $0) })
            }
        }
        return String(bytes: pieces, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Evaluate a token batch through the context. `startPos` is the
    /// absolute sequence position of the FIRST token; token i sits at
    /// startPos + i (the KV cache is position-keyed).
    private static func eval(
        tokens: [llama_token], startPos: Int,
        context: OpaquePointer, batch: inout llama_batch
    ) throws {
        // Rebuild the batch when the current allocation is too small.
        if batch.n_tokens < Int32(tokens.count) {
            llama_batch_free(batch)
            batch = llama_batch_init(Int32(max(tokens.count, 512)), 0, 1)
        }
        for (i, token) in tokens.enumerated() {
            batch.token[i] = token
            batch.pos[i] = Int32(startPos + i)
            batch.n_seq_id[i] = 1
            batch.seq_id[i]!.pointee = 0
            batch.logits[i] = 0
        }
        // Only the LAST token of the batch needs logits for greedy decode
        // (the caller reads the logits of the final position).
        batch.logits[tokens.count - 1] = 1
        batch.n_tokens = Int32(tokens.count)
        let rc = llama_decode(context, batch)
        guard rc == 0 else {
            throw ContextError.backendFailure(underlying: "llama_decode rc=\(rc)")
        }
    }
}
