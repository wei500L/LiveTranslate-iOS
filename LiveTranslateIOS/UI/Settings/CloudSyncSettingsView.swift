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
    @Environment(AppSession.self) private var session

    @State private var loginError: String?
    @State private var isSigningIn = false
    @State private var showDeleteCloudConfirm = false
    @State private var showDeleteAccountConfirm = false
    @State private var showAddAccount = false
    @State private var switchBlockedText: String?
    @State private var showGuestMigrationChoice = false
    @State private var showDeleteGuestCopyConfirm = false
    #if DEBUG
    @State private var devName = ""
    #endif

    var body: some View {
        Form {
            if let sync = environment.cloudSync {
                accountSection(sync)
                accountSwitcherSection
                guestMigrationSection
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
        .onAppear {
            // First sign-in with guest data present → the choice prompt.
            if let migration = environment.guestMigration, migration.needsPrompt {
                showGuestMigrationChoice = true
            }
        }
        .sheet(isPresented: $showGuestMigrationChoice) {
            guestMigrationChoiceSheet
        }
        .alert(
            String(localized: "暂时无法切换账号"),
            isPresented: Binding(
                get: { switchBlockedText != nil },
                set: { if !$0 { switchBlockedText = nil } }
            )
        ) {
            Button(String(localized: "好"), role: .cancel) { switchBlockedText = nil }
        } message: {
            Text(switchBlockedText ?? "")
        }
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
                        Text(currentAccountTitle)
                            .font(.headline)
                        Text(providerCaption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                NavigationLink(String(localized: "账号与安全")) {
                    AccountSecurityView()
                }
                NavigationLink(String(localized: "登录设备")) {
                    DeviceManagementView()
                }
                if currentProvider == "email" {
                    NavigationLink(String(localized: "修改密码")) {
                        ChangePasswordView()
                    }
                }
                Button(String(localized: "退出登录"), role: .destructive) {
                    Task { await session.signOutCurrentAccount() }
                }
            } else {
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.fullName]
                } onCompletion: { result in
                    handleAppleSignIn(result)
                }
                .signInWithAppleButtonStyle(.white)
                .frame(height: 44)
                .disabled(isSigningIn)
                Button {
                    showAddAccount = true
                } label: {
                    VStack(spacing: 4) {
                        Text(String(localized: "使用邮箱登录 / 注册"))
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isSigningIn)
                if isSigningIn {
                    HStack(spacing: 6) {
                        ProgressView()
                        Text(String(localized: "正在登录…"))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Text(String(localized: "支持多个账号：各账号的记录、书签与云端数据完全隔离，可随时在下方切换。App 不保存密码。"))
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
        .sheet(isPresented: $showAddAccount) {
            AccountAuthView()
        }
    }

    private var currentProvider: String? {
        if case .account(let account) = session.accounts.activeProfile {
            return account.provider
        }
        return nil
    }

    /// Title for the signed-in header: the account's display name when set,
    /// else the label the sync service fetched.
    private var currentAccountTitle: String {
        if case .account(let account) = session.accounts.activeProfile,
           let name = account.displayName, !name.isEmpty {
            return name
        }
        return syncTitleFallback
    }

    private var syncTitleFallback: String {
        environment.cloudSync?.accountLabel ?? String(localized: "已登录")
    }

    private var providerCaption: String {
        switch currentProvider {
        case "email": return String(localized: "邮箱账号 · 私人云端")
        case "apple": return String(localized: "通过 Apple 登录你的私人云端")
        default: return String(localized: "私人云端")
        }
    }

    private func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) {
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
                    try await session.signIn(label: "Apple 账号", provider: "apple") {
                        try await $0.signInWithApple(identityToken: token)
                    }
                    loginError = nil
                } catch {
                    loginError = AuthForm.message(for: error)
                }
            }
        case .failure(let error):
            // ASAuthorization errors (cancelled, not entitled…) — shown as
            // given; the token never existed.
            loginError = error.localizedDescription
        }
    }

    // MARK: - Account switcher (multi-account isolation)

    /// 本机模式 (guest) 与所有本地账号。切换会整体重建数据视图：各账号
    /// 的记录、书签、待上传队列与游标完全隔离。课堂进行中或访客数据
    /// 迁移进行中时切换入口被禁用并说明原因。
    private var accountSwitcherSection: some View {
        Section {
            if session.accounts.accounts.isEmpty {
                Text(String(localized: "当前为本机模式：记录仅保存在这台设备上。登录后可建立独立云端空间。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(session.accounts.accounts) { account in
                    accountRow(account)
                }
            }
            if session.accounts.activeAccountID != nil {
                Button(String(localized: "切换到本机模式（不登录）")) {
                    attemptSwitch { session.switchToGuest() }
                }
                .disabled(switchBlockerText != nil)
            }
            Button {
                showAddAccount = true
            } label: {
                Label(String(localized: "添加账号"), systemImage: "plus.circle")
            }
            if let blocker = switchBlockerText {
                // Visible reason while the entries above are disabled.
                Label(blocker, systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(LTColors.warning)
            }
        } header: {
            Text(String(localized: "账号"))
        } footer: {
            Text(String(localized: "每个账号的数据相互独立且互不可见；移除账号只清掉它在本机的数据，云端数据不受影响。"))
        }
    }

    /// The blocker explanation for the CURRENT state, nil when switching is
    /// allowed. (The alert path remains for a race: the block can appear
    /// between render and tap.)
    private var switchBlockerText: String? {
        switch session.switchBlocker() {
        case .classroomActive:
            return String(localized: "课堂正在进行中，暂时无法切换账号。请先结束当前课堂。")
        case .guestMigrationInProgress:
            return String(localized: "本机数据迁移进行中，请等待完成后再切换账号。")
        case nil:
            return nil
        }
    }

    /// Guarded switch wrapper: a live classroom or in-flight guest
    /// migration blocks the switch with an explanation instead of a silent
    /// no-op.
    private func attemptSwitch(_ action: () -> Bool) {
        if action() { return }
        switch session.switchBlocker() {
        case .classroomActive:
            switchBlockedText = String(localized: "课堂正在进行中，无法切换账号。请先结束当前课堂再切换。")
        case .guestMigrationInProgress:
            switchBlockedText = String(localized: "本机数据迁移正在进行中，请等待完成后再切换账号。")
        case nil:
            break
        }
    }

    @ViewBuilder
    private func accountRow(_ account: LocalAccount) -> some View {
        let isActive = session.accounts.activeAccountID == account.id
        Button {
            if !isActive {
                attemptSwitch { session.switchToAccount(account.id) }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.displayTitle)
                        .foregroundStyle(.primary)
                    Text(account.provider == "email"
                        ? String(localized: "邮箱账号")
                        : account.provider == "apple"
                            ? String(localized: "Apple 账号")
                            : String(localized: "开发者账号"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(LTColors.accentGreen)
                }
            }
        }
        .disabled(switchBlockerText != nil)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                Task { await session.removeAccount(account.id, revokeTokens: true) }
            } label: {
                Label(String(localized: "移除"), systemImage: "trash")
            }
        }
    }

    // MARK: - Guest data migration (本机记录待归属)

    /// The signed-in account's guest-migration status. Hidden entirely for
    /// the guest profile (nothing to migrate into itself).
    @ViewBuilder
    private var guestMigrationSection: some View {
        if let migration = environment.guestMigration {
            switch migration.record.phase {
            case .waiting, .preparing, .moving, .partiallyFailed:
                Section {
                    if migration.isRunning {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(migration.statusText)
                        }
                    } else {
                        Text(String(localized: "本机还有 \(migration.guestSessionCount()) 节未归属的访客记录。"))
                            .font(.subheadline)
                        Button(String(localized: "处理本机记录…")) {
                            if migration.needsPrompt {
                                showGuestMigrationChoice = true
                            } else {
                                migration.reopen()
                                showGuestMigrationChoice = true
                            }
                        }
                        if migration.record.phase == .partiallyFailed {
                            if !migration.record.failedSessionIDs.isEmpty {
                                Text(String(localized: "上次迁移有 \(migration.record.failedSessionIDs.count) 节复制失败（可重试，仅重试失败部分）。"))
                                    .font(.caption)
                                    .foregroundStyle(LTColors.warning)
                            }
                            if !migration.record.conflictedSessionIDs.isEmpty {
                                Text(String(localized: "\(migration.record.conflictedSessionIDs.count) 节与账号中已有记录的编号冲突，已跳过且未覆盖；请在课堂记录中核对。"))
                                    .font(.caption)
                                    .foregroundStyle(LTColors.warning)
                            }
                        }
                    }
                } header: {
                    Text(String(localized: "本机数据"))
                } footer: {
                    Text(String(localized: "登录前的本机记录不会被自动上传；由你决定是否并入当前账号。"))
                }
            case .queuedForUpload:
                Section {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(migration.statusText)
                    }
                } header: {
                    Text(String(localized: "本机数据"))
                }
            case .completed:
                Section {
                    Label(
                        String(localized: "本机记录已并入当前账号。"),
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(LTColors.accentGreen)
                    Button(String(localized: "删除本机（访客）副本"), role: .destructive) {
                        showDeleteGuestCopyConfirm = true
                    }
                } header: {
                    Text(String(localized: "本机数据"))
                } footer: {
                    Text(String(localized: "副本已上传到云端并保存在当前账号中；删除本机副本不影响云端与当前账号数据。"))
                }
                .confirmationDialog(
                    String(localized: "删除本机的访客记录副本？此操作不可撤销，云端与当前账号数据不受影响。"),
                    isPresented: $showDeleteGuestCopyConfirm,
                    titleVisibility: .visible
                ) {
                    Button(String(localized: "删除本机副本"), role: .destructive) {
                        migration.deleteGuestCopy()
                    }
                }
            case .declined:
                EmptyView()
            }
        }
    }

    /// The first-login choice: upload & join / keep local-only / later.
    private var guestMigrationChoiceSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Text(String(localized: "检测到登录前的本机课堂记录。要如何处理？"))
                        .font(.subheadline)
                    if let migration = environment.guestMigration {
                        Button {
                            showGuestMigrationChoice = false
                            migration.beginMigration()
                        } label: {
                            Label(
                                String(localized: "上传并加入当前账号"),
                                systemImage: "icloud.and.arrow.up"
                            )
                        }
                        Button {
                            showGuestMigrationChoice = false
                            migration.decline()
                        } label: {
                            Label(
                                String(localized: "继续仅保存在本机"),
                                systemImage: "iphone"
                            )
                        }
                        Button {
                            showGuestMigrationChoice = false
                        } label: {
                            Label(
                                String(localized: "稍后处理"),
                                systemImage: "clock"
                            )
                        }
                    }
                } footer: {
                    Text(String(localized: "上传会保留原始记录并沿用原编号，随时可以在「本机数据」中重试；不会自动删除本机记录。"))
                }
            }
            .navigationTitle(String(localized: "本机记录"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "稍后处理")) { showGuestMigrationChoice = false }
                }
            }
            .scrollContentBackground(.hidden)
            .background(LTBackground())
        }
        .presentationDetents([.medium])
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
            if sync.remoteUpdatesPending {
                LabeledRow(
                    label: String(localized: "云端有未拉取的变更记录"),
                    value: String(localized: "待同步")
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
                Task {
                    if await sync.deleteAccount() {
                        await session.handleServerAccountDeleted()
                    }
                }
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
                        let name = devName.trimmingCharacters(in: .whitespaces)
                        try await session.signIn(label: "dev:\(name)", provider: "dev") {
                            try await $0.devSignIn(devName: name)
                        }
                        loginError = nil
                    } catch {
                        loginError = AuthForm.message(for: error)
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
