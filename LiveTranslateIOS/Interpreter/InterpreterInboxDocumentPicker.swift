import SwiftUI

/// 从智能收件箱选择已接收的 PDF / 图片 / 文本文件作为随身翻译的
/// 文件上下文。选中后通过 Store API 取 payload 并立即复制进
/// Interpreter 自己的受控生命周期 —— 收件箱删除不影响已复制的文档。
struct InterpreterInboxDocumentPicker: View {
    @Environment(AppEnvironment.self) private var environment
    var onPick: (SharedInboxItem?) -> Void

    private var candidates: [SharedInboxItem] {
        environment.inbox.items.filter { item in
            guard item.payloadKind == .file else { return false }
            switch item.fileHints.family {
            case .pdf, .image, .text, .markdown: return true
            case .other: return false
            }
        }
    }

    var body: some View {
        NavigationStack {
            LTPage {
                Group {
                    if candidates.isEmpty {
                        LTEmptyState(
                            symbol: "tray",
                            title: "收件箱中没有可用文件",
                            message: "从其他 App 分享到 LiveTranslate 的 PDF、图片或文本会出现在这里。"
                        )
                    } else {
                        List {
                            ForEach(candidates, id: \.id) { item in
                                Button {
                                    onPick(item)
                                } label: {
                                    HStack(spacing: LTSpacing.s) {
                                        Image(systemName: familySymbol(item.fileHints.family))
                                            .foregroundStyle(LTColors.accentCyan)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.title.isEmpty ? "未命名文件" : item.title)
                                                .font(LTTypography.body)
                                                .foregroundStyle(LTColors.textPrimary)
                                                .lineLimit(2)
                                            Text("\(familyName(item.fileHints.family)) · \(ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))")
                                                .font(LTTypography.caption)
                                                .foregroundStyle(LTColors.textSecondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption2)
                                            .foregroundStyle(LTColors.textTertiary)
                                    }
                                }
                                .accessibilityLabel("选择 \(item.title)")
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                }
            }
            .navigationTitle("从收件箱选择")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onPick(nil) }
                }
            }
        }
        .onAppear {
            environment.inbox.reload()
        }
    }

    private func familySymbol(_ family: SharedInboxFileHints.FileFamily) -> String {
        switch family {
        case .pdf: return "doc.richtext"
        case .image: return "photo"
        case .text, .markdown: return "doc.plaintext"
        case .other: return "doc"
        }
    }

    private func familyName(_ family: SharedInboxFileHints.FileFamily) -> String {
        switch family {
        case .pdf: return "PDF"
        case .image: return "图片"
        case .text: return "文本"
        case .markdown: return "Markdown"
        case .other: return "文件"
        }
    }
}
