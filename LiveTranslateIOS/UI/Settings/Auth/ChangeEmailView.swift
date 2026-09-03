import SwiftUI

/// 修改登录邮箱 (two-step, server-verified):
/// 1. current password + new email → the server mails a code to the NEW
///    address (the current email stays valid until the code is consumed);
/// 2. the code swaps the email atomically, signs out every OTHER device
///    and issues this device a fresh token pair — adopted immediately.
///
/// The old email keeps working if the flow is cancelled or interrupted at
/// any point before the code is consumed.
struct ChangeEmailView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    let currentEmail: String?

    private enum Step {
        case request
        case verify
        case done
    }

    @State private var step: Step = .request
    @State private var currentPassword = ""
    @State private var newEmail = ""
    @State private var code = ""
    @State private var targetEmail = ""
    @State private var errorText: String?
    @State private var isBusy = false
    @State private var resendIn = 60
    @State private var countdownTask: Task<Void, Never>?
    @FocusState private var codeFieldFocused: Bool

    private var sync: CloudSyncService? { environment.cloudSync }

    var body: some View {
        NavigationStack {
            Form {
                switch step {
                case .request: requestSection
                case .verify: verifySection
                case .done: doneSection
                }
            }
            .navigationTitle(String(localized: "修改登录邮箱"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) { dismiss() }
                }
            }
            .scrollContentBackground(.hidden)
            .background(LTBackground())
        }
        .onDisappear { countdownTask?.cancel() }
    }

    // MARK: - Step 1

    private var requestSection: some View {
        Section {
            if let currentEmail, !currentEmail.isEmpty {
                LabeledRow(label: String(localized: "当前邮箱"), value: currentEmail)
            }
            AuthPasswordField(
                text: $currentPassword,
                prompt: String(localized: "当前密码")
            )
            AuthEmailField(text: $newEmail, prompt: String(localized: "新邮箱"))
            if let errorText {
                AuthErrorText(message: errorText)
            }
            AuthActionButton(
                title: String(localized: "向新邮箱发送验证码"),
                isBusy: isBusy,
                action: request
            )
            .listRowBackground(Color.clear)
        } header: {
            Text(String(localized: "第一步：验证身份"))
        } footer: {
            Text(String(localized: "验证完成前原邮箱保持有效；云端课堂数据不会因修改邮箱而丢失。"))
        }
    }

    private func request() {
        errorText = nil
        guard !currentPassword.isEmpty else {
            errorText = String(localized: "请输入当前密码")
            return
        }
        let email = newEmail.trimmingCharacters(in: .whitespaces)
        guard !email.isEmpty else {
            errorText = String(localized: "请填写新邮箱")
            return
        }
        if let problem = AuthForm.emailProblem(email) {
            errorText = problem
            return
        }
        isBusy = true
        let password = currentPassword
        Task {
            defer { isBusy = false }
            do {
                let state = try await sync?.requestEmailChange(
                    currentPassword: password, newEmail: email
                )
                targetEmail = state?.targetEmail ?? email
                step = .verify
                startTimer()
            } catch {
                errorText = AuthForm.message(for: error)
            }
        }
    }

    // MARK: - Step 2

    private var verifySection: some View {
        Section {
            Text(String(localized: "验证码已发送到 \(targetEmail)。在验证完成前，仍可用原邮箱登录。"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField(String(localized: "6 位验证码"), text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($codeFieldFocused)
                .onChange(of: code) { _, newValue in
                    let filtered = String(newValue.filter(\.isNumber).prefix(6))
                    if filtered != newValue { code = filtered }
                }
            if let errorText {
                AuthErrorText(message: errorText)
            }
            AuthActionButton(
                title: String(localized: "验证并完成修改"),
                isBusy: isBusy,
                action: verify
            )
            .disabled(code.count != 6)
            .listRowBackground(Color.clear)
            Button(resendTitle) { resend() }
                .disabled(resendIn > 0 || isBusy)
        } header: {
            Text(String(localized: "第二步：验证新邮箱"))
        } footer: {
            Text(String(localized: "验证成功后：其他设备将被退出登录，本机自动保持登录；此后请使用新邮箱登录。"))
        }
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
        let password = currentPassword
        let email = targetEmail
        Task {
            defer { isBusy = false }
            do {
                _ = try await sync?.requestEmailChange(
                    currentPassword: password, newEmail: email
                )
                resendIn = 60
                startTimer()
            } catch {
                if case .rateLimited(let retryAfter) = error, let after = retryAfter {
                    resendIn = max(60, Int(after))
                    startTimer()
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
                try await sync?.verifyEmailChange(code: code)
                // The server returned a fresh token pair for this device
                // (already adopted). Refresh the local account label.
                if let accountID = session.accounts.activeAccountID {
                    session.accounts.updateLabel(id: accountID, label: targetEmail)
                }
                step = .done
            } catch {
                errorText = AuthForm.message(for: error)
                codeFieldFocused = true
            }
        }
    }

    private var doneSection: some View {
        Section {
            Label(
                String(localized: "登录邮箱已修改为 \(targetEmail)。其他设备已退出登录，本机保持登录。"),
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(LTColors.accentGreen)
            Button(String(localized: "完成")) { dismiss() }
        }
    }
}
