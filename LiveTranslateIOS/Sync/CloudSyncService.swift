import Foundation
import Network
import OSLog

/// User-visible cloud-sync state. Derived from the real service — the UI
/// never hardcodes 已同步.
enum CloudSyncPhase: Equatable, Sendable {
    case localOnly          // 服务器未配置（该构建无云端地址）
    case signedOut          // 尚未登录
    case disabled           // 已登录但同步开关关闭：仅保存在本机
    case waitingForNetwork  // 等待网络
    case waitingToSync      // 等待同步（有待上传项）
    case syncing            // 正在同步
    case synced             // 已同步
    case authExpired        // 登录已过期
    case serverUnavailable  // 服务器暂时不可用
    case partialFailure     // 部分内容同步失败
    case updateRequired     // 需要更新 App
    case cloudDeleted       // 云端数据已删除
}

/// Composition-root facade for the private-server sync system.
///
/// Lifetime: one instance per app (owned by `AppEnvironment`), never per
/// screen. SwiftData reads/writes happen on the main actor; everything
/// crossing to the network layer is an immutable `SyncDTO` value.
@MainActor
@Observable
final class CloudSyncService: AuthenticationService {
    private static let logger = Logger(
        subsystem: "com.livetranslate.ios", category: "cloud-sync"
    )

    // MARK: - Dependencies

    let api: SyncAPIClient
    let authSession: ServerAuthSession
    let outbox: SyncOutboxStore
    let cursorStore: SyncCursorStore
    private let repository: any ClassroomRepositoryProtocol
    private let bookmarks: BookmarkStore
    private let defaults: UserDefaults

    // MARK: - Observable state (UI)

    private(set) var phase: CloudSyncPhase = .localOnly
    private(set) var isSyncing = false
    private(set) var pendingUploadCount = 0
    private(set) var lastSuccessfulSync: Date?
    private(set) var lastError: String?
    private(set) var isNetworkAvailable = true
    /// True when the server's change-log tail is AHEAD of the local pull
    /// cursor (远端有未拉取的变更记录). This is a CURSOR comparison, not a
    /// content claim: the pending entries may be echoes of this device's
    /// own pushes — the UI words it neutrally for exactly that reason.
    /// Updated after every completed sync via /sync/status.
    private(set) var remoteUpdatesPending = false

    var isServerConfigured: Bool { true }

    /// Synchronous sign-in state for the UI (backed by keychain tokens;
    /// refreshed asynchronously at init and after auth transitions). The
    /// next request verifies the token is still valid.
    private(set) var isSignedIn = false
    private(set) var accountLabel: String?
    private(set) var cloudDeletedRecently = false

    // MARK: - Run state

    private var syncTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var periodicTask: Task<Void, Never>?
    private let pathMonitor = NWPathMonitor()
    private var initialUploadKey = "cloudsync.initialUploadDone"

    // MARK: - Init

    /// The local account this service syncs for. Nil = the guest/local-only
    /// profile (sign-in state then lives in the legacy unscoped keys, only
    /// used by the one-time migration).
    let accountID: UUID?

    init(
        baseURL: URL,
        keychain: any KeychainStoring,
        repository: any ClassroomRepositoryProtocol,
        bookmarks: BookmarkStore,
        defaults: UserDefaults = .standard,
        outboxFileURL: URL? = nil,
        accountID: UUID? = nil
    ) {
        self.accountID = accountID
        let scope = accountID.map { AccountScope.keychainScope(accountID: $0) } ?? ""
        self.api = SyncAPIClient(baseURL: baseURL)
        self.authSession = ServerAuthSession(api: api, keychain: keychain, scope: scope)
        self.outbox = SyncOutboxStore(fileURL: outboxFileURL)
        self.cursorStore = SyncCursorStore(defaults: defaults)
        self.repository = repository
        self.bookmarks = bookmarks
        self.defaults = defaults
        self.lastSuccessfulSync = cursorStore.lastSuccessfulSync
        self.cloudDeletedRecently = cursorStore.cloudDeletedAt != nil

        // Observe local mutations → enqueue outbox operations.
        repository.mutationObserver = self
        bookmarks.syncObserver = { [weak self] change in
            self?.bookmarkStoreChanged(change)
        }

        startNetworkMonitoring()
        Task { await refreshSignInState() }
    }

    deinit {
        pathMonitor.cancel()
    }

    /// Tears the service down before an account switch releases it: stop
    /// timers, detach observers. After this the service is inert.
    func shutdown() {
        periodicTask?.cancel()
        periodicTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        syncTask?.cancel()
        syncTask = nil
        attachmentUploadTask?.cancel()
        attachmentUploadTask = nil
        pathMonitor.cancel()
        repository.mutationObserver = nil
        bookmarks.syncObserver = nil
    }

    // MARK: - AuthenticationService
    // (Fresh sign-ins — Apple, email, register+verify — run through
    // AppSession's transient session so tokens land in the right account
    // scope; this service only manages the CURRENT profile's session.)

    #if DEBUG
    /// Debug-only development login against a DEV_LOGIN_ENABLED server.
    /// Never compiled into Release; cannot serve as production auth.
    func devSignIn(devName: String) async throws {
        _ = try await authSession.devSignIn(devName: devName)
        await completeSignIn()
    }
    #endif

    /// Shared post-sign-in flow: refresh observable state, fetch the
    /// account label and kick off the first sync. Also called by
    /// `AppSession` after a profile rebuild following a fresh sign-in.
    func completeSignIn() async {
        await refreshSignInState()
        cursorStore.cloudDeletedAt = nil
        cloudDeletedRecently = false
        accountLabel = nil
        // A fresh sign-in validates the account server-side.
        do {
            let me: SyncMeDTO = try await authSession.authorize { [api] token in
                try await api.me(accessToken: token)
            }
            accountLabel = me.displayLabel
        } catch {
            // Non-fatal: the token pair is already stored.
        }
        phase = cursorStore.isSyncEnabled ? .waitingToSync : .disabled
        scheduleInitialUploadIfNeeded()
        scheduleSync(after: 1)
    }

