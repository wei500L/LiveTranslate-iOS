import Foundation
import OSLog

/// Thin wrapper over `OSSignposter` so every subsystem interval uses the
/// same constants. Signposts show up in Instruments (Points of Interest and
/// os_signpost tracks) without any per-call boilerplate.
enum SignpostLogger {
    static let signposter = OSSignposter(subsystem: "com.livetranslate.ios", category: "pipeline")

    /// Begin a named interval on the current task. Returns the state to
    /// hand back to `endInterval`.
    @discardableResult
    static func beginInterval(_ name: StaticString, id: OSSignpostID? = nil) -> OSSignpostIntervalState {
        let signpostID = id ?? signposter.makeSignpostID()
        return signposter.beginInterval(name, id: signpostID)
    }

    static func endInterval(
        _ name: StaticString,
        _ state: OSSignpostIntervalState,
        message: String? = nil
    ) {
        if let message {
            signposter.endInterval(name, state, "\(message, privacy: .public)")
        } else {
            signposter.endInterval(name, state)
        }
    }

    static func event(_ name: StaticString, _ message: String) {
        signposter.emitEvent(name, "\(message, privacy: .public)")
    }
}
