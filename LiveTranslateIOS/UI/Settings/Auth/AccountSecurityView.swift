import SwiftUI
import AuthenticationServices

/// 账号与安全: the signed-in account's full profile — identity, sign-in
/// methods, session counts — and every account-level action (change display
/// name / email / password, Apple bind/unbind, sign out, delete). All state
/// comes from the server (GET /v1/me); nothing here fabricates a value.
struct AccountSecurityView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSession.self) private var session

    @State private var profile: SyncMeProfileDTO?
    @State private var errorText: String?
    @State private var isBusy = false
    @State private var showDisplayNameEdit = false
    @State private var showChangeEmail = false
    @State private var showUnbindApple = false
    @State private var unbindPassword = ""
    @State private var showSignOutAllConfirm = false

    private var sync: CloudSyncService? { environment.cloudSync }

    var body: some View {
        Form {
            if let errorText {
                Section { AuthErrorText(message: errorText) }
            }
            if let profile {
                identitySection(profile)
                signInMethodsSection(profile)
                sessionsSection(profile)
                securityActionsSection
                dangerSection
            } else if isBusy {
                Section {
                    HStack {
                        ProgressView()
                        Text(String(localized: "正在加载…"))
                    }
                }
            }
        }
        .navigationTitle(String(localized: "账号与安全"))
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(LTBackground())
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $showDisplayNameEdit) {
            if let profile {
                DisplayNameEditView(current: profile.displayName ?? "")
            }
        }
        .sheet(isPresented: $showChangeEmail) {
            ChangeEmailView(currentEmail: profile?.email)
        }
        .sheet(isPresented: $showUnbindApple) { unbindSheet }
        .confirmationDialog(
            String(localized: "退出所有设备？本机也会退出登录。"),
            isPresented: $showSignOutAllConfirm,
            titleVisibility: .visible
        ) {
            Button(String(localized: "退出所有设备"), role: .destructive) {
                Task { await signOutAll() }
            }
        }
    }

    // MARK: - Identity

    private func identitySection(_ profile: SyncMeProfileDTO) -> some View {
        Section {
            LabeledRow(
                label: String(localized: "显示名称"),
                value: profile.displayName?.isEmpty == false
                    ? profile.displayName! : String(localized: "未设置")
            )
            Button(String(localized: "修改显示名称")) { showDisplayNameEdit = true }
            if let email = profile.email, !email.isEmpty {
                LabeledRow(label: String(localized: "登录邮箱"), value: email)
                LabeledRow(
                    label: String(localized: "邮箱验证状态"),
                    value: profile.emailVerified == true
                        ? String(localized: "已验证") : String(localized: "未验证")
                )
                Button(String(localized: "修改登录邮箱")) { showChangeEmail = true }
            } else {
                LabeledRow(
                    label: String(localized: "登录邮箱"),
                    value: String(localized: "（Apple / 开发者账号）")
                )
            }
        } header: {
            Text(String(localized: "账号资料"))
        } footer: {
            Text(String(localized: "修改邮箱需要验证新邮箱并重新输入当前密码；验证完成前原邮箱保持有效。"))
        }
    }

    // MARK: - Sign-in methods

    private func signInMethodsSection(_ profile: SyncMeProfileDTO) -> some View {
        Section {
            LabeledRow(
                label: String(localized: "密码登录"),
                value: profile.hasPassword == true
                    ? String(localized: "已启用") : String(localized: "未设置")
            )
            if profile.hasPassword == true {
                NavigationLink(String(localized: "修改密码")) {
                    ChangePasswordView()
                }
            }
            if profile.appleBound == true {
                LabeledRow(
                    label: String(localized: "Apple 账号"),
                    value: String(localized: "已绑定")
                )
                if profile.hasPassword == true {
                    Button(String(localized: "解绑 Apple 账号"), role: .destructive) {
                        unbindPassword = ""
                        showUnbindApple = true
                    }
                } else {
                    Text(String(localized: "当前仅剩 Apple 登录方式，无法解绑。请先设置密码。"))
                        .font(.caption)
                        .foregroundStyle(LTColors.warning)
                }
            } else {
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.fullName]
                } onCompletion: { result in
                    handleAppleBind(result)
                }
                .signInWithAppleButtonStyle(.white)
                .frame(height: 44)
                .disabled(isBusy)
                Text(String(localized: "绑定后可以用 Apple 账号在本 App 登录同一账号。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(String(localized: "登录方式"))
        } footer: {
            Text(String(localized: "至少保留一种登录方式：解绑 Apple 前需要先设置密码。"))
        }
    }

    // MARK: - Sessions

    private func sessionsSection(_ profile: SyncMeProfileDTO) -> some View {
        Section {
            LabeledRow(
                label: String(localized: "本机设备"),
                value: ServerConfiguration.deviceDisplayName
            )
            LabeledRow(
                label: String(localized: "已登录设备"),
                value: "\(profile.deviceCount ?? 0)"
            )
            LabeledRow(
                label: String(localized: "活跃会话"),
                value: "\(profile.liveSessions ?? 0)"
            )
            LabeledRow(
                label: String(localized: "上次登录"),
                value: profile.lastLoginAt.map { relativeTime($0) } ?? String(localized: "—")
            )
            LabeledRow(
                label: String(localized: "上次云端同步"),
                value: sync?.lastSuccessfulSync.map { relativeTime($0) } ?? String(localized: "从未")
            )
            NavigationLink(String(localized: "管理登录设备")) {
                DeviceManagementView()
            }
        } header: {
            Text(String(localized: "设备与会话"))
        }
    }

    // MARK: - Actions

    private var securityActionsSection: some View {
        Section {
            Button(String(localized: "退出当前账号"), role: .destructive) {
                Task { await session.signOutCurrentAccount() }
            }
            Button(String(localized: "退出所有设备"), role: .destructive) {
                showSignOutAllConfirm = true
            }
            .disabled(isBusy)
        } header: {
            Text(String(localized: "安全操作"))
        }
    }

    private var dangerSection: some View {
        Section {
            NavigationLink(String(localized: "删除云端副本 / 删除账号")) {
                CloudSyncSettingsView()
            }
            .foregroundStyle(LTColors.destructive)
        } header: {
            Text(String(localized: "危险区"))
        } footer: {
            Text(String(localized: "删除云端副本与删除账号入口在「云端同步」页。"))
        }
    }

    // MARK: - Unbind sheet

    private var unbindSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Text(String(localized: "解绑后将无法使用 Apple 账号登录，密码登录不受影响。"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    AuthPasswordField(
                        text: $unbindPassword,
                        prompt: String(localized: "当前密码")
                    )
                    if let errorText {
                        AuthErrorText(message: errorText)
                    }
                    AuthActionButton(
                        title: String(localized: "确认解绑"),
                        isBusy: isBusy,
                        action: unbindApple
                    )
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle(String(localized: "解绑 Apple"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) { showUnbindApple = false }
                }
            }
            .scrollContentBackground(.hidden)
            .background(LTBackground())
        }
        .presentationDetents([.medium])
    }

    // MARK: - Actions

    private func load() async {
        guard let sync else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            profile = try await sync.meProfile()
            errorText = nil
        } catch {
            errorText = AuthForm.message(for: error)
        }
    }

    private func handleAppleBind(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let token = String(data: tokenData, encoding: .utf8) else {
                errorText = String(localized: "无法从 Apple 获取身份凭据")
                return
            }
            isBusy = true
            Task {
                defer { isBusy = false }
                do {
                    try await sync?.bindApple(identityToken: token)
                    await load()
                } catch {
                    errorText = AuthForm.message(for: error)
                }
            }
        case .failure(let error):
            errorText = error.localizedDescription
        }
    }

    private func unbindApple() {
        guard let sync else { return }
        guard !unbindPassword.isEmpty else {
            errorText = String(localized: "请输入当前密码")
            return
        }
        isBusy = true
        let password = unbindPassword
        Task {
            defer { isBusy = false }
            do {
                try await sync.unbindApple(currentPassword: password)
                showUnbindApple = false
                unbindPassword = ""
                await load()
            } catch {
                errorText = AuthForm.message(for: error)
            }
        }
    }

    private func signOutAll() async {
        guard let sync else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await sync.logoutAllDevices()
        } catch {
            errorText = AuthForm.message(for: error)
        }
    }

    private func relativeTime(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }
}