    func signOut() async {
        await authSession.signOut()
        await refreshSignInState()
        phase = .signedOut
        pendingUploadCount = await outbox.pendingCount
    }

    // MARK: - Account management (current profile)

    /// Change the current account's password. Requires the current one;
    /// the server signs out every OTHER device.
    func changePassword(current: String, new: String) async throws {
        try await authSession.changePassword(current: current, new: new)
    }

    /// The current account's device sessions (this device marked current).
    func listDevices() async throws -> [SyncDeviceSessionDTO] {
        try await authSession.authorize { [api] token in
            try await api.listDevices(accessToken: token)
        }
    }

    // MARK: - Account profile (账号与安全)

    /// The enriched profile (email, verification, sign-in methods, counts).
    func meProfile() async throws -> SyncMeProfileDTO {
        try await authSession.authorize { [api] token in
            try await api.meProfile(accessToken: token)
        }
    }

    /// Update the display name server-side (PATCH /v1/me). The caller (the
    /// account UI) updates the local account entry from the response.
    func updateDisplayName(_ name: String) async throws -> SyncPublicUserDTO {
        try await authSession.authorize { [api] token in
            try await api.updateDisplayName(name, accessToken: token)
        }
    }

    /// Step 1 of the login-email change: re-auth + code to the NEW address.
    func requestEmailChange(currentPassword: String, newEmail: String) async throws -> EmailChangeStateDTO {
        try await authSession.authorize { [api] token in
            try await api.requestEmailChange(
                currentPassword: currentPassword, newEmail: newEmail, accessToken: token
            )
        }
    }

    /// Step 2: consume the code. The server swaps the email, signs out every
    /// OTHER device and returns a FRESH token pair for this device, which we
    /// adopt immediately (the old pair is invalid).
    func verifyEmailChange(code: String) async throws {
        let pair = try await authSession.authorize { [api] token in
            try await api.verifyEmailChange(
                code: code,
                device: SyncDeviceDTO(
                    clientDeviceId: ServerConfiguration.clientDeviceId(),
                    displayName: ServerConfiguration.deviceDisplayName,
                    appVersion: ServerConfiguration.appVersion
                ),
                accessToken: token
            )
        }
        await authSession.adopt(pair: pair)
        accountLabel = pair.user?.email ?? accountLabel
    }

    /// Bind a verified Apple identity (the caller obtains the identity
    /// token through SignInWithAppleButton).
    func bindApple(identityToken: String) async throws {
        try await authSession.authorize { [api] token in
            try await api.bindApple(identityToken: identityToken, accessToken: token)
        }
    }

    /// Unbind the Apple sign-in method (password re-verification required).
    func unbindApple(currentPassword: String) async throws {
        try await authSession.authorize { [api] token in
            try await api.unbindApple(currentPassword: currentPassword, accessToken: token)
        }
    }

    /// Revoke another device's sessions.
    func revokeDevice(_ id: UUID) async throws {
        try await authSession.authorize { [api] token in
            try await api.revokeDevice(id: id, accessToken: token)
        }
    }

    /// Sign out EVERY device of the account (lost-phone path).
    func logoutAllDevices() async throws {
        try await authSession.authorize { [api] token in
            try await api.logoutAll(accessToken: token)
        }
        // This device's refresh chain is gone too.
        await authSession.clear()
        await refreshSignInState()
        phase = .signedOut
    }

    private func refreshSignInState() async {
        isSignedIn = await authSession.hasTokens
        if !isSignedIn {
            accountLabel = nil
        }
        refreshPendingCount()
        recomputePhase()
    }

    // MARK: - Settings

    var isSyncEnabled: Bool {
        get { cursorStore.isSyncEnabled }
        set {
            cursorStore.isSyncEnabled = newValue
            if newValue {
                scheduleInitialUploadIfNeeded()
                scheduleSync(after: 0.5)
            } else {
                // Off stops NEW syncs; local and cloud data are untouched.
                recomputePhase()
            }
        }
    }

    /// 立即同步 (user action).
    func syncNow() {
        scheduleSync(after: 0)
    }

    // MARK: - Guest-data migration handoff

    /// Called by `GuestDataMigration` after rows were copied into THIS
    /// account's store: reset the first-upload flag and snapshot the store
    /// (the migrated rows carry serverVersion 0 and have no outbox ops of
    /// their own), then push.
    func prepareForGuestMigrationUpload() {
        guard isSignedIn, cursorStore.isSyncEnabled, !cloudDeletedRecently else { return }
        defaults.set(false, forKey: initialUploadKey)
        scheduleInitialUploadIfNeeded()
        scheduleSync(after: 0.5)
    }

    // MARK: - Lifecycle triggers

    /// Called once at app launch.
    func start() {
        scheduleSync(after: 2)
        startPeriodicSync()
    }

