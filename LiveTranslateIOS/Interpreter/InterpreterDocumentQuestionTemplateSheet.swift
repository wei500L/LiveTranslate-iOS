import SwiftUI

/// 围绕文件现场提问（第二十轮）：少量本地问题模板 —— 点击只填入中文
/// 输入框（applySuggestion 语义：不自动翻译、不自动发送、不自动朗读、
/// 不自动开麦）。需要 AI 结合文件回答时，用户在文件面板继续走第十六
/// 轮既有"按文件提问"链（发送预览/遮盖/chunk 预算/citation 校验）。
struct InterpreterDocumentQuestionTemplateSheet: View {
    let viewModel: InterpreterViewModel
    /// 选中的文件上下文摘要（chip 文案用）。
    var documentCount: Int = 0
    /// 交给 AI 按文件回答（打开文件面板并预填该问题 —— 走第十六轮
    /// 既有发送预览/遮盖/chunk 预算链）。
    var onAskWithAI: (String) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss

    /// 本地模板（现场最常问的问题；绝不携带文件名/页码/路径）。
    private let templates: [String] = [
        "这里应该填写什么？",
        "需要原件还是复印件？",
        "请您指出需要签字的位置",
        "这一栏是必填的吗？",
        "这份文件需要翻译成俄语吗？",
    ]

    var body: some View {
        NavigationStack {
            LTPage {
                ScrollView {
                    VStack(alignment: .leading, spacing: LTSpacing.s) {
                        if documentCount > 0 {
                            Label(
                                "围绕选中的 \(documentCount) 份文件",
                                systemImage: "doc.text.magnifyingglass"
                            )
                            .font(LTTypography.interpreterStatus)
                            .foregroundStyle(LTColors.textSecondary)
                        }
                        ForEach(templates, id: \.self) { template in
                            Button {
                                // 只填入输入框 —— 与待问问题、快捷回复同一
                                // 语义；用户确认后再走翻译。
                                viewModel.applySuggestion(template)
                                dismiss()
                            } label: {
                                HStack(spacing: LTSpacing.s) {
                                    Image(systemName: "text.insert")
                                        .font(.footnote)
                                        .foregroundStyle(LTColors.accentCyan)
                                    Text(template)
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
                            .accessibilityLabel("填入输入框：\(template)")
                            // AI 路径（第十六轮既有链）：进入文件面板按文
                            // 件提问（发送预览 + 遮盖 + citation 校验）。
                            Button {
                                onAskWithAI(template)
                            } label: {
                                Label("AI 按文件回答", systemImage: "sparkle")
                                    .font(LTTypography.interpreterStatus)
                                    .foregroundStyle(LTColors.accentBlue)
                                    .frame(minHeight: LTSpacing.minTouchTarget)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("让 AI 结合文件回答：\(template)")
                            .padding(.leading, LTSpacing.m + LTSpacing.s)
                        }
                    }
                    .padding(.horizontal, LTSpacing.screenPadding)
                    .padding(.vertical, LTSpacing.m)
                }
            }
            .navigationTitle("围绕文件提问")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
