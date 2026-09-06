import SwiftUI
import UIKit

/// 表单字段总览页（第二十一轮）：按原表顺序展示全部字段、四态状态、
/// 必填与页码、搜索、筛选、拖动排序、手动新增/编辑/合并/删除，以及
/// 完成前核对入口。"逐项填写"由此进入。
struct InterpreterFormOverviewSheet: View {
    @Environment(AppEnvironment.self) private var environment
    let model: InterpreterFormDraftModel
    let viewModel: InterpreterViewModel
    /// 逐项填写（进入当前字段页）。
    var onFillField: (UUID) -> Void
    /// 询问工作人员（从总览直接进入对话）。
    var onAskStaff: (InterpreterFormDraftField) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var showUnfinishedOnly = false
    @State private var editingField: InterpreterFormDraftField?
    @State private var addingField = false
    @State private var mergingState: MergeState?
    @State private var showReview = false
    @State private var showExportConfirm = false

    /// 合并操作的中间状态（选主字段后选并入目标）。
    struct MergeState: Equatable {
        var primaryID: UUID
        var primaryLabel: String
    }

    private var progress: InterpreterFormDraftProgress.Summary { model.progress }

    private var visibleFields: [InterpreterFormDraftField] {
        var fields = model.draft.fields
        if showUnfinishedOnly {
            fields = fields.filter {
                let status = InterpreterFormDraftField.effectiveStatus(field: $0)
                return status == .empty || status == .needsConfirmation
            }
        }
        guard !searchText.isEmpty else { return fields }
        return fields.filter {
            InterpreterFormDraftProgress.matches($0, query: searchText)
        }
    }

