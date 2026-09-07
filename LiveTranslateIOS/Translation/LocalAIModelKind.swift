import Foundation

/// The downloadable on-device AI models (distinct from the ASR backends):
/// two offline text-translation GGUF models and one image-understanding
/// LiteRT-LM model. Selection, install state, download and deletion all
/// key off this enum exactly the way ASR backends key off
/// `ASRBackendKind`.
enum LocalAIModelKind: String, CaseIterable, Identifiable, Sendable, Equatable {
    /// Hy-MT2-1.8B Q4_K_M — the DEFAULT Russian→Simplified-Chinese offline
    /// translation model (hunyuan-dense 2B, Apache-2.0, tencent).
    case hyMT2
    /// MiLMMT-46-1B-v1.0 Q4_K_M — the optional battery-saving translation
    /// model (gemma3-1b lineage, Gemma license, xiaomi-research;
    /// mradermacher static quant).
    case milmmt46
    /// Gemma 4 E2B it — the standalone image-understanding model
    /// (LiteRT-LM format, Apache-2.0, litert-community).
    case gemmaE2B

    var id: String { rawValue }

    /// Key in the manifest's `aiModels` dictionary.
    var manifestKey: String {
        switch self {
        case .hyMT2: return "hy-mt2-1.8b-q4km"
        case .milmmt46: return "milmmt-46-1b-q4km"
        case .gemmaE2B: return "gemma-4-e2b-it"
        }
    }

    /// Install directory name under Models/.
    var directoryName: String {
        switch self {
        case .hyMT2: return "hy-mt2-1.8b"
        case .milmmt46: return "milmmt-46-1b"
        case .gemmaE2B: return "gemma-4-e2b"
        }
    }

    /// Whether this model participates in text translation selection.
    var isTranslationModel: Bool {
        switch self {
        case .hyMT2, .milmmt46: return true
        case .gemmaE2B: return false
        }
    }

    /// Non-technical user-facing identity (product naming rule: never leak
    /// quant/technical strings into UI copy).
    var userTitle: String {
        switch self {
        case .hyMT2: return String(localized: "离线翻译 · 标准画质")
        case .milmmt46: return String(localized: "离线翻译 · 省电模式")
        case .gemmaE2B: return String(localized: "图片理解 · 离线")
        }
    }

    var userSubtitle: String {
        switch self {
        case .hyMT2: return String(localized: "俄语 → 简体中文，默认模型，无需网络")
        case .milmmt46: return String(localized: "更小的离线翻译模型，长时间课堂更省电")
        case .gemmaE2B: return String(localized: "课堂照片理解与视觉问答，仅在需要时加载")
        }
    }
}

extension ModelPaths {
    /// Install root for a downloadable AI model:
    /// `Models/<directoryName>/`.
    static func aiModelRoot(_ kind: LocalAIModelKind) throws -> URL {
        try modelsRoot().appendingPathComponent(kind.directoryName, isDirectory: true)
    }
}

extension ModelManifest {
    /// Entry for a downloadable AI model from the manifest's `aiModels`
    /// dictionary (same BackendInfo schema as the ASR backends — pinned
    /// revision, measured SHA256 per file, disk budgets).
    func aiModel(_ kind: LocalAIModelKind) -> ModelManifest.BackendInfo? {
        aiModels?[kind.manifestKey]
    }
}