// MARK: - Display name editor

/// PATCH /v1/me editor: length-capped, whitespace-collapsed, updates the
/// local account entry on success (the account switcher shows the name).
struct DisplayNameEditView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State var current: String
    @State private var name = ""
    @State private var errorText: String?
    @State private var isBusy = false

    private let maxLength = 64

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "显示名称"), text: $name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: name) { _, newValue in
                            if newValue.count > maxLength {
                                name = String(newValue.prefix(maxLength))
                            }
                        }
                    Text(String(localized: "\(name.count)/\(maxLength)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let errorText {
                        AuthErrorText(message: errorText)
                    }
                    AuthActionButton(
                        title: String(localized: "保存"),
                        isBusy: isBusy,
                        action: save
                    )
                    .listRowBackground(Color.clear)
                } footer: {
                    Text(String(localized: "名称会显示在账号列表中。连续空格会自动合并。"))
                }
            }
            .navigationTitle(String(localized: "修改显示名称"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) { dismiss() }
                }
            }
            .scrollContentBackground(.hidden)
            .background(LTBackground())
        }
        .presentationDetents([.medium])
        .onAppear {
            if name.isEmpty { name = current }
        }
    }

    private func save() {
        guard let sync = environment.cloudSync else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorText = String(localized: "显示名称不能为空")
            return
        }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                _ = try await sync.updateDisplayName(trimmed)
                if let accountID = session.accounts.activeAccountID {
                    session.accounts.updateDisplayName(id: accountID, displayName: trimmed)
                }
                dismiss()
            } catch {
                errorText = AuthForm.message(for: error)
            }
        }
    }
}