    private func startPeriodicSync() {
        guard periodicTask == nil else { return }
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(45))
                guard let self, !Task.isCancelled else { return }
                if await self.outbox.pendingCount > 0 || self.isSignedIn {
                    self.scheduleSync(after: 0)
                }
            }
        }
    }

    private func startNetworkMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self, self.isNetworkAvailable != available else { return }
                self.isNetworkAvailable = available
                if available {
                    // Network recovery: retry what failed while offline.
                    self.scheduleSync(after: 1)
                } else {
                    self.recomputePhase()
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.livetranslate.ios.sync-network"))
    }

    /// Debounced trigger — live-classroom mutations coalesce instead of
    /// firing a request per utterance.
    func scheduleSync(after seconds: TimeInterval) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            await self.runSync(reason: "scheduled")
        }
    }

    // MARK: - Enqueue (local mutations)

    /// Builds DTOs on the main actor and forwards them to the outbox.
    private func enqueueSessionUpsert(_ session: ClassroomSession) {
        let item = SyncOutboxItem(
            entityType: .session,
            entityID: session.id,
            operation: .upsert,
            baseServerVersion: session.serverVersion,
            payload: Self.payload(for: session)
        )
        Task { await outbox.enqueue(item) }
        refreshPendingCount()
    }

    private func enqueueEntryUpsert(_ entry: TranscriptEntry) {
        var payload = Self.payload(for: entry)
        payload.sessionId = entry.sessionID
        let item = SyncOutboxItem(
            entityType: .entry,
            entityID: entry.id,
            operation: .upsert,
            baseServerVersion: entry.serverVersion,
            payload: payload
        )
        Task { await outbox.enqueue(item) }
        refreshPendingCount()
    }

    private func enqueueCourseUpsert(_ course: Course) {
        let item = SyncOutboxItem(
            entityType: .course,
            entityID: course.id,
            operation: .upsert,
            baseServerVersion: course.serverVersion,
            payload: Self.payload(for: course)
        )
        Task { await outbox.enqueue(item) }
        refreshPendingCount()
    }

    private func enqueueNoteUpsert(_ note: SessionNote) {
        var payload = Self.payload(for: note)
        payload.sessionId = note.sessionID
        let item = SyncOutboxItem(
            entityType: .note,
            entityID: note.id,
            operation: .upsert,
            baseServerVersion: note.serverVersion,
            payload: payload
        )
        Task { await outbox.enqueue(item) }
        refreshPendingCount()
    }

    private func enqueueStudyReviewUpsert(_ review: StudyReview) {
        var payload = Self.payload(for: review)
        payload.sessionId = review.sessionID
        let item = SyncOutboxItem(
            entityType: .studyReview,
            entityID: review.id,
            operation: .upsert,
            baseServerVersion: review.serverVersion,
            payload: payload
        )
        Task { await outbox.enqueue(item) }
        refreshPendingCount()
    }

    private func enqueueAttachmentUpsert(_ attachment: SessionAttachment) {
        var payload = Self.payload(for: attachment)
        payload.sessionId = attachment.sessionID
        let item = SyncOutboxItem(
            entityType: .attachment,
            entityID: attachment.id,
            operation: .upsert,
            baseServerVersion: attachment.serverVersion,
            payload: payload
        )
        Task { await outbox.enqueue(item) }
        refreshPendingCount()
        // The metadata row is queued — the FILES ride the dedicated
        // upload pass (uploadPendingAttachmentFiles), not the JSON push.
        scheduleAttachmentFileUpload()
    }

    private func enqueueTermUpsert(_ term: GlossaryTerm) {
        let item = SyncOutboxItem(
            entityType: .term,
            entityID: term.id,
            operation: .upsert,
            baseServerVersion: term.serverVersion,
            payload: Self.payload(for: term)
        )
        Task { await outbox.enqueue(item) }
        refreshPendingCount()
    }

    private func enqueueCardUpsert(_ card: StudyCard) {
        let item = SyncOutboxItem(
            entityType: .studyCard,
            entityID: card.id,
            operation: .upsert,
            baseServerVersion: card.serverVersion,
            payload: Self.payload(for: card)
        )
        Task { await outbox.enqueue(item) }
        refreshPendingCount()
    }

    private func enqueueTaskUpsert(_ task: StudyTask) {
        // An unconfirmed AI candidate is device-local — never pushed.
        guard task.status != .pendingConfirm else { return }
        let item = SyncOutboxItem(
            entityType: .studyTask,
            entityID: task.id,
            operation: .upsert,
            baseServerVersion: task.serverVersion,
            payload: Self.payload(for: task)
        )
        Task { await outbox.enqueue(item) }
        refreshPendingCount()
    }

    private func enqueueDelete(entityType: SyncEntityType, entityID: UUID) {
        let item = SyncOutboxItem(
            entityType: entityType,
            entityID: entityID,
            operation: .delete,
            baseServerVersion: 0,
            payload: SyncPushPayloadDTO()
        )
        Task { await outbox.enqueue(item) }
        refreshPendingCount()
    }

    private func bookmarkStoreChanged(_ change: BookmarkStore.SyncChange) {
        // Remote-applied changes must not re-enter the outbox.
        guard !bookmarks.isApplyingRemote else { return }
        switch change {
        case .bookmark(let sessionID, let entryID, let isBookmarked, let version):
            let item = SyncOutboxItem(
                entityType: .bookmark,
                entityID: entryID,
                operation: .upsert,
                baseServerVersion: version,
                payload: SyncPushPayloadDTO(
                    sessionId: sessionID, entryId: entryID, isBookmarked: isBookmarked
                )
            )
            Task { await outbox.enqueue(item) }
        case .favorite(let sessionID, let isFavorite, let version):
            let item = SyncOutboxItem(
                entityType: .favorite,
                entityID: sessionID,
                operation: .upsert,
                baseServerVersion: version,
                payload: SyncPushPayloadDTO(sessionId: sessionID, isFavorite: isFavorite)
            )
            Task { await outbox.enqueue(item) }
        }
        refreshPendingCount()
    }

    // MARK: - Initial upload of existing data

    /// First-time upload of the pre-existing SwiftData library: batched,
    /// resumable (the outbox survives restarts), never blocking the UI —
    /// enqueueing happens in slices on the main actor.
    func scheduleInitialUploadIfNeeded() {
        guard isSignedIn, cursorStore.isSyncEnabled, !cloudDeletedRecently else { return }
        guard !defaults.bool(forKey: initialUploadKey) else { return }
        Task { [weak self] in
            await self?.performInitialUpload()
        }
    }

    private func performInitialUpload() async {
        let snapshots = repository.syncSnapshots(batchSize: 100) { [weak self] _, _ in
            Task { @MainActor in
                self?.refreshPendingCount()
            }
        }
        await outbox.enqueue(snapshots)
        refreshPendingCount()
        defaults.set(true, forKey: initialUploadKey)
        let pending = await outbox.pendingCount
        Self.logger.info(
            "initial upload enqueued: \(pending, privacy: .public) items"
        )
        scheduleSync(after: 0.5)
    }

    // MARK: - Sync run

    private func runSync(reason: String) async {
        guard syncTask == nil else { return }
        guard isSignedIn else {
            recomputePhase()
            return
        }
        guard cursorStore.isSyncEnabled else {
            recomputePhase()
            return
        }
        guard isNetworkAvailable else {
            phase = .waitingForNetwork
            return
        }
        syncTask = Task { [weak self] in
            await self?.performSync(reason: reason)
        }
        await syncTask?.value
        syncTask = nil
    }

    private func performSync(reason: String) async {
        isSyncing = true
        phase = .syncing
        lastError = nil
        var hadPermanentFailure = false

        // ---- Push phase -------------------------------------------------
        pushLoop: while true {
            let batch = await outbox.dueItems(limit: 100)
            guard !batch.isEmpty else { break }
            let request = SyncPushRequestDTO(
                operations: batch.map { item in
                    SyncPushItemDTO(
                        operationId: item.operationID,
                        entityType: item.entityType,
                        entityId: item.entityID,
                        operation: item.operation,
                        baseVersion: item.baseServerVersion,
                        clientUpdatedAt: item.createdAt,
                        payload: item.payload
                    )
                }
            )
            let response: SyncPushResponseDTO
            do {
                response = try await authSession.authorize { [api] token in
                    try await api.push(request, accessToken: token)
                }
            } catch let error as SyncAPIError {
                await handlePushError(error, batch: batch)
                switch error {
                case .authExpired:
                    isSignedIn = false
                    phase = .authExpired
                    isSyncing = false
                    return
                case .upgradeRequired:
                    phase = .updateRequired
                    isSyncing = false
                    return
                case .serverUnavailable, .rateLimited:
                    phase = .serverUnavailable
                    isSyncing = false
                    return
                default:
                    hadPermanentFailure = true
                    break pushLoop
                }
            } catch {
                Self.logger.error("push failed: \(String(describing: error), privacy: .public)")
                phase = .serverUnavailable
                isSyncing = false
                return
            }

            for (item, result) in zip(batch, response.results) {
                await handlePushResult(item, result: result, hadPermanentFailure: &hadPermanentFailure)
            }
            refreshPendingCount()
        }

        // ---- Pull phase -------------------------------------------------
        do {
            var cursor = cursorStore.pullCursor
            pullLoop: while true {
                // Snapshot the cursor per iteration: the @Sendable request
                // closure cannot capture a mutable var.
                let currentCursor = cursor
                let page: SyncPullResponseDTO = try await authSession.authorize { [api] token in
                    try await api.pull(cursor: currentCursor, limit: 200, accessToken: token)
                }
                applyRemoteChanges(page.changes)
                cursor = page.nextCursor
                cursorStore.pullCursor = cursor
                if !page.hasMore { break pullLoop }
            }
        } catch let error as SyncAPIError {
            switch error {
            case .authExpired:
                isSignedIn = false
                phase = .authExpired
                isSyncing = false
                return
            case .upgradeRequired:
                phase = .updateRequired
                isSyncing = false
                return
            default:
                Self.logger.error("pull failed: \(error.localizedDescription, privacy: .public)")
                phase = .serverUnavailable
                isSyncing = false
                return
            }
        } catch {
            phase = .serverUnavailable
            isSyncing = false
            return
        }

        // ---- Wrap up ----------------------------------------------------
        cursorStore.lastSuccessfulSync = .now
        lastSuccessfulSync = cursorStore.lastSuccessfulSync
        refreshPendingCount()
        // 远端待下载探针: compare the server's change-log tail with our
        // cursor. Non-fatal — a failed probe just leaves the flag as-is.
        if let status = try? await authSession.authorize({ [api] token in
            try await api.status(accessToken: token)
        }) {
            remoteUpdatesPending = status.changeLogTail > cursorStore.pullCursor
        }
        let remaining = await outbox.pendingCount
        if hadPermanentFailure {
            phase = .partialFailure
        } else if remaining > 0 {
            phase = .waitingToSync
        } else {
            phase = .synced
        }
        isSyncing = false
    }

    private func handlePushError(_ error: SyncAPIError, batch: [SyncOutboxItem]) async {
        let retryAfter: TimeInterval?
        switch error {
        case .rateLimited(let after), .serverUnavailable(let after):
            retryAfter = after
        default:
            retryAfter = nil
        }
        for item in batch {
            _ = await outbox.scheduleRetry(
                operationID: item.operationID, serverRetryAfter: retryAfter
            )
        }
        if !error.isRetryable {
            lastError = error.localizedDescription
        }
    }

    private func handlePushResult(
        _ item: SyncOutboxItem,
        result: SyncPushItemResultDTO,
        hadPermanentFailure: inout Bool
    ) async {
        switch result.status {
        case .accepted:
            await outbox.remove(operationID: item.operationID)
            if let version = result.serverVersion {
                recordServerVersion(
                    entityType: item.entityType, entityID: item.entityID, version: version
                )
            }

        case .conflict:
            guard let server = result.serverRecord else {
                // Cannot merge without the record: drop and count as failure.
                await outbox.remove(operationID: item.operationID)
                hadPermanentFailure = true
                return
            }
            if server.deleted {
                // Delete-wins: propagate the tombstone locally, drop the op.
                applyRemoteDeletion(
                    entityType: item.entityType, entityID: item.entityID
                )
                await outbox.remove(operationID: item.operationID)
                return
            }
            if item.operation == .delete {
                // Our delete lost the race; the server row lives on.
                // Rebase and re-submit.
                await outbox.rebase(
                    operationID: item.operationID,
                    baseVersion: server.serverVersion,
                    payload: item.payload
                )
                return
            }
            if let merged = SyncConflictResolver.mergedPayload(
                entityType: item.entityType, local: item.payload, server: server
            ) {
                await outbox.rebase(
                    operationID: item.operationID,
                    baseVersion: server.serverVersion,
                    payload: merged
                )
            } else {
                await outbox.remove(operationID: item.operationID)
            }

        case .rejected:
            await outbox.remove(operationID: item.operationID)
            hadPermanentFailure = true
            lastError = SyncAPIError.permanent(
                code: result.errorCode ?? "rejected", reason: ""
            ).localizedDescription
            Self.logger.info(
                "push rejected op=\(item.operationID, privacy: .public) code=\(result.errorCode ?? "?", privacy: .public)"
            )

        case .retryableError:
            _ = await outbox.scheduleRetry(
                operationID: item.operationID, serverRetryAfter: nil
            )
        }
    }

    /// Writes the acknowledged serverVersion back into the local store so
    /// the next push of the same entity uses the correct base.
    private func recordServerVersion(
        entityType: SyncEntityType, entityID: UUID, version: Int
    ) {
        switch entityType {
        case .session, .entry, .course, .note, .studyReview, .attachment,
             .term, .studyCard, .studyTask:
            try? repository.recordServerVersion(
                entityType: entityType, entityID: entityID, version: version
            )
        case .bookmark:
            bookmarks.recordRemoteVersion(entryID: entityID, version: version)
        case .favorite:
            bookmarks.recordRemoteFavoriteVersion(sessionID: entityID, version: version)
        }
    }

    // MARK: - Remote change application (pull)

    private func applyRemoteChanges(_ changes: [SyncPullChangeDTO]) {
        for change in changes {
            switch change.operation {
            case .delete:
                applyRemoteDeletion(entityType: change.entityType, entityID: change.entityId)
            case .upsert:
                guard let record = change.record else { continue }
                applyRemoteUpsert(
                    record: record,
                    entityType: change.entityType,
                    serverVersion: change.serverVersion
                )
            }
        }
    }

    private func applyRemoteDeletion(entityType: SyncEntityType, entityID: UUID) {
        switch entityType {
        case .session:
            try? repository.deleteSessionByID(entityID)
        case .entry:
            try? repository.deleteEntryByID(entityID)
        case .bookmark:
            bookmarks.applyRemoteBookmark(
                sessionID: nil, entryID: entityID, isBookmarked: false, version: 0
            )
        case .favorite:
            bookmarks.applyRemoteFavorite(sessionID: entityID, isFavorite: false, version: 0)
        case .course:
            try? repository.deleteCourseByID(entityID)
        case .note:
            try? repository.deleteNoteByID(entityID)
        case .studyReview:
            try? repository.deleteStudyReviewByID(entityID)
        case .attachment:
            try? repository.deleteAttachmentByID(entityID)
        case .term:
            try? repository.deleteTermByID(entityID)
        case .studyCard:
            try? repository.deleteCardByID(entityID)
        case .studyTask:
            try? repository.deleteTaskByID(entityID)
        }
    }

    private func applyRemoteUpsert(
        record: SyncServerRecordDTO, entityType: SyncEntityType, serverVersion: Int
    ) {
        switch entityType {
        case .session:
            try? repository.applyRemoteSession(record: record, serverVersion: serverVersion)
        case .entry:
            try? repository.applyRemoteEntry(record: record, serverVersion: serverVersion)
        case .bookmark:
            if let entryID = record.entryId ?? record.id {
                bookmarks.applyRemoteBookmark(
                    sessionID: record.sessionId,
                    entryID: entryID,
                    isBookmarked: record.isBookmarked ?? true,
                    version: serverVersion
                )
            }
        case .favorite:
            if let sessionID = record.sessionId ?? record.id {
                bookmarks.applyRemoteFavorite(
                    sessionID: sessionID,
                    isFavorite: record.isFavorite ?? true,
                    version: serverVersion
                )
            }
        case .course:
            try? repository.applyRemoteCourse(record: record, serverVersion: serverVersion)
        case .note:
            try? repository.applyRemoteNote(record: record, serverVersion: serverVersion)
        case .studyReview:
            try? repository.applyRemoteStudyReview(record: record, serverVersion: serverVersion)
        case .attachment:
            try? repository.applyRemoteAttachment(record: record, serverVersion: serverVersion)
            // Newly-learned attachments sync their previews on demand —
            // the file upload pass picks up anything local worth pushing.
        case .term:
            try? repository.applyRemoteTerm(record: record, serverVersion: serverVersion)
        case .studyCard:
            try? repository.applyRemoteStudyCard(record: record, serverVersion: serverVersion)
        case .studyTask:
            try? repository.applyRemoteStudyTask(record: record, serverVersion: serverVersion)
        }
    }

    // MARK: - Account actions

    /// 删除云端副本: clears the server-side data; local data stays.
    func deleteCloudData() async {
        do {
            try await authSession.authorize { [api] token in
                try await api.deleteCloudData(accessToken: token)
            }
        } catch {
            lastError = (error as? SyncAPIError)?.localizedDescription
                ?? String(localized: "删除云端数据失败")
            return
        }
        // Reset the cursor so a later re-enable does a fresh pull, drop
        // pending upserts (the user asked the cloud copy to stay gone) and
        // forget which attachment files were uploaded (they are gone too).
        cursorStore.resetCursor()
        cursorStore.cloudDeletedAt = .now
        cloudDeletedRecently = true
        defaults.set(false, forKey: initialUploadKey)
        defaults.removeObject(forKey: attachmentUploadKey)
        await outbox.dropAllUpserts()
        refreshPendingCount()
        phase = .cloudDeleted
    }

    /// 删除账号: revoke tokens + delete server account + cloud data.
    /// Returns false (with `lastError` set) when the server refused.
    @discardableResult
    func deleteAccount() async -> Bool {
        do {
            try await authSession.authorize { [api] token in
                try await api.deleteAccount(accessToken: token)
            }
        } catch {
            lastError = (error as? SyncAPIError)?.localizedDescription
                ?? String(localized: "删除账号失败")
            return false
        }
        await authSession.clear()
        await outbox.removeAll()
        cursorStore.resetCursor()
        cursorStore.cloudDeletedAt = nil
        cloudDeletedRecently = false
        defaults.set(false, forKey: initialUploadKey)
        defaults.removeObject(forKey: attachmentUploadKey)
        await refreshSignInState()
        phase = .signedOut
        return true
    }

    // MARK: - Attachment file upload (binary, outside the JSON push)

    /// Per-attachment file upload bookkeeping (metadata pushed → bytes
    /// confirmed). Survives restarts via the defaults key.
    enum AttachmentFileState: String, Codable {
        case pendingUpload
        case uploaded
    }

    private var attachmentUploadTask: Task<Void, Never>?
    private let attachmentUploadKey = "cloudsync.attachmentUploads"

    private func attachmentUploadRecord() -> [String: AttachmentFileState] {
        (defaults.dictionary(forKey: attachmentUploadKey) as? [String: String])
            .map { dict in
                dict.compactMapValues(AttachmentFileState.init(rawValue:))
            } ?? [:]
    }

    private func saveAttachmentUploadRecord(_ record: [String: AttachmentFileState]) {
        defaults.set(
            Dictionary(uniqueKeysWithValues: record.map { ($0.key, $1.rawValue) }),
            forKey: attachmentUploadKey
        )
    }

    /// Debounced file-upload pass: uploads preview + original for every
    /// attachment whose metadata has been pushed (serverVersion > 0) but
    /// whose files are not yet confirmed server-side.
    func scheduleAttachmentFileUpload() {
        attachmentUploadTask?.cancel()
        attachmentUploadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            await self.uploadPendingAttachmentFiles()
        }
    }

    private func uploadPendingAttachmentFiles() async {
        guard isSignedIn, cursorStore.isSyncEnabled, isNetworkAvailable else { return }
        var record = attachmentUploadRecord()
        guard let all = try? repository.allAttachments() else { return }

        for attachment in all {
            if Task.isCancelled { return }
            // Only attachments whose metadata the server already holds.
            guard attachment.serverVersion > 0 else { continue }
            let key = attachment.id.uuidString
            if record[key] == .uploaded { continue }
            guard let store = AttachmentFileStoreShared.store else { continue }

            // Preview first (lists want it), then the original.
            for variant: AttachmentFileStore.Variant in [.preview, .original] {
                let hasLocal = store.fileExists(
                    for: attachment.id, sessionID: attachment.sessionID, variant: variant
                )
                guard hasLocal else { continue } // reclaimed originals skip
                guard let data = variant == .preview
                    ? store.previewOrOriginalData(
                        for: attachment.id, sessionID: attachment.sessionID
                    )
                    : store.originalData(
                        for: attachment.id, sessionID: attachment.sessionID
                    ) else { continue }
                do {
                    try await authSession.authorize { [api] token in
                        try await api.uploadAttachmentFile(
                            attachmentID: attachment.id,
                            variant: variant.rawValue,
                            data: data,
                            contentHash: attachment.contentHash,
                            accessToken: token
                        )
                    }
                } catch let error as SyncAPIError {
                    // 原图未上传完成时不算"全部同步完成"：leave pending and
                    // retry on the next scheduled pass.
                    Self.logger.notice(
                        "attachment file upload deferred: \(error.localizedDescription, privacy: .public)"
                    )
                    return
                } catch {
                    return
                }
            }
            record[key] = .uploaded
            saveAttachmentUploadRecord(record)
        }
    }

    /// Whether every synced attachment's files are confirmed server-side
    /// (drives honest 全部同步完成 presentation).
    var allAttachmentFilesUploaded: Bool {
        guard let all = try? repository.allAttachments() else { return true }
        let record = attachmentUploadRecord()
        return all
            .filter { $0.serverVersion > 0 }
            .allSatisfy { record[$0.id.uuidString] == .uploaded }
    }

    /// Downloads one variant from the server into the local store
    /// (on-demand: lists pull previews, the viewer pulls originals).
    /// Returns the file bytes' availability locally after the attempt.
    func downloadAttachmentFile(
        _ attachment: SessionAttachment, variant: AttachmentFileStore.Variant
    ) async -> Bool {
        guard isSignedIn else { return false }
        guard let store = AttachmentFileStoreShared.store else { return false }
        if store.fileExists(
            for: attachment.id, sessionID: attachment.sessionID, variant: variant
        ) { return true }
        do {
            let data = try await authSession.authorize { [api] token in
                try await api.downloadAttachmentFile(
                    attachmentID: attachment.id,
                    variant: variant.rawValue,
                    accessToken: token
                )
            }
            let ext = variant == .original
                ? AttachmentFileStore.fileExtension(forMIME: attachment.mimeType) : "jpg"
            try store.writeSynced(
                data, variant: variant,
                attachmentID: attachment.id,
                sessionID: attachment.sessionID,
                fileExtension: ext
            )
            return true
        } catch {
            Self.logger.notice(
                "attachment download failed: \(String(describing: error), privacy: .public)"
            )
            return false
        }
    }

    /// 删除云端原图 (storage management): removes the server-side files of
    /// synced attachments while keeping local files and metadata. The
    /// upload record forgets them so a later edit re-uploads on demand.
    func deleteCloudAttachmentFiles(attachmentIDs: [UUID]) async {
        for id in attachmentIDs {
            try? await authSession.authorize { [api] token in
                try await api.deleteAttachmentFiles(attachmentID: id, accessToken: token)
            }
        }
        var record = attachmentUploadRecord()
        for id in attachmentIDs { record[id.uuidString] = nil }
        saveAttachmentUploadRecord(record)
    }

    // MARK: - Derived state

    private func refreshPendingCount() {
        Task { [weak self] in
            guard let self else { return }
            let count = await self.outbox.pendingCount
            Task { @MainActor in
                self.pendingUploadCount = count
                self.recomputePhase()
            }
        }
    }

    private func recomputePhase() {
        if isSyncing { return }
        switch phase {
        case .cloudDeleted, .updateRequired:
            // Sticky until the user acts (re-sign-in / app update).
            return
        case .authExpired:
            // Sticky while signed out; a re-sign-in transitions explicitly.
            if !isSignedIn { return }
        default:
            break
        }
        if !isSignedIn {
            phase = .signedOut
        } else if !cursorStore.isSyncEnabled {
            phase = .disabled
        } else if !isNetworkAvailable {
            phase = .waitingForNetwork
        } else if pendingUploadCount > 0 {
            phase = .waitingToSync
        } else if lastSuccessfulSync != nil {
            phase = .synced
        } else {
            phase = .waitingToSync
        }
    }

    // MARK: - DTO builders (main-actor only)

    static func payload(for session: ClassroomSession) -> SyncPushPayloadDTO {
        SyncPushPayloadDTO(
            title: session.title,
            startedAt: session.startTime,
            endedAt: session.endTime,
            duration: session.duration,
            sessionStatus: session.endTime == nil ? "active" : (session.abnormalTermination ? "abnormal" : "finished"),
            abnormalTermination: session.abnormalTermination,
            sourceLanguage: session.sourceLanguage,
            targetLanguage: session.targetLanguage,
            // Full desired state: an assigned course rides as its id, a
            // standalone session rides as the explicit-clear sentinel (nil
            // would mean "keep the server value" and never propagate an
            // unassignment). The server treats the sentinel as "no course".
            courseId: session.courseID ?? .nilSentinel
        )
    }

    static func payload(for entry: TranscriptEntry) -> SyncPushPayloadDTO {
        SyncPushPayloadDTO(
            sequenceId: entry.sequenceID,
            startOffset: entry.startOffset,
            endOffset: entry.endOffset,
            russianText: entry.originalText,
            chineseText: entry.translatedText,
            translationStatus: entry.translationStatus
        )
    }

    static func payload(for course: Course) -> SyncPushPayloadDTO {
        SyncPushPayloadDTO(
            title: course.name,
            teacher: course.teacherName,
            location: course.location,
            colorIndex: course.colorIndex,
            isArchived: course.isArchived
        )
    }

    static func payload(for note: SessionNote) -> SyncPushPayloadDTO {
        SyncPushPayloadDTO(
            noteText: note.text,
            // Same sentinel rule as the session→course reference: an
            // unanchored note explicitly clears the anchor server-side.
            anchorEntryId: note.anchorEntryID ?? .nilSentinel
        )
    }

    /// Only terminal states with content reach the outbox (the generator
    /// never notifies the observer for `generating` progress); the wire
    /// payload carries the structured result — never prompts or raw model
    /// responses.
    static func payload(for review: StudyReview) -> SyncPushPayloadDTO {
        SyncPushPayloadDTO(
            reviewStatus: review.status,
            reviewContent: review.contentJSON.isEmpty ? nil : review.contentJSON,
            reviewGeneratedContent: review.generatedJSON.isEmpty ? nil : review.generatedJSON,
            reviewModel: review.reviewModel.isEmpty ? nil : review.reviewModel,
            reviewGeneratedAt: review.generatedAt,
            reviewSourceUpdatedAt: review.sourceUpdatedAt
        )
    }

    /// Attachment metadata (files travel on /v1/attachments). The
    /// structured analysis rides as a JSON string; `analyzing` is a
    /// device-local state and never pushed — terminal states only.
    static func payload(for attachment: SessionAttachment) -> SyncPushPayloadDTO {
        SyncPushPayloadDTO(
            title: attachment.title,
            // Same sentinel rule as notes: an unanchored image explicitly
            // clears the anchor server-side.
            courseId: attachment.courseID ?? .nilSentinel,
            anchorEntryId: attachment.anchorEntryID ?? .nilSentinel,
            attachmentKind: attachment.kindRaw,
            attachmentMime: attachment.mimeType,
            attachmentWidth: attachment.pixelWidth,
            attachmentHeight: attachment.pixelHeight,
            attachmentFileSize: attachment.fileSize,
            attachmentHash: attachment.contentHash,
            attachmentCapturedAt: attachment.capturedAt,
            attachmentCaption: attachment.caption,
            attachmentSortIndex: attachment.sortIndex,
            attachmentTransform: attachment.transformJSON.isEmpty ? nil : attachment.transformJSON,
            attachmentAnalysisStatus: attachment.analysisStatus == .analyzing
                ? AttachmentAnalysisStatus.pending.rawValue
                : attachment.analysisStatusRaw,
            attachmentAnalysis: attachment.analysisJSON.isEmpty
                ? nil : attachment.analysisJSON,
            attachmentOcrText: attachment.ocrText.isEmpty ? nil : attachment.ocrText
        )
    }

    /// Glossary term. Source references follow the sentinel rule (a nil
    /// course means 未分类 and explicitly clears); the accumulated source
    /// sessions ride as a JSON array string.
    static func payload(for term: GlossaryTerm) -> SyncPushPayloadDTO {
        SyncPushPayloadDTO(
            termRussian: term.russian,
            termChinese: term.chinese,
            termExplanation: term.explanation.isEmpty ? nil : term.explanation,
            termPartOfSpeech: term.partOfSpeech.isEmpty ? nil : term.partOfSpeech,
            termUserNote: term.userNote.isEmpty ? nil : term.userNote,
            termSourceSessions: term.sourceSessionIDsJSON.isEmpty ? nil : term.sourceSessionIDsJSON,
            termFavorite: term.isFavorite,
            termStatus: term.statusRaw,
            courseId: term.courseID ?? .nilSentinel,
            sessionId: term.sessionID ?? .nilSentinel,
            entryId: term.sourceEntryID ?? .nilSentinel,
            sourceAttachmentId: term.sourceAttachmentID ?? .nilSentinel,
            sourceReviewId: term.sourceReviewID ?? .nilSentinel
        )
    }

    /// Study card: content + scheduling state. The full state rides every
    /// upsert; the server merges review fields newest-lastReviewedAt-wins.
    static func payload(for card: StudyCard) -> SyncPushPayloadDTO {
        SyncPushPayloadDTO(
            cardFront: card.front,
            cardBack: card.back,
            cardType: card.typeRaw,
            cardUserNote: card.userNote.isEmpty ? nil : card.userNote,
            cardOrigin: card.originRaw,
            cardStage: card.stageRaw,
            cardReviewCount: card.reviewCount,
            cardIntervalHours: card.intervalHours,
            cardDueAt: card.dueAt,
            cardLastReviewedAt: card.lastReviewedAt,
            cardLastGrade: card.lastGradeRaw.isEmpty ? nil : card.lastGradeRaw,
            courseId: card.courseID ?? .nilSentinel,
            sessionId: card.sessionID ?? .nilSentinel,
            entryId: card.sourceEntryID ?? .nilSentinel,
            sourceAttachmentId: card.sourceAttachmentID ?? .nilSentinel,
            sourceTermId: card.sourceTermID ?? .nilSentinel
        )
    }

    /// Study task (title rides the shared `title` field — course/
    /// attachment convention). Only confirmed tasks are ever enqueued, so
    /// `pendingConfirm` never reaches the wire.
    static func payload(for task: StudyTask) -> SyncPushPayloadDTO {
        SyncPushPayloadDTO(
            title: task.title,
            taskDetail: task.detail.isEmpty ? nil : task.detail,
            taskDueAt: task.dueAt,
            taskPriority: task.priorityRaw,
            taskStatus: task.statusRaw,
            taskOrigin: task.originRaw,
            taskUncertainty: task.uncertainty.isEmpty ? nil : task.uncertainty,
            taskUserNote: task.userNote.isEmpty ? nil : task.userNote,
            taskCompletedAt: task.completedAt,
            courseId: task.courseID ?? .nilSentinel,
            sessionId: task.sessionID ?? .nilSentinel,
            entryId: task.sourceEntryID ?? .nilSentinel,
            sourceAttachmentId: task.sourceAttachmentID ?? .nilSentinel,
            sourceReviewId: task.sourceReviewID ?? .nilSentinel
        )
    }
}

