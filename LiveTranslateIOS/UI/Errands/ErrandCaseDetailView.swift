import SwiftUI

/// 办事事项详情：以"下一步"优先的全宽卡片/分区（不是聊天气泡）。
/// 展示状态与下一步、材料/动作/问题清单、预约/截止/跟进、费用/地址/
/// 联系方式、本地来源与不确定项。
///
/// 交互边界：AI 候选逐项确认；问题可填入随身翻译输入框（不自动发送/
/// 朗读/开麦）；不确定日期、金额、地址始终可见；完成项折叠可查看。
struct ErrandCaseDetailView: View {
    @Environment(AppEnvironment.self) private var environment
    let caseID: UUID
    @State private var viewModel = ErrandViewModel()
    @State private var showingDateSheet: ErrandCaseItem?
    @State private var showingAddSheet = false
    @State private var showingCalendarPicker: ErrandCaseItem?
    @State private var showingResultSheet = false
    @State private var showingDeleteConfirm = false
    @State private var showingExport = false
    @State private var showingStartInterpreter = false
    @State private var revealCompleted = false
    @Environment(\.dismiss) private var dismiss

    private var errandCase: ErrandCase? {
        environment.repository.errandCase(id: caseID)
    }

    var body: some View {
        Group {
            if let errandCase {
                content(errandCase)
            } else {
                // 诚实状态：事项已被删除（迟到路由/通知）。
                LTPage {
                    LTEmptyState(
                        symbol: "checklist",
                        title: "事项已不存在",
                        message: "这个办事事项可能已在其他设备或本机删除。"
                    )
                }
                .navigationTitle("办事事项")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task {
            viewModel.attach(environment)
            viewModel.reload()
            viewModel.openDetailById(caseID)
        }
        .onAppear {
            viewModel.reload()
            viewModel.openDetailById(caseID)
        }
    }

    @ViewBuilder
    private func content(_ errandCase: ErrandCase) -> some View {
        LTPage {
            ScrollView {
                VStack(spacing: LTSpacing.l) {
                    headerCard(errandCase)
                    nextStepCard(errandCase)
                    candidatesSection(errandCase)
                    itemsSection(.requiredDocument, errandCase, title: "要带的材料")
                    itemsSection(.action, errandCase, title: "要完成的动作")
                    itemsSection(.question, errandCase, title: "到现场要问的问题")
                    timeSection(errandCase)
                    confirmedFactsSection(errandCase)
                    localSourcesSection(errandCase)
                    if viewModel.notificationsDenied {
                        deniedNotice
                    }
                }
                .padding(.horizontal, LTSpacing.screenPadding)
                .padding(.top, LTSpacing.s)
                .padding(.bottom, LTSpacing.xl)
            }
        }
        // 办事详情携带敏感内容（签证/医疗/证件材料清单）—— 录屏/镜像
        // 时遮挡（系统截图本身无法被 App 阻止，如实说明）。
        .screenCaptureMask()
        .navigationTitle(errandCase.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarMenu(errandCase) }
        .sheet(item: Binding(
            get: { showingDateSheet.map(ErrandItemSheetTarget.init) },
            set: { showingDateSheet = $0?.item }
        )) { target in
            ErrandDateConfirmSheet(
                item: target.item,
                caseTitle: errandCase.title,
                timezoneID: errandCase.timezoneID
            )
            .environment(environment)
        }
        .sheet(isPresented: $showingAddSheet) {
            ErrandItemAddSheet(errandCase: errandCase, initialKind: addSheetKind)
                .environment(environment)
        }
        .sheet(isPresented: $showingResultSheet) {
            ErrandResultSheet(errandCase: errandCase)
                .environment(environment)
        }
        .sheet(item: Binding(
            get: { showingCalendarPicker.map(ErrandItemSheetTarget.init) },
            set: { showingCalendarPicker = $0?.item }
        )) { target in
            ErrandCalendarPickerSheet(item: target.item, errandCase: errandCase)
                .environment(environment)
        }
        .sheet(isPresented: $showingExport) {
            ErrandExportSheet(errandCase: errandCase, items: viewModel.detailItems)
                .environment(environment)
        }
        .confirmationDialog(
            "删除这个办事事项？",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("删除（同时删除本机日历镜像）", role: .destructive) {
                viewModel.deleteCase(errandCase, alsoDeleteCalendarEvents: true)
                dismiss()
            }
            Button("删除（保留日历事件）", role: .destructive) {
                viewModel.deleteCase(errandCase, alsoDeleteCalendarEvents: false)
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("清单、提醒与本地来源链接将一并清理；原始对话和文件不受影响。")
        }
    }

    private struct ErrandItemSheetTarget: Identifiable {
        var item: ErrandCaseItem
        var id: UUID { item.id }
    }

    // MARK: - Header

    private func headerCard(_ errandCase: ErrandCase) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            HStack(spacing: LTSpacing.m) {
                LTIconBadge(symbol: errandCase.scene.symbol, tint: LTColors.accentBlue)
                VStack(alignment: .leading, spacing: 4) {
                    Text(errandCase.title)
                        .font(LTTypography.cardTitle)
                        .foregroundStyle(LTColors.textPrimary)
                    Text("\(errandCase.scene.displayName) · \(errandCase.status.displayName)")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textSecondary)
                }
                Spacer()
                if errandCase.status == .draft {
                    Text("草稿 · 仅本机")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(LTColors.warning)
                }
            }
            if !errandCase.purpose.isEmpty {
                Text(errandCase.purpose)
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textSecondary)
            }
            if errandCase.status == .draft {
                VStack(alignment: .leading, spacing: LTSpacing.xs) {
                    Text("保存后哪些内容会同步：标题、场景、状态、目的、备注、地点、联系方式、预计结果时间、清单文字与已确认的时间。")
                        .font(.caption2)
                        .foregroundStyle(LTColors.textTertiary)
                    Text("仅留本机：本地来源链接（文件名/页码/引文）、提醒与日历设置。")
                        .font(.caption2)
                        .foregroundStyle(LTColors.textTertiary)
                    Button {
                        viewModel.saveDraft(errandCase)
                    } label: {
                        Label("保存事项", systemImage: "checkmark.circle.fill")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LTColors.accentGreen)
                    .padding(.top, LTSpacing.xs)
                }
            }
        }
        .ltCard(padding: LTSpacing.l)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Next step

