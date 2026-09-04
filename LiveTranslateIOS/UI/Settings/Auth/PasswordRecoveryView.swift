import SwiftUI

/// 忘记密码 → 重置：one flow, two steps. The reset token arrives by mail
/// (the server never reveals whether the account exists) as an HTTPS
/// universal link or as a manual-paste credential from the web fallback
/// page. A deep link pre-fills the token via `prefilledToken`; it lives
/// only in this view's @State — never persistence.
struct PasswordRecoveryView: View {
    private enum Step {
        case request
        case reset
        case done
    }

    @State private var step: Step = .request
    @State private var email = ""
    @State private var token = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var form = AuthFormState()
    /// Deep-link token (in-memory only). When set, the flow starts at the
    /// reset step with the token already in place.
    @State private var deepLinkToken: String?

    init(prefilledToken: String? = nil) {
        // @State initial values must be set through the initializer.
        _deepLinkToken = State(initialValue: prefilledToken)
    }

    private var baseURL: URL? { ServerConfiguration.baseURL }

    var body: some View {
        Form {
            switch step {
            case .request: requestSection
            case .reset: resetSection
            case .done: doneSection
            }
        }
        .navigationTitle(String(localized: "找回密码"))
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(LTBackground())
        .onAppear(perform: applyDeepLink)
        .onDisappear {
            // Leaving the flow drops the token and password from memory.
            token = ""
            newPassword = ""
            confirmPassword = ""
        }
    }

    /// A deep-linked token jumps straight to the reset step.
    private func applyDeepLink() {
        // `deepLink` avoids shadowing the @State property (an unshadowed
        // `guard let deepLinkToken` would bind a local let and make the
        // clearing assignment below illegal).
        guard let deepLink = deepLinkToken, token.isEmpty else { return }
        token = deepLink
        deepLinkToken = nil
        if step == .request {
            step = .reset
        }
    }

    // MARK: - Step 1: request the reset mail

    private var requestSection: some View {
        Section {
            AuthEmailField(text: $email)
            if let errorText = form.errorText {
                AuthErrorText(message: errorText)
            }
            AuthActionButton(
                title: String(localized: "发送重置邮件"),
                isBusy: form.isBusy,
                action: requestReset
            )
            .listRowBackground(Color.clear)
        } header: {
            Text(String(localized: "第一步：验证邮箱"))
        } footer: {
            Text(String(localized: "如果该邮箱已注册，你将收到一封包含重置链接的邮件。为保护账号安全，无论邮箱是否存在，界面显示都相同。"))
        }
    }

    private func requestReset() {
        form.clearError()
        let email = email.trimmingCharacters(in: .whitespaces)
        guard !email.isEmpty else {
            form.fail(String(localized: "请填写邮箱"))
            return
        }
        if let problem = AuthForm.emailProblem(email) {
            form.fail(problem)
            return
        }
        guard form.begin() else { return }
        Task {
            defer { form.end() }
            do {
                guard let baseURL else { throw SyncAPIError.notConfigured }
                let api = SyncAPIClient(baseURL: baseURL)
                try await api.forgotPassword(email: email)
                step = .reset
            } catch {
                form.fail(error: error)
            }
        }
    }

    // MARK: - Step 2: token (pasted or deep-linked) + new password

    private var resetSection: some View {
        Section {
            Text(String(localized: "重置邮件已发送到 \(email)。打开邮件中的链接，或复制重置凭证粘贴到下方。"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField(
                String(localized: "重置凭证"),
                text: $token
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            AuthNewPasswordField(
                text: $newPassword,
                prompt: String(localized: "新密码（至少 10 位）")
            )
            AuthNewPasswordField(
                text: $confirmPassword,
                prompt: String(localized: "再次输入新密码")
            )
            if let errorText = form.errorText {
                AuthErrorText(message: errorText)
            }
            AuthActionButton(
                title: String(localized: "重置密码"),
                isBusy: form.isBusy,
                action: resetPassword
            )
            .listRowBackground(Color.clear)
        } header: {
            Text(String(localized: "第二步：设置新密码"))
        } footer: {
            Text(String(localized: "重置后所有已登录设备都会被退出，需要用新密码重新登录。链接 30 分钟内有效且只能使用一次。"))
        }
    }

    private func resetPassword() {
        form.clearError()
        guard !token.trimmingCharacters(in: .whitespaces).isEmpty else {
            form.fail(String(localized: "请粘贴邮件中的重置凭证"))
            return
        }
        if let problem = AuthForm.newPasswordProblem(newPassword)
            ?? AuthForm.confirmationProblem(newPassword, confirmPassword) {
            form.fail(problem)
            return
        }
        guard form.begin() else { return }
        let token = token.trimmingCharacters(in: .whitespaces)
        let newPassword = newPassword
        Task {
            defer { form.end() }
            do {
                guard let baseURL else { throw SyncAPIError.notConfigured }
                let api = SyncAPIClient(baseURL: baseURL)
                try await api.resetPassword(token: token, newPassword: newPassword)
                clearTokenFromMemory()
                step = .done
            } catch {
                form.fail(error: error)
            }
        }
    }

    /// The token is single-use and consumed — drop it from view state
    /// immediately (it must not linger in memory or anywhere else).
    private func clearTokenFromMemory() {
        token = ""
        deepLinkToken = nil
    }

    private var doneSection: some View {
        Section {
            Label(
                String(localized: "密码已重置。请使用新密码重新登录。"),
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(LTColors.accentGreen)
        } footer: {
            Text(String(localized: "所有设备均已退出登录。"))
        }
    }
}
