import SwiftUI

// 办事上下文条 + 待问问题/材料/文件 sheet（第十九轮柜台重构）。
//
// 文件和事项是翻译的上下文，不是时间线里的聊天消息：
// - 从 ErrandCase 进入时显示一条轻量上下文（最多一到两行）：通用
//   标签、受隐私档位门控的事项标题、未完成问题数、本机文件状态；
// - 普通进入（无事项、无文件）不显示空占位；
// - 待问问题点击只填入中文输入框 —— 不自动翻译、不自动发送、不自动
//   朗读；文件上下文以可移除的本地 chip 表达（移除 = 不随 AI 请求
//   发送，原文件不受影响）；不把对话自动写回 ErrandCase。

// MARK: - 上下文条

struct InterpreterContextBar: View {
    let counterContext: InterpreterCounterContext?
    /// 文件上下文摘要（nil = 无文件）。
    let documentSummary: DocumentSummary?
    /// 表单字段询问上下文（第二十一轮；nil = 无 —— 从填写页进入对话
    /// 时显示"当前字段"chip）。
    var fieldAskChip: String?
    /// 结束字段询问（chip 的移除操作）。
    var onEndFieldAsk: (() -> Void)?
    let onOpenSheet: () -> Void
    let onOpenDocuments: () -> Void
    /// 移除文件 chip：清除页面选择（原文件保留；之后的 AI 请求不再
    /// 自动携带文件内容）。
    let onRemoveDocumentContext: () -> Void

    struct DocumentSummary: Equatable {
        let readyCount: Int
        let totalCount: Int
        let extracting: Bool
        /// 是否仍有选中的页面（false = 用户已移除文件上下文）。
        let hasSelection: Bool
    }

    private var hasAnyContext: Bool {
        counterContext != nil
            || (documentSummary?.totalCount ?? 0) > 0
            || fieldAskChip != nil
    }

    var body: some View {
        if hasAnyContext {
            Button {
                if counterContext != nil {
                    onOpenSheet()
                } else {
                    onOpenDocuments()
                }
            } label: {
                HStack(spacing: LTSpacing.s) {
                    Image(systemName: "checklist")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(LTColors.accentBlue)
                    contextText
                    Spacer(minLength: 0)
                    if documentSummary?.extracting == true {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(LTColors.textTertiary)
                }
                .font(LTTypography.statusChip)
                .padding(.horizontal, LTSpacing.m)
                .padding(.vertical, LTSpacing.xs + 2)
                .background(
                    RoundedRectangle(cornerRadius: LTRadius.medium)
                        .fill(LTColors.surfaceElevated.opacity(0.4))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: LTRadius.medium)
                        .strokeBorder(LTColors.border, lineWidth: 0.5)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, LTSpacing.screenPadding)
            .padding(.top, LTSpacing.xs)
            .accessibilityLabel(accessibilitySummary)
        }
    }

    private var contextText: some View {
        HStack(spacing: LTSpacing.s) {
            if let counterContext {
                Text("正在办理")
                    .foregroundStyle(LTColors.textTertiary)
                Text(counterContext.displayTitle)
                    .foregroundStyle(LTColors.textPrimary)
                    .lineLimit(1)
                if counterContext.pendingQuestionCount > 0 {
                    Text("· \(counterContext.pendingQuestionCount) 个待问")
                        .foregroundStyle(LTColors.textSecondary)
                }
            }
            if let fieldAskChip {
                fieldAskChipView(fieldAskChip)
            }
            if let summary = documentSummary, summary.totalCount > 0 {
                documentChip(summary)
            }
        }
    }

    /// 当前字段 chip：简洁（俄文标签），可结束询问。
    private func fieldAskChipView(_ label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "list.number")
                .foregroundStyle(LTColors.accentGreen)
            Text(label)
                .foregroundStyle(LTColors.textSecondary)
                .lineLimit(1)
            if let onEndFieldAsk {
                Button {
                    onEndFieldAsk()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(LTColors.textTertiary)
                        .frame(minWidth: 22, minHeight: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("结束字段询问")
            }
        }
        .padding(.horizontal, LTSpacing.xs + 2)
        .padding(.vertical, 2)
        .background(Capsule().fill(LTColors.backgroundPrimary.opacity(0.5)))
    }

    /// 文件上下文 chip：紧凑、可移除（点击 xmark 清除页面选择 ——
    /// 原文件保留在本机；之后进入文件面板可重新选用）。
    @ViewBuilder
    private func documentChip(_ summary: DocumentSummary) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(LTColors.accentCyan)
            if summary.hasSelection {
                Text("文件 ×\(summary.totalCount)")
                    .foregroundStyle(LTColors.textSecondary)
                Button {
                    onRemoveDocumentContext()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(LTColors.textTertiary)
                        .frame(minWidth: 22, minHeight: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("移除文件上下文（不删除文件）")
            } else {
                Text("文件未选用")
                    .foregroundStyle(LTColors.textTertiary)
            }
        }
        .padding(.horizontal, LTSpacing.xs + 2)
        .padding(.vertical, 2)
        .background(Capsule().fill(LTColors.backgroundPrimary.opacity(0.5)))
    }

    private var accessibilitySummary: String {
        var parts: [String] = []
        if let counterContext {
            parts.append("正在办理 \(counterContext.displayTitle)")
            if counterContext.pendingQuestionCount > 0 {
                parts.append("\(counterContext.pendingQuestionCount) 个待问问题")
            }
        }
        if let fieldAskChip {
            parts.append(fieldAskChip)
        }
        if let summary = documentSummary, summary.totalCount > 0 {
            parts.append(summary.hasSelection
                ? "\(summary.totalCount) 份文件上下文"
                : "文件未选用")
        }
        parts.append("点击打开")
        return parts.joined(separator: "，")
    }
}

// MARK: - 办事上下文 sheet（待问问题 / 材料 / 文件 / 已确认信息）

struct InterpreterErrandContextSheet: View {
    @Environment(AppEnvironment.self) private var environment
    /// 关联事项（nil = 无事项 —— 显示诚实空态而非假数据）。
    let caseID: UUID?
    /// 点击待问问题 → 只填入输入框（不自动翻译/发送/朗读）。
    let onPrefillQuestion: (String) -> Void
    let onOpenDocuments: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var errandCase: ErrandCase?
    @State private var items: [ErrandCaseItem] = []

