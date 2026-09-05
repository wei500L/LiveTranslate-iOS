import SwiftUI

/// 隐私与数据 (round 17): the single privacy control center. Shows what
/// lives on this device, what syncs to the private server, what goes to
/// the AI service — and every round-17 protection switch.
///
/// Copy rules: no fake guarantees. Data protection ≠ end-to-end
/// encryption; the mask ≠ screenshot prevention; each section says what
/// is actually true.
struct PrivacyDataScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var exportStore = TemporaryExportStore()
    @State private var exportBytes: Int64 = 0
    @State private var interpreterDocumentBytes: Int64 = 0
    @State private var inboxBytes: Int64 = 0
    @State private var aiActivityBytes: Int64 = 0
    @State private var clearedExports = false
    @State private var clearedActivity = false

    var body: some View {
        List {
            protectionSection
            surfaceContentSection
            clipboardSection
            dataLocationsSection
            aiActivitySection
            retentionSection
            cleanupSection
            dangerZoneSection
        }
        .navigationTitle("隐私与数据")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { dismiss() }
            }
        }
        .task { refreshStats() }
    }

    private func refreshStats() {
        exportBytes = exportStore.totalBytes()
        interpreterDocumentBytes = environment.interpreterDocumentStore.totalBytes()
        inboxBytes = SharedInboxStore()?.statistics().bytesOnDisk ?? 0
        aiActivityBytes = environment.aiActivityLog.totalBytes
    }

    // MARK: - 保护开关

    private var protectionSection: some View {
        Section {
            Toggle(isOn: privacyLockBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("隐私锁")
                    Text("打开 App 或返回前台时需要 Face ID、触控 ID 或设备密码。开关与解锁状态只保存在本机，不同步、不跨账号。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if environment.settings.privacyLockEnabled {
                Picker("重新验证时机", selection: graceBinding) {
                    Text("立即").tag(0)
                    Text("1 分钟后").tag(60)
                    Text("5 分钟后").tag(300)
                    Text("15 分钟后").tag(900)
                }
            }
            Toggle(isOn: maskingBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("后台预览遮挡")
                    Text("切到任务切换器或通知时，用品牌占位层盖住界面 —— 系统快照里不会出现课堂转录或文件内容。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: captureMaskingBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("录屏与镜像遮挡")
                    Text("检测到正在录屏或投屏时，遮挡随身翻译、账号安全等敏感页面。截图无法被任何 App 阻止 —— 这只覆盖主动录屏与镜像。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("本机保护")
        } footer: {
            Text("隐私锁使用系统生物认证，不建立任何自定义密码库。课堂录音在锁屏后仍按系统后台音频规则继续。")
        }
    }

    private var privacyLockBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.privacyLockEnabled },
            set: { enabled in
                environment.settings.privacyLockEnabled = enabled
                if enabled {
                    environment.privacyLock.lockNow()
                } else {
                    environment.privacyLock.disable()
                }
            }
        )
    }

    private var graceBinding: Binding<Int> {
        Binding(
            get: { environment.settings.privacyLockGraceSeconds },
            set: { environment.settings.privacyLockGraceSeconds = $0 }
        )
    }

    private var maskingBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.backgroundMaskingEnabled },
            set: { environment.settings.backgroundMaskingEnabled = $0 }
        )
    }

    private var captureMaskingBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.screenCaptureMaskingEnabled },
            set: { environment.settings.screenCaptureMaskingEnabled = $0 }
        )
    }

    // MARK: - 系统界面内容级别

    private var surfaceContentSection: some View {
        Section {
            Picker("锁屏与小组件内容", selection: surfacePrivacyBinding) {
                Text("完整内容").tag(SystemSurfacePrivacy.showFullContent)
                Text("仅标题（默认）").tag(SystemSurfacePrivacy.showTitlesOnly)
                Text("仅状态").tag(SystemSurfacePrivacy.hideSensitiveContent)
            }
            .pickerStyle(.segmented)
            Text(surfaceHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("锁屏 · 小组件 · 通知 · Spotlight")
        } footer: {
            Text("一个级别控制所有系统界面：锁屏实时课堂、灵动岛、小组件、通知正文与 Spotlight 搜索。转录正文、OCR 与证件内容从不进入任何系统界面。")
        }
    }

    private var surfacePrivacyBinding: Binding<SystemSurfacePrivacy> {
        Binding(
            get: { environment.settings.systemSurfacePrivacy },
            set: { newValue in
                environment.settings.systemSurfacePrivacy = newValue
                // The live activity's title is immutable — the
                // coordinator recreates it under the new policy.
                environment.systemCoordinator?.handleSurfacePrivacyChange()
            }
        )
    }

    private var surfaceHint: String {
        switch environment.settings.systemSurfacePrivacy {
        case .showFullContent:
            return "锁屏实时课堂额外显示最新一条中文翻译。"
        case .showTitlesOnly:
            return "锁屏与小组件显示课堂/课程名称与时间，不显示转录正文。"
        case .hideSensitiveContent:
            return "锁屏、小组件、通知与 Spotlight 不显示任何名称 —— 只有状态与时间。Spotlight 索引同时关闭。"
        }
    }

    // MARK: - 剪贴板

    private var clipboardSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                LabeledRow(label: "复制保留", value: "翻译/OCR 2 分钟 · 普通短语不限")
                Text("敏感内容复制后仅在本机剪贴板保留 2 分钟（到期自动失效），且不参与跨设备接力。普通短语（如公式）只保留在本机。你之后复制的其他内容不会被本 App 清除。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("立即清除本 App 复制的内容") {
                _ = ClipboardService.shared.clearIfStillOurs()
            }
        } header: {
            Text("剪贴板")
        }
    }

    // MARK: - 数据在哪里

    private var dataLocationsSection: some View {
        Section {
            dataRow(
                title: "课堂转录 · 笔记 · 复习 · 课程资料",
                detail: "保存在本机的数据库中；登录后按你的选择同步到自建服务器。"
            )
            dataRow(
                title: "随身翻译文件（证件/表格/PDF）",
                detail: "只保存在这台设备：不进云同步、不进设备备份，App 之外无法访问。服务器上只有不含文件名与引文的对话文本。"
            )
            dataRow(
                title: "课堂录音",
                detail: "默认不保存；开启后只在本机，不随文字记录上传。"
            )
            dataRow(
                title: "AI 请求",
                detail: "你在设置中配置的翻译模型服务。发送内容因功能而异（转录/OCR/图片），随身翻译文件发送前会先显示预览并默认遮盖敏感信息。"
            )
        } header: {
            Text("数据在哪里")
        } footer: {
            Text("自建服务器同步与 Apple 设备备份是两件不同的事：前者是你账号下设备间的数据同步，后者是整机备份。随身翻译的原始文件两者都不进入。")
        }
    }

    private func dataRow(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.medium))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - AI 数据活动记录

    private var aiActivitySection: some View {
        Section {
            if environment.aiActivityLog.entries.isEmpty {
                Text("暂无记录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(environment.aiActivityLog.entries.suffix(50).reversed()) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(entry.feature.displayName)
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Text(Self.outcomeLabel(entry.outcome))
                                .font(.caption)
                                .foregroundStyle(
                                    entry.outcome == .failed
                                        ? LTColors.destructive
                                        : LTColors.textTertiary
                                )
                        }
                        Text(Self.entryMetadataLine(entry))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            Button("清空活动记录", role: .destructive) {
                environment.aiActivityLog.clear()
                clearedActivity = true
            }
        } header: {
            Text("AI 数据活动记录")
        } footer: {
            Text("只记录时间、功能、数据类别、字符/图片数量、是否遮盖、结果与服务商地址 —— 不记录请求正文、密钥或完整 URL。仅保存在本机，保留 \(Int(AIActivityLog.retention / 86_400)) 天，不进入同步或系统日志。这不是服务商侧的审计日志。\(clearedActivity ? "已清空。" : "")\(aiActivityBytes > 0 ? "当前占用 \(Format.bytes(aiActivityBytes))。" : "")")
        }
    }

    /// One metadata line per activity entry (kept as a helper — the
    /// inline concatenation exceeded the type-checker's budget).
    private static func entryMetadataLine(_ entry: AIActivityLog.Entry) -> String {
        var parts: [String] = [
            entry.occurredAt.formatted(date: .abbreviated, time: .shortened)
        ]
        if !entry.host.isEmpty { parts.append(entry.host) }
        var categoryAndCount = entry.textCategory.displayName
        if !categoryAndCount.isEmpty { categoryAndCount += " " }
        parts.append("\(categoryAndCount)\(entry.characterCount) 字")
        if entry.imageCount > 0 { parts.append("\(entry.imageCount) 图") }
        if entry.masked { parts.append("已遮盖") }
        return parts.joined(separator: " · ")
    }

    private static func outcomeLabel(_ outcome: AIActivityLog.Entry.Outcome) -> String {
        switch outcome {
        case .success: return "成功"
        case .cancelled: return "已取消"
        case .failed: return "失败"
        }
    }

    // MARK: - 敏感文件保留策略

    private var retentionSection: some View {
        Section {
            Picker("随身翻译文件保留", selection: retentionBinding) {
                Text("永久保留（默认）").tag(0)
                Text("保留 30 天").tag(30)
                Text("保留 7 天").tag(7)
                Text("保留 1 天").tag(1)
            }
            Text("到期文件在下次启动时删除（只处理已保存会话的文件；正在进行的草稿与收件箱不受影响）。删除同时清理数据库记录与文件。")
                .font(.caption)
                .foregroundStyle(.secondary)
            LabeledRow(
                label: "随身翻译文件占用",
                value: Format.bytes(interpreterDocumentBytes)
            )
        } header: {
            Text("敏感文件保留策略")
        }
    }

    private var retentionBinding: Binding<Int> {
        Binding(
            get: { environment.settings.interpreterDocumentRetentionDays },
            set: { environment.settings.interpreterDocumentRetentionDays = $0 }
        )
    }

    // MARK: - 清理

    private var cleanupSection: some View {
        Section {
            LabeledRow(label: "临时导出占用", value: Format.bytes(exportBytes))
            Button("清除临时导出文件") {
                _ = exportStore.reapAll()
                clearedExports = true
                refreshStats()
            }
            LabeledRow(label: "智能收件箱占用", value: Format.bytes(inboxBytes))
            Button("清理收件箱孤儿文件") {
                environment.inbox.reconcile()
                refreshStats()
            }
        } header: {
            Text("清理")
        } footer: {
            Text("临时导出是分享面板生成的文件副本（24 小时后自动清理）；清除它们不影响你正式导入的资料、附件或录音。\(clearedExports ? "已清除。" : "")")
        }
    }

    // MARK: - 删除控制（明确分层）

    private var dangerZoneSection: some View {
        Section {
            NavigationLink("删除云端数据 / 删除账号") {
                CloudSyncSettingsView()
            }
        } header: {
            Text("删除")
        } footer: {
            Text("删除分三层：清缓存（上面）只删可再生副本；\"删除本机记录\"在记录页按会话删除；\"删除云端数据 / 删除账号\"影响服务器上的数据。清缓存永远不会删除云端内容。")
        }
    }
}
