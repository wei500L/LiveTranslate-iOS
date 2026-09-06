import SwiftUI

/// 一键返回填写草稿（第二十一轮）：从柜台对话回到原字段。
/// 文档/字段已被删除时显示真实状态并回到字段总览（或提示文档已删
/// 除）—— 绝不重建假字段。进入前停止当前收音与朗读（页面切换语义：
/// suspend 在 InterpreterScreen onDisappear 已处理；这里再显式停一次
/// TTS，保证返回填写页时不在后台继续朗读）。
struct InterpreterFormReturnSheet: View {
    @Environment(AppEnvironment.self) private var environment
    let viewModel: InterpreterViewModel
    /// 从本页发起"记回字段"（字段上下文 + 对方最近一句中文翻译）。
    var onAskStaffRecord: (InterpreterFormFieldAskContext, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var document: InterpreterDocument?
    @State private var draftModel: InterpreterFormDraftModel?
    @State private var fieldExists = false
    @State private var loaded = false

    private var fieldContext: InterpreterFormFieldAskContext? {
        viewModel.fieldAskContext
    }

    /// 对方最近一句的中文翻译（工作人员的回答）。
    private var heardChinese: String {
        viewModel.turns.last(where: {
            $0.speaker == .counterpart && !$0.chineseText.isEmpty
        })?.chineseText ?? ""
    }

    var body: some View {
        NavigationStack {
            LTPage {
                ScrollView {
                    VStack(alignment: .leading, spacing: LTSpacing.s) {
                        if !loaded {
                            ProgressView("正在打开填写草稿…")
                        } else if let fieldContext, let draftModel, document != nil {
                            content(fieldContext, draftModel)
                        } else {
                            LTEmptyState(
                                symbol: "trash",
                                title: "来源文件已删除",
                                message: "这份表单的文件已被删除，填写草稿不再可用。可以关闭此页回到对话。"
                            )
                        }
                    }
                    .padding(.horizontal, LTSpacing.screenPadding)
                    .padding(.vertical, LTSpacing.m)
                }
            }
            .screenCaptureMask()
            .navigationTitle("返回填写")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("留在对话") { dismiss() }
                }
            }
        }
        .onAppear {
            // 返回填写页：停止当前朗读（不在后台继续读）。
            viewModel.stopSpeaking()
            load()
        }
    }

    // MARK: - 加载（真实状态，不重建假字段）

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let context = viewModel.fieldAskContext else { return }
        // pendingFormReturn 是一次性消费的定位引用 —— 保留 fieldContext
        // 渲染（chip 由 InterpreterScreen 持有）。
        guard let document = environment.repository.interpreterDocument(id: context.documentID) else {
            return
        }
        self.document = document
        let model = InterpreterFormDraftModel(
            document: document,
            store: InterpreterDocumentStoreShared.store
        )
        self.draftModel = model
        self.fieldExists = model.field(with: context.fieldID) != nil
    }

    @ViewBuilder
    private func content(
        _ context: InterpreterFormFieldAskContext, _ model: InterpreterFormDraftModel
    ) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            Label(context.chipLabel, systemImage: "list.number")
                .font(LTTypography.statusChip)
                .foregroundStyle(LTColors.accentGreen)
                .lineLimit(2)

            if fieldExists {
                let progress = model.progress
                HStack(spacing: LTSpacing.m) {
                    Text("已填 \(progress.filled)")
                        .font(LTTypography.statusChip)
                        .foregroundStyle(LTColors.accentGreen)
                    Text("待确认 \(progress.needsConfirmation)")
                        .font(LTTypography.statusChip)
                        .foregroundStyle(LTColors.warning)
                    Text("未填 \(progress.empty)")
                        .font(LTTypography.statusChip)
                        .foregroundStyle(LTColors.textTertiary)
                }
                Button {
                    returnToField(model, context: context)
                } label: {
                    Label("回到该字段继续填写", systemImage: "arrow.turn.down.left")
                        .font(LTTypography.button)
                        .foregroundStyle(Color.black.opacity(0.85))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, LTSpacing.s)
                        .background(Capsule().fill(LTColors.accentGreen.opacity(0.9)))
                }
                if !heardChinese.isEmpty {
                    Button {
                        onAskStaffRecord(context, heardChinese)
                    } label: {
                        Label("把回答记回这个字段", systemImage: "note.text.badge.plus")
                            .font(LTTypography.button)
                            .foregroundStyle(LTColors.accentBlue)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, LTSpacing.s)
                            .background(Capsule().fill(LTColors.accentBlue.opacity(0.14)))
                    }
                }
            } else {
                Label("这个字段已被删除（可在清单中手动重新新增）", systemImage: "trash")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.warning)
                Button {
                    returnToOverview(model)
                } label: {
                    Label("回到字段总览", systemImage: "list.clipboard")
                        .font(LTTypography.button)
                        .foregroundStyle(Color.black.opacity(0.85))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, LTSpacing.s)
                        .background(Capsule().fill(LTColors.accentGreen.opacity(0.9)))
                }
            }
            Button {
                returnToOverview(model)
            } label: {
                Label("打开字段总览", systemImage: "list.clipboard")
                    .font(LTTypography.button)
                    .foregroundStyle(LTColors.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, LTSpacing.s)
                    .background(Capsule().fill(LTColors.surfaceElevated.opacity(0.6)))
            }
            Text("返回时停止当前收音与朗读；进入填写页后再次询问需要重新进入对话。")
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.textTertiary)
        }
        .ltCard()
    }

    // MARK: - 返回导航

    /// 返回 = 收起本 sheet 并回到填写流。实现方式：把返回定位交给
    /// InterpreterScreen 的文件面板路由（打开文档面板 → 直接进入该文档
    /// 的填写清单）。定位字段由 Flow 的"继续逐项填写"定位到第一个未
    /// 完成项 —— 同一字段的上下文经 endFieldAsk 清除（chip 关闭）。
    private func returnToField(_ model: InterpreterFormDraftModel, context: InterpreterFormFieldAskContext) {
        viewModel.endFieldAsk()
        dismiss()
        NotificationCenter.default.post(
            name: .interpreterOpenFormDraft, object: context.documentID
        )
    }

    private func returnToOverview(_ model: InterpreterFormDraftModel) {
        viewModel.endFieldAsk()
        dismiss()
        NotificationCenter.default.post(
            name: .interpreterOpenFormDraft, object: model.document.id
        )
    }
}

extension Notification.Name {
    /// 表单填写返回路由（UI-only 内存通知 —— 打开指定文档的填写清单；
    /// InterpreterScreen 监听并打开文件面板 + 填写流）。
    static let interpreterOpenFormDraft = Notification.Name("interpreterOpenFormDraft")
}
