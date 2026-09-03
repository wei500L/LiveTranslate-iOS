import SwiftUI
import AuthenticationServices

/// Email/password 登录 + 注册 sheet. Registration does not sign in — it
/// pushes the email-verification step. Successful sign-in is handed to
/// `AppSession`, which scopes the tokens and switches the app into the
/// account's isolated profile.
struct AccountAuthView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable, Identifiable {
        case signIn = "登录"
        case register = "注册"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var displayName = ""
    @State private var errorText: String?
    @State private var isBusy = false
    @State private var pushVerification = false

    var body: some View {
        NavigationStack {
            Form {
                Picker(String(localized: "方式"), selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                Section {
                    AuthEmailField(text: $email)
                    if mode == .register {
                        TextField(
                            String(localized: "昵称（可选）"),
                            text: $displayName
                        )
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.next)
                    }
                    if mode == .signIn {
                        AuthPasswordField(text: $password)
                    } else {
                        AuthNewPasswordField(text: $password)
                        AuthNewPasswordField(
                            text: $confirmPassword,
                            prompt: String(localized: "再次输入密码")
                        )
                    }
                    if let errorText {
                        AuthErrorText(message: errorText)
                    }
                    AuthActionButton(
                        title: mode == .signIn
                            ? String(localized: "登录")
                            : String(localized: "注册并获取验证码"),
                        isBusy: isBusy,
                        action: submit
                    )
                    .listRowBackground(Color.clear)
                } header: {
                    Text(String(localized: "邮箱账号"))
                } footer: {
                    if mode == .register {
                        Text(String(localized: "密码至少 10 位，支持中文与符号；不会以此判定相似内容。注册后需要验证邮箱。"))
                    }
                }

                if mode == .signIn {
                    Section {
                        NavigationLink(
                            String(localized: "忘记密码？"),
                            destination: PasswordRecoveryView()
                        )
                    }
                }
            }
            .navigationTitle(String(localized: "邮箱登录"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) { dismiss() }
                }
            }
            .scrollContentBackground(.hidden)
            .background(LTBackground())
            .navigationDestination(isPresented: $pushVerification) {
                EmailVerificationView(email: email.trimmingCharacters(in: .whitespaces))
            }
        }
    }

    private func submit() {
        errorText = nil
        let email = email.trimmingCharacters(in: .whitespaces)
        guard !email.isEmpty, !password.isEmpty else {
            errorText = String(localized: "请填写邮箱和密码")
            return
        }
        if let problem = AuthForm.emailProblem(email) {
            errorText = problem
            return
        }
        switch mode {
        case .signIn:
            signIn(email: email)
        case .register:
            register(email: email)
        }
    }

    private func signIn(email: String) {
        isBusy = true
        let password = password
        Task {
            defer { isBusy = false }
            do {
                try await session.signIn(label: email, provider: "email") { authSession in
                    try await authSession.signIn(email: email, password: password)
                }
                // Success: AppSession rebuilt the environment; this sheet's
                // tree is gone with the profile switch.
                dismiss()
            } catch {
                errorText = AuthForm.message(for: error)
            }
        }
    }

    private func register(email: String) {
        if let problem = AuthForm.newPasswordProblem(password)
            ?? AuthForm.confirmationProblem(password, confirmPassword) {
            errorText = problem
            return
        }
        isBusy = true
        let password = password
        let name = displayName.trimmingCharacters(in: .whitespaces)
        Task {
            defer { isBusy = false }
            do {
                try await session.register(
                    email: email, password: password, displayName: name
                )
                pushVerification = true
            } catch {
                errorText = AuthForm.message(for: error)
            }
        }
    }
}