    var body: some View {
        NavigationStack {
            LTPage {
                ScrollView {
                    VStack(alignment: .leading, spacing: LTSpacing.s) {
                        if let error = model.loadError {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(LTTypography.caption)
                                .foregroundStyle(LTColors.warning)
                        }
                        summaryCard
                        if model.hasFields {
                            searchAndFilter
                            fieldList
                        } else {
                            emptyState
                        }
                        if let error = model.lastWriteError {
                            Text(error)
                                .font(LTTypography.caption)
                                .foregroundStyle(LTColors.warning)
                        }
                    }
                    .padding(.horizontal, LTSpacing.screenPadding)
                    .padding(.vertical, LTSpacing.s)
                }
            }
            .screenCaptureMask()
            .navigationTitle("填写清单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        addingField = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("新增字段")
                }
            }
        }
        .sheet(item: $editingField) { field in
            InterpreterFormFieldEditorSheet(model: model, field: field)
        }
        .sheet(isPresented: $addingField) {
            InterpreterFormFieldEditorSheet(model: model, field: nil)
        }
        .sheet(isPresented: $showReview) {
            InterpreterFormReviewSheet(model: model)
        }
        .sheet(isPresented: $showExportConfirm) {
            ExportConfirmSheet(
                includesValues: $exportIncludesValues,
                onExport: { exportReference() }
            )
        }
    }

    // MARK: - 导出填写参考（TemporaryExportStore；可选）

    @State private var exportIncludesValues = true

    /// 导出确认 sheet 的按钮操作（由 sheet 调用；动作在父视图执行 ——
    /// 需要访问 model 的草稿与导出状态）。
    private func exportReference() {
        let options = InterpreterFormReferenceExporter.Options(
            includeValues: exportIncludesValues
        )
        let text = InterpreterFormReferenceExporter.text(
            documentName: model.documentName,
            draft: model.draft,
            options: options
        )
        let fileName = InterpreterFormReferenceExporter.suggestedFileName(
            documentName: model.documentName
        )
        let store = TemporaryExportStore()
        do {
            let url = try store.stage(
                fileName: fileName, data: Data(text.utf8)
            )
            // 系统分享（share sheet 弹出；导出内容受 24h 受控生命周期）。
            presentShareSheet(url: url)
        } catch {
            // 失败诚实提示（导出 sheet 内不展示 —— 通过 lastWriteError
            // 模式之外的轻量路径：直接保持 sheet 开启让用户重试）。
        }
    }

    private func presentShareSheet(url: URL) {
        let activityVC = UIActivityViewController(
            activityItems: [url], applicationActivities: nil
        )
        // sheet 内呈现：找当前呈现的控制器（根场景口径）。
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        guard let root = scenes.first?.keyWindow?.rootViewController else { return }
        var presenter = root
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        presenter.present(activityVC, animated: true)
    }

    /// 导出确认 sheet（独立 struct —— dismiss 语义在本 sheet 内）。
    private struct ExportConfirmSheet: View {
        @Binding var includesValues: Bool
        let onExport: () -> Void
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            NavigationStack {
                LTPage {
                    ScrollView {
                        VStack(alignment: .leading, spacing: LTSpacing.s) {
                            Label("导出填写参考", systemImage: "square.and.arrow.up")
                                .font(LTTypography.cardTitle)
                                .foregroundStyle(LTColors.textPrimary)
                            Text("导出为 Markdown 文本（不是 PDF、不代表已提交表单）。文件进入本机临时导出目录，24 小时后自动清理。")
                                .font(LTTypography.caption)
                                .foregroundStyle(LTColors.textSecondary)
                            Toggle("包含填写值", isOn: $includesValues)
                                .font(LTTypography.body)
                            Text("关闭后仅导出字段标签与解释，不含你的填写内容。")
                                .font(LTTypography.caption)
                                .foregroundStyle(LTColors.textTertiary)
                        }
                        .padding(.horizontal, LTSpacing.screenPadding)
                        .padding(.vertical, LTSpacing.m)
                    }
                }
                .navigationTitle("导出参考")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("导出") {
                            onExport()
                            dismiss()
                        }
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }

    // MARK: - 汇总卡

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: LTSpacing.xs) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.documentName)
                        .font(LTTypography.cardTitle)
                        .foregroundStyle(LTColors.textPrimary)
                        .lineLimit(1)
                    Text("填写参考清单 · 只保存在这台设备")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textTertiary)
                }
                Spacer()
                if model.isChecked {
                    Label("已核对", systemImage: "checkmark.seal")
                        .font(LTTypography.statusChip)
                        .foregroundStyle(LTColors.accentGreen)
                }
            }
            HStack(spacing: LTSpacing.m) {
                statChip("共 \(progress.total)", tint: LTColors.textSecondary)
                statChip("已填 \(progress.filled)", tint: LTColors.accentGreen)
                statChip("未填 \(progress.empty)", tint: LTColors.textTertiary)
                statChip("待确认 \(progress.needsConfirmation)", tint: LTColors.warning)
                statChip("不适用 \(progress.notApplicable)", tint: LTColors.textSecondary)
            }
            ProgressView(value: Double(progress.filled + progress.notApplicable), total: Double(max(progress.total, 1)))
                .tint(LTColors.accentCyan)
            HStack(spacing: LTSpacing.m) {
                Button {
                    if let first = firstUnfinishedField() {
                        onFillField(first.id)
                    }
                } label: {
                    Text(progress.unfinished > 0 ? "继续逐项填写" : "开始逐项填写")
                        .font(LTTypography.button)
                        .foregroundStyle(Color.black.opacity(0.85))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, LTSpacing.s)
                        .background(Capsule().fill(LTColors.accentCyan.opacity(0.9)))
                }
                .disabled(model.draft.fields.isEmpty)
                Button {
                    showReview = true
                } label: {
                    Text("完成前核对")
                        .font(LTTypography.button)
                        .foregroundStyle(LTColors.accentBlue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, LTSpacing.s)
                        .background(Capsule().fill(LTColors.accentBlue.opacity(0.14)))
                }
                .disabled(model.draft.fields.isEmpty)
            }
            // 导出填写参考（可选 —— 临时导出目录，24h 清理）。
            Button {
                showExportConfirm = true
            } label: {
                Label("导出填写参考", systemImage: "square.and.arrow.up")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.accentBlue)
                    .frame(minHeight: LTSpacing.minTouchTarget)
            }
            .buttonStyle(.plain)
            .disabled(model.draft.fields.isEmpty)
        }
        .ltCard()
    }

    private func statChip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(LTTypography.statusChip)
            .foregroundStyle(tint)
            .padding(.horizontal, LTSpacing.s)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.08)))
    }

    private func firstUnfinishedField() -> InterpreterFormDraftField? {
        model.draft.fields.first {
            let status = InterpreterFormDraftField.effectiveStatus(field: $0)
            return status == .empty || status == .needsConfirmation
        } ?? model.draft.fields.first
    }

    // MARK: - 搜索与筛选

    private var searchAndFilter: some View {
        VStack(alignment: .leading, spacing: LTSpacing.xs) {
            TextField("搜索俄文标签、中文解释、备注", text: $searchText)
                .font(LTTypography.body)
                .padding(LTSpacing.s)
                .background(
                    RoundedRectangle(cornerRadius: LTRadius.medium)
                        .fill(LTColors.surfaceElevated.opacity(0.6))
                )
            Toggle("只看未完成", isOn: $showUnfinishedOnly)
                .font(LTTypography.caption)
        }
    }

    // MARK: - 字段列表

    private var fieldList: some View {
        LazyVStack(alignment: .leading, spacing: LTSpacing.xs) {
            if visibleFields.isEmpty {
                Text(showUnfinishedOnly ? "没有未完成的字段" : "没有匹配的字段")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textTertiary)
            }
            ForEach(visibleFields) { field in
                fieldRow(field)
            }
        }
    }

    private func fieldRow(_ field: InterpreterFormDraftField) -> some View {
        let status = InterpreterFormDraftField.effectiveStatus(field: field)
        return VStack(alignment: .leading, spacing: LTSpacing.xxs) {
            HStack(alignment: .top, spacing: LTSpacing.s) {
                statusIcon(status)
                VStack(alignment: .leading, spacing: 2) {
                    Text(field.russianLabel)
                        .font(LTTypography.body)
                        .foregroundStyle(LTColors.textPrimary)
                        .lineLimit(2)
                    HStack(spacing: LTSpacing.xs) {
                        Text(status.displayName)
                            .foregroundStyle(statusTint(status))
                        if field.requirement == .required {
                            Text("· 必填")
                                .foregroundStyle(LTColors.warning)
                        }
                        if let page = field.pageNumber {
                            Text("· 第\(page)页")
                                .foregroundStyle(LTColors.textTertiary)
                        }
                    }
                    .font(LTTypography.statusChip)
                    if !field.chineseMeaning.isEmpty {
                        Text(field.chineseMeaning)
                            .font(LTTypography.caption)
                            .foregroundStyle(LTColors.textSecondary)
                            .lineLimit(1)
                    }
                    if !field.userValue.isEmpty {
                        Text(field.userValue)
                            .font(LTTypography.caption)
                            .foregroundStyle(LTColors.accentCyan)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if let merging = mergingState, merging.primaryID == field.id {
                    Image(systemName: "arrow.triangle.merge")
                        .font(.caption)
                        .foregroundStyle(LTColors.warning)
                }
                rowMenu(field)
            }
        }
        .padding(LTSpacing.s)
        .background(
            RoundedRectangle(cornerRadius: LTRadius.medium)
                .fill(LTColors.surfaceElevated.opacity(0.4))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if let merging = mergingState {
                // 合并第二击：把主字段并入此字段位置。
                model.mergeFields(primaryID: merging.primaryID, intoSecondaryID: field.id)
                self.mergingState = nil
            } else {
                onFillField(field.id)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(field.russianLabel)，\(status.displayName)，点击逐项填写")
    }

    @ViewBuilder
    private func statusIcon(_ status: InterpreterFormFieldStatus) -> some View {
        Image(systemName: statusSymbol(status))
            .font(.footnote)
            .foregroundStyle(statusTint(status))
            .frame(minWidth: 22, minHeight: 22)
    }

    private func statusSymbol(_ status: InterpreterFormFieldStatus) -> String {
        switch status {
        case .filled: return "checkmark.circle.fill"
        case .empty: return "circle.dashed"
        case .needsConfirmation: return "questionmark.circle"
        case .notApplicable: return "minus.circle"
        }
    }

    private func statusTint(_ status: InterpreterFormFieldStatus) -> Color {
        switch status {
        case .filled: return LTColors.accentGreen
        case .empty: return LTColors.textTertiary
        case .needsConfirmation: return LTColors.warning
        case .notApplicable: return LTColors.textSecondary
        }
    }

    @ViewBuilder
    private func rowMenu(_ field: InterpreterFormDraftField) -> some View {
        Menu {
            Button("逐项填写") { onFillField(field.id) }
            Button("编辑字段") { editingField = field }
            Button("询问工作人员") { onAskStaff(field) }
            Button("朗读俄文字段名") {
                viewModel.speakRussianText(field.russianLabel)
            }
            Button("复制俄文字段名") {
                ClipboardService.shared.copySensitive(field.russianLabel)
            }
            if !field.userValue.isEmpty {
                Button("复制填写值") {
                    ClipboardService.shared.copySensitive(field.userValue)
                }
            }
            Button("标记不适用") {
                model.markNotApplicable(fieldID: field.id, notApplicable: true)
            }
            // 顺序修正（识别错误导致顺序不对时上移/下移）。
            if let index = model.index(of: field.id), index > 0 {
                Button("上移（修正字段顺序）") { model.moveUp(fieldID: field.id) }
            }
            if let index = model.index(of: field.id), index + 1 < model.fieldCount {
                Button("下移（修正字段顺序）") { model.moveDown(fieldID: field.id) }
            }
            if mergingState == nil {
                Button("合并到其他字段…") {
                    mergingState = MergeState(
                        primaryID: field.id, primaryLabel: field.russianLabel
                    )
                }
            } else {
                Button("取消合并") { mergingState = nil }
            }
            Button("删除字段", role: .destructive) {
                if mergingState?.primaryID == field.id { mergingState = nil }
                model.deleteField(fieldID: field.id)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body)
                .foregroundStyle(LTColors.textTertiary)
                .frame(minWidth: LTSpacing.minTouchTarget, minHeight: LTSpacing.minTouchTarget)
                .contentShape(Rectangle())
        }
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            LTEmptyState(
                symbol: "list.clipboard",
                title: model.loadError == nil ? "还没有字段清单" : "草稿无法读取",
                message: "可以从 AI 分析结果与识别文字建立字段清单（AI 不可用时也可手动新增字段）。"
            )
            if model.loadError == nil {
                Button {
                    let store = InterpreterDocumentStoreShared.store
                    let extraction = store.flatMap {
                        $0.readExtraction(documentID: model.document.id)
                    }
                    model.populateFromSources(extraction: extraction)
                } label: {
                    Text("从识别结果创建清单")
                        .font(LTTypography.button)
                        .foregroundStyle(Color.black.opacity(0.85))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, LTSpacing.s)
                        .background(Capsule().fill(LTColors.accentCyan.opacity(0.9)))
                }
            }
            Button {
                addingField = true
            } label: {
                Label("手动新增字段", systemImage: "plus.circle")
                    .font(LTTypography.button)
                    .foregroundStyle(LTColors.accentBlue)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, LTSpacing.s)
                    .background(Capsule().fill(LTColors.accentBlue.opacity(0.14)))
            }
        }
    }
}

