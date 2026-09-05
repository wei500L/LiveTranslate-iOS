import SwiftUI

/// 一个对话回合的阅读卡片（全宽，非社交聊天气泡）。
///
/// 折叠态（默认）：
/// - 对方回合："对方说" + 俄语原文 + 突出的中文翻译 + 翻译状态 + 播放/
///   复制/展开；
/// - 用户回复："我的回复" + 突出的带重音俄语 + 较小的中文原文 + 播放/
///   给对方看/复制/展开。
///
/// 展开态（点击）：普通俄语、带重音俄语、中文回译、语气、关键词、
/// 备选表达、歧义/不确定项、重新翻译、编辑原文、删除回合。展开状态
/// 属于 UI 状态，不上传。长按可复制，但主要操作全部可见。
struct InterpreterTurnCard: View {
    let turn: InterpreterTurn
    let isExpanded: Bool
    var showStress: Bool
    var isTranslating: Bool
    /// 本会话仍存在的本地文件来源 documentID 集合（nil = 调用方未
    /// 提供，来源一律按存在渲染）。用于"本机删除文件后 local
    /// citation 如实变为不可用"。
    var availableDocumentIDs: Set<UUID>? = nil
    var onToggleExpanded: () -> Void
    var onRetry: () -> Void
    var onSpeak: () -> Void
    var onPresent: () -> Void
    var onDelete: () -> Void
    /// 编辑原文保存回调（stamp modifiedAt — 合并裁决基准）。
    var onUpdateSource: (String) -> Void

    @State private var showEditSheet = false
    @State private var editedSource = ""