// MARK: - TranscriptMutationObserving

/// Repository → sync hook: every persisted mutation notifies the sync
/// service, which snapshots the model into a Sendable DTO on the main
/// actor and enqueues an outbox operation.
@MainActor
protocol TranscriptMutationObserving: AnyObject {
    func sessionCreated(_ session: ClassroomSession)
    func sessionUpdated(_ session: ClassroomSession)
    func sessionDeleted(id: UUID)
    func entryCreated(_ entry: TranscriptEntry)
    func entryUpdated(_ entry: TranscriptEntry)
    func courseCreated(_ course: Course)
    func courseUpdated(_ course: Course)
    func courseDeleted(id: UUID)
    func noteCreated(_ note: SessionNote)
    func noteUpdated(_ note: SessionNote)
    func noteDeleted(id: UUID)
    func studyReviewUpdated(_ review: StudyReview)
    func studyReviewDeleted(id: UUID)
    func attachmentCreated(_ attachment: SessionAttachment)
    func attachmentUpdated(_ attachment: SessionAttachment)
    func attachmentDeleted(id: UUID)
    func termCreated(_ term: GlossaryTerm)
    func termUpdated(_ term: GlossaryTerm)
    func termDeleted(id: UUID)
    func cardCreated(_ card: StudyCard)
    func cardUpdated(_ card: StudyCard)
    func cardDeleted(id: UUID)
    func taskCreated(_ task: StudyTask)
    func taskUpdated(_ task: StudyTask)
    func taskDeleted(id: UUID)
}

