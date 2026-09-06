import SwiftUI

// 一个对话回合的聚焦式排版（第十九轮柜台重构）。
//
// 排版决策全部来自 InterpreterTurnPresentation（纯函数派生）：
// - 对方回合：中文翻译是第一视觉层级，俄语原文是核对层；
// - 我的回复：普通俄语译文是第一视觉层级（也是 TTS 与"给对方看"
//   的唯一来源），中文原意是核对层；
// - pending / translating / failed：原文先稳定落位，绝不显示伪骨架；
//   失败的重试直接可见；
// - 层级（当前/最近/历史）由时间线位置决定 —— 字号与颜色逐级降，
//   不用低到无法阅读的透明度；
// - 非聊天气泡：全宽阅读块，角色用短标签与细微强调色区分。

/// 回合动作回调束（避免平铺 props）。
struct InterpreterTurnActions {
    var onSpeak: () -> Void = {}
    var onCopy: (String) -> Void = { _ in }
    var onPresent: () -> Void = {}
    var onRetry: () -> Void = {}
    var onEditSource: (String) -> Void = { _ in }
    var onDelete: () -> Void = {}
    var onToggleExpanded: () -> Void = {}
    /// 记入当前办事事项（第二十轮：确认 sheet 由页面持有）。
    var onRecordToErrand: (() -> Void)? = nil
    /// 快速回复（第二十轮：暂停连续听 + 聚焦输入框；nil = 不提供）。
    var onBeginReply: (() -> Void)? = nil
}

struct InterpreterTurnRow: View {
    let turn: InterpreterTurn
    let presentation: InterpreterTurnPresentation
    let emphasis: InterpreterTimelineEmphasis
    let isExpanded: Bool
    /// 本会话仍存在的本地文件来源 documentID 集合（nil = 按存在渲染）。
    var availableDocumentIDs: Set<UUID>? = nil
    let actions: InterpreterTurnActions

    @State private var showEditSheet = false
    @State private var editedSource = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - 排版 token（层级 → 字号/颜色）

    private var primaryFont: Font {
        switch emphasis {
        case .current: return LTTypography.interpreterPrimaryCurrent
        case .recent: return LTTypography.interpreterPrimaryRecent
        case .history: return LTTypography.interpreterPrimaryHistory
        }
    }

    private var secondaryFont: Font {
        switch emphasis {
        case .current: return LTTypography.interpreterSecondaryCurrent
        case .recent: return LTTypography.interpreterSecondaryRecent
        case .history: return LTTypography.interpreterSecondaryHistory
        }
    }

    private var primaryColor: Color {
        switch emphasis {
        case .current, .recent: return LTColors.textPrimary
        case .history: return LTColors.textSecondary
        }
    }

    private var roleTint: Color {
        presentation.role == .counterpart ? LTColors.accentCyan : LTColors.accentGreen
    }

    private var isCurrent: Bool { emphasis == .current }

