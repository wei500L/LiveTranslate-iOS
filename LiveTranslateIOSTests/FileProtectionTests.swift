import XCTest
@testable import LiveTranslateIOS

/// 第十七轮文件保护层测试：等级映射、属性应用(写入/原子改名后)、
/// reconcile 幂等升级、备份排除、失败不删文件、收件箱 manifest 防毁损。
final class FileProtectionTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fp-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    /// File protection is DEVICE-only: the simulator does not persist
    /// NSFileProtection attributes (setAttributes succeeds, but
    /// attributesOfItem reads the key back as nil). Probe once per run;
    /// read-back assertions skip with an explicit reason where the
    /// runtime does not support them — backup-exclusion assertions run
    /// everywhere.
    static let protectionRoundTripSupported: Bool = {
        let probe = FileManager.default.temporaryDirectory
            .appendingPathComponent("fp-probe-\(UUID().uuidString)")
        try? Data("x".utf8).write(to: probe)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete], ofItemAtPath: probe.path
        )
        let value = (try? FileManager.default.attributesOfItem(atPath: probe.path))?
            [.protectionKey] as? FileProtectionType
        try? FileManager.default.removeItem(at: probe)
        return value == .complete
    }()

    /// Asserts the protection level, skipping with an explicit reason on
    /// runtimes that do not persist protection attributes.
    private func verifyProtection(
        _ url: URL, expected: FileProtectionType, _ message: String
    ) throws {
        guard Self.protectionRoundTripSupported else {
            throw XCTSkip("Simulator does not persist file protection attributes (device-only); write path verified, level not read-back-able here")
        }
        XCTAssertEqual(protection(of: url), expected, message)
    }

    private func makeFile(_ name: String, protection: FileProtectionType? = nil) throws -> URL {
        let url = workDir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        if let protection {
            try FileManager.default.setAttributes(
                [.protectionKey: protection], ofItemAtPath: url.path
            )
        }
        return url
    }

    private func protection(of url: URL) -> FileProtectionType? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.protectionKey] as? FileProtectionType
    }


    private func backupExcluded(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey])
            .isExcludedFromBackup) ?? false
    }

    // MARK: - 等级映射契约

    func testClassMatrix() {
        // 敏感内容:锁屏不可访问 + 排除备份
        XCTAssertEqual(DataProtectionClass.sensitiveLocalDocument.fileProtection, .complete)
        XCTAssertTrue(DataProtectionClass.sensitiveLocalDocument.excludesFromBackup)
        XCTAssertEqual(DataProtectionClass.regenerableCache.fileProtection, .complete)
        XCTAssertTrue(DataProtectionClass.regenerableCache.excludesFromBackup)
        XCTAssertEqual(DataProtectionClass.temporaryExport.fileProtection, .complete)
        XCTAssertTrue(DataProtectionClass.temporaryExport.excludesFromBackup)
        XCTAssertEqual(DataProtectionClass.sharedInboxItem.fileProtection, .complete)
        XCTAssertFalse(DataProtectionClass.sharedInboxItem.excludesFromBackup)
        // 课堂工作数据:锁屏后台仍可写(后台课堂 + 45s 同步)
        XCTAssertEqual(
            DataProtectionClass.classroomWorking.fileProtection,
            .completeUntilFirstUserAuthentication
        )
        XCTAssertFalse(DataProtectionClass.classroomWorking.excludesFromBackup)
        XCTAssertEqual(
            DataProtectionClass.syncedUserContent.fileProtection,
            .completeUntilFirstUserAuthentication
        )
        XCTAssertFalse(DataProtectionClass.syncedUserContent.excludesFromBackup)
        // 模型:后台锁屏课堂仍可读 + 可重建
        XCTAssertEqual(
            DataProtectionClass.modelFile.fileProtection,
            .completeUntilFirstUserAuthentication
        )
        XCTAssertTrue(DataProtectionClass.modelFile.excludesFromBackup)
        // 系统表面(快照/命令/路由):锁屏 Widget 可读 + 可重建
        XCTAssertEqual(
            DataProtectionClass.systemSurface.fileProtection,
            .completeUntilFirstUserAuthentication
        )
        XCTAssertTrue(DataProtectionClass.systemSurface.excludesFromBackup)
    }

    // MARK: - 属性应用

    func testApplySetsProtectionAndBackupExclusion() throws {
        let url = try makeFile("original.pdf")
        XCTAssertNil(FileProtection.apply(.sensitiveLocalDocument, to: url))
        XCTAssertTrue(backupExcluded(url))
        try verifyProtection(url, expected: .complete, "敏感文件锁屏不可读")
    }

    func testApplyIsIdempotent() throws {
        let url = try makeFile("original.pdf")
        XCTAssertNil(FileProtection.apply(.sensitiveLocalDocument, to: url))
        XCTAssertNil(FileProtection.apply(.sensitiveLocalDocument, to: url))
        XCTAssertTrue(backupExcluded(url))
        try verifyProtection(url, expected: .complete, "重复应用幂等")
    }

    func testApplyToMissingPathIsNotAnError() {
        // 不存在的根(新账号无附件)不视为失败。
        XCTAssertNil(
            FileProtection.apply(
                .sensitiveLocalDocument,
                to: workDir.appendingPathComponent("no-such-file")
            )
        )
    }

    func testWriteAppliesCompleteProtectionAtomically() throws {
        let url = workDir.appendingPathComponent("extraction.json")
        try FileProtection.write(
            Data("{}".utf8), to: url, class: .sensitiveLocalDocument
        )
        XCTAssertTrue(backupExcluded(url))
        try verifyProtection(url, expected: .complete, "写入即带 .complete")
    }

    func testWriteAppliesWorkingProtection() throws {
        let url = workDir.appendingPathComponent("outbox.json")
        try FileProtection.write(
            Data("[]".utf8), to: url, class: .classroomWorking
        )
        XCTAssertFalse(backupExcluded(url))
        try verifyProtection(
            url, expected: .completeUntilFirstUserAuthentication,
            "工作数据锁屏后台可写"
        )
    }

    /// 原子改名(temp → rename)后属性仍在 —— rename 保留属性,但
    /// replaceItemAt 无此保证,所以落地后必须重新应用。
    func testProtectionSurvivesAtomicReplaceSequence() throws {
        let destination = workDir.appendingPathComponent("original.pdf")
        try FileProtection.write(
            Data("v1".utf8), to: destination, class: .sensitiveLocalDocument
        )
        let temp = workDir.appendingPathComponent(".tmp-replace")
        try Data("v2".utf8).write(to: temp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
        // replace 后重新应用 —— 存储层落地路径必须这么做。
        FileProtection.apply(.sensitiveLocalDocument, to: destination)
        XCTAssertEqual(
            try String(contentsOf: destination, encoding: .utf8), "v2"
        )
        try verifyProtection(destination, expected: .complete, "replace 后重新应用")
    }

    // MARK: - Reconcile 幂等升级

    func testReconcileUpgradesLegacyDefaultFiles() throws {
        // 旧版本写入的文件:系统默认等级(无保护属性)。
        let legacy = try makeFile("original.pdf", protection: nil)
        let legacyThumb = try makeFile("page-1.jpg", protection: nil)

        let result = FileProtection.reconcile(
            root: workDir, class: .sensitiveLocalDocument
        )
        XCTAssertEqual(result.upgraded, 2)
        XCTAssertEqual(result.failed.count, 0)
        XCTAssertTrue(backupExcluded(legacy))
        XCTAssertTrue(backupExcluded(legacyThumb))
        try verifyProtection(legacy, expected: .complete, "旧文件升级")
        try verifyProtection(legacyThumb, expected: .complete, "旧文件升级")
    }

    func testReconcileIsIdempotent() throws {
        try makeFile("original.pdf", protection: nil)
        _ = FileProtection.reconcile(root: workDir, class: .sensitiveLocalDocument)
        let second = FileProtection.reconcile(
            root: workDir, class: .sensitiveLocalDocument
        )
        XCTAssertEqual(second.failed.count, 0)
        guard Self.protectionRoundTripSupported else {
            throw XCTSkip("Simulator does not persist protection attributes — the no-op upgrade count is only meaningful where the level reads back")
        }
        XCTAssertEqual(second.upgraded, 0, "第二次运行不得产生属性变更")
    }

    func testReconcileWithMatcherSplitsRenditions() throws {
        // 同一目录下混放原件与派生缓存 —— 两次带匹配器的 reconcile
        // 分别应用各自的等级。
        let original = try makeFile("original.pdf", protection: nil)
        let preview = try makeFile("preview.jpg", protection: nil)
        let analysis = try makeFile("analysis.jpg", protection: nil)

        _ = FileProtection.reconcile(
            root: workDir, class: .syncedUserContent
        ) { $0.lastPathComponent.hasPrefix("original.") }
        _ = FileProtection.reconcile(
            root: workDir, class: .regenerableCache
        ) { ["preview.jpg", "analysis.jpg"].contains($0.lastPathComponent) }

        XCTAssertFalse(backupExcluded(original), "原件是正式数据,留在备份里")
        XCTAssertTrue(backupExcluded(preview), "预览是可重建缓存,排除备份")
        XCTAssertTrue(backupExcluded(analysis), "分析副本排除备份")
        try verifyProtection(
            original, expected: .completeUntilFirstUserAuthentication, "原件等级"
        )
        try verifyProtection(preview, expected: .complete, "预览等级")
        try verifyProtection(analysis, expected: .complete, "分析副本等级")
    }

    func testReconcileNeverDeletesFilesOnFailure() throws {
        // reconcile 从不删除文件 —— 只统计失败。(用存在的目录验证零删除。)
        let url = try makeFile("keep.txt", protection: nil)
        _ = FileProtection.reconcile(root: workDir, class: .sensitiveLocalDocument)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - 收件箱 manifest 防毁损(属性升级前的同层修复)

    func testInboxUpdateManifestRefusesCorruptManifestOverwrite() throws {
        let store = SharedInboxStore(root: workDir.appendingPathComponent("inbox"))
        let itemID = UUID()
        let staged = try store.stageTextPayload(itemID: itemID, text: "护照信息")
        let saved = store.updateManifest { m in
            m.items.append(SharedInboxItem(
                id: itemID, scopeKey: SystemScope.guest,
                payloadKind: .text, title: "分享"
            ))
        }
        XCTAssertEqual(saved.items.count, 1)
        XCTAssertNotNil(staged)

        // 毁损 manifest:字节存在但不可解码。
        let manifestURL = workDir.appendingPathComponent("inbox/manifest.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
        try Data("not-json{{".utf8).write(to: manifestURL, options: .atomic)

        // mutate 必须被拒绝 —— 空回退结果不得覆盖毁损文件。
        let refused = store.updateManifest { m in
            m.items.append(SharedInboxItem(
                id: UUID(), scopeKey: SystemScope.guest,
                payloadKind: .text, title: "x"
            ))
        }
        XCTAssertEqual(refused.items.count, 0, "毁损时返回空回退(仅展示用)")
        XCTAssertEqual(
            try String(contentsOf: manifestURL, encoding: .utf8),
            "not-json{{",
            "毁损的 manifest 不得被空回退覆盖"
        )

        // reconcile 不得把已提交的 item 目录当孤儿删除。
        let itemDir = workDir.appendingPathComponent("inbox/items/\(itemID.uuidString)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: itemDir.path))
        store.reconcile()
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: itemDir.path),
            "manifest 不可读时,孤儿收割必须跳过"
        )
    }

    func testInboxStagedPayloadCarriesCompleteProtection() throws {
        let store = SharedInboxStore(root: workDir.appendingPathComponent("inbox2"))
        let itemID = UUID()
        _ = try store.stageTextPayload(itemID: itemID, text: "敏感文本")
        let payload = workDir
            .appendingPathComponent("inbox2/items/\(itemID.uuidString)/payload.txt")
        try verifyProtection(payload, expected: .complete, "收件箱条目锁屏不可读")
        XCTAssertFalse(backupExcluded(payload), "未确认的收件箱是正式数据,留在备份")
    }
}
