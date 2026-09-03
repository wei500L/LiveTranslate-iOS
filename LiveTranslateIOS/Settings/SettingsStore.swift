import Foundation
import SwiftUI

/// User-facing app settings, persisted in UserDefaults. Model download
/// state lives in the manifest + file system instead, and API keys live
/// exclusively in the Keychain (never here).
@MainActor
@Observable
final class SettingsStore {
    static let shared = SettingsStore()

    private let defaults: UserDefaults

    struct Keys {
        static let preferredBackend = "preferredBackend"
        static let coreMLCompute = "coreMLComputePreference"
        static let onnxThreads = "onnxThreadCount"
        static let vadThreshold = "vad.threshold"
        static let vadMinSpeechMs = "vad.minSpeechMs"
        static let vadSilenceEndMs = "vad.silenceEndMs"
        static let saveRawAudio = "saveRawAudio"
        static let apiBase = "translation.apiBase"
        static let translationModel = "translation.model"
        static let streaming = "translation.streaming"
        static let contextTurns = "translation.contextTurns"
        static let temperature = "translation.temperature"
        static let maxTokens = "translation.maxTokens"
        static let timeout = "translation.timeoutSeconds"
        static let thinkingStyle = "translation.thinkingStyle"
        static let systemPrompt = "translation.customSystemPrompt"
        static let concurrency = "translation.concurrency"
        static let liveTranslationEnabled = "ui.liveTranslationEnabled"
        /// Model for post-class study reviews; empty = inherit the
        /// translation model.
        static let studyReviewModel = "studyReview.model"
    }

    /// Live-classroom translation toggle (new-classroom form). When off,
    /// Russian is still recognized and saved, but translations are not
    /// requested for that classroom. Applies per utterance at dispatch
    /// time, so switching mid-classroom affects subsequent segments.
    var liveTranslationEnabled: Bool {
        didSet { defaults.set(liveTranslationEnabled, forKey: Keys.liveTranslationEnabled) }
    }

    var preferredBackend: ASRBackendKind {
        didSet { defaults.set(preferredBackend.rawValue, forKey: Keys.preferredBackend) }
    }

    var coreMLCompute: CoreMLComputePreference {
        didSet { defaults.set(coreMLCompute.rawValue, forKey: Keys.coreMLCompute) }
    }

    var onnxThreads: Int {
        didSet { defaults.set(onnxThreads, forKey: Keys.onnxThreads) }
    }

    var vadThreshold: Double {
        didSet { defaults.set(vadThreshold, forKey: Keys.vadThreshold) }
    }

    var vadMinSpeechMs: Int {
        didSet { defaults.set(vadMinSpeechMs, forKey: Keys.vadMinSpeechMs) }
    }

    var vadSilenceEndMs: Int {
        didSet { defaults.set(vadSilenceEndMs, forKey: Keys.vadSilenceEndMs) }
    }

    var saveRawAudio: Bool {
        didSet { defaults.set(saveRawAudio, forKey: Keys.saveRawAudio) }
    }

    var apiBase: String {
        didSet { defaults.set(apiBase, forKey: Keys.apiBase) }
    }

    var translationModel: String {
        didSet { defaults.set(translationModel, forKey: Keys.translationModel) }
    }

    var streaming: Bool {
        didSet { defaults.set(streaming, forKey: Keys.streaming) }
    }

    var contextTurns: Int {
        didSet { defaults.set(contextTurns, forKey: Keys.contextTurns) }
    }

    var temperature: Double {
        didSet { defaults.set(temperature, forKey: Keys.temperature) }
    }

    var maxTokens: Int {
        didSet { defaults.set(maxTokens, forKey: Keys.maxTokens) }
    }

    var timeout: TimeInterval {
        didSet { defaults.set(timeout, forKey: Keys.timeout) }
    }

    var thinkingStyle: String {
        didSet { defaults.set(thinkingStyle, forKey: Keys.thinkingStyle) }
    }

    var customSystemPrompt: String {
        didSet { defaults.set(customSystemPrompt, forKey: Keys.systemPrompt) }
    }

    var translationConcurrency: Int {
        didSet { defaults.set(translationConcurrency, forKey: Keys.concurrency) }
    }

    /// Dedicated model for study reviews; empty = use `translationModel`.
    var studyReviewModel: String {
        didSet { defaults.set(studyReviewModel, forKey: Keys.studyReviewModel) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferredBackend = ASRBackendKind(
            rawValue: defaults.string(forKey: Keys.preferredBackend) ?? ""
        ) ?? .coreMLFP16
        coreMLCompute = CoreMLComputePreference(
            rawValue: defaults.string(forKey: Keys.coreMLCompute) ?? ""
        ) ?? .accuracy
        let threads = defaults.integer(forKey: Keys.onnxThreads)
        onnxThreads = threads == 0 ? 2 : threads
        let threshold = defaults.object(forKey: Keys.vadThreshold) as? Double
        vadThreshold = threshold ?? 0.5
        let minSpeech = defaults.object(forKey: Keys.vadMinSpeechMs) as? Int
        vadMinSpeechMs = minSpeech ?? 250
        let silenceEnd = defaults.object(forKey: Keys.vadSilenceEndMs) as? Int
        vadSilenceEndMs = silenceEnd ?? 600
        saveRawAudio = defaults.bool(forKey: Keys.saveRawAudio)
        apiBase = defaults.string(forKey: Keys.apiBase) ?? ""
        translationModel = defaults.string(forKey: Keys.translationModel) ?? ""
        let stream = defaults.object(forKey: Keys.streaming) as? Bool
        streaming = stream ?? true
        let turns = defaults.object(forKey: Keys.contextTurns) as? Int
        contextTurns = turns ?? 4
        let temp = defaults.object(forKey: Keys.temperature) as? Double
        temperature = temp ?? 0.3
        let tokens = defaults.object(forKey: Keys.maxTokens) as? Int
        maxTokens = tokens ?? 256
        let timeoutVal = defaults.object(forKey: Keys.timeout) as? Double
        timeout = timeoutVal ?? 30
        thinkingStyle = defaults.string(forKey: Keys.thinkingStyle) ?? "auto"
        customSystemPrompt = defaults.string(forKey: Keys.systemPrompt) ?? ""
        let conc = defaults.object(forKey: Keys.concurrency) as? Int
        translationConcurrency = conc ?? 2
        studyReviewModel = defaults.string(forKey: Keys.studyReviewModel) ?? ""
        let liveTranslation = defaults.object(forKey: Keys.liveTranslationEnabled) as? Bool
        liveTranslationEnabled = liveTranslation ?? true
    }
}

/// Core ML compute unit selection. `accuracy` is the default: results are
/// token-exact against the PyTorch reference. The Neural Engine option is
/// explicitly experimental — it can shift boundary tokens and compile
/// slower on first use.
enum CoreMLComputePreference: String, Codable, Sendable, CaseIterable, Identifiable {
    case accuracy
    case neuralEngineExperimental

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .accuracy: return String(localized: "CPU + GPU (accuracy first, recommended)")
        case .neuralEngineExperimental: return String(localized: "CPU + Neural Engine (experimental)")
        }
    }
}
