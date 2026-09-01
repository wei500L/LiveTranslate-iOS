import Foundation

/// User-facing presentation for the two local recognition runtimes.
///
/// The backend enum's own `displayName`/`shortLabel` are technical
/// identifiers for logs, diagnostics and exports. Product UI never surfaces
/// them: the two runtimes of the same local model are presented as
/// 准确度优先 / 速度优先 (spec: no Core ML / FP16 / INT8 / sherpa-onnx in
/// user-visible UI).
extension ASRBackendKind {
    /// Picker title and card headline.
    var userTitle: String {
        switch self {
        case .coreMLFP16: return String(localized: "准确度优先")
        case .sherpaONNXInt8: return String(localized: "速度优先")
        }
    }

    /// One-line explanation shown under the title.
    var userSubtitle: String {
        switch self {
        case .coreMLFP16:
            return String(localized: "识别更准确 · 推荐机型优先使用")
        case .sherpaONNXInt8:
            return String(localized: "体积更小、启动更快 · 兼容更多设备")
        }
    }
}