    /// 下一步优先：最近的确认时间（预约/截止/跟进分别标注）。
    private func nextStepCard(_ errandCase: ErrandCase) -> some View {
        let dated = viewModel.detailItems.filter {
            $0.kind.carriesTime && $0.dueAt != nil && $0.status == .pending
        }
        let next = dated.min { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
        return VStack(alignment: .leading, spacing: LTSpacing.s) {
            HStack {
                Label("下一步", systemImage: "arrow.right.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(LTColors.textSecondary)
                Spacer()
                // 现场单手操作的主按钮 —— 固定在卡片顶部，不被长清单推走。
                Button {
                    showingStartInterpreter = true
                } label: {
                    Label("开始现场沟通", systemImage: "person.2.wave.2.fill")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(LTColors.accentCyan)
            }
            if let next, let dueAt = next.dueAt {
                HStack(spacing: LTSpacing.s) {
                    Image(systemName: next.kind.symbol)
                        .foregroundStyle(kindTint(next.kind))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(next.title)
                            .font(.body.weight(.medium))
                            .foregroundStyle(LTColors.textPrimary)
                        Text("\(next.kind.displayName) · \(ErrandViewModel.shortDate(dueAt))\(dueAt < .now ? " · 已逾期" : "")")
                            .font(LTTypography.caption)
                            .foregroundStyle(dueAt < .now ? LTColors.destructive : LTColors.textSecondary)
                    }
                    Spacer()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("下一步：\(next.title)，\(next.kind.displayName)，\(ErrandViewModel.shortDate(dueAt))\(dueAt < .now ? "，已逾期" : "")"))
            } else {
                Text(nextStepFallback(errandCase))
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textSecondary)
            }
            // 问题清单一键带入随身翻译（只导航，不自动开麦/发送）。
            ForEach(viewModel.detailItems.filter { $0.kind == .question && $0.status == .pending }.prefix(3)) { question in
                questionRow(question)
            }
        }
        .ltCard(padding: LTSpacing.l)
        .navigationDestination(isPresented: $showingStartInterpreter) {
            // 只导航 —— 场景与背景由随身翻译界面自行展示；绝不自动
            // 请求麦克风、自动开始收音或自动朗读。
            InterpreterScreen(prefilledQuestion: pendingQuestionText)
        }
    }

    private func nextStepFallback(_ errandCase: ErrandCase) -> String {
        switch errandCase.status {
        case .preparing: return "准备材料 —— 勾选已备好的材料项"
        case .scheduled: return "按预约时间到场（加入日历可在下方预约卡片操作）"
        case .waitingForResult:
            if let expected = errandCase.expectedResultAt {
                return "等待结果 · 预计 \(ErrandViewModel.shortDate(expected))"
            }
            return "等待结果 —— 可设置预计领取时间"
        case .needsFollowUp: return "需要补交或跟进 —— 完成后勾选对应项"
        case .completed, .cancelled, .archived: return "已结束（历史保留，可归档）"
        case .draft: return "整理并保存这个事项"
        }
    }

    private var pendingQuestionText: String? {
        viewModel.detailItems
            .first { $0.kind == .question && $0.status == .pending }?
            .title
    }

    private func questionRow(_ question: ErrandCaseItem) -> some View {
        HStack(alignment: .top, spacing: LTSpacing.s) {
            Image(systemName: "questionmark.bubble")
                .font(.footnote)
                .foregroundStyle(LTColors.accentCyan)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(question.title)
                    .font(.footnote)
                    .foregroundStyle(LTColors.textPrimary)
                // 把问题填入随身翻译输入框（不自动发送/朗读 —— 复制到
                // 剪贴板由用户粘贴，或直接带入输入框字段）。
                Button {
                    ClipboardService.shared.copySensitive(question.title)
                } label: {
                    Label("复制问题", systemImage: "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(LTColors.accentBlue)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - 候选（AI/规则 → 逐项确认；.unconfirmed 行 —— 设备本地，
    // 绝不上船，直到用户逐项确认）

    @ViewBuilder
    private func candidatesSection(_ errandCase: ErrandCase) -> some View {
        let unconfirmed = viewModel.detailItems.filter { $0.status == .unconfirmed }
        if !unconfirmed.isEmpty {
            VStack(alignment: .leading, spacing: LTSpacing.s) {
                LTSectionHeader(title: "候选（未确认 · 不会同步）")
                ForEach(unconfirmed) { item in
                    candidateRow(item)
                }
            }
        }
    }

    private func candidateRow(_ item: ErrandCaseItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: LTSpacing.s) {
                Image(systemName: item.kind.symbol)
                    .foregroundStyle(LTColors.warning)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(LTColors.textPrimary)
                    Text(item.origin == .ai
                        ? "AI 建议（\(item.kind.displayName)）—— 请核对后加入"
                        : "规则建议（\(item.kind.displayName)）—— 请核对后加入")
                        .font(.caption2)
                        .foregroundStyle(LTColors.textTertiary)
                    if !item.dateText.isEmpty {
                        Label(
                            item.dateUncertain
                                ? "时间不确定：「\(item.dateText)」（确认时需裁决）"
                                : "时间候选：「\(item.dateText)」",
                            systemImage: item.dateUncertain ? "exclamationmark.triangle" : "clock"
                        )
                        .font(.caption2)
                        .foregroundStyle(item.dateUncertain ? LTColors.warning : LTColors.textSecondary)
                    }
                }
                Spacer()
                VStack(spacing: 6) {
                    Button {
                        viewModel.confirmItem(item, dueAt: nil)
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(LTColors.accentGreen)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("加入清单：\(item.title)"))
                    Button {
                        viewModel.deleteItem(item)
                    } label: {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 18))
                            .foregroundStyle(LTColors.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("丢弃候选：\(item.title)"))
                }
            }
        }
        .ltCard(padding: LTSpacing.m)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("候选：\(item.title)，未确认"))
    }

