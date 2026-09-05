import XCTest
import SwiftUI
import LocalAuthentication
@testable import LiveTranslateIOS

/// 第十七轮：隐私锁、系统界面内容策略、剪贴板、临时导出、AI 活动记录。
final class PrivacyHardeningTests: XCTestCase {

    // MARK: - 隐私锁

    @MainActor
    private func makeLock(
        enabled: Bool, grace: Int,
        result: @escaping @MainActor () async -> PrivacyLockController.AuthenticationResult
    ) -> PrivacyLockController {
        let defaults = UserDefaults(suiteName: "privacy-lock-tests-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        settings.privacyLockEnabled = enabled
        settings.privacyLockGraceSeconds = grace
        return PrivacyLockController(settings: settings, authenticate: result)
    }

    @MainActor
    func testLockDisabledNeverCovers() async {
        let lock = makeLock(enabled: false, grace: 0) {
            .init(success: false, errorCode: nil)
        }
        XCTAssertFalse(lock.requiresUnlock, "默认关闭：不得覆盖界面")
        // 即使从未认证，禁用状态下前台进入也不要求验证。
        XCTAssertFalse(lock.handleForegroundEntry())
    }

    @MainActor
    func testArmedLaunchStartsLocked() async {
        let lock = makeLock(enabled: true, grace: 300) { .init(success: true, errorCode: nil) }
        XCTAssertTrue(lock.requiresUnlock, "启用后启动即锁定 —— 不继承上次会话的授权")
    }

    @MainActor
    func testGraceElapsedRearmsOnForeground() async {
        let lock = makeLock(enabled: true, grace: 300) { .init(success: true, errorCode: nil) }
        // 先解锁。
        _ = await lock.attemptUnlock()
        XCTAssertFalse(lock.requiresUnlock)
        // 后台超过宽限期 → 前台必须重新验证（返回 true = 需要认证）。
        lock.trackLeftForeground(at: .now.addingTimeInterval(-600))
        XCTAssertTrue(lock.handleForegroundEntry())
        XCTAssertTrue(lock.requiresUnlock)
        // 后台未超宽限期 → 不重新锁定。
        _ = await lock.attemptUnlock()
        lock.trackLeftForeground(at: .now.addingTimeInterval(-10))
        XCTAssertFalse(lock.handleForegroundEntry())
        XCTAssertFalse(lock.requiresUnlock)
    }

    @MainActor
    func testImmediateGraceLocksOnAnyBackground() async {
        let lock = makeLock(enabled: true, grace: 0) { .init(success: true, errorCode: nil) }
        _ = await lock.attemptUnlock()
        lock.trackLeftForeground(at: .now)
        XCTAssertTrue(lock.graceElapsed(), "grace=0：任何离开前台都立即到期")
        XCTAssertTrue(lock.handleForegroundEntry())
        XCTAssertTrue(lock.requiresUnlock)
    }

    @MainActor
    func testAuthenticationFailureStatesAreHonest() async {
        // 用户取消：保持锁定，状态为 userCancelled。
        let cancelled = makeLock(enabled: true, grace: 0) {
            .init(success: false, errorCode: LAError.Code.userCancel.rawValue)
        }
        _ = await cancelled.attemptUnlock()
        XCTAssertTrue(cancelled.requiresUnlock)
        XCTAssertEqual(cancelled.lastFailure, .userCancelled)

        // 无生物能力 → 系统会回退密码,错误状态如实呈现。
        let unavailable = makeLock(enabled: true, grace: 0) {
            .init(success: false, errorCode: LAError.Code.biometryNotAvailable.rawValue)
        }
        _ = await unavailable.attemptUnlock()
        XCTAssertEqual(unavailable.lastFailure, .biometryUnavailable)

        // 成功 → 解锁并清除失败状态。
        let success = makeLock(enabled: true, grace: 0) { .init(success: true, errorCode: nil) }
        _ = await success.attemptUnlock()
        XCTAssertFalse(success.requiresUnlock)
        XCTAssertNil(success.lastFailure)
    }

    @MainActor
    func testDisableClearsLockImmediately() async {
        let lock = makeLock(enabled: true, grace: 0) { .init(success: false, errorCode: nil) }
        XCTAssertTrue(lock.requiresUnlock)
        lock.disable()
        XCTAssertFalse(lock.requiresUnlock)
    }

    @MainActor
    func testProfileSwitchLocksImmediately() async {
        // lockNow = 账号切换路径:已解锁状态立即失效。
        let lock = makeLock(enabled: true, grace: 900) { .init(success: true, errorCode: nil) }
        _ = await lock.attemptUnlock()
        XCTAssertFalse(lock.requiresUnlock)
        lock.lockNow()
        XCTAssertTrue(lock.requiresUnlock, "切号后不得继承上一个账号的解锁授权")
    }

    // MARK: - 系统界面内容策略

    func testSurfacePolicyMapsToClassroomLevels() {
        XCTAssertEqual(SystemSurfacePrivacy.showFullContent.classroomLockScreenPrivacy, .statusTitleAndLatestText)
        XCTAssertEqual(SystemSurfacePrivacy.showTitlesOnly.classroomLockScreenPrivacy, .statusAndTitle)
        XCTAssertEqual(SystemSurfacePrivacy.hideSensitiveContent.classroomLockScreenPrivacy, .statusOnly)
        // 逆向映射无损(存量设置推导)。
        XCTAssertEqual(SystemSurfacePrivacy(lockScreenPrivacy: .statusOnly), .hideSensitiveContent)
        XCTAssertEqual(SystemSurfacePrivacy(lockScreenPrivacy: .statusAndTitle), .showTitlesOnly)
        XCTAssertEqual(SystemSurfacePrivacy(lockScreenPrivacy: .statusTitleAndLatestText), .showFullContent)
        // 标题可见性。
        XCTAssertTrue(SystemSurfacePrivacy.showFullContent.showsTitles)
        XCTAssertTrue(SystemSurfacePrivacy.showTitlesOnly.showsTitles)
        XCTAssertFalse(SystemSurfacePrivacy.hideSensitiveContent.showsTitles)
    }

    @MainActor
    func testSettingsSurfacePolicyDerivesFromLegacy() {
        let defaults = UserDefaults(suiteName: "surface-derive-\(UUID().uuidString)")!
        defaults.set(LockScreenPrivacy.statusTitleAndLatestText.rawValue, forKey: "ui.lockScreenPrivacy")
        let settings = SettingsStore(defaults: defaults)
        XCTAssertEqual(settings.systemSurfacePrivacy, .showFullContent, "存量三档选择不得丢失")
        // 修改统一级别 → 课堂维度同步(单一来源)。
        settings.systemSurfacePrivacy = .hideSensitiveContent
        XCTAssertEqual(settings.lockScreenPrivacy, .statusOnly)
    }

    // MARK: - 剪贴板

    @MainActor
    func testSensitiveCopyIsLocalOnlyWithExpiration() {
        let service = ClipboardService.shared
        let hint = service.copySensitive("护照复印件内容")
        XCTAssertEqual(
            hint, "已复制，将在本机剪贴板中短暂保留（2 分钟）",
            "复制提示如实说明保留策略"
        )
        let pasteboard = UIPasteboard.general
        XCTAssertTrue(pasteboard.localOnly, "默认仅本机,不参与跨设备接力")
        guard let expiry = pasteboard.expirationDate else {
            return XCTFail("敏感复制必须设置过期时间")
        }
        let remaining = expiry.timeIntervalSinceNow
        XCTAssertGreaterThan(remaining, 60, "过期时间在 1-2 分钟窗口内")
        XCTAssertLessThanOrEqual(remaining, 2 * 60 + 5)
        // 本 App 写入的内容可被守卫清除。
        XCTAssertTrue(service.clipboardStillOurs)
    }

    @MainActor
    func testPlainCopyIsLocalOnlyWithoutExpiration() {
        _ = ClipboardService.shared.copy("E = mc^2", policy: .plain)
        let pasteboard = UIPasteboard.general
        XCTAssertTrue(pasteboard.localOnly)
        XCTAssertNil(pasteboard.expirationDate, "普通短语明确不过期 —— 与敏感策略不同且如实")
    }

    @MainActor
    func testClearNeverWipesLaterCopies() {
        let service = ClipboardService.shared
        _ = service.copySensitive("旧内容")
        XCTAssertTrue(service.clipboardStillOurs)
        // 模拟用户随后在其他 App 复制了新内容(changeCount 变化)。
        UIPasteboard.general.string = "用户的新内容"
        XCTAssertFalse(service.clipboardStillOurs, "changeCount 已变 —— 不是我们的内容")
        XCTAssertFalse(
            service.clearIfStillOurs(),
            "不得清除用户后来复制的内容"
        )
        XCTAssertEqual(UIPasteboard.general.string, "用户的新内容")
    }

    // MARK: - 临时导出生命周期

    func testExportStoreStagesProtectedAndReapsOnExpiry() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TemporaryExportStore(root: root)

        let url = try store.stage(fileName: "LiveTranslate-课堂.md", data: Data("内容".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(store.entryCount, 1)
        // 受控目录内的文件带 .complete 保护 + 排除备份。
        let values = try url.resourceValues(forKeys: [.protectionKey, .isExcludedFromBackupKey])
        XCTAssertEqual(values.protectionKey, .complete)
        XCTAssertEqual(values.isExcludedFromBackup, true)
        XCTAssertGreaterThan(store.totalBytes(), 0)

        // 未到期:不得删除(分享面板可能还开着)。
        _ = store.reap(asOf: .now)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        // 到期:文件与 manifest 行一起收割。
        _ = store.reap(asOf: .now.addingTimeInterval(TemporaryExportStore.retention + 60))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(store.entryCount, 0)
    }

    func testExportStoreUniqueNamesNeverReplace() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TemporaryExportStore(root: root)
        let first = try store.stage(fileName: "a.md", data: Data("1".utf8))
        let second = try store.stage(fileName: "a.md", data: Data("2".utf8))
        XCTAssertNotEqual(first.lastPathComponent, second.lastPathComponent, "同分钟重复导出不得覆盖分享中的文件")
        XCTAssertEqual(store.entryCount, 2)
    }

    func testExportStoreReapNeverTouchesOutsideFiles() throws {
        // 受控目录之外的正式资料绝不被清理。
        let formal = FileManager.default.temporaryDirectory
            .appendingPathComponent("formal-material-\(UUID().uuidString).pdf")
        try Data("正式资料".utf8).write(to: formal)
        defer { try? FileManager.default.removeItem(at: formal) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TemporaryExportStore(root: root)
        _ = try store.stage(fileName: "x.md", data: Data("x".utf8))
        _ = store.reapAll()
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: formal.path),
            "清理只作用于受控导出目录"
        )
    }

