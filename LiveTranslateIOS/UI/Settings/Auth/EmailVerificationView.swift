import SwiftUI

/// Six-digit email verification (the step after 注册). Verifying issues the
/// first token pair, so completion is a full sign-in handed to AppSession.
struct EmailVerificationView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    let email: String

    @State private var code = ""
    @State private var errorText: String?
    @State private var isBusy = false
    @State private var resendIn = 60
    @State private var countdownTask: Task<Void, Never>?

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
                .onChange(of: code) { _, newValue in
                    // Digits only, max 6.
                    let filtered = String(newValue.filter(\.isNumber).prefix(6))
                    if filtered != newValue { code = filtered }
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
        }
        .navigationTitle(String(localized: "验证邮箱"))
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(LTBackground())
        .onAppear(perform: startTimer)
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

    private func resend() {
        errorText = nil
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                try await session.resendCode(email: email)
                resendIn = 60
                startTimer()
            } catch {
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
                dismiss()
            } catch {
                errorText = AuthForm.message(for: error)
            }
        }
    }
}
