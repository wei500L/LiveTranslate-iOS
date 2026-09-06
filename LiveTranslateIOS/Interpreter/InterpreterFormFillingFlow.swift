import SwiftUI

/// 表单填写流容器（第二十一轮）：持有字段总览 sheet 与逐项填写页之间
/// 的导航状态（当前字段 ID）—— 从填写页进对话返回后定位同一字段。
/// 由 InterpreterDocumentPanel 以 sheet 呈现。
///
/// 音频语义（沿用第二十轮）：进入本流不自动开麦；从填写页进入连续
/// 对话由 InterpreterScreen 侧处理；返回时由 InterpreterScreen 停止
/// 收音与朗读（suspend 已有语义）。
struct InterpreterFormFillingFlow: View {
    @Environment(AppEnvironment.self) private var environment
    let viewModel: InterpreterViewModel
    let document: InterpreterDocument
    /// 带字段进入柜台对话（panel 收起、InterpreterScreen 接管）。
    var onAskStaff: (InterpreterFormDraftField, String) -> Void

    @State private var model: InterpreterFormDraftModel?
    /// 逐项填写的当前字段（返回同一字段定位）。
    @State private var currentFieldID: UUID?
    @State private var showFieldPage = false
    /// 模板选择 sheet 的目标字段（选完直接带问题进入对话）。
    @State private var askTemplateTarget: InterpreterFormDraftField?

    var body: some View {
        Group {
            if let model {
                // Overview 自带 NavigationStack（toolbar/标题归它）。
                InterpreterFormOverviewSheet(
                    model: model,
                    viewModel: viewModel,
                    onFillField: { fieldID in
                        currentFieldID = fieldID
                        showFieldPage = true
                    },
                    onAskStaff: { field in
                        askTemplateTarget = field
                    }
                )
            } else {
                Color.clear
            }
        }
        .task {
            if model == nil {
                model = InterpreterFormDraftModel(
                    document: document,
                    store: InterpreterDocumentStoreShared.store
                )
            }
        }
        .fullScreenCover(isPresented: $showFieldPage) {
            if let model, let currentFieldID {
                InterpreterFormFieldPage(
                    model: model,
                    viewModel: viewModel,
                    currentFieldID: Binding(
                        get: { currentFieldID },
                        set: { newValue in self.currentFieldID = newValue }
                    ),
                    onAskStaff: { field in
                        askTemplateTarget = field
                    }
                )
                .environment(environment)
            }
        }
        .sheet(item: $askTemplateTarget) { field in
            InterpreterFormFieldAskTemplateSheet(
                field: field
            ) { question in
                askStaff(field, prefilled: question)
            }
        }
    }

    /// 本地问题模板（点击只填输入框 —— 不自动发送、不自动翻译、不
    /// 自动开麦）。
    static let askTemplates: [String] = [
        "这个字段应该填写什么？",
        "这里需要填写俄语还是拉丁字母？",
        "这一项是必填的吗？",
        "这里需要签字还是填写姓名？",
        "日期应该使用什么格式？",
    ]

    private func askStaff(_ field: InterpreterFormDraftField, prefilled: String) {
        showFieldPage = false
        onAskStaff(field, prefilled)
    }
}

/// 询问工作人员的问题模板 sheet：字段摘要 + 本地模板（含按字段生成的
/// 默认问题）。选择即带预填问题进入柜台对话 —— 不自动发送。
struct InterpreterFormFieldAskTemplateSheet: View {
    let field: InterpreterFormDraftField
    let onAsk: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    /// 按字段生成的默认问题（第一个选项）。
    private var defaultQuestion: String {
        let label = field.russianLabel.isEmpty ? field.chineseMeaning : field.russianLabel
        return "请问表格里「\(label)」这一栏应该填写什么？"
    }

    private var options: [String] {
        [defaultQuestion] + InterpreterFormFillingFlow.askTemplates
    }