    // MARK: - AI 活动记录

    @MainActor
    func testAIActivityLogRecordsMetadataOnlyAndPrunes() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-activity-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let log = AIActivityLog(fileURL: file)

        await AICallScope.with(
            AICallContext(feature: .interpreterDocumentQA, textCategory: .documentText, masked: true)
        ) {
            await AIActivityLog.recordTransport(
                characterCount: 1234, imageCount: 0,
                outcome: .success, host: "api.example.com"
            )
        }
        // 无调用上下文的传输记录不得产生噪音行。
        await AIActivityLog.recordTransport(
            characterCount: 10, imageCount: 0, outcome: .success, host: "x"
        )

        XCTAssertEqual(log.entries.count, 1)
        let entry = try XCTUnwrap(log.entries.first)
        XCTAssertEqual(entry.feature, .interpreterDocumentQA)
        XCTAssertEqual(entry.textCategory, .documentText)
        XCTAssertEqual(entry.characterCount, 1234)
        XCTAssertTrue(entry.masked)
        XCTAssertEqual(entry.host, "api.example.com")
        XCTAssertEqual(entry.outcome, .success)

        // 磁盘上的记录只有元数据:正文/密钥/完整 URL 不存在。
        let raw = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(raw.contains("Authorization"))
        XCTAssertFalse(raw.contains("Bearer"))
        XCTAssertFalse(raw.contains("api-key"))
        XCTAssertFalse(raw.contains("?"))

