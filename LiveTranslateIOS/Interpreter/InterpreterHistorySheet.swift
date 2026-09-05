import SwiftUI

/// 最近办事翻译 —— 已保存的随身翻译记录（页面内部历史，不混入课堂
/// 记录列表）。支持搜索、重命名、继续作为新对话的上下文副本、导出
/// （双语 TXT / Markdown / 系统分享）、删除。置顶不做（避免扩张成
/// 收藏系统）。
struct InterpreterHistorySheet: View {
    let environment: AppEnvironment
    var onContinueAsContext: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var conversations: [InterpreterConversation] = []
    @State private var turnCounts: [UUID: Int] = [:]
    @State private var searchQuery = ""
    @State private var renaming: InterpreterConversation?
    @State private var renameText = ""
    @State private var shareURL: URL?

    var body: some View {
        NavigationStack {
            LTPage {
                content
            }
            .navigationTitle("最近翻译")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .task { reload() }
        .searchable(text: $searchQuery, prompt: "搜索标题、场景或对话内容")
        .onChange(of: searchQuery) { _, _ in reload() }
        .sheet(item: Binding(
            get: { renaming },
            set: { renaming = $0 }
        )) { conversation in
            renameSheet(conversation)
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

    private var content: some View {
        Group {
            if filteredConversations.isEmpty {
                LTEmptyState(
                    symbol: "clock.arrow.circlepath",
                    title: "还没有保存的翻译记录",
                    message: "结束一次随身翻译时选择\"保存记录\"，就会出现在这里。"
                )
            } else {
                List {
                    ForEach(filteredConversations, id: \.id) { conversation in
                        row(conversation)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func row(_ conversation: InterpreterConversation) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.xs) {
            HStack {
                Image(systemName: conversation.scene.symbol)
                    .foregroundStyle(LTColors.accentCyan)
                Text(conversation.title)
                    .font(LTTypography.cardTitle)
                    .foregroundStyle(LTColors.textPrimary)
                Spacer()
            }
            HStack(spacing: LTSpacing.s) {
                Text(conversation.scene.displayName)
                Text("·")
                Text("\(turnCounts[conversation.id] ?? 0) 个回合")
                Text("·")
                Text(Self.dateText(conversation.startedAt))
            }
            .font(LTTypography.caption)
            .foregroundStyle(LTColors.textSecondary)

            HStack(spacing: LTSpacing.l) {
                Button {
                    onContinueAsContext(conversation.id)
                    dismiss()
                } label: {
                    Label("用作新对话背景", systemImage: "arrow.uturn.backward.circle")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.accentBlue)
                }
                .buttonStyle(.plain)

                Menu {
                    Button {
                        export(conversation, markdown: false)
                    } label: {
                        Label("双语 TXT", systemImage: "doc.plaintext")
                    }
                    Button {
                        export(conversation, markdown: true)
                    } label: {
                        Label("Markdown", systemImage: "number.square")
                    }
                } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.accentGreen)
                }

                Button {
                    renameText = conversation.title
                    renaming = conversation
                } label: {
                    Label("重命名", systemImage: "pencil")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textSecondary)
                }
                .buttonStyle(.plain)

                Button(role: .destructive) {
                    delete(conversation)
                } label: {
                    Label("删除", systemImage: "trash")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.destructive)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, LTSpacing.xs)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                delete(conversation)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func renameSheet(_ conversation: InterpreterConversation) -> some View {
        NavigationStack {
            Form {
                TextField("标题", text: $renameText)
            }
            .navigationTitle("重命名")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { renaming = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        try? environment.repository.renameInterpreterConversation(
                            conversation, to: renameText
                        )
                        renaming = nil
                        reload()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Actions

    private var filteredConversations: [InterpreterConversation] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return conversations }
        return ((try? environment.repository.interpreterConversations(matching: trimmed)) ?? [])
    }

    private func reload() {
        conversations = (try? environment.repository.savedInterpreterConversations()) ?? []
        var counts: [UUID: Int] = [:]
        for conversation in conversations {
            counts[conversation.id] = ((try? environment.repository.interpreterTurns(
                conversationID: conversation.id
            )) ?? []).count
        }
        turnCounts = counts
    }

    private func delete(_ conversation: InterpreterConversation) {
        try? environment.repository.deleteInterpreterConversation(conversation)
        reload()
    }

    private func export(_ conversation: InterpreterConversation, markdown: Bool) {
        let turns = (try? environment.repository.interpreterTurns(
            conversationID: conversation.id
        )) ?? []
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

    private static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }
}
