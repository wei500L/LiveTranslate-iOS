import SwiftUI
import Observation

/// The study-review reading page: one classroom's AI-organized review
/// material. Reading-first layout (plain sections, no card-per-line),
/// every AI item traceable back to its transcript lines, full edit
/// support on the user's copy. Generated content and the user's additions
/// stay clearly separated.
struct StudyReviewView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewModel = StudyReviewViewModel()
    /// Editor sheet context (addition / item edit / outline node edit).
    @State private var editor: ReviewEditorContext?
    @State private var shareItem: SharedFile?
    @State private var exportError = false
    @State private var pendingRegenerate = false
    @State private var viewedAttachment: AttachmentIDBox?
    /// Identifiable wrapper (sheet(item:) needs Identifiable; UUID isn't).
    private struct AttachmentIDBox: Identifiable {
        let id: UUID
        init(_ id: UUID) { self.id = id }
    }
    // Learning-material save flows (term book / cards / tasks). The draft
    // wrappers make the sheets item-driven.
    @State private var termDraftBox: TermDraftBox?
    @State private var cardDraftBox: CardDraftBox?
    @State private var taskDraftBox: TaskDraftBox?
    @State private var showingAICards = false

    let sessionID: UUID
    /// Pops back to the classroom detail and scrolls to the entry.
    let onJumpToEntry: (UUID) -> Void

    /// What the editor sheet is editing.
    struct ReviewEditorContext: Identifiable {
        enum Kind {
            /// Editing one AI text field; `apply` routes the new text into
            /// the view model (which persists through the repository).
            case itemText(title: String, text: String, apply: (String) -> Void)
            /// Adding or editing a user addition.
            case userAddition(existing: StudyReviewContent.UserAddition?, apply: (String) -> Void)
        }

        let kind: Kind
        var id: String {
            switch kind {
            case .itemText(let title, _, _): return "item-\(title)"
            case .userAddition(let existing, _): return existing?.id.uuidString ?? "new-addition"
            }
        }
    }

    var body: some View {
        LTPage {
            Group {
                if viewModel.isLoaded, viewModel.session == nil {
                    LTEmptyState(
                        symbol: "questionmark.folder",
                        title: "课堂不存在",
                        message: "这条记录可能已被删除"
                    )
                } else if viewModel.isLoaded, let session = viewModel.session {
                    content(session)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("学习整理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                menu
            }
        }
        .task {
            viewModel.attach(environment)
            viewModel.load(sessionID: sessionID)
        }
        .onAppear {
            if viewModel.isLoaded {
                viewModel.reload()
            }
        }
        // Leaving the page does NOT cancel an in-flight generation: the
        // user may pop out and come back (or read the entry card's live
        // progress) — the generator runs to completion either way.
        .sheet(item: $editor) { context in
            ReviewItemEditor(context: context)
                .onDisappear { viewModel.reload() }
        }
        .sheet(item: $viewedAttachment) { viewed in
            if let session = viewModel.session {
                AttachmentDetailView(
                    session: session,
                    attachmentID: viewed.id,
                    onChanged: { viewModel.reload() }
                )
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .sheet(item: $termDraftBox) { box in
            TermSaveSheet(draft: box.draft)
        }
        .sheet(item: $cardDraftBox) { box in
            CardSaveSheet(draft: box.draft)
        }
        .sheet(item: $taskDraftBox) { box in
            TaskSaveSheet(draft: box.draft, editingTask: nil)
        }
        .sheet(isPresented: $showingAICards) {
            AICardGenerationView(
                preselectedCourseID: viewModel.session?.courseID,
                courses: [],
                preselectedSessionID: sessionID
            )
        }
        .alert("导出失败", isPresented: $exportError) {
            Button("好", role: .cancel) {}
        } message: {
            Text("无法生成导出文件，请重试。")
        }
        .confirmationDialog(
            "重新整理会替换当前的整理内容",
            isPresented: $pendingRegenerate,
            titleVisibility: .visible
        ) {
            Button("重新整理", role: .destructive) {
                viewModel.generate(resume: false)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(viewModel.hasUserEdits
                 ? "你在 AI 内容上做过修改，重新整理后这些修改会被新结果取代（“我的补充”会保留）。"
                 : "将根据当前课堂内容重新生成一份整理。")
        }
    }

    // MARK: - Content

    private func content(_ session: ClassroomSession) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LTSpacing.l) {
                statusCard(session)
                if let content = viewModel.content, viewModel.hasReadableContent {
                    reviewSections(content)
                }
                generationInfo
            }
            .padding(.horizontal, LTSpacing.screenPadding)
            .padding(.top, LTSpacing.s)
            .padding(.bottom, LTSpacing.xl)
        }
    }

    // MARK: - Status

    @ViewBuilder
    private func statusCard(_ session: ClassroomSession) -> some View {
        // In-flight generation with real progress.
        if let progress = viewModel.progress {
            generatingCard(progress)
        } else if !viewModel.isServiceConfigured {
            unconfiguredCard
        } else if viewModel.content == nil && viewModel.review == nil {
            emptyCard
        } else if viewModel.status == .partial {
            partialCard
        } else if viewModel.status == .failed && viewModel.content == nil {
            failedCard
        } else if let content = viewModel.content {
            completedHeader(content)
        }
    }

    private func generatingCard(_ progress: StudyReviewGenerator.Progress) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            HStack(spacing: LTSpacing.s) {
                LTActivityDot(active: true)
                Text(progress.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LTColors.textPrimary)
                Spacer()
                Button("取消") {
                    viewModel.cancel()
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(LTColors.destructive)
            }
            if progress.total > 0 {
                ProgressView(value: Double(progress.done), total: Double(progress.total))
                    .tint(LTColors.accentGreen)
            }
            if let content = viewModel.content {
                // Regenerating over an existing result: keep it readable.
                Text("当前仍显示上一次的整理结果，完成后自动替换。")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textTertiary)
                completedHeader(content, compact: true)
            }
        }
        .ltCard()
    }

    private var unconfiguredCard: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            LTEmptyState(
                symbol: "sparkles",
                title: "整理功能需要模型服务",
                message: "把课堂文字整理为复习资料，需要先配置一个 OpenAI 兼容的模型服务。"
            )
            Button {
                environment.flow.collapseLive(to: .profile)
            } label: {
                Label("前往配置（与翻译服务共用地址和密钥）", systemImage: "gearshape")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(LTColors.accentBlue)
            }
        }
        .ltCard()
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            LTEmptyState(
                symbol: "sparkles.rectangle.stack",
                title: "还没有整理",
                message: "把这堂课的转录、翻译、你的笔记和板书图片，整理成一份可复习的学习资料。"
            )
            Button {
                viewModel.generate(resume: false)
            } label: {
                Label("开始整理", systemImage: "wand.and.stars")
                    .font(LTTypography.button)
                    .foregroundStyle(Color.black.opacity(0.85))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, LTSpacing.s + 2)
                    .background(Capsule().fill(LTColors.accentGreen))
            }
            .disabled(viewModel.entryCount == 0)
            if viewModel.entryCount == 0 {
                Text("这堂课没有可整理的文字内容。")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textTertiary)
            } else if viewModel.unanalyzedAttachmentCount > 0 {
                Label(
                    "还有 \(viewModel.unanalyzedAttachmentCount) 张图片未分析，整理时不会包含它们",
                    systemImage: "photo.badge.exclamationmark"
                )
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.textTertiary)
            } else if viewModel.analyzedAttachmentCount > 0 {
                Label(
                    "将包含 \(viewModel.analyzedAttachmentCount) 张图片的板书与笔记内容",
                    systemImage: "photo.on.rectangle.angled"
                )
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.textTertiary)
            }
        }
        .ltCard()
    }

    private var partialCard: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            HStack(spacing: LTSpacing.xs) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(LTColors.warning)
                Text("整理未完成")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LTColors.textPrimary)
                Spacer()
                Button("继续整理") {
                    viewModel.generate(resume: true)
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(LTColors.accentBlue)
            }
            Text("上次整理中断了，已完成的进度已保留，继续将从上次的位置接着进行。")
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.textSecondary)
        }
        .ltCard()
    }

    private var failedCard: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            HStack(spacing: LTSpacing.xs) {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(LTColors.destructive)
                Text("整理失败")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LTColors.textPrimary)
                Spacer()
                Button("重试") {
                    viewModel.generate(resume: false)
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(LTColors.accentBlue)
            }
            Text("可能是网络或模型服务暂时不可用。课堂原始内容不受影响。")
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.textSecondary)
        }
        .ltCard()
    }

    /// Topic + summary of a readable review.
    @ViewBuilder
    private func completedHeader(_ content: StudyReviewContent, compact: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            if viewModel.status == .failed, !compact {
                HStack(spacing: LTSpacing.xs) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.caption)
                    Text("上次重新整理没有成功，当前显示之前的结果，可重新整理。")
                        .font(LTTypography.caption)
                    Spacer()
                }
                .foregroundStyle(LTColors.warning)
                .padding(LTSpacing.s)
                .background(RoundedRectangle(cornerRadius: LTRadius.small).fill(LTColors.warning.opacity(0.08)))
            }
            if viewModel.isStale, !compact {
                HStack(spacing: LTSpacing.xs) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.caption)
                    Text("课堂资料在整理后有更新（例如补翻译、新笔记或新的板书图片），可重新整理。")
                        .font(LTTypography.caption)
                    Spacer()
                }
                .foregroundStyle(LTColors.warning)
                .padding(LTSpacing.s)
                .background(RoundedRectangle(cornerRadius: LTRadius.small).fill(LTColors.warning.opacity(0.08)))
            }
            if !content.topic.isEmpty {
                Text(content.topic)
                    .font(LTTypography.cardTitle)
                    .foregroundStyle(LTColors.textPrimary)
            }
            if !content.summary.isEmpty {
                Text(content.summary)
                    .font(.body)
                    .foregroundStyle(LTColors.textPrimary)
                    .lineSpacing(4)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Review sections

    @ViewBuilder
    private func reviewSections(_ content: StudyReviewContent) -> some View {
        if !content.outline.isEmpty {
            outlineSection(content.outline)
        }
        if !content.keyPoints.isEmpty {
            listSection(
                title: "重点知识",
                copyText: content.keyPoints.map(\.text).joined(separator: "\n")
            ) {
                ForEach(content.keyPoints) { point in
                    itemRow(
                        text: point.text,
                        refEntryIDs: point.refEntryIDs,
                        refAttachmentIDs: point.refAttachmentIDs
                    ) { newText in
                        viewModel.editKeyPoint(point, text: newText)
                    } onDelete: {
                        viewModel.deleteKeyPoint(point)
                    }
                }
            }
        }
        if !content.terms.isEmpty {
            listSection(
                title: "俄语术语",
                copyText: content.terms.map { "\($0.russian) — \($0.chinese)" }.joined(separator: "\n")
            ) {
                ForEach(content.terms) { term in
                    termRow(term)
                }
            }
        }
        if !content.assignments.isEmpty {
            listSection(
                title: "作业与待办",
                copyText: content.assignments.map(\.text).joined(separator: "\n")
            ) {
                ForEach(content.assignments) { assignment in
                    itemRow(
                        text: assignment.text,
                        refEntryIDs: assignment.refEntryIDs,
                        refAttachmentIDs: assignment.refAttachmentIDs,
                        symbol: "checklist"
                    ) { newText in
                        viewModel.editAssignment(assignment, text: newText)
                    } onDelete: {
                        viewModel.deleteAssignment(assignment)
                    }
                }
            }
        } else if !content.userNotes.isEmpty || viewModel.content != nil {
            // Honest empty assignment state (only when there is a review).
            listSection(title: "作业与待办", copyText: nil) {
                Text("未识别到老师明确布置的任务")
                    .font(.footnote)
                    .foregroundStyle(LTColors.textTertiary)
            }
        }
        if !content.uncertainties.isEmpty {
            listSection(
                title: "待确认内容",
                copyText: content.uncertainties.map(\.text).joined(separator: "\n")
            ) {
                ForEach(content.uncertainties) { item in
                    itemRow(
                        text: item.text,
                        refEntryIDs: item.refEntryIDs,
                        refAttachmentIDs: item.refAttachmentIDs,
                        symbol: "questionmark.diamond"
                    ) { newText in
                        viewModel.editUncertainty(item, text: newText)
                    } onDelete: {
                        viewModel.deleteUncertainty(item)
                    }
                }
            }
        }
        userNotesSection(content)
    }

    private func listSection(
        title: String,
        copyText: String?,
        @ViewBuilder rows: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            HStack(spacing: LTSpacing.xs) {
                LTSectionHeader(title: title)
                Spacer()
                if let copyText {
                    Button {
                        ClipboardService.shared.copySensitive(copyText)
                        LTHaptics.tap()
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                            .foregroundStyle(LTColors.textTertiary)
                    }
                    .accessibilityLabel(Text("复制\(title)"))
                }
            }
            VStack(alignment: .leading, spacing: LTSpacing.s) {
                rows()
            }
            .padding(.leading, LTSpacing.xxs)
        }
    }

    // MARK: Outline

    private func outlineSection(_ nodes: [StudyReviewContent.OutlineNode]) -> some View {
        listSection(
            title: "课堂提纲",
            copyText: nodes.map(\.title).joined(separator: "\n")
        ) {
            ForEach(nodes) { node in
                OutlineNodeView(
                    node: node,
                    entryPreview: { id in viewModel.entryPreview(id) },
                    onEdit: { node in
                        editor = ReviewEditorContext(
                            kind: .itemText(
                                title: "编辑提纲节点",
                                text: node.detail.isEmpty ? node.title : "\(node.title)\n\n\(node.detail)"
                            ) { merged in
                                viewModel.editOutlineNode(node, mergedText: merged)
                            }
                        )
                    },
                    onDeleteNode: { viewModel.deleteOutlineNode($0) },
                    onJump: { onJumpToEntry($0) }
                )
            }
        }
    }

    // MARK: Rows

    private func itemRow(
        text: String,
        refEntryIDs: [UUID],
        refAttachmentIDs: [UUID] = [],
        symbol: String = "circle.fill",
        onEdit: @escaping (String) -> Void,
        onDelete: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.xs) {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(LTColors.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !refEntryIDs.isEmpty || !refAttachmentIDs.isEmpty {
                HStack(spacing: LTSpacing.s) {
                    citationsRow(refEntryIDs, expand: false)
                    attachmentChips(refAttachmentIDs)
                }
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("编辑") { onEdit(text) }
            Button("删除", role: .destructive) { onDelete() }
            Divider()
            Button {
                cardDraftBox = CardDraftBox(draft: cardDraft(
                    front: text, back: "",
                    entryID: refEntryIDs.first,
                    attachmentID: refAttachmentIDs.first
                ))
            } label: {
                Label("制作学习卡片", systemImage: "rectangle.on.rectangle")
            }
            Button {
                taskDraftBox = TaskDraftBox(draft: taskDraft(
                    title: text,
                    entryID: refEntryIDs.first,
                    attachmentID: refAttachmentIDs.first
                ))
            } label: {
                Label("转为任务", systemImage: "checklist")
            }
            if let first = refEntryIDs.first {
                Button("查看原文") { onJumpToEntry(first) }
            }
        }
    }

    private func termRow(_ term: StudyReviewContent.TermItem) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: LTSpacing.s) {
                Text(term.russian)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LTColors.textPrimary)
                    .textSelection(.enabled)
                Text(term.chinese)
                    .font(.subheadline)
                    .foregroundStyle(LTColors.textSecondary)
                    .textSelection(.enabled)
                Spacer()
            }
            if !term.explanation.isEmpty {
                Text(term.explanation)
                    .font(.footnote)
                    .foregroundStyle(LTColors.textSecondary)
                    .textSelection(.enabled)
            }
            if !term.refEntryIDs.isEmpty {
                citationsRow(term.refEntryIDs)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("编辑") {
                editor = ReviewEditorContext(
                    kind: .itemText(
                        title: "编辑术语",
                        text: "\(term.russian)\n\(term.chinese)\n\(term.explanation)"
                    ) { merged in
                        viewModel.editTerm(term, mergedText: merged)
                    }
                )
            }
            Button("删除", role: .destructive) {
                viewModel.deleteTerm(term)
            }
            Divider()
            Button {
                termDraftBox = TermDraftBox(draft: TermDraft(
                    russian: term.russian,
                    chinese: term.chinese,
                    explanation: term.explanation,
                    courseID: viewModel.session?.courseID,
                    sessionID: sessionID,
                    sourceEntryID: term.refEntryIDs.first,
                    sourceAttachmentID: term.refAttachmentIDs.first,
                    sourceReviewID: sessionID
                ))
            } label: {
                Label("保存到术语本", systemImage: "character.book.closed")
            }
            Button {
                cardDraftBox = CardDraftBox(draft: cardDraft(
                    front: term.russian,
                    back: term.chinese.isEmpty ? term.explanation : term.chinese,
                    entryID: term.refEntryIDs.first,
                    attachmentID: term.refAttachmentIDs.first
                ))
            } label: {
                Label("制作术语卡片", systemImage: "rectangle.on.rectangle")
            }
            if let first = term.refEntryIDs.first {
                Button("查看原文") { onJumpToEntry(first) }
            }
        }
    }

    /// "查看原文" affordance: the timestamp of the cited line, tappable.
    /// `expand == false` keeps the trailing Spacer for inline rows.
    private func citationsRow(_ entryIDs: [UUID], expand: Bool = true) -> some View {
        HStack(spacing: LTSpacing.s) {
            ForEach(entryIDs.prefix(3), id: \.self) { entryID in
                Button {
                    onJumpToEntry(entryID)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "text.bubble")
                            .font(.caption2)
                        Text(viewModel.citationLabel(entryID))
                            .font(LTTypography.timestamp)
                    }
                    .foregroundStyle(LTColors.accentBlue.opacity(0.9))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("查看原文 \(viewModel.citationLabel(entryID))"))
            }
            if entryIDs.count > 3 {
                Text("+\(entryIDs.count - 3)")
                    .font(LTTypography.timestamp)
                    .foregroundStyle(LTColors.textTertiary)
            }
            if expand { Spacer() }
        }
    }

    /// 板书引用 chips: tap opens the referenced image (not just the
    /// transcript line).
    private func attachmentChips(_ attachmentIDs: [UUID]) -> some View {
        HStack(spacing: LTSpacing.s) {
            ForEach(attachmentIDs.prefix(3), id: \.self) { attachmentID in
                Button {
                    viewedAttachment = AttachmentIDBox(attachmentID)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "photo")
                            .font(.caption2)
                        Text(viewModel.attachmentLabel(attachmentID))
                            .font(LTTypography.timestamp)
                    }
                    .foregroundStyle(LTColors.accentGreen.opacity(0.9))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("查看图片 \(viewModel.attachmentLabel(attachmentID))"))
            }
            if attachmentIDs.count > 3 {
                Text("+\(attachmentIDs.count - 3)")
                    .font(LTTypography.timestamp)
                    .foregroundStyle(LTColors.textTertiary)
            }
        }
    }

    private func userNotesSection(_ content: StudyReviewContent) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            HStack(spacing: LTSpacing.xs) {
                LTSectionHeader(title: "我的补充")
                Text("不会被重新整理覆盖")
                    .font(LTTypography.timestamp)
                    .foregroundStyle(LTColors.textTertiary)
                Spacer()
                Button {
                    editor = ReviewEditorContext(
                        kind: .userAddition(existing: nil) { text in
                            viewModel.addUserAddition(text)
                        }
                    )
                } label: {
                    Label("添加", systemImage: "plus")
                        .font(LTTypography.caption.weight(.semibold))
                        .foregroundStyle(LTColors.accentBlue)
                }
            }
            if content.userNotes.isEmpty {
                Text("写下你自己的理解和补充，重新整理时这里的内容会保留。")
                    .font(.footnote)
                    .foregroundStyle(LTColors.textTertiary)
            } else {
                VStack(alignment: .leading, spacing: LTSpacing.s) {
                    ForEach(content.userNotes) { note in
                        HStack(alignment: .top, spacing: LTSpacing.s) {
                            Image(systemName: "pencil.line")
                                .font(.caption)
                                .foregroundStyle(LTColors.warning)
                                .padding(.top, 2)
                            Text(note.text)
                                .font(.subheadline)
                                .foregroundStyle(LTColors.textPrimary)
                                .textSelection(.enabled)
                        }
                        .contextMenu {
                            Button("编辑") {
                                editor = ReviewEditorContext(
                                    kind: .userAddition(existing: note) { text in
                                        viewModel.editUserAddition(note, text: text)
                                    }
                                )
                            }
                            Button("删除", role: .destructive) {
                                viewModel.deleteUserAddition(note)
                            }
                            Divider()
                            Button {
                                cardDraftBox = CardDraftBox(draft: cardDraft(
                                    front: note.text, back: "", entryID: nil, attachmentID: nil
                                ))
                            } label: {
                                Label("制作卡片", systemImage: "rectangle.on.rectangle")
                            }
                            Button {
                                taskDraftBox = TaskDraftBox(draft: taskDraft(
                                    title: note.text, entryID: nil, attachmentID: nil
                                ))
                            } label: {
                                Label("创建任务", systemImage: "checklist")
                            }
                        }
                    }
                }
                .padding(.leading, LTSpacing.xxs)
            }
        }
    }

    // MARK: - Learning draft builders

    /// Pre-fills a card draft with this session's source refs.
    private func cardDraft(
        front: String, back: String, entryID: UUID?, attachmentID: UUID?
    ) -> CardDraft {
        CardDraft(
            front: front,
            back: back,
            courseID: viewModel.session?.courseID,
            sessionID: sessionID,
            sourceEntryID: entryID,
            sourceAttachmentID: attachmentID
        )
    }

    /// Pre-fills a task draft from review material. AI-sourced text
    /// starts as a pendingConfirm candidate with its provenance note.
    private func taskDraft(
        title: String, entryID: UUID?, attachmentID: UUID?
    ) -> TaskDraft {
        TaskDraft(
            title: title,
            status: .pendingConfirm,
            origin: .ai,
            uncertainty: "来自 AI 学习整理的作业条目，确认后生效",
            courseID: viewModel.session?.courseID,
            sessionID: sessionID,
            sourceEntryID: entryID,
            sourceAttachmentID: attachmentID,
            sourceReviewID: sessionID
        )
    }

    // MARK: - Generation info + menu

    @ViewBuilder
    private var generationInfo: some View {
        if viewModel.content != nil || viewModel.review != nil {
            VStack(alignment: .leading, spacing: 3) {
                if let generatedAt = viewModel.generatedAt {
                    Text("整理于 \(Format.date(generatedAt)) \(Format.time(generatedAt))")
                }
                if !viewModel.reviewModel.isEmpty {
                    Text("模型：\(viewModel.reviewModel)")
                }
            }
            .font(LTTypography.timestamp)
            .foregroundStyle(LTColors.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var menu: some View {
        Menu {
            if viewModel.content != nil {
                Button {
                    pendingRegenerate = true
                } label: {
                    Label("重新整理", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(viewModel.progress != nil)
                Button {
                    showingAICards = true
                } label: {
                    Label("AI 制作复习卡片", systemImage: "sparkles")
                }
                .disabled(viewModel.progress != nil)
                Button {
                    exportReview()
                } label: {
                    Label("导出整理结果", systemImage: "square.and.arrow.up")
                }
                Button(role: .destructive) {
                    viewModel.deleteReview()
                } label: {
                    Label("删除整理", systemImage: "trash")
                }
            } else if viewModel.status == .partial {
                Button {
                    viewModel.generate(resume: true)
                } label: {
                    Label("继续整理", systemImage: "play.fill")
                }
                Button(role: .destructive) {
                    viewModel.deleteReview()
                } label: {
                    Label("删除未完成的整理", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(LTColors.textSecondary)
        }
        .accessibilityLabel(Text("更多操作"))
    }

    // MARK: - Export

    private func exportReview() {
        Task {
            if let url = await viewModel.exportReviewURL() {
                shareItem = SharedFile(url: url)
            } else {
                exportError = true
            }
        }
    }
}

// MARK: - Outline node view

/// One outline node: title, optional detail, citations, collapsible
/// children. Edit/delete act by node identity — the view model finds the
/// node anywhere in the tree, so nested nodes need no parent bookkeeping.
private struct OutlineNodeView: View {
    let node: StudyReviewContent.OutlineNode
    let entryPreview: (UUID) -> String?
    let onEdit: (StudyReviewContent.OutlineNode) -> Void
    let onDeleteNode: (StudyReviewContent.OutlineNode) -> Void
    let onJump: (UUID) -> Void
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: LTSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: LTSpacing.s) {
                if !node.children.isEmpty {
                    Button {
                        withAnimation(LTMotion.quick) { isExpanded.toggle() }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(LTColors.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(isExpanded ? "收起子节点" : "展开子节点"))
                }
                Text(node.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(LTColors.textPrimary)
                    .textSelection(.enabled)
                Spacer()
            }
            if isExpanded {
                VStack(alignment: .leading, spacing: LTSpacing.xs) {
                    if !node.detail.isEmpty {
                        Text(node.detail)
                            .font(.footnote)
                            .foregroundStyle(LTColors.textSecondary)
                            .textSelection(.enabled)
                            .padding(.leading, LTSpacing.m)
                    }
                    ForEach(node.refEntryIDs.prefix(3), id: \.self) { entryID in
                        Button {
                            onJump(entryID)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "text.bubble")
                                    .font(.caption2)
                                Text(entryPreview(entryID) ?? "原文")
                                    .font(LTTypography.timestamp)
                                    .lineLimit(1)
                            }
                            .foregroundStyle(LTColors.accentBlue.opacity(0.9))
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, LTSpacing.m)
                    }
                    ForEach(node.children) { child in
                        OutlineNodeView(
                            node: child,
                            entryPreview: entryPreview,
                            onEdit: onEdit,
                            onDeleteNode: onDeleteNode,
                            onJump: onJump
                        )
                        .padding(.leading, LTSpacing.m)
                    }
                }
            }
        }
        .contextMenu {
            Button("编辑") { onEdit(node) }
            Button("删除", role: .destructive) { onDeleteNode(node) }
            if let first = node.refEntryIDs.first {
                Button("查看原文") { onJump(first) }
            }
        }
    }
}

// MARK: - Item editor sheet

/// Simple text editor for one review item or a user addition. Saves
/// through the view model's repository-backed callbacks.
private struct ReviewItemEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    let context: StudyReviewView.ReviewEditorContext

    var body: some View {
        NavigationStack {
            LTPage {
                TextEditor(text: $text)
                    .font(.body)
                    .foregroundStyle(LTColors.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(LTSpacing.s)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(
                        RoundedRectangle(cornerRadius: LTRadius.small)
                            .fill(LTColors.surfacePrimary)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: LTRadius.small)
                            .strokeBorder(LTColors.border, lineWidth: 0.5)
                    )
                    .focused($focused)
                    .padding(LTSpacing.screenPadding)
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .foregroundStyle(LTColors.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(LTColors.accentGreen)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            switch context.kind {
            case .itemText(_, let initial, _):
                text = initial
            case .userAddition(let existing, _):
                text = existing?.text ?? ""
            }
            focused = true
        }
    }

    private var navigationTitle: String {
        switch context.kind {
        case .itemText(let title, _, _): return title
        case .userAddition(let existing): return existing == nil ? "添加补充" : "编辑补充"
        }
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch context.kind {
        case .itemText(_, _, let apply):
            apply(trimmed)
        case .userAddition(_, let apply):
            apply(trimmed)
        }
        LTHaptics.success()
        dismiss()
    }
}


// MARK: - Learning draft boxes (item-driven sheets)

/// Item wrappers for the draft-based sheets (drafts themselves are plain
/// values without identity).
struct TermDraftBox: Identifiable {
    let id = UUID()
    let draft: TermDraft
}

struct CardDraftBox: Identifiable {
    let id = UUID()
    let draft: CardDraft
}

struct TaskDraftBox: Identifiable {
    let id = UUID()
    let draft: TaskDraft
}