    var body: some View {
        VStack(alignment: .leading, spacing: LTSpacing.xs) {
            header
            mainContent
            statusSection
            actionRow
            if isExpanded {
                expandedDetails
            }
        }
        // 当前聚焦回合获得轻量材质与角色色边缘高亮；历史回合是安静的
        // 阅读块（不套厚卡片）。
        .modifier(InterpreterTurnSurface(
            isCurrent: isCurrent, tint: roleTint, reduceMotion: reduceMotion
        ))
        .contentShape(Rectangle())
        .onTapGesture(perform: actions.onToggleExpanded)
        .contextMenu {
            Button {
                actions.onCopy(presentation.copyText)
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
        }
        .sheet(isPresented: $showEditSheet) {
            editSheet
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.accessibilitySummary)
    }

    // MARK: - Header（角色 + 编辑标记）

    private var header: some View {
        HStack(spacing: LTSpacing.xs) {
            Image(systemName: presentation.role == .counterpart
                ? "person.wave.2" : "person.crop.circle")
                .font(.caption.weight(.medium))
                .foregroundStyle(roleTint)
            Text(presentation.role.displayName)
                .font(LTTypography.statusChip)
                .foregroundStyle(LTColors.textSecondary)
            if presentation.isEdited {
                Text("已编辑")
                    .font(LTTypography.statusChip)
                    .foregroundStyle(LTColors.warning)
            }
            Spacer()
            overflowMenu
        }
    }

    private var overflowMenu: some View {
        Menu {
            ForEach(presentation.overflowActions, id: \.self) { action in
                switch action {
                case .editSource:
                    Button {
                        editedSource = turn.sourceText
                        showEditSheet = true
                    } label: {
                        Label("编辑原文", systemImage: "pencil")
                    }
                case .retryTranslation:
                    Button {
                        actions.onRetry()
                    } label: {
                        Label("重新翻译", systemImage: "arrow.clockwise")
                    }
                case .deleteTurn:
                    Button(role: .destructive) {
                        actions.onDelete()
                    } label: {
                        Label("删除回合", systemImage: "trash")
                    }
                case .recordToErrand:
                    // 历史对方回合的记入事项（低频路径）。
                    if let onRecordToErrand = actions.onRecordToErrand {
                        Button(action: onRecordToErrand) {
                            Label("记入事项", systemImage: "checklist")
                        }
                    }
                default:
                    EmptyView()
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 17))
                .foregroundStyle(LTColors.textTertiary)
                .frame(minWidth: LTSpacing.minTouchTarget, minHeight: LTSpacing.minTouchTarget)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("更多操作")
        .disabled(presentation.overflowActions.isEmpty)
    }

    // MARK: - 主内容（主文本 → 核对层）

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: LTSpacing.xs) {
            Text(presentation.primaryText)
                .font(primaryFont)
                .foregroundStyle(primaryColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !presentation.secondaryText.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    if !presentation.secondaryLabel.isEmpty, emphasis != .history {
                        Text(presentation.secondaryLabel)
                            .font(LTTypography.statusChip)
                            .foregroundStyle(LTColors.textTertiary)
                    }
                    Text(presentation.secondaryText)
                        .font(secondaryFont)
                        .foregroundStyle(LTColors.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 状态行（pending / translating / failed）

    /// 高度稳定的状态区：pending/translating/failed 各占固定行高，
    /// 翻译完成时主文本原位更新（不重插、不闪烁）。
    @ViewBuilder
    private var statusSection: some View {
        switch presentation.phase {
        case .completed:
            EmptyView()
        case .pending:
            statusRow {
                Text(presentation.statusText ?? "")
                    .foregroundStyle(LTColors.textTertiary)
            }
        case .translating:
            statusRow {
                HStack(spacing: LTSpacing.xs) {
                    ProgressView()
                        .controlSize(.small)
                    Text(presentation.statusText ?? "翻译中…")
                        .foregroundStyle(LTColors.textSecondary)
                }
            }
        case .failed:
            // 失败：状态 + 重试直接可见（不藏进展开区）。
            statusRow {
                HStack(spacing: LTSpacing.s) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(LTColors.warning)
                    Text(presentation.statusText ?? "翻译失败")
                        .foregroundStyle(LTColors.warning)
                    Spacer()
                    Button {
                        actions.onRetry()
                    } label: {
                        Label("重试", systemImage: "arrow.clockwise")
                            .font(LTTypography.interpreterStatus.weight(.medium))
                            .foregroundStyle(LTColors.accentBlue)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("重试翻译这条内容")
                }
            }
        }
    }

    @ViewBuilder
    private func statusRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(LTTypography.interpreterStatus)
            .frame(minHeight: 22, alignment: .leading)
    }

    // MARK: - 高频动作行

    private var actionRow: some View {
        HStack(spacing: LTSpacing.l) {
            ForEach(presentation.primaryActions, id: \.self) { action in
                switch action {
                case .speakRussian:
                    Button(action: actions.onSpeak) {
                        Label("播放", systemImage: "speaker.wave.2")
                            .font(LTTypography.interpreterStatus)
                            .foregroundStyle(LTColors.accentBlue)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("播放俄语")
                case .copyPrimary:
                    Button {
                        actions.onCopy(presentation.copyText)
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                            .font(LTTypography.interpreterStatus)
                            .foregroundStyle(LTColors.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("复制主文本")
                case .presentToCounterpart:
                    Button(action: actions.onPresent) {
                        Label("给对方看", systemImage: "rectangle.expand.vertical")
                            .font(LTTypography.interpreterStatus)
                            .foregroundStyle(LTColors.accentGreen)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("给对方看这条俄语")
                case .recordToErrand:
                    if let onRecordToErrand = actions.onRecordToErrand {
                        Button(action: onRecordToErrand) {
                            Label("记入事项", systemImage: "checklist")
                                .font(LTTypography.interpreterStatus)
                                .foregroundStyle(LTColors.accentBlue)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("把这条现场要求记入当前办事事项")
                    }
                case .beginReply:
                    if let onBeginReply = actions.onBeginReply {
                        Button(action: onBeginReply) {
                            Label("回复", systemImage: "arrowshape.turn.up.left")
                                .font(LTTypography.interpreterStatus)
                                .foregroundStyle(LTColors.accentGreen)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("回复对方，暂停连续收听并聚焦输入框")
                    }
                default:
                    EmptyView()
                }
            }
            Spacer()
            Button(action: actions.onToggleExpanded) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.footnote)
                    .foregroundStyle(LTColors.textTertiary)
                    .frame(minWidth: LTSpacing.minTouchTarget, minHeight: LTSpacing.minTouchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "收起详情" : "展开详情")
        }
    }

    // MARK: - 展开详情（三级核对内容，默认折叠）

    @ViewBuilder
    private var expandedDetails: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            Divider().overlay(LTColors.separator)
            ForEach(
                InterpreterTurnPresentation.supplementRows(for: turn, presentation: presentation)
            ) { row in
                switch row.value {
                case .text(let value):
                    detailRow(title: row.title, value: value)
                case .list(let items):
                    detailList(title: row.title, items: items)
                }
            }
            localSourcesSection
        }
    }

    @ViewBuilder
    private func detailRow(title: String, value: String) -> some View {
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

    @ViewBuilder
    private func detailList(title: String, items: [String]) -> some View {
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

    // MARK: - 本地文件来源（设备本地字段 —— 绝不进 wire）

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
        } else if presentation.hasLocalSources {
            Text("来源文件仅保存在原设备；本设备未保存该文件。")
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.textTertiary)
        }
    }

    // MARK: - 编辑原文 sheet

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
                        actions.onEditSource(editedSource)
                        showEditSheet = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - 当前回合表面（轻量材质 + 角色色边缘）

/// 当前聚焦回合的克制层次：微升表面 + 细边框 + 3pt 角色色前缘。
/// 历史/最近回合为透明阅读块（Reduce Motion 下无过渡动画）。
private struct InterpreterTurnSurface: ViewModifier {
    let isCurrent: Bool
    let tint: Color
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        if isCurrent {
            content
                .padding(.horizontal, LTSpacing.m)
                .padding(.vertical, LTSpacing.s + 2)
                .background(
                    RoundedRectangle(cornerRadius: LTRadius.medium)
                        .fill(LTColors.surfacePrimary.opacity(0.92))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: LTRadius.medium)
                        .strokeBorder(LTColors.border, lineWidth: 0.5)
                )
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(tint.opacity(0.85))
                        .frame(width: 3)
                        .padding(.vertical, LTSpacing.s)
                        .accessibilityHidden(true)
                }
                .animation(reduceMotion ? nil : LTMotion.quick, value: isCurrent)
        } else {
            content
                .padding(.horizontal, LTSpacing.m)
                .padding(.vertical, LTSpacing.xs + 2)
        }
    }
}