extension CloudSyncService: TranscriptMutationObserving {
    func sessionCreated(_ session: ClassroomSession) {
        enqueueSessionUpsert(session)
    }

    func sessionUpdated(_ session: ClassroomSession) {
        enqueueSessionUpsert(session)
    }

    func sessionDeleted(id: UUID) {
        enqueueDelete(entityType: .session, entityID: id)
    }

    func entryCreated(_ entry: TranscriptEntry) {
        enqueueEntryUpsert(entry)
    }

    func entryUpdated(_ entry: TranscriptEntry) {
        enqueueEntryUpsert(entry)
    }

    func courseCreated(_ course: Course) {
        enqueueCourseUpsert(course)
    }

    func courseUpdated(_ course: Course) {
        enqueueCourseUpsert(course)
    }

    func courseDeleted(id: UUID) {
        enqueueDelete(entityType: .course, entityID: id)
    }

    func noteCreated(_ note: SessionNote) {
        enqueueNoteUpsert(note)
    }

    func noteUpdated(_ note: SessionNote) {
        enqueueNoteUpsert(note)
    }

    func noteDeleted(id: UUID) {
        enqueueDelete(entityType: .note, entityID: id)
    }

    func studyReviewUpdated(_ review: StudyReview) {
        enqueueStudyReviewUpsert(review)
    }

