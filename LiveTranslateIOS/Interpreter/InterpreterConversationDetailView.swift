import SwiftUI

/// 已保存的随身翻译对话详情（搜索结果/最近记录点击打开）：回合列表
/// + 导出。只读展示 —— 编辑发生在新的随身翻译会话中。
struct InterpreterConversationDetailView: View {
    let conversationID: UUID
    let environment: AppEnvironment

    @Environment(\.dismiss) private var dismiss
    @State private var turns: [InterpreterTurn] = []
    @State private var availableDocumentIDs: Set<UUID> = []
    @State private var shareURL: URL?
    /// 整理为办事事项（草稿编辑器）。
    @State private var showErrandEditor = false

    private var conversation: InterpreterConversation? {
        environment.repository.interpreterConversation(id: conversationID)
    }

    var body: some View {
        LTPage {
            ScrollView {
                LazyVStack(spacing: LTSpacing.s) {
                    if let conversation {
                        header(conversation)
                        ForEach(turns, id: \.id) { turn in
                            InterpreterTurnCard(
                                turn: turn,
                                isExpanded: false,
                                showStress: environment.settings.interpreterShowStress,
                                isTranslating: false,
                                availableDocumentIDs: availableDocumentIDs
                            )
                        }
                    } else {
                        LTEmptyState(
                            symbol: "clock.arrow.circlepath",
                            title: "这条翻译记录已不存在",
                            message: "它可能已被删除。"
                        )
                    }
                }
                .padding(.horizontal, LTSpacing.screenPadding)
                .padding(.vertical, LTSpacing.s)
            }
        }
        .navigationTitle(conversation?.title ?? "随身翻译")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // 已保存对话 → 事项草稿（本地来源链接）。
                Button {
                    showErrandEditor = true
                } label: {
                    Image(systemName: "checklist")
                }
                .accessibilityLabel("整理为办事事项")
                .disabled(conversation == nil)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        export(markdown: false)
                    } label: {
                        Label("双语 TXT", systemImage: "doc.plaintext")
                    }
                    Button {
                        export(markdown: true)
                    } label: {
                        Label("Markdown", systemImage: "number.square")
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("导出")
            }
        }
        .sheet(isPresented: $showErrandEditor) {
            ErrandCaseEditorView(sourceConversationID: conversationID)
                .environment(environment)
        }
        .task {
            turns = (try? environment.repository.interpreterTurns(
                conversationID: conversationID
            )) ?? []
            availableDocumentIDs = Set(
                ((try? environment.repository.interpreterDocuments(
                    conversationID: conversationID
                )) ?? []).map(\.id)
            )
        }
        .sheet(item: Binding(
            get: { shareURL.map { ShareURL(url: $0) } },
            set: { shareURL = $0?.url }
        )) { wrapper in
            ShareSheet(items: [wrapper.url])
        }
    }

    private struct ShareURL: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    private func header(_ conversation: InterpreterConversation) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.xs) {
            HStack {
                Image(systemName: conversation.scene.symbol)
                    .foregroundStyle(LTColors.accentCyan)
                Text(conversation.scene.displayName)
                    .font(LTTypography.cardTitle)
                    .foregroundStyle(LTColors.textPrimary)
                Spacer()
            }
            Text("\(turns.count) 个回合 · \(conversation.startedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.textSecondary)
        }
        .ltCard()
    }

    private func export(markdown: Bool) {
        guard let conversation else { return }
        let projection = InterpreterExporter.export(conversation: conversation, turns: turns)
        let content = markdown
            ? InterpreterExporter.markdown(projection)
            : InterpreterExporter.bilingualText(projection)
        let fileName = InterpreterExporter.suggestedFileName(
            title: conversation.title, ext: markdown ? "md" : "txt"
        )
        shareURL = try? InterpreterExporter.writeTemporaryFile(
            content: content, fileName: fileName
        )
    }
}