        // 30 天之外的历史被修剪(通过磁盘上的过期条目验证)。
        var stale = log.entries
        stale[0].occurredAt = .now.addingTimeInterval(-40 * 86_400)
        try JSONEncoder().encode(stale).write(to: file)
        let reloaded = AIActivityLog(fileURL: file)
        XCTAssertTrue(reloaded.entries.isEmpty, "过期记录在加载时被修剪")

        // 清空。
        log.clear()
        XCTAssertTrue(log.entries.isEmpty)
    }

    @MainActor
    func testTransportRecordsCancellationNotFailure() async {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-activity-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let log = AIActivityLog(fileURL: file)
        let previous = AIActivityLog.shared
        AIActivityLog.shared = log
        defer { AIActivityLog.shared = previous }

        await AICallScope.with(
            AICallContext(feature: .studyReview, textCategory: .mixed)
        ) {
            await AIActivityLog.recordTransport(
                characterCount: 100, imageCount: 2,
                outcome: .cancelled, host: "api.example.com"
            )
        }
        XCTAssertEqual(log.entries.first?.outcome, .cancelled, "用户取消不是模型失败")
        XCTAssertEqual(log.entries.first?.imageCount, 2)
    }

    // MARK: - 请求披露文案

    func testDisclosurePreviewSummary() {
        let disclosure = AIRequestDisclosure(
            feature: .interpreterDocumentQA,
            host: "api.example.com",
            textCategory: .documentText,
            characterCount: 3000,
            imageCount: 2,
            masked: true,
            userTriggered: true
        )
        let summary = disclosure.previewSummary
        XCTAssertTrue(summary.contains("文件问答"))
        XCTAssertTrue(summary.contains("api.example.com"))
        XCTAssertTrue(summary.contains("2 张图片"))
        XCTAssertTrue(summary.contains("已自动遮盖敏感信息"))
    }
}
