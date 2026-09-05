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
        /// Dedicated model for image understanding (multimodal); empty =
        /// inherit the study-review model (then the translation model).
        static let attachmentAnalysisModel = "attachmentAnalysis.model"
        /// What the lock screen / Live Activity may reveal about the
        /// running classroom. A device-level privacy preference (stored
        /// globally, not per-account): status-only, status + name (the
        /// restrained default), or additionally one latest Chinese line.
        static let lockScreenPrivacy = "ui.lockScreenPrivacy"
        /// Round 17: the SINGLE content policy for every system surface
        /// (Live Activities / widgets / notification bodies / Spotlight /
        /// App-Entity suggestions). nil on first run → derived from the
        /// legacy lockScreenPrivacy value.
        static let systemSurfacePrivacy = "ui.systemSurfacePrivacy"
        /// Round 17: device-local biometric privacy lock (off by default;
        /// the config never syncs and never crosses profiles).
        static let privacyLockEnabled = "privacy.lock.enabled"
        /// Grace period before the lock re-arms after leaving the app:
        /// 0 (immediately) / 60 / 300 / 900 seconds.
        static let privacyLockGraceSeconds = "privacy.lock.graceSeconds"
        /// Round 17: brand placeholder over the UI in the task switcher
        /// snapshot (on by default — it hides content, costs nothing).
        static let backgroundMaskingEnabled = "privacy.backgroundMasking"
        /// Round 17: mask sensitive screens while the system screen is
        /// being captured or mirrored (on by default).
        static let screenCaptureMaskingEnabled = "privacy.screenCaptureMasking"
        /// Round 17: 随身翻译 document retention (days; 0 = keep forever,
        /// the default — nothing is ever auto-deleted without consent).
        static let interpreterDocumentRetentionDays = "privacy.interpreterDocumentRetentionDays"
        // 随身翻译 (interpreter) preferences.
        /// Default errand scene for a new interpreter conversation.
        static let interpreterDefaultScene = "interpreter.defaultScene"
        /// Whether Russian stress marks render by default (U+0301).
        static let interpreterShowStress = "interpreter.showStress"
        /// Auto-expand turn details after translation completes (off).
        static let interpreterAutoExpand = "interpreter.autoExpandDetails"
        /// Auto-speak a finished user reply (off — never automatic).
        static let interpreterAutoSpeak = "interpreter.autoSpeak"
        /// Ask save-or-discard when a conversation ends (on).
        static let interpreterAskToSave = "interpreter.askToSave"
    }

    /// Live-classroom translation toggle (new-classroom form). When off,
    /// Russian is still recognized and saved, but translations are not
    /// requested for that classroom. Applies per utterance at dispatch
    /// time, so switching mid-classroom affects subsequent segments.
    var liveTranslationEnabled: Bool {
        didSet { defaults.set(liveTranslationEnabled, forKey: Keys.liveTranslationEnabled) }
    }

    /// Lock-screen reveal level. Restrained default: status + classroom
    /// name; the transcript body never shows unless the user opts in.
    /// Changing it updates the running Live Activity + snapshot (via the
    /// system coordinator); saved classroom data is unaffected.
    var lockScreenPrivacy: LockScreenPrivacy {
        didSet { defaults.set(lockScreenPrivacy.rawValue, forKey: Keys.lockScreenPrivacy) }
    }

    /// The unified system-surface content policy (round 17). Setter keeps
    /// the legacy classroom dimension in sync so the existing LA /
    /// snapshot machinery follows the single source.
    var systemSurfacePrivacy: SystemSurfacePrivacy {
        didSet {
            defaults.set(systemSurfacePrivacy.rawValue, forKey: Keys.systemSurfacePrivacy)
            lockScreenPrivacy = systemSurfacePrivacy.classroomLockScreenPrivacy
        }
    }

    /// Whether the device-local privacy lock is armed (default off).
    var privacyLockEnabled: Bool {
        didSet { defaults.set(privacyLockEnabled, forKey: Keys.privacyLockEnabled) }
    }

    /// Grace seconds before the privacy lock re-arms (0/60/300/900).
    var privacyLockGraceSeconds: Int {
        didSet { defaults.set(privacyLockGraceSeconds, forKey: Keys.privacyLockGraceSeconds) }
    }

    /// Task-switcher snapshot masking (default on).
    var backgroundMaskingEnabled: Bool {
        didSet { defaults.set(backgroundMaskingEnabled, forKey: Keys.backgroundMaskingEnabled) }
    }

    /// Screen-capture/mirror masking for sensitive screens (default on).
    var screenCaptureMaskingEnabled: Bool {
        didSet { defaults.set(screenCaptureMaskingEnabled, forKey: Keys.screenCaptureMaskingEnabled) }
    }

    /// 随身翻译 document retention in days (0 = keep forever — the
    /// default: round 16's "保存会话时保留原件" behavior is unchanged
    /// until the user explicitly chooses a window).
    var interpreterDocumentRetentionDays: Int {
        didSet {
            defaults.set(
                interpreterDocumentRetentionDays,
                forKey: Keys.interpreterDocumentRetentionDays
            )
        }
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

    /// Dedicated model for image understanding; empty = use
    /// `studyReviewModel` (which itself falls back to `translationModel`).
    var attachmentAnalysisModel: String {
        didSet { defaults.set(attachmentAnalysisModel, forKey: Keys.attachmentAnalysisModel) }
    }

    // MARK: - 随身翻译 (interpreter)

    /// Default errand scene for a new conversation.
    var interpreterDefaultScene: InterpreterScene {
        didSet { defaults.set(interpreterDefaultScene.rawValue, forKey: Keys.interpreterDefaultScene) }
    }

    /// Whether Russian stress marks render by default.
    var interpreterShowStress: Bool {
        didSet { defaults.set(interpreterShowStress, forKey: Keys.interpreterShowStress) }
    }

    /// Auto-expand turn details after translation completes (default off).
    var interpreterAutoExpand: Bool {
        didSet { defaults.set(interpreterAutoExpand, forKey: Keys.interpreterAutoExpand) }
    }

    /// Auto-speak a finished user reply (default off — never automatic).
    var interpreterAutoSpeak: Bool {
        didSet { defaults.set(interpreterAutoSpeak, forKey: Keys.interpreterAutoSpeak) }
    }

    /// Ask save-or-discard when a conversation ends (default on).
    var interpreterAskToSave: Bool {
        didSet { defaults.set(interpreterAskToSave, forKey: Keys.interpreterAskToSave) }
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
        attachmentAnalysisModel = defaults.string(forKey: Keys.attachmentAnalysisModel) ?? ""
        let liveTranslation = defaults.object(forKey: Keys.liveTranslationEnabled) as? Bool
        liveTranslationEnabled = liveTranslation ?? true
        lockScreenPrivacy = LockScreenPrivacy(
            rawValue: defaults.string(forKey: Keys.lockScreenPrivacy) ?? ""
        ) ?? .statusAndTitle
        // Round 17: derive the unified level from the legacy classroom
        // preference on first run (nothing the user had chosen is lost).
        if let stored = defaults.string(forKey: Keys.systemSurfacePrivacy),
           let parsed = SystemSurfacePrivacy(rawValue: stored) {
            systemSurfacePrivacy = parsed
        } else {
            switch lockScreenPrivacy {
            case .statusOnly: systemSurfacePrivacy = .hideSensitiveContent
            case .statusAndTitle: systemSurfacePrivacy = .showTitlesOnly
            case .statusTitleAndLatestText: systemSurfacePrivacy = .showFullContent
            }
        }
        privacyLockEnabled = defaults.bool(forKey: Keys.privacyLockEnabled)
        let grace = defaults.object(forKey: Keys.privacyLockGraceSeconds) as? Int
        privacyLockGraceSeconds = grace ?? 0
        let masking = defaults.object(forKey: Keys.backgroundMaskingEnabled) as? Bool
        backgroundMaskingEnabled = masking ?? true
        let captureMasking = defaults.object(forKey: Keys.screenCaptureMaskingEnabled) as? Bool
        screenCaptureMaskingEnabled = captureMasking ?? true
        let retention = defaults.object(forKey: Keys.interpreterDocumentRetentionDays) as? Int
        interpreterDocumentRetentionDays = retention ?? 0
        interpreterDefaultScene = InterpreterScene(
            rawValue: defaults.string(forKey: Keys.interpreterDefaultScene) ?? ""
        ) ?? .general
        let interpreterStress = defaults.object(forKey: Keys.interpreterShowStress) as? Bool
        interpreterShowStress = interpreterStress ?? true
        let interpreterExpand = defaults.object(forKey: Keys.interpreterAutoExpand) as? Bool
        interpreterAutoExpand = interpreterExpand ?? false
        let interpreterSpeak = defaults.object(forKey: Keys.interpreterAutoSpeak) as? Bool
        interpreterAutoSpeak = interpreterSpeak ?? false
        let interpreterSave = defaults.object(forKey: Keys.interpreterAskToSave) as? Bool
        interpreterAskToSave = interpreterSave ?? true
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
