import SwiftUI

/// Six-digit email verification (the step after 注册). Verifying issues the
/// first token pair, so completion is a full sign-in handed to AppSession.
///
/// UX contract: auto-focused on appear, paste-tolerant (any 6 digits
/// auto-submit), the resend countdown honors the server's Retry-After, and
/// the flow can be resumed after the app was closed (AppSession keeps the
/// pending email; this view also allows switching the address and going
/// back to re-register).
struct EmailVerificationView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    let email: String

    @State private var code = ""
    @State private var errorText: String?
    @State private var isBusy = false
    @State private var resendIn = 60
    @State private var countdownTask: Task<Void, Never>?
    @FocusState private var codeFieldFocused: Bool
    /// Set while the auto-submit from a full paste is in flight (guards
    /// against onChange re-triggering during the request).
    @State private var autoSubmitted = false

    var body: some View {
        Form {
            Section {
                Text(String(localized: "验证码已发送到 \(email)。请在 10 分钟内输入。"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField(
                    String(localized: "6 位验证码"),
                    text: $code
                )
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($codeFieldFocused)
                .onChange(of: code) { _, newValue in
                    // Digits only, max 6; a full 6-digit value (typed or
                    // pasted — the OTP AutoFill delivers the whole code)
                    // submits itself.
                    let filtered = String(newValue.filter(\.isNumber).prefix(6))
                    if filtered != newValue { code = filtered }
                    if filtered.count == 6, !autoSubmitted, !isBusy {
                        autoSubmitted = true
                        verify()
                    } else if filtered.count < 6 {
                        autoSubmitted = false
                    }
                }
                if let errorText {
                    AuthErrorText(message: errorText)
                }
                AuthActionButton(
                    title: String(localized: "验证并登录"),
                    isBusy: isBusy,
                    action: verify
                )
                .disabled(code.count != 6)
                .listRowBackground(Color.clear)
            } header: {
                Text(String(localized: "邮箱验证"))
            }

            Section {
                Button(resendTitle) { resend() }
                    .disabled(resendIn > 0 || isBusy)
            } footer: {
                Text(String(localized: "未收到邮件？60 秒后可重新发送；也请检查垃圾邮件文件夹。"))
            }

            Section {
                Button(String(localized: "换个邮箱重新注册"), role: .destructive) {
                    abandonAndGoBack()
                }
                .font(.caption)
            } footer: {
                Text(String(localized: "仅放弃当前这次注册；验证码作废，需要用新邮箱重新注册。"))
            }
        }
        .navigationTitle(String(localized: "验证邮箱"))
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(LTBackground())
        .onAppear {
            startTimer()
            // Auto-focus the code field so the keyboard (and the OTP
            // AutoFill suggestion) is ready immediately.
            codeFieldFocused = true
        }
        .onDisappear { countdownTask?.cancel() }
    }

    private var resendTitle: String {
        resendIn > 0
            ? String(localized: "重新发送（\(resendIn) 秒后）")
            : String(localized: "重新发送验证码")
    }

    private func startTimer() {
        countdownTask?.cancel()
        countdownTask = Task { @MainActor in
            while resendIn > 0 && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                resendIn -= 1
            }
        }
    }

    /// Restarts the countdown at a server-communicated minimum (Retry-After
    /// on 429) rather than the fixed 60 s.
    private func restartCountdown(minimumSeconds: Int) {
        resendIn = max(60, minimumSeconds)
        startTimer()
    }

    private func resend() {
        errorText = nil
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                try await session.resendCode(email: email)
                restartCountdown(minimumSeconds: 60)
            } catch {
                // The server's Retry-After drives the countdown so the
                // button stays honest about when a retry is possible.
                if case .rateLimited(let retryAfter) = error, let after = retryAfter {
                    restartCountdown(minimumSeconds: Int(after))
                }
                errorText = AuthForm.message(for: error)
            }
        }
    }

    private func verify() {
        errorText = nil
        isBusy = true
        let code = code
        Task {
            defer { isBusy = false }
            do {
                try await session.signIn(label: email, provider: "email") { authSession in
                    try await authSession.verifyEmail(email: email, code: code)
                }
                session.clearPendingVerification()
                dismiss()
            } catch {
                errorText = AuthForm.message(for: error)
                autoSubmitted = false
                // Wrong code: select-all for a clean retype.
                codeFieldFocused = true
            }
        }
    }

    private func abandonAndGoBack() {
        session.clearPendingVerification()
        dismiss()
    }
}