    var body: some View {
        NavigationStack {
            LTPage {
                ScrollView {
                    VStack(alignment: .leading, spacing: LTSpacing.s) {
                        Label("询问工作人员", systemImage: "person.wave.2")
                            .font(LTTypography.cardTitle)
                            .foregroundStyle(LTColors.textPrimary)
                        VStack(alignment: .leading, spacing: LTSpacing.xxs) {
                            Text("当前字段")
                                .font(LTTypography.statusChip)
                                .foregroundStyle(LTColors.textTertiary)
                            Text(field.russianLabel)
                                .font(LTTypography.body)
                                .foregroundStyle(LTColors.textPrimary)
                                .textSelection(.enabled)
                            if !field.chineseMeaning.isEmpty {
                                Text(field.chineseMeaning)
                                    .font(LTTypography.caption)
                                    .foregroundStyle(LTColors.textSecondary)
                            }
                        }
                        .ltCard(padding: LTSpacing.s)
                        Text("选择一个问题带入对话（只预填输入框 —— 你可以编辑后再发送；对话中可用连续听、朗读与给对方看）")
                            .font(LTTypography.caption)
                            .foregroundStyle(LTColors.textTertiary)
                        ForEach(options, id: \.self) { question in
                            Button {
                                dismiss()
                                onAsk(question)
                            } label: {
                                HStack(spacing: LTSpacing.s) {
                                    Image(systemName: "text.insert")
                                        .font(.footnote)
                                        .foregroundStyle(LTColors.accentCyan)
                                    Text(question)
                                        .font(LTTypography.body)
                                        .foregroundStyle(LTColors.textPrimary)
                                        .multilineTextAlignment(.leading)
                                    Spacer()
                                }
                                .padding(LTSpacing.s)
                                .background(
                                    RoundedRectangle(cornerRadius: LTRadius.medium)
                                        .fill(LTColors.surfaceElevated.opacity(0.4))
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("询问：\(question)")
                        }
                    }
                    .padding(.horizontal, LTSpacing.screenPadding)
                    .padding(.vertical, LTSpacing.m)
                }
            }
            .navigationTitle("询问工作人员")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// 从柜台对话把工作人员回答记回字段（明确操作 + 用户确认）：
/// "记为字段备注" / "使用为当前值"（后者显示待写入内容并确认）。
struct InterpreterFormFieldRecordSheet: View {
    let fieldContext: InterpreterFormFieldAskContext
    /// 最近一条对方（俄语）回合的中文翻译 —— 现场问到的回答。
    let heardChinese: String
    let onRecordNote: (String) -> Void
    let onUseAsValue: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draftNote = ""

    var body: some View {
        NavigationStack {
            LTPage {
                ScrollView {
                    VStack(alignment: .leading, spacing: LTSpacing.s) {
                        Label(fieldContext.chipLabel, systemImage: "text.book.closed")
                            .font(LTTypography.statusChip)
                            .foregroundStyle(LTColors.accentCyan)
                            .lineLimit(2)

                        VStack(alignment: .leading, spacing: LTSpacing.xxs) {
                            Text("工作人员的回答（对方最近一句的翻译）")
                                .font(LTTypography.statusChip)
                                .foregroundStyle(LTColors.textTertiary)
                            Text(heardChinese)
                                .font(LTTypography.body)
                                .foregroundStyle(LTColors.textPrimary)
                                .textSelection(.enabled)
                        }
                        .ltCard(padding: LTSpacing.s)

                        VStack(alignment: .leading, spacing: LTSpacing.xxs) {
                            Text("备注（可编辑后记为字段备注）")
                                .font(LTTypography.statusChip)
                                .foregroundStyle(LTColors.textTertiary)
                            TextField("备注", text: $draftNote, axis: .vertical)
                                .lineLimit(2...5)
                                .font(LTTypography.body)
                                .padding(LTSpacing.s)
                                .background(
                                    RoundedRectangle(cornerRadius: LTRadius.medium)
                                        .fill(LTColors.surfaceElevated.opacity(0.6))
                                )
                        }
                        .ltCard(padding: LTSpacing.s)

                        Button {
                            onRecordNote(draftNote)
                            dismiss()
                        } label: {
                            Label("记为字段备注", systemImage: "note.text")
                                .font(LTTypography.button)
                                .foregroundStyle(LTColors.accentBlue)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, LTSpacing.s)
                                .background(Capsule().fill(LTColors.accentBlue.opacity(0.14)))
                        }
                        .disabled(draftNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        // "使用为当前值"：显示待写入内容并由用户确认（本
                        // sheet 的按钮即是确认 —— 写入前内容已在上方展示）。
                        Button {
                            onUseAsValue(heardChinese)
                            dismiss()
                        } label: {
                            Label("使用为当前值（写入上方显示的回答）", systemImage: "square.and.pencil")
                                .font(LTTypography.button)
                                .foregroundStyle(Color.black.opacity(0.85))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, LTSpacing.s)
                                .background(Capsule().fill(LTColors.accentCyan.opacity(0.85)))
                        }

                        Text("记回内容只保存在本机草稿 —— 不会同步。")
                            .font(LTTypography.caption)
                            .foregroundStyle(LTColors.textTertiary)
                    }
                    .padding(.horizontal, LTSpacing.screenPadding)
                    .padding(.vertical, LTSpacing.m)
                }
            }
            .navigationTitle("记回字段")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            if draftNote.isEmpty { draftNote = heardChinese }
        }
    }
}