    private var surfacePrivacy: SystemSurfacePrivacy {
        environment.settings.systemSurfacePrivacy
    }

    var body: some View {
        NavigationStack {
            LTPage {
                ScrollView {
                    VStack(alignment: .leading, spacing: LTSpacing.l) {
                        if let errandCase {
                            headerSection(errandCase)
                            questionsSection
                            materialsSection
                            confirmedSection(errandCase)
                        } else {
                            LTEmptyState(
                                symbol: "checklist",
                                title: caseID == nil ? "没有关联的办事事项" : "事项已不存在",
                                message: caseID == nil
                                    ? "从办事事项的\"开始现场沟通\"进入时会带上待问问题与材料清单。"
                                    : "这个办事事项可能已在本机或其他设备删除。"
                            )
                        }
                    }
                    .padding(.horizontal, LTSpacing.screenPadding)
                    .padding(.vertical, LTSpacing.m)
                }
            }
            .navigationTitle("现场沟通上下文")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .screenCaptureMask()
        .task { reload() }
    }

    private func reload() {
        guard let caseID else {
            errandCase = nil
            items = []
            return
        }
        errandCase = environment.repository.errandCase(id: caseID)
        items = (try? environment.repository.errandCaseItems(caseID: caseID)) ?? []
    }

    // MARK: - 头部（隐私档位门控标题）

    private func headerSection(_ errandCase: ErrandCase) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.xs) {
            HStack(spacing: LTSpacing.s) {
                LTIconBadge(
                    symbol: errandCase.scene.symbol,
                    tint: LTColors.accentBlue
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(surfacePrivacy.showsTitles ? errandCase.title : "正在办理的事项")
                        .font(LTTypography.cardTitle)
                        .foregroundStyle(LTColors.textPrimary)
                    Text("\(errandCase.scene.displayName) · \(errandCase.status.displayName)")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textSecondary)
                }
                Spacer()
            }
            if !errandCase.purpose.isEmpty, surfacePrivacy.showsTitles {
                Text(errandCase.purpose)
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textSecondary)
            }
        }
        .ltCard(padding: LTSpacing.m)
        .accessibilityElement(children: .combine)
    }

    // MARK: - 待问问题（点击只填输入框）

    @ViewBuilder
    private var questionsSection: some View {
        let questions = items.filter {
            $0.kind == .question && $0.status != .done && $0.status != .skipped
        }
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            LTSectionHeader(title: "待问问题（\(questions.count)）")
            if questions.isEmpty {
                Text("没有记录待问问题")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textTertiary)
            }
            ForEach(questions) { question in
                Button {
                    // 只填入输入框 —— 不自动翻译、不自动发送、不自动朗读。
                    onPrefillQuestion(question.title)
                    dismiss()
                } label: {
                    HStack(alignment: .top, spacing: LTSpacing.s) {
                        Image(systemName: "questionmark.bubble")
                            .font(.footnote)
                            .foregroundStyle(LTColors.accentCyan)
                            .padding(.top, 2)
                        Text(question.title)
                            .font(LTTypography.body)
                            .foregroundStyle(LTColors.textPrimary)
                            .multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: "text.insert")
                            .font(.caption)
                            .foregroundStyle(LTColors.textTertiary)
                    }
                    .padding(LTSpacing.s)
                    .background(
                        RoundedRectangle(cornerRadius: LTRadius.medium)
                            .fill(LTColors.surfaceElevated.opacity(0.4))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("把问题填入输入框：\(question.title)")
            }
        }
    }

    // MARK: - 待备材料

    @ViewBuilder
    private var materialsSection: some View {
        let materials = items.filter {
            $0.kind == .requiredDocument && $0.status != .done && $0.status != .skipped
        }
        if !materials.isEmpty {
            VStack(alignment: .leading, spacing: LTSpacing.s) {
                LTSectionHeader(title: "未备材料（\(materials.count)）")
                ForEach(materials) { material in
                    HStack(spacing: LTSpacing.s) {
                        Image(systemName: material.status == .pending
                            ? "doc.text" : "doc.badge.ellipsis")
                            .font(.footnote)
                            .foregroundStyle(LTColors.warning)
                        Text(material.title)
                            .font(LTTypography.body)
                            .foregroundStyle(LTColors.textPrimary)
                        Spacer()
                    }
                    .padding(.vertical, LTSpacing.xs)
                }
            }
        }
    }

    // MARK: - 已确认信息（地点 / 费用 / 时间）+ 文件入口

    private func confirmedSection(_ errandCase: ErrandCase) -> some View {
        let rows = confirmedRows(errandCase)
        return VStack(alignment: .leading, spacing: LTSpacing.s) {
            LTSectionHeader(title: "已确认信息")
            if rows.isEmpty {
                Text("尚无已确认的地点/联系方式/费用/时间")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textTertiary)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: LTSpacing.s) {
                    Text(row.0)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LTColors.textSecondary)
                        .frame(width: 56, alignment: .leading)
                    Text(row.1)
                        .font(.footnote)
                        .foregroundStyle(LTColors.textPrimary)
                    Spacer()
                }
            }
            Divider().overlay(LTColors.separator)
            Button {
                onOpenDocuments()
                dismiss()
            } label: {
                Label("现场文件与按文件提问", systemImage: "doc.text.magnifyingglass")
                    .font(LTTypography.body)
                    .foregroundStyle(LTColors.accentBlue)
            }
            .buttonStyle(.plain)
        }
        .ltCard(padding: LTSpacing.m)
    }

    private func confirmedRows(_ errandCase: ErrandCase) -> [(String, String)] {
        var rows: [(String, String)] = []
        let privacy = surfacePrivacy
        if privacy.showsTitles {
            if !errandCase.location.isEmpty { rows.append(("地点", errandCase.location)) }
            if !errandCase.contact.isEmpty { rows.append(("联系方式", errandCase.contact)) }
        }
        let payments = items.filter {
            $0.kind == .payment && $0.status != .unconfirmed
        }
        for payment in payments where privacy.showsTitles {
            let fee = payment.feeText.isEmpty ? payment.title : payment.feeText
            rows.append(("费用", fee))
        }
        let timed = items.filter {
            $0.kind.carriesTime && $0.dueAt != nil && $0.status != .unconfirmed
        }
        if let next = timed.min(by: { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }),
           let dueAt = next.dueAt {
            rows.append((
                next.kind.displayName,
                "\(next.title) · \(ErrandViewModel.shortDate(dueAt))\(dueAt < .now ? " · 已逾期" : "")"
            ))
        }
        return rows
    }
}
