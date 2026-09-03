import SwiftUI
import AuthenticationServices

/// Email/password 登录 + 注册 sheet. Registration does not sign in — it
/// pushes the email-verification step. Successful sign-in is handed to
/// `AppSession`, which scopes the tokens and switches the app into the
/// account's isolated profile.
///
/// The register tab exists ONLY when the server's capabilities allow it
/// (GET /v1/auth/capabilities is the single source of truth — the UI never
/// hardcodes "registration is open"); invite-only mode adds the invitation
/// code field.
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
    @State private var invitationCode = ""
    @State private var form = AuthFormState()
    @State private var pushVerification = false
    @State private var showTerms = false
    @State private var showPrivacy = false
    /// Server capabilities; nil while loading. Fails SAFE: no capabilities
    /// → no registration tab (a transport failure never opens registration).
    @State private var capabilities: SyncCapabilitiesDTO?

    /// Tabs available in the CURRENT server posture.
    private var modes: [Mode] {
        guard let caps = capabilities else { return [.signIn] }
        var out: [Mode] = [.signIn]
        if caps.passwordLogin && caps.registrationMode != .disabled {
            out.append(.register)
        }
        return out
    }

    private var registrationMode: RegistrationMode {
        capabilities?.registrationMode ?? .disabled
    }

    var body: some View {
        NavigationStack {
            Form {
                if capabilities == nil, ServerConfiguration.isConfigured {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(String(localized: "正在连接服务器…"))
                        }
                        .foregroundStyle(.secondary)
                    }
                } else if let caps = capabilities, caps.maintenance {
                    maintenanceSection
                } else {
                    Picker(String(localized: "方式"), selection: $mode) {
                        ForEach(modes) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .onChange(of: mode) { _, _ in form.clearError() }

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
                            passwordHint
                            if registrationMode == .inviteOnly {
                                TextField(
                                    String(localized: "邀请码"),
                                    text: $invitationCode
                                )
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            }
                        }
                        if let errorText = form.errorText {
                            AuthErrorText(message: errorText)
                        }
                        AuthActionButton(
                            title: mode == .signIn
                                ? String(localized: "登录")
                                : String(localized: "注册并获取验证码"),
                            isBusy: form.isBusy,
                            action: submit
                        )
                        .listRowBackground(Color.clear)
                    } header: {
                        Text(String(localized: "邮箱账号"))
                    } footer: {
                        if mode == .register {
                            Text(String(localized: "密码至少 10 位，支持中文与符号；不会以此判定相似内容。注册即表示同意用户协议与隐私政策。"))
                        }
                    }

                    if mode == .register {
                        Section {
                            Button(String(localized: "用户协议")) { showTerms = true }
                            Button(String(localized: "隐私政策")) { showPrivacy = true }
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

                    // Resume an interrupted registration (the app closed at
                    // the verification step): offer to continue verifying.
                    if mode == .signIn, let pending = session.pendingVerificationEmail {
                        Section {
                            Button {
                                email = pending
                                continueToVerification(email: pending)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(String(localized: "继续未完成的注册"))
                                        .font(.subheadline.weight(.medium))
                                    Text(String(localized: "\(pending) 的邮箱验证尚未完成。"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Button(String(localized: "放弃该注册"), role: .destructive) {
                                session.clearPendingVerification()
                            }
                            .font(.caption)
                        } footer: {
                            Text(String(localized: "验证成功后即可登录；放弃后需要重新注册。"))
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "邮箱登录"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "暂不登录")) { dismiss() }
                }
            }
            .scrollContentBackground(.hidden)
            .background(LTBackground())
            .navigationDestination(isPresented: $pushVerification) {
                EmailVerificationView(email: email.trimmingCharacters(in: .whitespaces))
            }
            .sheet(isPresented: $showTerms) { TermsSheet() }
            .sheet(isPresented: $showPrivacy) { PrivacySheet() }
            // Leaving the form drops everything sensitive from memory.
            .onDisappear {
                password = ""
                confirmPassword = ""
                invitationCode = ""
            }
        }
        .task { await loadCapabilities() }
    }

    private var maintenanceSection: some View {
        Section {
            Label(
                String(localized: "服务器维护中，暂无法注册或登录。请稍后再试。"),
                systemImage: "wrench.and.screwdriver"
            )
            .foregroundStyle(LTColors.warning)
        } header: {
            Text(String(localized: "邮箱账号"))
        }
    }

    /// Live password policy feedback (client mirror of the server rules).
    @ViewBuilder
    private var passwordHint: some View {
        if !password.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                hintRow(
                    ok: password.count >= 10,
                    text: String(localized: "至少 10 个字符")
                )
                hintRow(
                    ok: !AuthForm.isCommonPassword(password),
                    text: String(localized: "不是常见密码")
                )
                if !confirmPassword.isEmpty {
                    hintRow(
                        ok: password == confirmPassword,
                        text: String(localized: "两次输入一致")
                    )
                }
            }
            .font(.caption)
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func hintRow(ok: Bool, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ok ? LTColors.accentGreen : LTColors.textSecondary)
            Text(text)
                .foregroundStyle(ok ? LTColors.accentGreen : LTColors.textSecondary)
        }
    }

    private func loadCapabilities() async {
        guard ServerConfiguration.isConfigured, let baseURL = ServerConfiguration.baseURL else {
            return
        }
        do {
            let api = SyncAPIClient(baseURL: baseURL)
            let caps = try await api.capabilities()
            capabilities = caps
            // Keep the tab selection valid when 注册 disappears.
            if !caps.passwordLogin || caps.registrationMode == .disabled {
                mode = .signIn
            }
        } catch {
            // Fail closed: without a capabilities answer the register tab
            // stays hidden and sign-in still works.
            capabilities = SyncCapabilitiesDTO(
                registration: "disabled",
                requiresInvitation: false,
                passwordLogin: true,
                appleLogin: true,
                maintenance: false,
                minClientSchemaVersion: nil,
                maxClientSchemaVersion: nil
            )
        }
    }

    private func continueToVerification(email: String) {
        pushVerification = true
    }

    private func submit() {
        form.clearError()
        let email = email.trimmingCharacters(in: .whitespaces)
        guard !email.isEmpty, !password.isEmpty else {
            form.fail(String(localized: "请填写邮箱和密码"))
            return
        }
        if let problem = AuthForm.emailProblem(email) {
            form.fail(problem)
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
        guard form.begin() else { return }
        let password = password
        Task {
            defer { form.end() }
            do {
                try await session.signIn(label: email, provider: "email") { authSession in
                    try await authSession.signIn(email: email, password: password)
                }
                // Success: AppSession rebuilt the environment; this sheet's
                // tree is gone with the profile switch.
                session.clearPendingVerification()
                dismiss()
            } catch {
                form.fail(error: error)
            }
        }
    }

    private func register(email: String) {
        if let problem = AuthForm.newPasswordProblem(password)
            ?? AuthForm.confirmationProblem(password, confirmPassword) {
            form.fail(problem)
            return
        }
        if registrationMode == .inviteOnly
            && invitationCode.trimmingCharacters(in: .whitespaces).isEmpty {
            form.fail(String(localized: "当前为邀请制注册，请填写邀请码"))
            return
        }
        guard form.begin() else { return }
        let password = password
        let name = displayName.trimmingCharacters(in: .whitespaces)
        let code = invitationCode.trimmingCharacters(in: .whitespaces)
        Task {
            defer { form.end() }
            do {
                try await session.registerWithInvitation(
                    email: email, password: password, displayName: name, invitationCode: code
                )
                pushVerification = true
            } catch {
                form.fail(error: error)
            }
        }
    }
}

/// 用户协议 summary sheet (same tone as PrivacySheet).
struct TermsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    termsPoint(String(localized: "本应用提供课堂俄语转写与中文翻译。语音识别在本机完成，仅转写文字按你的配置参与云端同步或翻译。"))
                    termsPoint(String(localized: "注册账号时提供的信息（邮箱、昵称）仅用于账号体系与登录通知，不用于广告或第三方共享。"))
                    termsPoint(String(localized: "你可以随时删除云端副本或注销账号；删除后服务器端数据不可恢复。"))
                    termsPoint(String(localized: "请勿用本应用做违反当地法律法规的用途。"))
                }
                .padding()
            }
            .navigationTitle(String(localized: "用户协议"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "完成")) { dismiss() }
                }
            }
        }
    }

    private func termsPoint(_ text: String) -> some View {
        Label { Text(text).font(.subheadline) } icon: {
            Image(systemName: "doc.text").foregroundStyle(LTColors.accentBlue)
        }
    }
}
