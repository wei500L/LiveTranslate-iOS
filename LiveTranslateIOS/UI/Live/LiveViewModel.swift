import SwiftUI
import Observation

/// View model for the Live tab. Wraps the pipeline coordinator (which owns
/// audio/VAD/ASR/translation orchestration) and the model manager, exposing
/// exactly what the screen renders.
@MainActor
@Observable
final class LiveViewModel {
    enum ControlMode { case start, running, paused }

    private var environment: AppEnvironment?

    // Coordinator state mirrors (kept here so the view stays dumb).
    var needsOnboarding = false
    var onboardingDismissed = false
    var isNearBottom = true
    var coreMLInstalled = false
    var sherpaInstalled = false
    var coreMLDownloadBytes = 0
    var sherpaDownloadBytes = 0

    var state: PipelineState {
        environment?.coordinator.state ?? PipelineState()
    }
    var entries: [SubtitleEntryViewModel] {
        environment?.coordinator.entries ?? []
    }
    var audioLevels: [Float] {
        environment?.coordinator.audioLevels ?? []
    }

    var backendDescription: String {
        guard let environment else { return "" }
        let settings = environment.settings
        switch settings.preferredBackend {
        case .coreMLFP16:
            return "\(ASRBackendKind.coreMLFP16.shortLabel) · \(settings.coreMLCompute.displayName)"
        case .sherpaONNXInt8:
            return "\(ASRBackendKind.sherpaONNXInt8.shortLabel) · \(settings.onnxThreads) \(String(localized: "threads"))"
        }
    }

    /// Mic route as reported by the coordinator (e.g. "iPhone mic", "AirPods").
    var micRoute: String {
        environment?.coordinator.audioRouteDescription ?? String(localized: "Microphone")
    }

    var controlMode: ControlMode {
        switch state.phase {
        case .listening, .speechDetected, .transcribing, .translating:
            return .running
        case .paused, .micInterrupted:
            return .paused
        default:
            return .start
        }
    }

    var canStart: Bool {
        switch state.phase {
        case .modelNotInstalled, .downloading, .verifying, .compilingCoreML,
             .loadingModel, .warmingUp, .micInterrupted:
            return false
        default:
            return coreMLInstalled || sherpaInstalled
        }
    }

    var errorBannerText: String? {
        if let message = state.errorMessage { return message }
        switch state.phase {
        case .backendError:
            return String(localized: "The recognition backend failed. The session was not switched automatically.")
        case .diskSpaceLow:
            return String(localized: "Not enough free disk space to install the model.")
        case .modelNotInstalled:
            return String(localized: "The selected backend is not installed.")
        default:
            return nil
        }
    }

    var showsSwitchToOtherBackend: Bool {
        guard state.phase == .backendError || state.phase == .modelNotInstalled else { return false }
        return otherInstalledBackend != nil
    }

    private var otherInstalledBackend: ASRBackendKind? {
        guard let environment else { return nil }
        let preferred = environment.settings.preferredBackend
        let other: ASRBackendKind = preferred == .coreMLFP16 ? .sherpaONNXInt8 : .coreMLFP16
        let installed = other == .coreMLFP16 ? coreMLInstalled : sherpaInstalled
        return installed ? other : nil
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        guard let environment else { return }
        await refreshInstallState()
        if !coreMLInstalled && !sherpaInstalled && !onboardingDismissed {
            needsOnboarding = true
        }
        _ = environment.engineManager
    }

    func attach(_ environment: AppEnvironment) {
        self.environment = environment
    }

    func dismissOnboarding() {
        onboardingDismissed = true
        needsOnboarding = false
    }

    func refreshInstallState() async {
        guard let environment else { return }
        async let coreML = environment.engineManager.isInstalled(.coreMLFP16)
        async let sherpa = environment.engineManager.isInstalled(.sherpaONNXInt8)
        coreMLInstalled = await coreML
        sherpaInstalled = await sherpa
        if let manifest = try? ModelManifest.load() {
            coreMLDownloadBytes = manifest.backend(.coreMLFP16)?.totalDownloadBytes ?? 0
            sherpaDownloadBytes = manifest.backend(.sherpaONNXInt8)?.totalDownloadBytes ?? 0
        }
        if !coreMLInstalled && !sherpaInstalled && !onboardingDismissed {
            needsOnboarding = true
        } else if coreMLInstalled || sherpaInstalled {
            needsOnboarding = false
        }
    }

    // MARK: - Session control

    func start() async {
        guard let environment else { return }
        if needsOnboarding { needsOnboarding = false }
        await environment.coordinator.start()
    }

    func pause() {
        environment?.coordinator.pause()
    }

    func resume() async {
        await environment?.coordinator.resume()
    }

    func stop() async {
        await environment?.coordinator.stop()
    }

    func retryFailedTranslations() async {
        await environment?.coordinator.retryFailedTranslations()
    }

    /// Explicit, user-initiated switch to the other installed backend.
    /// Never automatic; requires the session to be stopped.
    func switchToOtherInstalledBackend() async {
        guard let environment, let other = otherInstalledBackend else { return }
        environment.settings.preferredBackend = other
        await environment.coordinator.start()
    }

    func install(_ kind: ASRBackendKind) async {
        guard let environment else { return }
        await environment.modelManager.install(kind)
        await refreshInstallState()
    }

    // MARK: - Scroll anchoring

    func updateScrollPosition(minY: CGFloat) {
        // Within ~80 pt of the bottom counts as "at the bottom"; anything
        // above that is the user reading history.
        isNearBottom = minY > -80
    }
}
