import SwiftUI

/// 发送前预览（隐私闸门）：列出将发送的文档、页码与文字范围；敏感
/// 信息默认遮盖；用户可查看遮盖后的最终文本、选择发送未遮盖内容，
/// 或取消某些 source 行。确认后执行 AI 动作（提问/解释/多模态）。
struct InterpreterSendPreviewSheet: View {
    let viewModel: InterpreterViewModel
    let documentModel: InterpreterDocumentContextModel
    var question: String

    @Environment(\.dismiss) private var dismiss
    @State private var excludedSources: Set<String> = []
    @State private var sendUnmasked = false
    @State private var showFullText = false

    private var preview: InterpreterDocumentContextModel.SendPreview? {
        documentModel.pendingPreview
    }

    private var visibleLines: [String] {
        guard let preview else { return [] }
        // 源行以 "[S1]" 开头 —— 被取消的 source 行整行隐藏（完整
        // chunk 为单位，绝不半行截断）。
        return preview.sourceLines.filter { line in
            guard let id = line.split(separator: " ", maxSplits: 1).first,
                  id.hasPrefix("[") else { return true }
            return !excludedSources.contains(String(id.dropFirst().dropLast()))
        }
    }

    var body: some View {
        NavigationStack {
            LTPage {
                ScrollView {
                    VStack(alignment: .leading, spacing: LTSpacing.s) {
                        if let preview {
                            content(preview)
                        } else {
                            LTEmptyState(
                                symbol: "eye.slash",
                                title: "没有待发送的内容",
                                message: "请先选择要使用的文件页面。"
                            )
                        }
                    }
                    .padding(.horizontal, LTSpacing.screenPadding)
                    .padding(.vertical, LTSpacing.s)
                }
            }
            .navigationTitle("发送前确认")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        documentModel.cancelPreview()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("发送") {
                        confirm()
                    }
                    .disabled(visibleLines.isEmpty || viewModel.isTranslatingReply)
                }
            }
        }
    }

    @ViewBuilder
    private func content(
        _ preview: InterpreterDocumentContextModel.SendPreview
    ) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            Label("将发送以下内容给你的翻译模型", systemImage: "paperplane")
                .font(LTTypography.cardTitle)
                .foregroundStyle(LTColors.textPrimary)
            Text("只包含你选择发送的文字；原始文件和完整识别文本仍留在本机。")
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.textSecondary)

            if preview.maskedSensitive {
                sensitiveCard(preview)
            }

            sourcesCard

            if !question.isEmpty {
                questionCard
            }

            if viewModel.isTranslatingReply {
                HStack(spacing: LTSpacing.xs) {
                    ProgressView().controlSize(.small)
                    Text("正在生成…")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textSecondary)
                }
            }
            if let error = viewModel.lastTranslationError {
                Text(error)
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.warning)
            }

            syncBoundaryFootnote
        }
    }

    private func sensitiveCard(
        _ preview: InterpreterDocumentContextModel.SendPreview
    ) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.xs) {
            Label("已自动遮盖疑似敏感信息", systemImage: "eye.slash")
                .font(LTTypography.body)
                .foregroundStyle(LTColors.warning)
            ForEach(preview.sensitiveFindings, id: \.self) { finding in
                Text("· \(finding)")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textSecondary)
            }
            Text("自动检测只是建议，不能保证找全。默认发送遮盖后的文本；如需发送原文请打开下面的开关。")
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.textTertiary)
            Toggle("发送未遮盖内容", isOn: $sendUnmasked)
                .font(LTTypography.caption)
        }
        .ltCard()
    }

    private var sourcesCard: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            HStack {
                Label("内容预览", systemImage: "doc.text.magnifyingglass")
                    .font(LTTypography.body)
                    .foregroundStyle(LTColors.textPrimary)
                Spacer()
                Button(showFullText ? "收起" : "展开全文") {
                    showFullText.toggle()
                }
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.accentBlue)
            }
            ForEach(visibleLines.prefix(showFullText ? visibleLines.count : 4), id: \.self) { line in
                sourceRow(line)
            }
            if !showFullText, visibleLines.count > 4 {
                Text("还有 \(visibleLines.count - 4) 个片段…")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textTertiary)
            }
        }
        .ltCard()
    }

    private func sourceRow(_ line: String) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.xxs) {
            let parts = line.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            if let header = parts.first {
                let sourceID = sourceID(of: line)
                HStack {
                    Text(header)
                        .font(LTTypography.statusChip)
                        .foregroundStyle(LTColors.accentCyan)
                    Spacer()
                    // 整行取消（完整 chunk 为单位，绝不半行截断）。
                    Button {
                        if excludedSources.contains(sourceID) {
                            excludedSources.remove(sourceID)
                        } else {
                            excludedSources.insert(sourceID)
                        }
                    } label: {
                        Image(systemName: excludedSources.contains(sourceID) ? "circle" : "minus.circle")
                            .font(LTTypography.caption)
                            .foregroundStyle(LTColors.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(excludedSources.contains(sourceID) ? "恢复发送该片段" : "取消发送该片段")
                }
            }
            if parts.count > 1 {
                Text(parts[1])
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textSecondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
        }
        .opacity(excludedSources.contains(sourceID(of: line)) ? 0.4 : 1)
    }

    private func sourceID(of line: String) -> String {
        guard let id = line.split(separator: " ", maxSplits: 1).first,
              id.hasPrefix("[") else { return "" }
        return String(id.dropFirst().dropLast())
    }

    private var questionCard: some View {
        VStack(alignment: .leading, spacing: LTSpacing.xs) {
            Label("你的问题", systemImage: "questionmark.bubble")
                .font(LTTypography.body)
                .foregroundStyle(LTColors.textPrimary)
            Text(question)
                .font(LTTypography.body)
                .foregroundStyle(LTColors.textSecondary)
                .textSelection(.enabled)
        }
        .ltCard()
    }

    private var syncBoundaryFootnote: some View {
        Text("你提交的问题与生成的回答会像其他随身翻译对话一样同步到云端；文件原文与完整识别文本不会。")
            .font(LTTypography.caption)
            .foregroundStyle(LTColors.textTertiary)
    }

    // MARK: - Actions

    private func confirm() {
        guard let preview = documentModel.pendingPreview else { return }
        // 未遮盖选择：重建 source 集（无遮盖）。
        if sendUnmasked, preview.maskedSensitive {
            documentModel.useUnmaskedSources(question: question)
        }
        // 预览中被用户取消的 source 行（完整 chunk）从请求中剔除。
        if !excludedSources.isEmpty {
            documentModel.excludeSources(excludedSources)
        }
        switch preview.action {
        case .analyze:
            Task {
                await viewModel.submitDocumentAnalysis()
                dismiss()
            }
        case .ask:
            Task {
                await viewModel.submitDocumentQuestion(question: question)
                dismiss()
            }
        case .multimodal:
            Task {
                await viewModel.submitMultimodalAnalysis(question: question)
                dismiss()
            }
        }
    }
}