    var body: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            header
            mainContent
            if isTranslating {
                translatingRow
            } else if turn.translationFailed {
                failedRow
            } else if turn.translationStatusRaw == "pending" {
                pendingRow
            }
            actionRow
            if isExpanded {
                expandedDetails
            }
        }
        .ltCard(padding: LTSpacing.m)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggleExpanded)
        .contextMenu {
            Button {
                ClipboardService.shared.copySensitive(primaryCopyText)
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
        }
        .sheet(isPresented: $showEditSheet) {
            editSheet
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: LTSpacing.xs) {
            Image(systemName: turn.speaker == .counterpart ? "person.wave.2" : "person.crop.circle")
                .font(.caption)
                .foregroundStyle(turn.speaker == .counterpart ? LTColors.accentCyan : LTColors.accentGreen)
            Text(turn.speaker.displayName)
                .font(LTTypography.statusChip)
                .foregroundStyle(LTColors.textSecondary)
            Spacer()
            Text(turn.direction == .ru2zh ? "俄 → 中" : "中 → 俄")
                .font(LTTypography.timestamp)
                .foregroundStyle(LTColors.textTertiary)
        }
    }

    // MARK: - Main content

    @ViewBuilder
    private var mainContent: some View {
        if turn.direction == .ru2zh {
            // 对方回合：中文理解结果占视觉主体，俄语原文作为可核对信息。
            VStack(alignment: .leading, spacing: LTSpacing.xs) {
                Text(turn.chineseText.isEmpty ? "…" : turn.chineseText)
                    .font(LTTypography.liveCurrentTranslation)
                    .foregroundStyle(LTColors.textPrimary)
                    .textSelection(.enabled)
                Text(turn.sourceText)
                    .font(LTTypography.liveOriginal)
                    .foregroundStyle(LTColors.textSecondary)
                    .textSelection(.enabled)
            }
        } else {
            // 用户回复：突出的俄语（带重音，可切换），较小的中文原文。
            VStack(alignment: .leading, spacing: LTSpacing.xs) {
                if turn.plainRussian.isEmpty {
                    Text(turn.translationFailed ? "翻译失败" : "生成中…")
                        .font(LTTypography.liveCurrentTranslation)
                        .foregroundStyle(LTColors.textTertiary)
                } else {
                    Text(displayRussian)
                        .font(LTTypography.liveCurrentTranslation)
                        .foregroundStyle(LTColors.textPrimary)
                        .textSelection(.enabled)
                }
                Text(turn.sourceText)
                    .font(LTTypography.liveOriginal)
                    .foregroundStyle(LTColors.textSecondary)
                    .textSelection(.enabled)
            }
        }
    }

    /// 折叠态展示的俄语：默认带重音（校验通过的），无重音标注用普通。
    private var displayRussian: String {
        if showStress, !turn.stressedRussian.isEmpty {
            return turn.stressedRussian
        }
        return turn.plainRussian
    }

    // MARK: - Status rows

    private var translatingRow: some View {
        HStack(spacing: LTSpacing.xs) {
            ProgressView()
            Text("翻译中…")
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.textSecondary)
        }
    }

    private var failedRow: some View {
        HStack(spacing: LTSpacing.xs) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(LTColors.warning)
            Text("翻译失败，原文已保留")
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.warning)
        }
    }

    private var pendingRow: some View {
        Text("等待翻译")
            .font(LTTypography.caption)
            .foregroundStyle(LTColors.textTertiary)
    }

    // MARK: - Actions

    private var actionRow: some View {
        HStack(spacing: LTSpacing.l) {
            // 播放（朗读俄语；系统语音，普通俄语）。
            if !turn.plainRussian.isEmpty {
                Button(action: onSpeak) {
                    Label("播放", systemImage: "speaker.wave.2")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.accentBlue)
                }
            }
            // 给对方看（用户回复专用）。
            if turn.direction == .zh2ru, !turn.plainRussian.isEmpty {
                Button(action: onPresent) {
                    Label("给对方看", systemImage: "rectangle.expand.vertical")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.accentGreen)
                }
            }
            Button {
                ClipboardService.shared.copySensitive(primaryCopyText)
            } label: {
                Label("复制", systemImage: "doc.on.doc")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textSecondary)
            }
            Spacer()
            Button(action: onToggleExpanded) {
                Label(isExpanded ? "收起" : "展开",
                      systemImage: isExpanded ? "chevron.up" : "chevron.down")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textSecondary)
            }
        }
        .buttonStyle(.plain)
    }

    private var primaryCopyText: String {
        turn.direction == .ru2zh
            ? (turn.chineseText.isEmpty ? turn.sourceText : turn.chineseText)
            : (turn.plainRussian.isEmpty ? turn.sourceText : turn.plainRussian)
    }

    // MARK: - Expanded details

    /// 本地文件来源（设备本地字段）—— 本机有标签时逐条呈现；文件
    /// 已被删除的来源如实标灰；只有标记（其他设备的回合）时说明
    /// 来源不在本机。
    @ViewBuilder
    private var localSourcesSection: some View {
        if let localSources = turn.localSources, !localSources.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("来源（仅保存在本设备）")
                    .font(LTTypography.statusChip)
                    .foregroundStyle(LTColors.textTertiary)
                ForEach(Array(localSources.enumerated()), id: \.offset) { _, source in
                    let isAvailable = source.documentID.map { id in
                        availableDocumentIDs?.contains(id) ?? true
                    } ?? true
                    HStack(spacing: LTSpacing.xs) {
                        Image(systemName: isAvailable ? "doc.text" : "doc.slash")
                            .font(LTTypography.caption)
                            .foregroundStyle(
                                isAvailable ? LTColors.textTertiary : LTColors.destructive
                            )
                        VStack(alignment: .leading, spacing: 1) {
                            Text(source.displayLabel)
                                .font(LTTypography.caption)
                                .foregroundStyle(
                                    isAvailable ? LTColors.textSecondary : LTColors.textTertiary
                                )
                                .strikethrough(!isAvailable, color: LTColors.textTertiary)
                            if !source.snippet.isEmpty {
                                Text(source.snippet)
                                    .font(LTTypography.caption)
                                    .foregroundStyle(LTColors.textTertiary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    if !isAvailable {
                        Text("该来源文件已从本机删除")
                            .font(LTTypography.caption)
                            .foregroundStyle(LTColors.textTertiary)
                    }
                }
            }
        } else if turn.details?.hasLocalSources == true {
            Text("来源文件仅保存在原设备；本设备未保存该文件。")
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.textTertiary)
        }
    }

    @ViewBuilder
    private var expandedDetails: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            Divider().overlay(LTColors.separator)

            if turn.direction == .zh2ru {
                detailRow(title: "普通俄语", value: turn.plainRussian)
                detailRow(title: "带重音俄语", value: turn.stressedRussian.isEmpty ? "暂未生成重音标注" : turn.stressedRussian)
                detailRow(title: "中文回译", value: turn.backTranslation)
            } else {
                detailRow(title: "普通俄语", value: turn.plainRussian)
                detailRow(title: "带重音俄语", value: turn.stressedRussian.isEmpty ? "暂未生成重音标注" : turn.stressedRussian)
            }

            if let details = turn.details {
                if !details.detailsAvailable {
                    Text("本次为纯文本翻译，详细解释不可用")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textTertiary)
                }
                detailRow(title: "意图", value: details.intentSummary)
                detailList(title: "关键词", items: details.keywords)
                detailRow(title: "歧义", value: details.ambiguity)
                detailList(title: "不确定项", items: details.uncertainties)
                detailRow(title: "更礼貌的表达", value: details.politeAlternative)
                detailRow(title: "更简单的表达", value: details.simpleAlternative)
            }

            // 文件上下文回合的来源。真实标签只存在本机
            // （localSourcesJSON —— 从不上传）；details 只携带无内容的
            // hasLocalSources 标记。其他设备打开同一会话时看到的是
            // 标记而非标签 —— 显示"来源文件仅保存在原设备"，绝不渲染
            // 一个打不开的假链接。
            localSourcesSection

            // 编辑原文（stamp modifiedAt — 合并裁决基准）。
            Button {
                editedSource = turn.sourceText
                showEditSheet = true
            } label: {
                Label("编辑原文", systemImage: "pencil")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.accentBlue)
            }
            .buttonStyle(.plain)

            // 重新翻译（支持逐条重试）。
            Button(action: onRetry) {
                Label("重新翻译", systemImage: "arrow.clockwise")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.accentBlue)
            }
            .buttonStyle(.plain)

            Button(role: .destructive, action: onDelete) {
                Label("删除回合", systemImage: "trash")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.destructive)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func detailRow(title: String, value: String?) -> some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(LTTypography.statusChip)
                    .foregroundStyle(LTColors.textTertiary)
                Text(value)
                    .font(LTTypography.body)
                    .foregroundStyle(LTColors.textSecondary)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func detailList(title: String, items: [String]?) -> some View {
        if let items, !items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(LTTypography.statusChip)
                    .foregroundStyle(LTColors.textTertiary)
                ForEach(items, id: \.self) { item in
                    Text("· \(item)")
                        .font(LTTypography.body)
                        .foregroundStyle(LTColors.textSecondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: - Edit sheet

    private var editSheet: some View {
        NavigationStack {
            Form {
                Section("原文（编辑后可重新翻译）") {
                    TextField("原文", text: $editedSource, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .navigationTitle("编辑原文")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showEditSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onUpdateSource(editedSource)
                        showEditSheet = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
