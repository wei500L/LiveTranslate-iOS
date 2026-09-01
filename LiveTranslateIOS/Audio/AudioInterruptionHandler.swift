import Foundation
import AVFoundation

/// System audio events that can break an active capture session.
enum AudioInterruptionEvent: Sendable, Equatable {
    /// Phone call, Siri, alarm, timer.
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    /// Headphones plugged/unplugged, AirPods connect, Bluetooth mic switch.
    case routeChanged(reason: String)
    /// Media server reset — everything must be rebuilt.
    case mediaServicesReset

    var displayName: String {
        switch self {
        case .interruptionBegan: return String(localized: "Audio interrupted")
        case .interruptionEnded: return String(localized: "Audio interruption ended")
        case .routeChanged(let reason): return String(localized: "Audio route changed: \(reason)")
        case .mediaServicesReset: return String(localized: "Media services reset")
        }
    }
}

/// Observes AVAudioSession notifications and forwards them as a stream so
/// `AudioCaptureService` can run its recovery sequence. Pure observer — no
/// policy decisions live here.
final class AudioInterruptionHandler: @unchecked Sendable {
    private var continuation: AsyncStream<AudioInterruptionEvent>.Continuation?
    private var observers: [NSObjectProtocol] = []

    /// Serial queue the notification handlers run on (OperationQueue —
    /// NotificationCenter's block-based API wants one).
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "com.livetranslate.ios.audio-interruptions"
        return queue
    }()

    /// Start observing. The returned stream delivers events until `stop()`.
    func start() -> AsyncStream<AudioInterruptionEvent> {
        stop()
        let stream = AsyncStream<AudioInterruptionEvent> { continuation in
            self.continuation = continuation
        }
        let center = NotificationCenter.default

        let interruption = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: queue
        ) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let typeRaw = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
            switch type {
            case .began:
                self?.continuation?.yield(.interruptionBegan)
            case .ended:
                let optionRaw = (userInfo[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: optionRaw)
                self?.continuation?.yield(.interruptionEnded(shouldResume: options.contains(.shouldResume)))
            @unknown default:
                break
            }
        }

        let routeChange = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: queue
        ) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let reasonRaw = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else { return }
            let reasonName: String
            switch reason {
            case .unknown: reasonName = "unknown"
            case .newDeviceAvailable: reasonName = "new device available"
            case .oldDeviceUnavailable: reasonName = "old device unavailable"
            case .categoryChange: reasonName = "category change"
            case .override: reasonName = "override"
            case .wakeFromSleep: reasonName = "wake from sleep"
            case .noSuitableRouteForCategory: reasonName = "no suitable route"
            case .routeConfigurationChange: reasonName = "route configuration change"
            @unknown default: reasonName = "unknown(\(reasonRaw))"
            }
            self?.continuation?.yield(.routeChanged(reason: reasonName))
        }

        let mediaReset = center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: queue
        ) { [weak self] _ in
            self?.continuation?.yield(.mediaServicesReset)
        }

        observers = [interruption, routeChange, mediaReset]
        return stream
    }

    func stop() {
        let center = NotificationCenter.default
        for observer in observers {
            center.removeObserver(observer)
        }
        observers = []
        continuation?.finish()
        continuation = nil
    }
}
