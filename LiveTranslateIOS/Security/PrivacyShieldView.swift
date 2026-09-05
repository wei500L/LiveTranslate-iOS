import SwiftUI

/// The brand placeholder that covers the app in the task-switcher
/// snapshot and the biometric lock state (round 17).
///
/// What it shows by design: the app name and a lock/status icon. NEVER
/// course names, translations, file names, emails, counts or errors —
/// the snapshot in the app switcher must be content-free.
struct PrivacyShieldView: View {
    enum Mode {
        /// App not active (task switcher / notification shade / control
        /// center): pure placeholder, no actions.
        case masked
        /// Biometric lock engaged: unlock button + honest failure state.
        case locked
    }

    let mode: Mode
    var failure: PrivacyLockController.FailureState?
    var isAuthenticating = false
    var onUnlock: () -> Void = {}

    var body: some View {
        ZStack {
            LTBackground()
            VStack(spacing: LTSpacing.l) {
                Spacer()
                Image(systemName: mode == .locked ? "lock.fill" : "waveform")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(LTColors.accentCyan)
                    .padding(.bottom, LTSpacing.s)
                Text("LiveTranslate")
                    .font(LTTypography.cardTitle)
                    .foregroundStyle(LTColors.textPrimary)
                if mode == .locked {
                    failureText
                    Button {
                        onUnlock()
                    } label: {
                        Label(
                            isAuthenticating ? "正在验证…" : "解锁",
                            systemImage: "faceid"
                        )
                        .font(LTTypography.body)
                        .padding(.horizontal, LTSpacing.l)
                        .padding(.vertical, LTSpacing.s)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isAuthenticating)
                }
                Spacer()
            }
        }
        .ignoresSafeArea()
    }

    /// Honest per-state copy — a failure is a real state, never a fake
    /// success and never a raw LAError dump.
    @ViewBuilder
    private var failureText: some View {
        switch failure {
        case .none:
            Text("已锁定 · 需要 Face ID、触控 ID 或设备密码")
        case .some(.userCancelled), .some(.systemCancelled):
            Text("验证已取消，点击解锁重试")
        case .some(.biometryUnavailable):
            Text("生物识别不可用 · 将使用设备密码验证")
        case .some(.notEnrolled):
            Text("尚未设置 Face ID / 密码 · 请先在系统设置中配置")
        case .some(.lockedOut):
            Text("尝试次数过多已被锁定 · 请稍后重试或使用设备密码")
        case .some(.generic):
            Text("验证未成功，点击解锁重试")
        }
    }
}

/// Root-level privacy shield (round 17): covers the attached content in
/// the task-switcher snapshot while the app is inactive/background, and
/// covers everything with the biometric lock when armed.
///
/// NO-FLASH GUARANTEE: visibility is computed SYNCHRONOUSLY in body from
/// `scenePhase`, the controller's unlock state and its recorded
/// left-foreground timestamp — the moment scenePhase flips to .active
/// the same body pass already knows whether the lock re-arms, so the
/// content can never appear for one frame before the shield. The
/// scenePhase→controller bridge (foreground handling + auto-auth) lives
/// in RootTabView; every presentation layer (root, live-classroom cover,
/// sheets) reuses this modifier for its own layer.
struct PrivacyShieldModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    let controller: PrivacyLockController
    let settings: SettingsStore

    func body(content: Content) -> some View {
        content.overlay {
            if let mode = activeMode {
                PrivacyShieldView(
                    mode: mode,
                    failure: controller.lastFailure,
                    isAuthenticating: controller.isAuthenticating,
                    onUnlock: { Task { await controller.attemptUnlock() } }
                )
                .zIndex(100)
            }
        }
    }

    private var activeMode: PrivacyShieldView.Mode? {
        if controller.requiresUnlock {
            return .locked
        }
        guard settings.backgroundMaskingEnabled else { return nil }
        if scenePhase != .active {
            return .masked
        }
        // The transition frame: scenePhase already .active but the
        // foreground-entry bridge (onChange) has not run yet — the grace
        // decision must not wait for it.
        if settings.privacyLockEnabled,
           let leftAt = controller.leftForegroundAt {
            let grace = TimeInterval(max(0, settings.privacyLockGraceSeconds))
            if Date().timeIntervalSince(leftAt) >= grace {
                return .masked
            }
        }
        return nil
    }
}

extension View {
    /// Covers this layer with the task-switcher mask / biometric lock
    /// shield. Apply to EVERY top-level presentation layer (root view,
    /// full-screen covers, sensitive sheets).
    func privacyShield(
        controller: PrivacyLockController, settings: SettingsStore
    ) -> some View {
        modifier(PrivacyShieldModifier(controller: controller, settings: settings))
    }
}
