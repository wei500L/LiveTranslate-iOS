import SwiftUI
import PDFKit

/// 表单字段逐项填写页（第二十一轮）—— 以当前字段为核心的独立页面，
/// 不是聊天气泡堆叠。四个稳定区域：
/// 1. 顶部进度：文件名、第 n / N 项、已填/待确认、返回总览；
/// 2. 来源区：页面局部预览（缩略图裁剪到页码所在）或整页入口；OCR
///    无 bounding box —— 绝不伪造定位框，无页码时诚实显示未定位；
/// 3. 字段区：俄文原字段为主、中文解释、必填、格式提示；
/// 4. 输入与操作区：类型化系统控件、键盘工具栏（上一项/下一项/完成）、
///    翻译为俄语、跳过、询问工作人员。
///
/// 隐私：来源图/裁剪图全部本机；值不经 outbox；朗读用普通俄语（TTS
/// 自动去重音）；复制走 ClipboardService（敏感策略）。
struct InterpreterFormFieldPage: View {
    @Environment(AppEnvironment.self) private var environment
    let model: InterpreterFormDraftModel
    let viewModel: InterpreterViewModel
    /// 当前字段 ID（由父视图持有并按用户导航更新 —— 返回同一字段）。
    @Binding var currentFieldID: UUID
    /// 询问工作人员（进入柜台对话，带上字段上下文）。
    var onAskStaff: (InterpreterFormDraftField) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var valueFieldFocused: Bool
    @State private var showFullPage = false
    /// 翻译为俄语：先披露将发送的内容（用户确认后才发起请求）。
    @State private var showTranslationSendPreview = false
    @State private var showTranslationResult = false
    @State private var pendingTranslation: InterpreterViewModel.FormFieldTranslation?
    @State private var translationInput = ""

    private var currentIndex: Int? { model.index(of: currentFieldID) }
    private var field: InterpreterFormDraftField? { model.field(with: currentFieldID) }
    private var progress: InterpreterFormDraftProgress.Summary { model.progress }

    var body: some View {
        NavigationStack {
            LTPage {
                if let field, let index = currentIndex {
                    VStack(spacing: 0) {
                        progressHeader(index)
                        ScrollView {
                            VStack(alignment: .leading, spacing: LTSpacing.m) {
                                sourceSection(field)
                                fieldSection(field)
                                if field.type.acceptsUserValue {
                                    inputSection(field)
                                } else {
                                    signatureSection(field)
                                }
                                valueActions(field)
                            }
                            .padding(.horizontal, LTSpacing.screenPadding)
                            .padding(.vertical, LTSpacing.m)
                            .padding(.bottom, LTSpacing.l)
                        }
                        bottomBar(field: field, index: index)
                    }
                    .screenCaptureMask()
                    .toolbar {
                        ToolbarItem(placement: .keyboard) {
                            keyboardToolbar(index)
                        }
                    }
                } else {
                    LTPage {
                        LTEmptyState(
                            symbol: "list.clipboard",
                            title: "字段不存在",
                            message: "该字段可能已被删除。返回总览选择其他字段。"
                        )
                    }
                }
            }
            .navigationTitle("逐项填写")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("总览") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showFullPage) {
            if let field {
                InterpreterFormPagePreview(
                    document: model.document,
                    pageNumber: field.pageNumber
                )
                .environment(environment)
            }
        }
        .sheet(isPresented: $showTranslationSendPreview) {
            if let field {
                translationSendPreviewSheet(field)
            }
        }
        .sheet(isPresented: $showTranslationResult) {
            if let field, let pendingTranslation {
                translationConfirmSheet(field, pendingTranslation)
            }
        }
    }

    // MARK: - 1. 顶部进度