    func studyReviewDeleted(id: UUID) {
        enqueueDelete(entityType: .studyReview, entityID: id)
    }

    func attachmentCreated(_ attachment: SessionAttachment) {
        enqueueAttachmentUpsert(attachment)
    }

    func attachmentUpdated(_ attachment: SessionAttachment) {
        enqueueAttachmentUpsert(attachment)
    }

    func attachmentDeleted(id: UUID) {
        enqueueDelete(entityType: .attachment, entityID: id)
    }

    func termCreated(_ term: GlossaryTerm) {
        enqueueTermUpsert(term)
    }

    func termUpdated(_ term: GlossaryTerm) {
        enqueueTermUpsert(term)
    }

    func termDeleted(id: UUID) {
        enqueueDelete(entityType: .term, entityID: id)
    }

    func cardCreated(_ card: StudyCard) {
        enqueueCardUpsert(card)
    }

    func cardUpdated(_ card: StudyCard) {
        enqueueCardUpsert(card)
    }

    func cardDeleted(id: UUID) {
        enqueueDelete(entityType: .studyCard, entityID: id)
    }

    func taskCreated(_ task: StudyTask) {
        enqueueTaskUpsert(task)
    }

    func taskUpdated(_ task: StudyTask) {
        enqueueTaskUpsert(task)
    }

    func taskDeleted(id: UUID) {
        enqueueDelete(entityType: .studyTask, entityID: id)
    }
}
