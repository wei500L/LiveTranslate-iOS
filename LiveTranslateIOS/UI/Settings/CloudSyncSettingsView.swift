import SwiftUI
import AuthenticationServices

/// User-visible presentation of `CloudSyncPhase` — every state the spec
/// enumerates, mapped from the real service (never hardcoded in the UI).
extension CloudSyncPhase {
    var statusText: String {
        switch self {
        case .localOnly: return String(localized: "仅保存在本机")
        case .signedOut: return String(localized: "尚未登录")
        case .disabled: return String(localized: "同步已关闭")
        case .waitingForNetwork: return String(localized: "等待网络")
        case .waitingToSync: return String(localized: "等待同步")
        case .syncing: return String(localized: "正在同步")
        case .synced: return String(localized: "已同步")
        case .authExpired: return String(localized: "登录已过期")
        case .serverUnavailable: return String(localized: "服务器暂时不可用")
        case .partialFailure: return String(localized: "部分内容同步失败")
        case .updateRequired: return String(localized: "需要更新 App")
        case .cloudDeleted: return String(localized: "云端数据已删除")
        }
    }

    var tint: Color {
        switch self {
        case .localOnly, .signedOut, .disabled: return LTColors.textSecondary
        case .waitingForNetwork, .authExpired, .cloudDeleted: return LTColors.warning
        case .waitingToSync: return LTColors.accentBlue
        case .syncing: return LTColors.accentCyan
        case .synced: return LTColors.accentGreen
        case .serverUnavailable, .partialFailure, .updateRequired: return LTColors.destructive
        }
    }

    /// One-line explanation shown under the status row.
    var detailText: String {
        switch self {
        case .localOnly:
            return String(localized: "此构建未配置云端服务器地址，课堂记录仅保存在本机。")
        case .signedOut:
            return String(localized: "登录后可在你的设备间同步课堂记录。")
        case .disabled:
            return String(localized: "同步开关已关闭：新的记录不再上传，本机与云端数据均保留。")
        case .waitingForNetwork:
            return String(localized: "网络恢复后会自动继续同步，本机记录不受影响。")
        case .waitingToSync:
            return String(localized: "记录已在本机保存，将在联网时自动上传。")
        case .syncing:
            return String(localized: "正在与云端服务器交换数据…")
        case .synced:
            return String(localized: "本机与云端服务器一致。")
        case .authExpired:
            return String(localized: "登录已过期或已在其他设备注销，请重新登录。")
        case .serverUnavailable:
            return String(localized: "云端服务器暂时无法连接，稍后会自动重试。")
        case .partialFailure:
            return String(localized: "部分记录同步失败，可点击“立即同步”重试。")
        case .updateRequired:
            return String(localized: "此 App 版本过旧，无法与云端服务器同步，请更新 App。")
        case .cloudDeleted:
            return String(localized: "云端副本已删除，本机记录保留。重新登录或重新开启同步后会重新上传。")
        }
    }
}