    private func progressHeader(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.xxs) {
            HStack {
                Text(model.documentName)
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textSecondary)
                    .lineLimit(1)
                Spacer()
                statusBadge
            }
            HStack(spacing: LTSpacing.s) {
                Text("第 \(index + 1) / \(progress.total) 项")
                    .font(LTTypography.cardTitle)
                    .foregroundStyle(LTColors.textPrimary)
                Text("已填 \(progress.filled) · 待确认 \(progress.needsConfirmation)")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textSecondary)
                Spacer()
            }
            ProgressView(value: Double(progress.filled + progress.notApplicable), total: Double(max(progress.total, 1)))
                .tint(LTColors.accentCyan)
        }
        .padding(.horizontal, LTSpacing.screenPadding)
        .padding(.top, LTSpacing.s)
        .padding(.bottom, LTSpacing.xs)
        .background(LTColors.backgroundPrimary.opacity(0.9))
    }

    @ViewBuilder
    private var statusBadge: some View {
        if let field {
            let status = InterpreterFormDraftField.effectiveStatus(field: field)
            Label(status.displayName, systemImage: statusIcon(status))
                .font(LTTypography.statusChip)
                .foregroundStyle(statusColor(status))
                .padding(.horizontal, LTSpacing.s)
                .padding(.vertical, 2)
                .background(Capsule().fill(statusColor(status).opacity(0.12)))
        }
    }

    private func statusIcon(_ status: InterpreterFormFieldStatus) -> String {
        switch status {
        case .filled: return "checkmark.circle.fill"
        case .empty: return "circle.dashed"
        case .needsConfirmation: return "questionmark.circle"
        case .notApplicable: return "minus.circle"
        }
    }

    private func statusColor(_ status: InterpreterFormFieldStatus) -> Color {
        switch status {
        case .filled: return LTColors.accentGreen
        case .empty: return LTColors.textTertiary
        case .needsConfirmation: return LTColors.warning
        case .notApplicable: return LTColors.textSecondary
        }
    }

    // MARK: - 2. 来源区

    @ViewBuilder
    private func sourceSection(_ field: InterpreterFormDraftField) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.xs) {
            HStack {
                Label("原表位置", systemImage: "doc.viewfinder")
                    .font(LTTypography.statusChip)
                    .foregroundStyle(LTColors.textTertiary)
                Spacer()
                if field.pageNumber != nil {
                    Button("查看整页") { showFullPage = true }
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.accentBlue)
                        .frame(minHeight: LTSpacing.minTouchTarget)
                        .contentShape(Rectangle())
                }
            }
            if let page = field.pageNumber {
                // OCR 无 bounding box：不伪造定位框 —— 显示该页缩略图与
                // 字段原文行（诚实降级到页级定位）。
                sourceThumbnail(page)
                if let snippet = field.sourceSnippet, !snippet.isEmpty {
                    Text(snippet)
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textSecondary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
            } else {
                Label("未定位到原表位置（可手动编辑字段页码）", systemImage: "mappin.slash")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textTertiary)
            }
        }
        .ltCard(padding: LTSpacing.s)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func sourceThumbnail(_ page: Int) -> some View {
        if let data = InterpreterDocumentStoreShared.store?
            .pageThumbnailData(documentID: model.document.id, pageNumber: page),
           let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 160)
                .clipShape(RoundedRectangle(cornerRadius: LTRadius.medium))
                .overlay(
                    RoundedRectangle(cornerRadius: LTRadius.medium)
                        .strokeBorder(LTColors.border, lineWidth: 0.5)
                )
        } else {
            Label("第\(page)页预览不可用（原始文件或页面图缺失）", systemImage: "photo")
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.textTertiary)
        }
    }

    // MARK: - 3. 字段区

    private func fieldSection(_ field: InterpreterFormDraftField) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.xs) {
            Text(field.russianLabel)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(LTColors.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !field.chineseMeaning.isEmpty {
                Text(field.chineseMeaning)
                    .font(LTTypography.body)
                    .foregroundStyle(LTColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: LTSpacing.s) {
                // 必填是提示不是限制（文字标签 —— 不只靠颜色）。
                if field.requirement != .unknown {
                    Label(field.requirement.displayName, systemImage: field.requirement == .required ? "asterisk.circle" : "circle")
                        .foregroundStyle(field.requirement == .required ? LTColors.warning : LTColors.textTertiary)
                } else {
                    Label("必填未知", systemImage: "questionmark.circle")
                        .foregroundStyle(LTColors.textTertiary)
                }
                Text("· \(field.type.displayName)")
                    .foregroundStyle(LTColors.textTertiary)
                if let page = field.pageNumber {
                    Text("· 第\(page)页")
                        .foregroundStyle(LTColors.textTertiary)
                }
            }
            .font(LTTypography.statusChip)
            if let hint = field.formatHint, !hint.isEmpty {
                Label("格式提示：\(hint)（示例，不是你的真实信息）", systemImage: "textformat")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.accentCyan)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let snippet = field.sourceSnippet, !snippet.isEmpty, field.pageNumber == nil {
                Text(snippet)
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textSecondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
            }
        }
        .ltCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(fieldAccessibility(field))
    }

    private func fieldAccessibility(_ field: InterpreterFormDraftField) -> String {
        var parts = ["第\((currentIndex ?? 0) + 1)项"]
        parts.append("俄语字段：\(field.russianLabel)")
        if !field.chineseMeaning.isEmpty {
            parts.append("中文解释：\(field.chineseMeaning)")
        }
        parts.append(field.requirement.displayName)
        if !field.userValue.isEmpty {
            parts.append("当前值：\(field.userValue)")
        } else {
            parts.append("未填写")
        }
        return parts.joined(separator: "，")
    }

    // MARK: - 4. 输入区（类型化系统控件）

    @ViewBuilder
    private func inputSection(_ field: InterpreterFormDraftField) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            Label("你的填写", systemImage: "square.and.pencil")
                .font(LTTypography.statusChip)
                .foregroundStyle(LTColors.textTertiary)
            switch field.type {
            case .date:
                DatePicker(
                    "日期",
                    selection: dateBinding(field),
                    displayedComponents: .date
                )
                .datePickerStyle(.compact)
                .labelsHidden()
                // 系统日期选择 + 显式格式预览（不猜测不完整日期）。
                if let date = parsedDate(field.userValue) {
                    Text(russianFormatPreview(date: date))
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textSecondary)
                        .textSelection(.enabled)
                }
            case .singleChoice:
                choiceRows(field, multiple: false)
            case .multipleChoice:
                choiceRows(field, multiple: true)
            case .multiline:
                TextField("多行说明（中文输入后可翻译为俄语）", text: valueBinding(field), axis: .vertical)
                    .lineLimit(3...8)
                    .focused($valueFieldFocused)
                    .font(LTTypography.body)
                    .padding(LTSpacing.s)
                    .background(
                        RoundedRectangle(cornerRadius: LTRadius.medium)
                            .fill(LTColors.surfaceElevated.opacity(0.6))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: LTRadius.medium)
                            .strokeBorder(LTColors.border, lineWidth: 0.5)
                    )
            case .number:
                TextField("数字/金额（原样保存，不自动换算币种）", text: valueBinding(field))
                    .keyboardType(.decimalPad)
                    .focused($valueFieldFocused)
                    .font(LTTypography.body)
                    .padding(LTSpacing.s)
                    .background(
                        RoundedRectangle(cornerRadius: LTRadius.medium)
                            .fill(LTColors.surfaceElevated.opacity(0.6))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: LTRadius.medium)
                            .strokeBorder(LTColors.border, lineWidth: 0.5)
                    )
            case .singleLine, .unknown:
                // 单行/未知类型用普通系统键盘（姓名、证件号、地址等
                // 原样填写 —— 不自动翻译、不改变大小写/空格/标点）。
                TextField("输入你的值（原样填写）", text: valueBinding(field))
                    .focused($valueFieldFocused)
                    .font(LTTypography.body)
                    .padding(LTSpacing.s)
                    .background(
                        RoundedRectangle(cornerRadius: LTRadius.medium)
                            .fill(LTColors.surfaceElevated.opacity(0.6))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: LTRadius.medium)
                            .strokeBorder(LTColors.border, lineWidth: 0.5)
                    )
            case .signature:
                EmptyView()
            }
            noteRow(field)
        }
        .ltCard()
    }

    /// 备注（现场问到的答案可记回这里）。
    private func noteRow(_ field: InterpreterFormDraftField) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.xxs) {
            Label("备注", systemImage: "note.text")
                .font(LTTypography.statusChip)
                .foregroundStyle(LTColors.textTertiary)
            TextField("现场问到的答案、提醒（可选）", text: noteBinding(field), axis: .vertical)
                .lineLimit(1...3)
                .font(LTTypography.body)
                .padding(LTSpacing.s)
                .background(
                    RoundedRectangle(cornerRadius: LTRadius.medium)
                        .fill(LTColors.surfaceElevated.opacity(0.4))
                )
        }
    }

    /// 候选项：显示俄文选项与中文解释（如提供），由用户亲自选择。
    private func choiceRows(_ field: InterpreterFormDraftField, multiple: Bool) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.xs) {
            if field.options.isEmpty {
                Text("没有识别到候选选项 —— 可直接输入值，或在编辑字段时补充选项。")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textTertiary)
                TextField("输入你的值（原样填写）", text: valueBinding(field))
                    .focused($valueFieldFocused)
                    .font(LTTypography.body)
                    .padding(LTSpacing.s)
                    .background(
                        RoundedRectangle(cornerRadius: LTRadius.medium)
                            .fill(LTColors.surfaceElevated.opacity(0.6))
                    )
            } else if multiple {
                ForEach(field.options, id: \.self) { option in
                    let selected = selectedOptions(field).contains(option)
                    Button {
                        toggleOption(field, option: option)
                    } label: {
                        HStack(spacing: LTSpacing.s) {
                            Image(systemName: selected ? "checkmark.square.fill" : "square")
                                .foregroundStyle(selected ? LTColors.accentCyan : LTColors.textTertiary)
                            Text(option)
                                .font(LTTypography.body)
                                .foregroundStyle(LTColors.textPrimary)
                                .multilineTextAlignment(.leading)
                            Spacer()
                        }
                        .frame(minHeight: LTSpacing.minTouchTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(option)，\(selected ? "已选中" : "未选中")")
                }
            } else {
                ForEach(field.options, id: \.self) { option in
                    let selected = field.userValue == option
                    Button {
                        model.setValue(fieldID: field.id, value: selected ? "" : option)
                    } label: {
                        HStack(spacing: LTSpacing.s) {
                            Image(systemName: selected ? "circle.inset.filled" : "circle")
                                .foregroundStyle(selected ? LTColors.accentCyan : LTColors.textTertiary)
                            Text(option)
                                .font(LTTypography.body)
                                .foregroundStyle(LTColors.textPrimary)
                                .multilineTextAlignment(.leading)
                            Spacer()
                        }
                        .frame(minHeight: LTSpacing.minTouchTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(option)，\(selected ? "已选中" : "未选中")")
                }
            }
        }
    }

    private func selectedOptions(_ field: InterpreterFormDraftField) -> [String] {
        field.userValue
            .components(separatedBy: "; ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func toggleOption(_ field: InterpreterFormDraftField, option: String) {
        var current = selectedOptions(field)
        if let index = current.firstIndex(of: option) {
            current.remove(at: index)
        } else {
            current.append(option)
        }
        model.setValue(fieldID: field.id, value: current.joined(separator: "; "))
    }

    // MARK: - 签名位置（只解释要求）

    private func signatureSection(_ field: InterpreterFormDraftField) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.xs) {
            Label("签名位置", systemImage: "signature")
                .font(LTTypography.statusChip)
                .foregroundStyle(LTColors.textTertiary)
            Text("这里需要手写签名（或填写姓名/日期 —— 见字段说明）")
                .font(LTTypography.body)
                .foregroundStyle(LTColors.textPrimary)
            Text("本应用不提供绘制、保存或自动插入签名的能力。请在纸质表单或官方电子表单中亲自签名。")
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.textSecondary)
        }
        .ltCard()
    }

    // MARK: - 值操作（复制/朗读/翻译/状态）

    @ViewBuilder
    private func valueActions(_ field: InterpreterFormDraftField) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            HStack(spacing: LTSpacing.m) {
                Button {
                    ClipboardService.shared.copySensitive(field.russianLabel)
                } label: {
                    Label("复制俄文字段名", systemImage: "doc.on.doc")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.accentBlue)
                        .frame(minHeight: LTSpacing.minTouchTarget)
                }
                .buttonStyle(.plain)
                if !field.userValue.isEmpty {
                    Button {
                        ClipboardService.shared.copySensitive(field.userValue)
                    } label: {
                        Label("复制填写值", systemImage: "doc.on.doc.fill")
                            .font(LTTypography.caption)
                            .foregroundStyle(LTColors.accentBlue)
                            .frame(minHeight: LTSpacing.minTouchTarget)
                    }
                    .buttonStyle(.plain)
                    Button {
                        // 朗读（TTS 自动去重音 —— 普通俄语）。
                        viewModel.speakRussianText(field.userValue)
                    } label: {
                        Label("朗读", systemImage: "speaker.wave.2")
                            .font(LTTypography.caption)
                            .foregroundStyle(LTColors.accentBlue)
                            .frame(minHeight: LTSpacing.minTouchTarget)
                    }
                    .buttonStyle(.plain)
                }
            }
            if !field.userValue.isEmpty {
                HStack(spacing: LTSpacing.m) {
                    statusToggle(field)
                }
            }
        }
        .padding(.horizontal, LTSpacing.xxs)
    }

    @ViewBuilder
    private func statusToggle(_ field: InterpreterFormDraftField) -> some View {
        Button {
            let status = InterpreterFormDraftField.effectiveStatus(field: field)
            switch status {
            case .filled:
                model.markNeedsConfirmation(fieldID: field.id)
            case .needsConfirmation:
                // 再次点击确认 → 回到已填。
                model.confirmFilled(fieldID: field.id)
            default:
                break
            }
        } label: {
            Label("标记待确认/确认无误", systemImage: "questionmark.circle")
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.warning)
                .frame(minHeight: LTSpacing.minTouchTarget)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 底部操作区（上一项/下一项/翻译/询问）

    private func bottomBar(field: InterpreterFormDraftField, _ index: Int) -> some View {
        VStack(spacing: LTSpacing.xs) {
            if field.type == .multiline || field.type == .singleLine || field.type == .unknown {
                // 自由文本字段（来访目的、情况说明…）：显式"翻译为俄语"
                // —— 先披露将发送的内容，确认后才发起请求。
                Button {
                    showTranslationSendPreview = true
                } label: {
                    HStack(spacing: LTSpacing.s) {
                        if viewModel.isTranslatingFormText {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "translate")
                        }
                        Text("翻译为俄语")
                            .font(LTTypography.button)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, LTSpacing.s)
                    .background(Capsule().fill(LTColors.accentCyan.opacity(0.16)))
                }
                .disabled(viewModel.isTranslatingFormText || field.userValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack(spacing: LTSpacing.m) {
                Button {
                    navigate(-1, from: index)
                } label: {
                    Label("上一项", systemImage: "chevron.up")
                        .font(LTTypography.button)
                        .foregroundStyle(LTColors.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, LTSpacing.s)
                        .background(Capsule().fill(LTColors.surfaceElevated.opacity(0.6)))
                }
                .disabled(index == 0)
                Button {
                    onAskStaff(field)
                } label: {
                    Label("询问工作人员", systemImage: "person.wave.2")
                        .font(LTTypography.button)
                        .foregroundStyle(Color.black.opacity(0.85))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, LTSpacing.s)
                        .background(Capsule().fill(LTColors.accentCyan.opacity(0.9)))
                }
                Button {
                    navigate(1, from: index)
                } label: {
                    Label("下一项", systemImage: "chevron.down")
                        .font(LTTypography.button)
                        .foregroundStyle(LTColors.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, LTSpacing.s)
                        .background(Capsule().fill(LTColors.surfaceElevated.opacity(0.6)))
                }
                .disabled(index + 1 >= progress.total)
            }
            if let error = model.lastWriteError {
                Text(error)
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.warning)
            }
            if let error = viewModel.lastTranslationError {
                Text(error)
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.warning)
            }
        }
        .padding(.horizontal, LTSpacing.screenPadding)
        .padding(.top, LTSpacing.s)
        .padding(.bottom, LTSpacing.s)
        .background(
            LTColors.backgroundPrimary.opacity(0.92)
                .ignoresSafeArea(edges: .bottom)
        )
        .overlay(alignment: .top) {
            Rectangle().fill(LTColors.separator).frame(height: 0.5)
        }
    }

    // 键盘工具栏（上一项/下一项/完成）。
    private func keyboardToolbar(_ index: Int) -> some View {
        HStack(spacing: LTSpacing.m) {
            Button("上一项") { navigate(-1, from: index) }
                .disabled(index == 0)
            Spacer()
            Button("下一项") { navigate(1, from: index) }
                .disabled(index + 1 >= progress.total)
            Spacer()
            Button("完成") { valueFieldFocused = false }
        }
        .font(LTTypography.body)
    }

    private func navigate(_ delta: Int, from index: Int) {
        let target = index + delta
        guard target >= 0, target < model.fieldCount else { return }
        if let field = model.field(at: target) {
            currentFieldID = field.id
        }
    }

    // MARK: - 绑定

    private func valueBinding(_ field: InterpreterFormDraftField) -> Binding<String> {
        Binding(
            get: { model.field(with: field.id)?.userValue ?? "" },
            set: { model.setValue(fieldID: field.id, value: $0) }
        )
    }

    private func noteBinding(_ field: InterpreterFormDraftField) -> Binding<String> {
        Binding(
            get: { model.field(with: field.id)?.userNote ?? "" },
            set: { model.setNote(fieldID: field.id, note: $0) }
        )
    }

    private func dateBinding(_ field: InterpreterFormDraftField) -> Binding<Date> {
        Binding(
            get: { parsedDate(field.userValue) ?? Date() },
            set: { newValue in
                // 日期只做格式预览和显式转换：统一 DD.MM.YYYY（俄表惯例）。
                let formatter = DateFormatter()
                formatter.dateFormat = "dd.MM.yyyy"
                model.setValue(fieldID: field.id, value: formatter.string(from: newValue))
            }
        )
    }

    private func parsedDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        for format in ["dd.MM.yyyy", "yyyy-MM-dd", "dd/MM/yyyy", "d.M.yyyy"] {
            let formatter = DateFormatter()
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil // 不猜测不完整日期
    }

    private func russianFormatPreview(date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy"
        let ddMMYYYY = formatter.string(from: date)
        return "俄表常用格式：\(ddMMYYYY)（显式转换 —— 请核对）"
    }

    // MARK: - 翻译发送前披露（用户确认后才发起请求）

    /// 披露将发送的内容：字段说明（俄文标签 + 中文解释）与用户输入的
    /// 中文 —— 与 AIRequestDisclosure 同一词汇（feature · host · 内容
    /// 类别）。确认后发起翻译；取消不标失败。
    private func translationSendPreviewSheet(_ field: InterpreterFormDraftField) -> some View {
        NavigationStack {
            LTPage {
                ScrollView {
                    VStack(alignment: .leading, spacing: LTSpacing.s) {
                        Label("翻译为俄语（发送前确认）", systemImage: "paperplane")
                            .font(LTTypography.cardTitle)
                            .foregroundStyle(LTColors.textPrimary)
                        Text(sendPreviewDisclosure)
                            .font(LTTypography.caption)
                            .foregroundStyle(LTColors.accentCyan)
                        VStack(alignment: .leading, spacing: LTSpacing.xxs) {
                            Text("字段说明")
                                .font(LTTypography.statusChip)
                                .foregroundStyle(LTColors.textTertiary)
                            Text(fieldSummary(field))
                                .font(LTTypography.body)
                                .foregroundStyle(LTColors.textSecondary)
                                .textSelection(.enabled)
                        }
                        .ltCard(padding: LTSpacing.s)
                        VStack(alignment: .leading, spacing: LTSpacing.xxs) {
                            Text("将发送的中文输入")
                                .font(LTTypography.statusChip)
                                .foregroundStyle(LTColors.textTertiary)
                            Text(field.userValue.isEmpty ? "（无输入）" : field.userValue)
                                .font(LTTypography.body)
                                .foregroundStyle(LTColors.textPrimary)
                                .textSelection(.enabled)
                        }
                        .ltCard(padding: LTSpacing.s)
                        if viewModel.isTranslatingFormText {
                            HStack(spacing: LTSpacing.xs) {
                                ProgressView().controlSize(.small)
                                Text("正在翻译…")
                                    .font(LTTypography.caption)
                                    .foregroundStyle(LTColors.textSecondary)
                            }
                        }
                        if let error = viewModel.lastTranslationError {
                            Text(error)
                                .font(LTTypography.caption)
                                .foregroundStyle(LTColors.warning)
                        }
                        Text("翻译结果不会自动写入草稿 —— 返回后由你确认。取消不标失败。")
                            .font(LTTypography.caption)
                            .foregroundStyle(LTColors.textTertiary)
                    }
                    .padding(.horizontal, LTSpacing.screenPadding)
                    .padding(.vertical, LTSpacing.m)
                }
            }
            .navigationTitle("发送前确认")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        showTranslationSendPreview = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("发送翻译") {
                        translationInput = field.userValue
                        Task {
                            if let result = await viewModel.translateFormFieldText(translationInput) {
                                pendingTranslation = result
                                showTranslationSendPreview = false
                                showTranslationResult = true
                            }
                        }
                    }
                    .disabled(
                        field.userValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || viewModel.isTranslatingFormText
                    )
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var sendPreviewDisclosure: String {
        let host = URL(
            string: OpenAICompatibleTranslator.normalizeAPIBase(
                viewModel.apiBaseForDisclosure
            ) ?? ""
        )?.host ?? ""
        let disclosure = AIRequestDisclosure(
            feature: .interpreterFormTextTranslation,
            host: host,
            textCategory: .userInput,
            characterCount: 0,
            imageCount: 0,
            masked: false,
            userTriggered: true
        )
        return "请求概要：" + disclosure.previewSummary
    }

    private func fieldSummary(_ field: InterpreterFormDraftField) -> String {
        var parts = [field.russianLabel]
        if !field.chineseMeaning.isEmpty {
            parts.append(field.chineseMeaning)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 翻译确认 sheet（用户确认后才写入草稿）

    private func translationConfirmSheet(
        _ field: InterpreterFormDraftField,
        _ result: InterpreterViewModel.FormFieldTranslation
    ) -> some View {
        NavigationStack {
            LTPage {
                ScrollView {
                    VStack(alignment: .leading, spacing: LTSpacing.s) {
                        Label("翻译为俄语（写入前确认）", systemImage: "translate")
                            .font(LTTypography.cardTitle)
                            .foregroundStyle(LTColors.textPrimary)
                        VStack(alignment: .leading, spacing: LTSpacing.xxs) {
                            Text("你的中文输入（保留供核对）")
                                .font(LTTypography.statusChip)
                                .foregroundStyle(LTColors.textTertiary)
                            Text(field.userValue)
                                .font(LTTypography.body)
                                .foregroundStyle(LTColors.textSecondary)
                                .textSelection(.enabled)
                        }
                        .ltCard(padding: LTSpacing.s)
                        VStack(alignment: .leading, spacing: LTSpacing.xxs) {
                            Text("普通俄语（将写入草稿 —— 正式表单值，不带重音符号）")
                                .font(LTTypography.statusChip)
                                .foregroundStyle(LTColors.textTertiary)
                            Text(result.plainRussian)
                                .font(LTTypography.body)
                                .foregroundStyle(LTColors.textPrimary)
                                .textSelection(.enabled)
                        }
                        .ltCard(padding: LTSpacing.s)
                        if let back = result.backTranslation, !back.isEmpty {
                            VStack(alignment: .leading, spacing: LTSpacing.xxs) {
                                Text("中文回译（核对）")
                                    .font(LTTypography.statusChip)
                                    .foregroundStyle(LTColors.textTertiary)
                                Text(back)
                                    .font(LTTypography.body)
                                    .foregroundStyle(LTColors.textSecondary)
                                    .textSelection(.enabled)
                            }
                            .ltCard(padding: LTSpacing.s)
                        }
                        if let uncertainties = result.uncertainties, !uncertainties.isEmpty {
                            ForEach(uncertainties, id: \.self) { item in
                                Label(item, systemImage: "exclamationmark.triangle")
                                    .font(LTTypography.caption)
                                    .foregroundStyle(LTColors.warning)
                            }
                        }
                        Text("写入后字段标记为待确认 —— 你核对无误后可确认。翻译失败或取消都不影响原输入。")
                            .font(LTTypography.caption)
                            .foregroundStyle(LTColors.textTertiary)
                    }
                    .padding(.horizontal, LTSpacing.screenPadding)
                    .padding(.vertical, LTSpacing.m)
                }
            }
            .navigationTitle("翻译为俄语")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        showTranslationResult = false
                        pendingTranslation = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("写入") {
                        if let field = self.field {
                            model.applyTranslatedValue(
                                fieldID: field.id,
                                russian: result.plainRussian,
                                chinese: field.userValue
                            )
                        }
                        showTranslationResult = false
                        pendingTranslation = nil
                    }
                }
            }
        }
    }
}

// MARK: - 整页预览

/// 字段来源的整页预览（复用现有页面缩略图 / PDFKit 渲染；全部本机）。
struct InterpreterFormPagePreview: View {
    let document: InterpreterDocument
    /// nil = 显示第一页（无页码字段的兜底入口）。
    var pageNumber: Int?

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?

    var body: some View {
        NavigationStack {
            LTPage {
                if let image {
                    ScrollView([.vertical, .horizontal]) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .padding(LTSpacing.s)
                    }
                } else {
                    LTEmptyState(
                        symbol: "photo",
                        title: "页面预览不可用",
                        message: "原始文件或页面图缺失（可能已被删除或未生成缩略图）。"
                    )
                }
            }
            .screenCaptureMask()
            .navigationTitle(pageNumber.map { "第\($0)页" } ?? "页面预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .task { loadImage() }
    }

    private func loadImage() {
        let page = pageNumber ?? 1
        // 缩略图缓存优先（600px）；没有则渲染整页（PDFKit / 图片字节）。
        if let data = InterpreterDocumentStoreShared.store?
            .pageThumbnailData(documentID: document.id, pageNumber: page),
           let cached = UIImage(data: data) {
            image = cached
            return
        }
        // Swift 6：@Model 对象不跨 actor —— 先在主线程提取 Sendable 值
        // （InterpreterDocumentService 的同一惯例）。
        let documentID = document.id
        let relativePath = document.originalRelativePath
        let format = document.format
        Task.detached(priority: .utility) {
            guard let store = InterpreterDocumentStoreShared.store,
                  let url = store.originalURL(forRelativePath: relativePath) else {
                return
            }
            let rendered: UIImage?
            switch format {
            case .pdf:
                guard let pdf = PDFDocument(url: url),
                      page >= 1, page <= pdf.pageCount,
                      let pdfPage = pdf.page(at: page - 1) else { rendered = nil; break }
                let bounds = pdfPage.bounds(for: .mediaBox)
                let longEdge = max(bounds.width, bounds.height)
                guard longEdge > 0 else { rendered = nil; break }
                let scale = min(1200 / longEdge, 4)
                rendered = pdfPage.thumbnail(
                    of: CGSize(width: bounds.width * scale, height: bounds.height * scale),
                    for: .mediaBox
                )
            case .image:
                rendered = UIImage(contentsOfFile: url.path)
            default:
                rendered = nil
            }
            if let rendered {
                await MainActor.run { image = rendered }
            }
        }
    }
}