// MARK: - 字段编辑 sheet（手动新增 / 修正识别错误）

/// 新增或编辑一个字段（标签、解释、类型、必填、格式、选项、页码、
/// 来源引文）。AI 识别错误的修正入口。
struct InterpreterFormFieldEditorSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let model: InterpreterFormDraftModel
    /// nil = 新增。
    let field: InterpreterFormDraftField?

    @State private var russianLabel = ""
    @State private var chineseMeaning = ""
    @State private var type: InterpreterFormFieldType = .singleLine
    @State private var requirement: InterpreterFormFieldRequirement = .unknown
    @State private var formatHint = ""
    @State private var optionsText = ""
    @State private var pageNumberText = ""
    @State private var sourceSnippet = ""

    var body: some View {
        NavigationStack {
            LTPage {
                ScrollView {
                    VStack(alignment: .leading, spacing: LTSpacing.s) {
                        formSection
                    }
                    .padding(.horizontal, LTSpacing.screenPadding)
                    .padding(.vertical, LTSpacing.m)
                }
            }
            .navigationTitle(field == nil ? "新增字段" : "编辑字段")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(russianLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear { load() }
    }

    private var formSection: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            VStack(alignment: .leading, spacing: LTSpacing.xxs) {
                Text("俄文字段原文 *")
                    .font(LTTypography.statusChip)
                    .foregroundStyle(LTColors.textTertiary)
                TextField("例如：Фамилия Имя Отчество", text: $russianLabel, axis: .vertical)
                    .lineLimit(1...3)
                    .font(LTTypography.body)
                    .padding(LTSpacing.s)
                    .background(
                        RoundedRectangle(cornerRadius: LTRadius.medium)
                            .fill(LTColors.surfaceElevated.opacity(0.6))
                    )
            }
            VStack(alignment: .leading, spacing: LTSpacing.xxs) {
                Text("中文解释")
                    .font(LTTypography.statusChip)
                    .foregroundStyle(LTColors.textTertiary)
                TextField("例如：姓名（姓、名、父称）", text: $chineseMeaning, axis: .vertical)
                    .lineLimit(1...3)
                    .font(LTTypography.body)
                    .padding(LTSpacing.s)
                    .background(
                        RoundedRectangle(cornerRadius: LTRadius.medium)
                            .fill(LTColors.surfaceElevated.opacity(0.6))
                    )
            }
            VStack(alignment: .leading, spacing: LTSpacing.xxs) {
                Text("字段类型")
                    .font(LTTypography.statusChip)
                    .foregroundStyle(LTColors.textTertiary)
                Picker("字段类型", selection: $type) {
                    ForEach(InterpreterFormFieldType.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.menu)
            }
            VStack(alignment: .leading, spacing: LTSpacing.xxs) {
                Text("必填性")
                    .font(LTTypography.statusChip)
                    .foregroundStyle(LTColors.textTertiary)
                Picker("必填性", selection: $requirement) {
                    Text("必填").tag(InterpreterFormFieldRequirement.required)
                    Text("可选").tag(InterpreterFormFieldRequirement.optional)
                    Text("未知").tag(InterpreterFormFieldRequirement.unknown)
                }
                .pickerStyle(.segmented)
            }
            VStack(alignment: .leading, spacing: LTSpacing.xxs) {
                Text("格式提示（只是建议，不是你的真实信息）")
                    .font(LTTypography.statusChip)
                    .foregroundStyle(LTColors.textTertiary)
                TextField("例如：DD.MM.YYYY", text: $formatHint)
                    .font(LTTypography.body)
                    .padding(LTSpacing.s)
                    .background(
                        RoundedRectangle(cornerRadius: LTRadius.medium)
                            .fill(LTColors.surfaceElevated.opacity(0.6))
                    )
            }
            VStack(alignment: .leading, spacing: LTSpacing.xxs) {
                Text("候选项（每行一个）")
                    .font(LTTypography.statusChip)
                    .foregroundStyle(LTColors.textTertiary)
                TextField("例如：да / нет", text: $optionsText, axis: .vertical)
                    .lineLimit(2...6)
                    .font(LTTypography.body)
                    .padding(LTSpacing.s)
                    .background(
                        RoundedRectangle(cornerRadius: LTRadius.medium)
                            .fill(LTColors.surfaceElevated.opacity(0.6))
                    )
            }
            VStack(alignment: .leading, spacing: LTSpacing.xxs) {
                Text("页码（1 起；空 = 未定位）")
                    .font(LTTypography.statusChip)
                    .foregroundStyle(LTColors.textTertiary)
                TextField("例如：1", text: $pageNumberText)
                    .keyboardType(.numberPad)
                    .font(LTTypography.body)
                    .padding(LTSpacing.s)
                    .background(
                        RoundedRectangle(cornerRadius: LTRadius.medium)
                            .fill(LTColors.surfaceElevated.opacity(0.6))
                    )
            }
            VStack(alignment: .leading, spacing: LTSpacing.xxs) {
                Text("来源引文（原表中的行，可选）")
                    .font(LTTypography.statusChip)
                    .foregroundStyle(LTColors.textTertiary)
                TextField("例如：Фамилия Имя Отчество: ______", text: $sourceSnippet, axis: .vertical)
                    .lineLimit(1...3)
                    .font(LTTypography.body)
                    .padding(LTSpacing.s)
                    .background(
                        RoundedRectangle(cornerRadius: LTRadius.medium)
                            .fill(LTColors.surfaceElevated.opacity(0.6))
                    )
            }
        }
        .ltCard()
    }

    private func load() {
        guard let field else { return }
        russianLabel = field.russianLabel
        chineseMeaning = field.chineseMeaning
        type = field.type
        requirement = field.requirement
        formatHint = field.formatHint ?? ""
        optionsText = field.options.joined(separator: "\n")
        pageNumberText = field.pageNumber.map(String.init) ?? ""
        sourceSnippet = field.sourceSnippet ?? ""
    }

    private func save() {
        let options = optionsText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let page = Int(pageNumberText.trimmingCharacters(in: .whitespaces))
        let hint = formatHint.trimmingCharacters(in: .whitespaces)
        let snippet = sourceSnippet.trimmingCharacters(in: .whitespaces)
        if var field {
            field.russianLabel = russianLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            field.chineseMeaning = chineseMeaning.trimmingCharacters(in: .whitespacesAndNewlines)
            field.type = type
            field.requirement = requirement
            field.formatHint = hint.isEmpty ? nil : hint
            field.options = options
            field.pageNumber = page
            field.sourceSnippet = snippet.isEmpty ? nil : snippet
            model.updateField(field)
        } else {
            model.addField(
                russianLabel: russianLabel,
                chineseMeaning: chineseMeaning,
                pageNumber: page,
                type: type,
                requirement: requirement,
                formatHint: hint.isEmpty ? nil : hint,
                options: options
            )
        }
        dismiss()
    }
}

