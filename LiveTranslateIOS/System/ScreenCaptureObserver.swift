import SwiftUI
import UIKit
import OSLog

/// Observes the system screen-capture / mirroring state (round 17).
///
/// HONEST BOUNDARY: iOS cannot prevent screenshots — anyone pressing the
/// buttons keeps the image. What the app CAN do, and does:
///   - detect ACTIVE capture (screen recording, AirPlay/USB mirroring)
///     via UIScreen.isCaptured, and cover sensitive screens while it is
///     happening (recovering safely when it ends);
///   - tell the user the truth about screenshots being unstoppable.
///
/// No private APIs, no window tricks, no secure-text-field hacks.
@MainActor
@Observable
final class ScreenCaptureObserver {
    private static let logger = Logger(
        subsystem: "com.livetranslate.ios", category: "screen-capture")

    static let shared = ScreenCaptureObserver()

    private(set) var isCaptured: Bool

    private var observer: NSObjectProtocol?

    private init() {
        // UIScreen.main is deprecated in iOS 26 but remains the only
        // source of the captured state for the key screen; silence the
        // deprecation rather than lose the signal.
        isCaptured = ScreenCaptureObserver.keyScreen?.isCaptured ?? false
        observer = NotificationCenter.default.addObserver(
            forName: UIScreen.capturedDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let captured = ScreenCaptureObserver.keyScreen?.isCaptured ?? false
                if captured != self.isCaptured {
                    self.isCaptured = captured
                    Self.logger.info(
                        "screen capture state: \(captured ? "captured" : "stopped", privacy: .public)"
                    )
                }
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    @available(iOS, deprecated: 26.0)
    private static var keyScreen: UIScreen? {
        UIScreen.main
    }
}

/// Sensitive-screen capture masking (round 17): while the system screen
/// is being recorded or mirrored (and the user has not turned the
/// protection off), the modified view is covered by a brand placeholder
/// with an honest explanation. When capture ends the content returns on
/// its own — nothing is destroyed, nothing is "un-recorded" (what was
/// already captured stays captured; the copy says exactly that).
struct ScreenCaptureMaskModifier: ViewModifier {
    @Environment(SettingsStore.self) private var settings
    @State private var observer = ScreenCaptureObserver.shared

    func body(content: Content) -> some View {
        content.overlay {
            if settings.screenCaptureMaskingEnabled && observer.isCaptured {
                ZStack {
                    LTBackground()
                    VStack(spacing: LTSpacing.m) {
                        Image(systemName: "video.slash")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(LTColors.destructive)
                        Text("正在录屏或镜像")
                            .font(LTTypography.cardTitle)
                            .foregroundStyle(LTColors.textPrimary)
                        Text("此页面内容已暂时遮挡。结束录屏或断开镜像后自动恢复。\n提示：截图无法被 App 阻止，请自行留意。")
                            .font(LTTypography.caption)
                            .foregroundStyle(LTColors.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(LTSpacing.l)
                }
                .zIndex(100)
            }
        }
    }
}

extension View {
    /// Apply to screens carrying sensitive content (随身翻译 documents,
    /// 给对方看 mode, account security).
    func screenCaptureMask() -> some View {
        modifier(ScreenCaptureMaskModifier())
    }
}