    // MARK: - 清单分区

    @ViewBuilder
    private func itemsSection(
        _ kind: ErrandCaseItemKind, _ errandCase: ErrandCase, title: String
    ) -> some View {
        let items = viewModel.detailItems.filter { $0.kind == kind && $0.status != .unconfirmed }
        let visible = revealCompleted
            ? items : items.filter { $0.status != .done && $0.status != .skipped }
        let completed = items.count - visible.count
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            LTSectionHeader(
                title: title,
                actionTitle: "添加",
                action: { showingAddSheet = true; addSheetKind = kind }
            )
            if visible.isEmpty && completed == 0 {
                Text(kind == .question ? "还没有记录问题" : "暂无")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textTertiary)
            }
            ForEach(visible) { item in
                itemRow(item, errandCase: errandCase)
            }
            if completed > 0 {
                Button {
                    withAnimation { revealCompleted.toggle() }
                } label: {
                    Label(
                        revealCompleted ? "收起已完成" : "查看已完成（\(completed)）",
                        systemImage: revealCompleted ? "chevron.up" : "chevron.down"
                    )
                    .font(.caption2)
                    .foregroundStyle(LTColors.textSecondary)
                }
            }
        }
    }

    @State private var addSheetKind: ErrandCaseItemKind = .requiredDocument

    private func itemRow(_ item: ErrandCaseItem, errandCase: ErrandCase) -> some View {
        HStack(alignment: .top, spacing: LTSpacing.s) {
            Button {
                viewModel.setItemStatus(
                    item, to: item.status == .done ? .pending : .done
                )
            } label: {
                Image(systemName: item.status == .done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21))
                    .foregroundStyle(item.status == .done ? LTColors.accentGreen : LTColors.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(item.status == .done ? "标记为未完成" : "标记为已完成"))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(
                        item.status == .done ? LTColors.textSecondary : LTColors.textPrimary
                    )
                    .strikethrough(item.status == .done)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.caption2)
                        .foregroundStyle(LTColors.textSecondary)
                }
                if !item.dateText.isEmpty {
                    Label("原文：「\(item.dateText)」", systemImage: "text.quote")
                        .font(.caption2)
                        .foregroundStyle(LTColors.textTertiary)
                }
                if item.dateUncertain {
                    Label("时间仍不确定 —— 不会被提醒", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(LTColors.warning)
                }
            }
            Spacer()
            Menu {
                if item.kind.carriesTime {
                    Button {
                        showingDateSheet = item
                    } label: {
                        Label(
                            item.dueAt == nil ? "确认时间…" : "修改时间…",
                            systemImage: "calendar"
                        )
                    }
                    if item.kind == .appointment && item.dueAt != nil && !item.dateUncertain {
                        Button {
                            showingCalendarPicker = item
                        } label: {
                            Label(
                                environment.errandCalendar.hasMirroredAppointment(itemID: item.id)
                                    ? "更新日历事件"
                                    : "加入日历",
                                systemImage: "calendar.badge.plus"
                            )
                        }
                    }
                }
                Button {
                    ClipboardService.shared.copySensitive(item.title)
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                Button(role: .destructive) {
                    viewModel.deleteItem(item)
                } label: {
                    Label("删除", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(LTColors.textSecondary)
            }
            .accessibilityLabel(Text("更多操作"))
        }
        .ltCard(padding: LTSpacing.m)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(
            "\(item.kind.displayName)：\(item.title)，\(item.status.displayName)"
                + (item.dueAt.map { "，时间 \(ErrandViewModel.shortDate($0))" } ?? "")
                + (item.dateUncertain ? "，时间不确定" : "")
        ))
    }

    // MARK: - 时间分区（预约/截止/跟进 —— 三种语义分开列出）

    private func timeSection(_ errandCase: ErrandCase) -> some View {
        let timed = viewModel.detailItems.filter { $0.kind.carriesTime && $0.status != .unconfirmed }
        return VStack(alignment: .leading, spacing: LTSpacing.s) {
            LTSectionHeader(title: "预约 · 截止 · 跟进")
            if timed.isEmpty {
                Text("尚无确认的时间（识别到日期不会自动成为预约）")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textTertiary)
            }
            ForEach(timed) { item in
                timeRow(item, errandCase: errandCase)
            }
            if errandCase.status == .waitingForResult, let expected = errandCase.expectedResultAt {
                Label(
                    "预计结果 \(ErrandViewModel.shortDate(expected))",
                    systemImage: "hourglass"
                )
                .font(.caption2)
                .foregroundStyle(LTColors.textSecondary)
            }
        }
    }

    private func timeRow(_ item: ErrandCaseItem, errandCase: ErrandCase) -> some View {
        HStack(spacing: LTSpacing.s) {
            Image(systemName: item.kind.symbol)
                .foregroundStyle(kindTint(item.kind))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(LTColors.textPrimary)
                if let dueAt = item.dueAt {
                    Text(timeDescription(item, dueAt: dueAt))
                        .font(.caption2)
                        .foregroundStyle(dueAt < .now && item.status == .pending ? LTColors.destructive : LTColors.textSecondary)
                } else {
                    Text("时间未确认 —— 不会被提醒")
                        .font(.caption2)
                        .foregroundStyle(LTColors.warning)
                }
            }
            Spacer()
            Button {
                showingDateSheet = item
            } label: {
                Text(item.dueAt == nil ? "确认时间" : "修改")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.bordered)
            .tint(kindTint(item.kind))
        }
        .ltCard(padding: LTSpacing.m)
        .accessibilityElement(children: .combine)
    }

    private func timeDescription(_ item: ErrandCaseItem, dueAt: Date) -> String {
        var parts = ["\(item.kind.displayName) · \(ErrandViewModel.shortDate(dueAt))"]
        if item.dateIsRelative { parts.append("相对日期换算") }
        if let errandCase, !errandCase.timezoneID.isEmpty {
            parts.append("时区 \(errandCase.timezoneID)")
        }
        if dueAt < .now && item.status == .pending { parts.append("已逾期") }
        return parts.joined(separator: " · ")
    }

    private func kindTint(_ kind: ErrandCaseItemKind) -> Color {
        switch kind {
        case .appointment: return LTColors.accentCyan
        case .deadline: return LTColors.destructive
        case .followUp: return LTColors.warning
        default: return LTColors.accentBlue
        }
    }

    // MARK: - 已确认事实（费用/地点/联系方式）

    private func confirmedFactsSection(_ errandCase: ErrandCase) -> some View {
        let payments = viewModel.detailItems.filter { $0.kind == .payment && $0.status != .unconfirmed }
        var rows: [(String, String)] = []
        if !errandCase.location.isEmpty { rows.append(("地点", errandCase.location)) }
        if !errandCase.contact.isEmpty { rows.append(("联系方式", errandCase.contact)) }
        for payment in payments {
            var fee = payment.feeText.isEmpty ? payment.title : payment.feeText
            if let amount = payment.feeAmount {
                fee += "（\(amount)\(payment.feeCurrency.isEmpty ? "" : " \(payment.feeCurrency)")"
                    + "，未换算）"
            }
            rows.append(("费用", fee))
        }
        return VStack(alignment: .leading, spacing: LTSpacing.s) {
            LTSectionHeader(title: "已确认信息")
            if rows.isEmpty {
                Text("尚无已确认的地点/联系方式/费用")
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
                .accessibilityElement(children: .combine)
            }
        }
        .ltCard(padding: LTSpacing.m)
    }

    // MARK: - 本地来源

    private func localSourcesSection(_ errandCase: ErrandCase) -> some View {
        let sources = errandCase.localSources ?? []
        return VStack(alignment: .leading, spacing: LTSpacing.s) {
            LTSectionHeader(title: "本地来源（仅本机）")
            if sources.isEmpty {
                if errandCase.hasLocalSources {
                    // 其他设备保存的来源 —— 诚实显示，不显示伪链接。
                    Text("来源资料仅保存在原设备")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textTertiary)
                } else {
                    Text("暂无来源（可在随身翻译中把对话/文件加入事项）")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textTertiary)
                }
            }
            ForEach(sources) { source in
                localSourceRow(source)
            }
        }
        .ltCard(padding: LTSpacing.m)
    }

    private func localSourceRow(_ source: ErrandLocalSource) -> some View {
        let availability = sourceAvailability(source)
        return HStack(alignment: .top, spacing: LTSpacing.s) {
            Image(systemName: source.kind == .conversation ? "bubble.left.and.bubble.right" : "doc.text")
                .foregroundStyle(availability.available ? LTColors.accentBlue : LTColors.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.kind == .conversation ? "对话" : source.documentName)
                    .font(.footnote)
                    .foregroundStyle(LTColors.textPrimary)
                if source.kind == .document, let page = source.pageNumber {
                    Text("第 \(page) 页")
                        .font(.caption2)
                        .foregroundStyle(LTColors.textTertiary)
                }
                if !availability.available {
                    Text("原文件已从本机删除")
                        .font(.caption2)
                        .foregroundStyle(LTColors.warning)
                }
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private func sourceAvailability(_ source: ErrandLocalSource) -> (available: Bool, kind: String) {
        switch source.kind {
        case .conversation:
            let exists = source.conversationID.map {
                environment.repository.interpreterConversation(id: $0) != nil
            } ?? false
            return (exists, "对话")
        case .document:
            let exists = source.documentID.map {
                environment.repository.interpreterDocument(id: $0) != nil
            } ?? false
            return (exists, "文件")
        }
    }

    private var deniedNotice: some View {
        Label(
            "通知权限被拒绝 —— 事项已保存，但提醒未创建。可在系统设置中开启。",
            systemImage: "bell.slash"
        )
        .font(.caption)
        .foregroundStyle(LTColors.warning)
        .ltCard(padding: LTSpacing.m)
    }

    // MARK: - Toolbar

    @ViewBuilder
    private func toolbarMenu(_ errandCase: ErrandCase) -> some View {
        Menu {
            if errandCase.status == .draft {
                Button {
                    viewModel.saveDraft(errandCase)
                } label: {
                    Label("保存事项", systemImage: "checkmark.circle")
                }
                Button(role: .destructive) {
                    viewModel.discardDraft(errandCase)
                    dismiss()
                } label: {
                    Label("丢弃草稿", systemImage: "trash")
                }
            } else {
                statusMenu(errandCase)
                Button {
                    showingResultSheet = true
                } label: {
                    Label("记录办理结果", systemImage: "square.and.pencil")
                }
                Button {
                    showingExport = true
                } label: {
                    Label("导出记录", systemImage: "square.and.arrow.up")
                }
                Button(role: .destructive) {
                    showingDeleteConfirm = true
                } label: {
                    Label("删除事项", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    @ViewBuilder
    private func statusMenu(_ errandCase: ErrandCase) -> some View {
        // 受约束转换：只有合法目标可选（非法项直接不显示 —— 绝不出现
        // 点了没反应的按钮）。
        let targets: [(ErrandCaseStatus, String, String)] = [
            (.waitingForResult, "hourglass", "等待结果"),
            (.needsFollowUp, "arrow.clockwise", "需要跟进"),
            (.completed, "checkmark.circle", "已完成"),
            (.cancelled, "xmark.circle", "取消此事"),
            (.archived, "archivebox", "归档")
        ]
        Menu {
            ForEach(targets.filter { errandCase.status.canTransition(to: $0.0) }, id: \.0) { target in
                Button {
                    if target.0 == .waitingForResult {
                        showingResultSheet = true
                    } else {
                        viewModel.setCaseStatus(errandCase, to: target.0)
                    }
                } label: {
                    Label(target.2, systemImage: target.1)
                }
            }
        } label: {
            Label("状态", systemImage: "flag")
        }
    }
}