/// 云端同步 settings page: Sign in with Apple, sync toggle, live status
/// from `CloudSyncService`, manual sync, data-scope explanation and the
/// two destructive cloud actions. Everything reads the real service —
/// nothing here fabricates a status.
struct CloudSyncSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var loginError: String?
    @State private var isSigningIn = false
    @State private var showDeleteCloudConfirm = false
    @State private var showDeleteAccountConfirm = false
    #if DEBUG
    @State private var devName = ""
    #endif

    var body: some View {
        Form {
            if let sync = environment.cloudSync {
                accountSection(sync)
                syncSection(sync)
                scopeSection
                dangerSection(sync)
                #if DEBUG
                devSection(sync)
                #endif
            } else {
                unconfiguredSection
            }
        }
        .navigationTitle(String(localized: "云端同步"))
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(LTBackground())
    }

    // MARK: - Account

    @ViewBuilder
    private func accountSection(_ sync: CloudSyncService) -> some View {
        Section {
            if sync.isSignedIn {
                HStack(spacing: 14) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(LTColors.accentBlue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sync.accountLabel ?? String(localized: "已登录"))
                            .font(.headline)
                        Text(String(localized: "通过 Apple 登录你的私人云端"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Button(String(localized: "退出登录"), role: .destructive) {
                    Task { await sync.signOut() }
                }
            } else {
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.fullName]
                } onCompletion: { result in
                    handleAppleSignIn(result, service: sync)
                }
                .signInWithAppleButtonStyle(.white)
                .frame(height: 44)
                .disabled(isSigningIn)
                if isSigningIn {
                    HStack(spacing: 6) {
                        ProgressView()
                        Text(String(localized: "正在登录…"))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Text(String(localized: "使用 Apple 账号登录你的云端服务器。App 不收集邮箱，也不上传任何 Apple 个人信息。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let loginError {
                Text(loginError)
                    .font(.caption)
                    .foregroundStyle(LTColors.destructive)
            }
            if sync.phase == .authExpired {
                Text(String(localized: "登录已过期，请重新登录。"))
                    .font(.caption)
                    .foregroundStyle(LTColors.warning)
            }
        } header: {
            Text(String(localized: "Account"))
        }
    }

    private func handleAppleSignIn(
        _ result: Result<ASAuthorization, Error>, service: CloudSyncService
    ) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let token = String(data: tokenData, encoding: .utf8) else {
                loginError = String(localized: "无法从 Apple 获取登录凭据")
                return
            }
            isSigningIn = true
            Task {
                defer { isSigningIn = false }
                do {
                    try await service.signInWithApple(identityToken: token)
                    loginError = nil
                } catch {
                    loginError = (error as? SyncAPIError)?.localizedDescription
                        ?? String(localized: "登录失败")
                }
            }
        case .failure(let error):
            // ASAuthorization errors (cancelled, not entitled…) — shown as
            // given; the token never existed.
            loginError = error.localizedDescription
        }
    }

    // MARK: - Sync status & controls

    private func syncSection(_ sync: CloudSyncService) -> some View {
        Section {
            Toggle(isOn: syncEnabledBinding(sync)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "同步课堂记录"))
                    Text(String(localized: "关闭后新记录仅保存在本机，云端数据保留。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!sync.isSignedIn)

            HStack {
                Text(String(localized: "同步状态"))
                Spacer()
                if sync.isSyncing {
                    ProgressView().padding(.trailing, 6)
                }
                StatusChip(text: sync.phase.statusText, tint: sync.phase.tint)
            }
            Text(sync.phase.detailText)
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledRow(
                label: String(localized: "上次成功同步"),
                value: sync.lastSuccessfulSync.map { relativeTime($0) }
                    ?? String(localized: "从未")
            )
            if sync.pendingUploadCount > 0 {
                LabeledRow(
                    label: String(localized: "待上传记录"),
                    value: "\(sync.pendingUploadCount)"
                )
            }
            if let host = ServerConfiguration.baseURL?.host {
                LabeledRow(label: String(localized: "云端服务器"), value: host)
            }

            Button(String(localized: "立即同步")) {
                sync.syncNow()
            }
            .disabled(!sync.isSignedIn || !sync.isSyncEnabled || sync.isSyncing)

            if let error = sync.lastError {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(LTColors.destructive)
                    Button(String(localized: "重试")) {
                        sync.syncNow()
                    }
                    .font(.caption)
                }
            }
        } header: {
            Text(String(localized: "Sync"))
        } footer: {
            Text(String(localized: "同步失败只影响云端备份，不影响本机的转写与翻译。"))
        }
    }

    private func syncEnabledBinding(_ sync: CloudSyncService) -> Binding<Bool> {
        Binding(
            get: { sync.isSyncEnabled },
            set: { sync.isSyncEnabled = $0 }
        )
    }

    // MARK: - Data scope

    /// What is and is not uploaded — stated plainly. HTTPS is transport
    /// security only; the app does not claim end-to-end encryption.
    private var scopeSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                scopePoint(
                    icon: "checkmark.circle.fill", tint: LTColors.accentGreen,
                    text: String(localized: "上传：课堂记录文字（俄语原文与中文翻译）、标题与时间、书签与收藏。")
                )
                scopePoint(
                    icon: "nosign", tint: LTColors.destructive,
                    text: String(localized: "不上传：语音音频、识别模型、翻译 API 密钥、导出文件。")
                )
                scopePoint(
                    icon: "lock.shield", tint: LTColors.textSecondary,
                    text: String(localized: "数据经 HTTPS 传输并存储在你的云端服务器上；服务器管理员可以访问内容，本应用不提供端到端加密。")
                )
            }
            .padding(.vertical, 4)
        } header: {
            Text(String(localized: "数据范围"))
        }
    }

    private func scopePoint(icon: String, tint: Color, text: String) -> some View {
        Label {
            Text(text).font(.caption)
        } icon: {
            Image(systemName: icon).foregroundStyle(tint)
        }
    }

    // MARK: - Destructive actions

    private func dangerSection(_ sync: CloudSyncService) -> some View {
        Section {
            Button(String(localized: "删除云端副本"), role: .destructive) {
                showDeleteCloudConfirm = true
            }
            .disabled(!sync.isSignedIn)
            Button(String(localized: "删除账号"), role: .destructive) {
                showDeleteAccountConfirm = true
            }
            .disabled(!sync.isSignedIn)
        } header: {
            Text(String(localized: "云端数据"))
        } footer: {
            Text(String(localized: "删除云端副本只清除服务器上的数据，本机记录保留。删除账号会同时清除云端数据并注销本机登录。"))
        }
        .confirmationDialog(
            String(localized: "删除云端服务器上的全部课堂记录、书签与收藏？"),
            isPresented: $showDeleteCloudConfirm,
            titleVisibility: .visible
        ) {
            Button(String(localized: "删除云端副本"), role: .destructive) {
                Task { await sync.deleteCloudData() }
            }
        }
        .confirmationDialog(
            String(localized: "删除账号将清除云端全部数据并注销本机登录，此操作不可撤销。"),
            isPresented: $showDeleteAccountConfirm,
            titleVisibility: .visible
        ) {
            Button(String(localized: "删除账号"), role: .destructive) {
                Task { await sync.deleteAccount() }
            }
        }
    }

    // MARK: - No server configured

    private var unconfiguredSection: some View {
        Section {
            HStack {
                Text(String(localized: "同步状态"))
                Spacer()
                StatusChip(
                    text: CloudSyncPhase.localOnly.statusText,
                    tint: CloudSyncPhase.localOnly.tint
                )
            }
            Text(String(localized: "此构建未配置云端服务器地址，课堂记录仅保存在本机。语音识别与翻译不受任何影响。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text(String(localized: "Sync"))
        }
    }

    #if DEBUG
    // MARK: - Development sign-in (Debug builds only)

    /// Debug-only login against a local server started with
    /// DEV_LOGIN_ENABLED=true. Never compiled into Release builds and the
    /// server rejects it by default — it cannot serve as production auth.
    private func devSection(_ sync: CloudSyncService) -> some View {
        Section {
            TextField(String(localized: "开发登录名（仅调试）"), text: $devName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(String(localized: "开发登录")) {
                Task {
                    do {
                        try await sync.devSignIn(devName: devName)
                        loginError = nil
                    } catch {
                        loginError = (error as? SyncAPIError)?.localizedDescription
                            ?? String(localized: "开发登录失败")
                    }
                }
            }
            .disabled(devName.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: {
            Text(String(localized: "Development"))
        } footer: {
            Text(String(localized: "仅 Debug 构建可见：连接 DEV_LOGIN_ENABLED 的本地服务器，不适用于生产环境。"))
        }
    }
    #endif

    // MARK: - Formatting

    private func relativeTime(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }
}