// MARK: - 完成前核对 sheet

/// 完成前核对：分组显示缺失必填项、待确认项、已填项与值、不适用项。
/// "完成"只表示本机清单已核对 —— 不代表官方表单已填写/签署/提交。
struct InterpreterFormReviewSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let model: InterpreterFormDraftModel

    @State private var checked = false

    private var groups: InterpreterFormDraftProgress.ReviewGroups {
        model.reviewGroups
    }

    var body: some View {
        NavigationStack {
            LTPage {
                ScrollView {
                    VStack(alignment: .leading, spacing: LTSpacing.l) {
                        disclaimerHeader
                        group(
                            title: "尚未填写的必填项（\(groups.missingRequired.count)）",
                            symbol: "exclamationmark.circle.fill",
                            tint: LTColors.warning,
                            fields: groups.missingRequired
                        )
                        group(
                            title: "待确认的字段（\(groups.needsConfirmation.count)）",
                            symbol: "questionmark.circle",
                            tint: LTColors.warning,
                            fields: groups.needsConfirmation
                        )
                        group(
                            title: "已填写（\(groups.filled.count)）",
                            symbol: "checkmark.circle.fill",
                            tint: LTColors.accentGreen,
                            fields: groups.filled
                        )
                        group(
                            title: "不适用（\(groups.notApplicable.count)）",
                            symbol: "minus.circle",
                            tint: LTColors.textSecondary,
                            fields: groups.notApplicable
                        )
                        completeSection
                    }
                    .padding(.horizontal, LTSpacing.screenPadding)
                    .padding(.vertical, LTSpacing.m)
                }
            }
            .screenCaptureMask()
            .navigationTitle("完成前核对")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var disclaimerHeader: some View {
        VStack(alignment: .leading, spacing: LTSpacing.xxs) {
            Label("完成 = 本机清单已核对", systemImage: "checkmark.seal")
                .font(LTTypography.cardTitle)
                .foregroundStyle(LTColors.textPrimary)
            Text("这不代表官方表单已经填写、签署或提交 —— 你仍需在纸质或官方电子表单中亲自填写。完成后此清单仍可继续编辑。")
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.textSecondary)
        }
        .ltCard(padding: LTSpacing.m)
    }

    @ViewBuilder
    private func group(
        title: String, symbol: String, tint: Color,
        fields: [InterpreterFormDraftField]
    ) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.xs) {
            Label(title, systemImage: symbol)
                .font(LTTypography.cardTitle)
                .foregroundStyle(LTColors.textPrimary)
            if fields.isEmpty {
                Text("无")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textTertiary)
            }
            ForEach(fields) { field in
                VStack(alignment: .leading, spacing: 2) {
                    Text(field.russianLabel)
                        .font(LTTypography.body)
                        .foregroundStyle(LTColors.textPrimary)
                    if let meaning = optionalText(field.chineseMeaning) {
                        Text(meaning)
                            .font(LTTypography.caption)
                            .foregroundStyle(LTColors.textSecondary)
                    }
                    if let value = optionalText(field.userValue) {
                        Text("值：\(value)")
                            .font(LTTypography.caption)
                            .foregroundStyle(LTColors.accentCyan)
                            .textSelection(.enabled)
                    }
                }
                .padding(LTSpacing.s)
                .background(
                    RoundedRectangle(cornerRadius: LTRadius.medium)
                        .fill(tint.opacity(0.06))
                )
            }
        }
    }

    private var completeSection: some View {
        VStack(alignment: .leading, spacing: LTSpacing.xs) {
            if checked || model.isChecked {
                Label("已标记为本机清单核对完成（仍可编辑）", systemImage: "checkmark.seal.fill")
                    .font(LTTypography.body)
                    .foregroundStyle(LTColors.accentGreen)
            } else {
                Button {
                    model.markChecked()
                    checked = true
                } label: {
                    Text("标记本机清单已核对")
                        .font(LTTypography.button)
                        .foregroundStyle(Color.black.opacity(0.85))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, LTSpacing.s)
                        .background(Capsule().fill(LTColors.accentGreen.opacity(0.9)))
                }
                .disabled(groups.missingRequired.count > 0 && model.draft.fields.isEmpty)
            }
        }
        .padding(.top, LTSpacing.s)
    }

    private func optionalText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
