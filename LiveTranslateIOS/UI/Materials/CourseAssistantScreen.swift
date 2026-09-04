import SwiftUI
import Observation

/// The course assistant (问这门课): grounded Q&A over the course's
/// materials, transcripts, notes, blackboard images and study reviews.
/// Not a chatbot: every answer cites its sources; citations tap through
/// to the real page / transcript / note; a no-evidence question gets the
/// honest answer instead of a fabricated one.
struct CourseAssistantScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    /// Course scope (nil = 未归类 threads).
    let courseID: UUID?
    /// Fixed material scope (entered from the reader: 就本页提问).
    var fixedMaterialID: UUID? = nil
    var fixedPageNumber: Int? = nil
    /// Open this thread directly (search hits jump into the thread).
    var initialThreadID: UUID? = nil

    @State private var threads: [CourseAssistantThread] = []
    @State private var activeThread: CourseAssistantThread?
    @State private var showNewThread = false
    @State private var loaded = false

    var body: some View {
        LTPage {
            Group {
                if !loaded {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let thread = activeThread {
                    AssistantChatView(thread: thread, fixedScope: fixedScope)
                } else if threads.isEmpty {
                    LTEmptyState(
                        symbol: "bubble.left.and.text.bubble.right",
                        title: "问这门课",
                        message: "提问会检索课程资料、课堂转录、笔记与图片理解，回答带来源出处"
                    )
                } else {
                    threadList
                }
            }
        }
        .navigationTitle(activeThread == nil ? "问这门课" : (activeThread?.title ?? ""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("完成") { dismiss() }
            }
            if activeThread != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("返回列表") {
                        activeThread = nil
                    }
                    .font(LTTypography.button)
                }
            }
        }
        .task {
            reloadThreads()
            loaded = true
            // A fixed material scope opens the course's most recent
            // thread directly (the reader's 就本页提问 path); a search hit
            // opens ITS thread.
            if activeThread == nil {
                if let initialThreadID,
                   let thread = threads.first(where: { $0.id == initialThreadID }) {
                    activeThread = thread
                } else if fixedMaterialID != nil {
                    activeThread = threads.first
                }
            }
        }
        .onAppear {
            if loaded { reloadThreads() }
        }
        .sheet(isPresented: $showNewThread) {
            NavigationStack {
                NewAssistantThreadSheet(courseID: courseID) { thread in
                    reloadThreads()
                    activeThread = thread
                }
                .environment(environment)
            }
            .presentationDetents([.medium])
        }
    }

    private var fixedScope: CourseAssistantService.Scope? {
        if let fixedMaterialID, let fixedPageNumber {
            return .page(materialID: fixedMaterialID, pageNumber: fixedPageNumber)
        }
        if let fixedMaterialID {
            return .material(materialID: fixedMaterialID)
        }
        return nil
    }

    private var threadList: some View {
        ScrollView {
            VStack(spacing: LTSpacing.l) {
                Button {
                    showNewThread = true
                } label: {
                    Label("新提问", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(LTPrimaryButtonStyle())
                .padding(.top, LTSpacing.s)

                LazyVStack(spacing: LTSpacing.s) {
                    ForEach(threads) { thread in
                        Button {
                            activeThread = thread
                        } label: {
                            HStack(spacing: LTSpacing.m) {
                                LTIconBadge(
                                    symbol: "bubble.left.and.text.bubble.right",
                                    tint: LTColors.accentGreen,
                                    size: 38
                                )
                                VStack(alignment: .leading, spacing: LTSpacing.xxs) {
                                    Text(thread.title)
                                        .font(LTTypography.cardTitle)
                                        .foregroundStyle(LTColors.textPrimary)
                                        .lineLimit(2)
                                    Text(thread.updatedAt, style: .date)
                                        .font(LTTypography.caption)
                                        .foregroundStyle(LTColors.textTertiary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(LTColors.textTertiary)
                            }
                            .ltCard(padding: LTSpacing.m)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, LTSpacing.screenPadding)
            .padding(.bottom, LTSpacing.tabBarReserve)
        }
    }

    private func reloadThreads() {
        threads = (try? environment.repository.assistantThreads(courseID: courseID)) ?? []
    }
}

// MARK: - New thread sheet

private struct NewAssistantThreadSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let courseID: UUID?
    let onCreate: (CourseAssistantThread) -> Void

    @State private var title = ""

    var body: some View {
        LTPage {
            VStack(spacing: LTSpacing.l) {
                VStack(alignment: .leading, spacing: LTSpacing.s) {
                    TextField("主题（如：第三章习题、考试范围）", text: $title)
                        .font(Font.subheadline)
                        .padding(LTSpacing.s)
                        .background(LTColors.surfacePrimary.opacity(0.7))
                        .clipShape(RoundedRectangle(cornerRadius: LTRadius.small))
                    Button("开始提问") {
                        create()
                    }
                    .buttonStyle(LTPrimaryButtonStyle())
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .ltCard()
                Spacer()
            }
            .padding(.horizontal, LTSpacing.screenPadding)
            .padding(.top, LTSpacing.l)
        }
        .navigationTitle("新提问")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("取消") { dismiss() }
            }
        }
    }

    private func create() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let thread = try? environment.repository.addAssistantThread(
            courseID: courseID, title: trimmed
        ) {
            onCreate(thread)
            dismiss()
        }
    }
}

// MARK: - Chat view

/// One thread's conversation: durable history (offline-readable), a
/// question input with image evidence attachment (visual Q&A), REAL
/// stage states (准备图片 / 检索 / 提问 / 保存 — no streaming animation),
/// citations that tap through to their sources, and structured visual
/// answers with learning-loop actions.
struct AssistantChatView: View {
    @Environment(AppEnvironment.self) private var environment
    let thread: CourseAssistantThread
    /// The reader's fixed scope (本资料 / 本页); nil = course-wide.
    let fixedScope: CourseAssistantService.Scope?
    /// A handoff from the visual-ask composer: the question and evidence
    /// to send immediately on appear (the user already confirmed the
    /// send scope in the composer).
    var initialQuestion: String = ""
    var initialEvidence: [VisualEvidence] = []
    var initialOptions: CourseAssistantService.VisualAskOptions = .all

    @State private var messages: [CourseAssistantMessage] = []
    @State private var question = ""
    @State private var scope: CourseAssistantService.Scope?
    @State private var renameText = ""
    @State private var showRename = false
    @State private var showDeleteConfirm = false
    @State private var pendingEvidence: [VisualEvidence] = []
    @State private var showEvidencePicker = false
    @State private var options = CourseAssistantService.VisualAskOptions.all
    @State private var firedInitialAsk = false

    var body: some View {
        VStack(spacing: 0) {
            messageList
            inputBar
        }
        .task {
            scope = fixedScope ?? .course(courseID: thread.courseID)
            options = initialOptions
            reload()
            fireInitialAskIfNeeded()
        }
        .onAppear { reload() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        renameText = thread.title
                        showRename = true
                    } label: {
                        Label("重命名", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("删除对话", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(LTColors.textSecondary)
                }
            }
        }
        .alert("重命名对话", isPresented: $showRename) {
            TextField("名称", text: $renameText)
            Button("保存") {
                try? environment.repository.renameAssistantThread(thread, title: renameText)
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog(
            "删除这个对话？", isPresented: $showDeleteConfirm, titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                try? environment.repository.deleteAssistantThread(thread)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("对话历史会一并删除。")
        }
        .sheet(isPresented: $showEvidencePicker) {
            VisualEvidencePickerSheet(
                courseID: thread.courseID,
                focusSessionID: scope?.sessionIDValue,
                focusMaterialID: scope?.materialIDValue,
                existing: pendingEvidence
            ) { picked in
                pendingEvidence = picked
            }
            .environment(environment)
        }
    }

    private var messageList: some View {
        ScrollView {
            VStack(spacing: LTSpacing.m) {
                if messages.isEmpty {
                    VStack(spacing: LTSpacing.s) {
                        LTIconBadge(
                            symbol: "bubble.left.and.text.bubble.right",
                            tint: LTColors.accentGreen, size: 44
                        )
                        Text("问点什么吧")
                            .font(LTTypography.cardTitle)
                            .foregroundStyle(LTColors.textPrimary)
                        Text(scopeHint)
                            .font(LTTypography.caption)
                            .foregroundStyle(LTColors.textTertiary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, LTSpacing.xl)
                }
                ForEach(messages) { message in
                    AssistantMessageBubble(
                        message: message,
                        citations: message.citations,
                        onFollowUp: { followUp in
                            question = followUp
                        }
                    )
                }
                if let stage = environment.courseAssistant.stage(threadID: thread.id) {
                    HStack(spacing: LTSpacing.xs) {
                        ProgressView().controlSize(.small)
                        Text(stage.label)
                            .font(LTTypography.caption)
                            .foregroundStyle(LTColors.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, LTSpacing.screenPadding)
                }
            }
            .padding(.horizontal, LTSpacing.screenPadding)
            .padding(.vertical, LTSpacing.l)
            .padding(.bottom, LTSpacing.s)
        }
    }

    /// The question input. Offline / unconfigured states are honest:
    /// asking is unavailable; READING history stays possible. Image
    /// evidence chips ride above the field (multi-image asks up to 4).
    private var inputBar: some View {
        VStack(spacing: LTSpacing.xs) {
            if !pendingEvidence.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: LTSpacing.xs) {
                        ForEach(Array(pendingEvidence.enumerated()), id: \.element.id) { index, item in
                            VisualEvidenceChip(evidence: item, order: item.kind.isImageKind ? index : nil, compact: true)
                            Button {
                                pendingEvidence.removeAll { $0.id == item.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(LTColors.textTertiary)
                            }
                            .accessibilityLabel(Text("移除图片"))
                        }
                    }
                }
            }
            if !modelReadyHint.isEmpty {
                Text(modelReadyHint)
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: LTSpacing.s) {
                Button {
                    showEvidencePicker = true
                } label: {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 18))
                        .foregroundStyle(
                            pendingEvidence.count >= VisualAskImagePipeline.maxEvidenceCount
                                ? LTColors.textTertiary
                                : LTColors.accentCyan
                        )
                }
                .disabled(pendingEvidence.count >= VisualAskImagePipeline.maxEvidenceCount)
                .accessibilityLabel(Text("添加图片"))
                Menu {
                    Toggle(isOn: $options.includeTranscript) {
                        Label("结合课堂讲解", systemImage: "text.bubble")
                    }
                    Toggle(isOn: $options.includeNotes) {
                        Label("结合本堂课笔记", systemImage: "note.text")
                    }
                    Toggle(isOn: $options.includeRetrieval) {
                        Label("结合课程资料检索", systemImage: "books.vertical")
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(LTColors.textSecondary)
                }
                .accessibilityLabel(Text("回答上下文范围"))
                TextField("问这门课…", text: $question, axis: .vertical)
                    .font(Font.subheadline)
                    .lineLimit(1...4)
                    .padding(LTSpacing.s)
                    .background(LTColors.surfacePrimary.opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: LTRadius.medium))
                    .onSubmit(ask)
                Button {
                    ask()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(
                            canAsk ? LTColors.accentGreen : LTColors.textTertiary
                        )
                }
                .disabled(!canAsk)
                .accessibilityLabel(Text("提问"))
            }
        }
        .padding(.horizontal, LTSpacing.screenPadding)
        .padding(.vertical, LTSpacing.s)
        .background(.ultraThinMaterial)
    }

    /// Honest unconfigured guidance: text asks need the text model,
    /// image asks need the image model; history always stays readable.
    private var modelReadyHint: String {
        let hasImages = !pendingEvidence.isEmpty
        if hasImages && !environment.isImageModelConfigured {
            return "图片问答需要先在设置中配置「图片理解」模型；历史回答与图片 OCR 不受影响。"
        }
        if !hasImages && !environment.isTranslationConfigured {
            return "课程助手需要先在设置中配置兼容模型；历史回答仍可查看。"
        }
        return ""
    }

    private var canAsk: Bool {
        let hasImages = !pendingEvidence.filter { $0.kind.isImageKind }.isEmpty
        let configured = hasImages
            ? environment.isImageModelConfigured
            : environment.isTranslationConfigured
        return configured
            && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !environment.courseAssistant.isAsking(threadID: thread.id)
    }

    private var scopeHint: String {
        switch scope {
        case .page(let materialID, let pageNumber):
            return scopeMaterialTitle(materialID)
                .map { "当前范围：\($0) · 第 \(pageNumber) 页" }
                ?? "当前范围：本页"
        case .material(let materialID):
            return scopeMaterialTitle(materialID)
                .map { "当前范围：\($0)" }
                ?? "当前范围：本资料"
        case .session(let sessionID):
            _ = sessionID
            return "当前范围：一堂课"
        case .course:
            return "当前范围：整门课程（资料、课堂、笔记、图片与学习整理）"
        case nil:
            return ""
        }
    }

    private func scopeMaterialTitle(_ materialID: UUID) -> String? {
        ((try? environment.repository.material(id: materialID)) ?? nil)?
            .title
    }

    private func reload() {
        messages = (try? environment.repository.assistantMessages(threadID: thread.id)) ?? []
    }

    /// The composer handoff: send immediately (the user already chose
    /// what to send there).
    private func fireInitialAskIfNeeded() {
        guard !firedInitialAsk,
              !initialQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        firedInitialAsk = true
        question = initialQuestion
        pendingEvidence = initialEvidence
        options = initialOptions
        ask()
    }

    private func ask() {
        let text = question
        let currentScope = scope ?? .course(courseID: thread.courseID)
        let evidence = pendingEvidence
        let currentOptions = options
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let hasImages = !evidence.filter { $0.kind.isImageKind }.isEmpty
        guard hasImages ? environment.isImageModelConfigured : environment.isTranslationConfigured else { return }
        question = ""
        pendingEvidence = []
        environment.courseAssistant.ask(
            thread: thread,
            question: text,
            scope: currentScope,
            evidence: evidence,
            options: currentOptions
        )
        // The user message lands immediately; poll-free observation is
        // enough for v1 (the stage row reflects the run; onAppear and
        // the run's completion both reload).
        Task {
            while environment.courseAssistant.isAsking(threadID: thread.id) {
                try? await Task.sleep(for: .milliseconds(300))
            }
            reload()
        }
        reload()
    }
}

// MARK: - Message bubble

private struct AssistantMessageBubble: View {
    @Environment(AppEnvironment.self) private var environment
    let message: CourseAssistantMessage
    let citations: [AssistantMessageCitation]
    /// Suggested-action taps prefill the input (never auto-send).
    var onFollowUp: (String) -> Void = { _ in }

    /// Visual answers render as the structured reading card; visual
    /// questions attach their evidence chips.
    private var isVisual: Bool {
        message.assistantMode == .visual
    }

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: LTSpacing.xs) {
            if message.role == .assistant, isVisual, let answer = message.visualAnswer {
                VisualAnswerCard(
                    message: message,
                    answer: answer,
                    evidence: message.visualEvidence,
                    citations: citations,
                    onFollowUp: onFollowUp
                )
            } else {
                Text(message.text)
                    .font(Font.subheadline)
                    .foregroundStyle(LTColors.textPrimary)
                    .textSelection(.enabled)
                    .lineSpacing(4)
                    .padding(LTSpacing.m)
                    .background(
                        message.role == .user
                            ? LTColors.accentGreen.opacity(0.16)
                            : LTColors.surfacePrimary.opacity(0.85)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: LTRadius.medium))
                if !citations.isEmpty {
                    VStack(alignment: .leading, spacing: LTSpacing.xxs) {
                        ForEach(citations) { citation in
                            citationLink(citation)
                        }
                    }
                    .padding(LTSpacing.s)
                    .background(LTColors.surfaceElevated.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: LTRadius.small))
                }
            }

            // The question's evidence chips (image kinds only — the
            // 图片 n references of the answer below).
            if message.role == .user, isVisual {
                let images = message.visualEvidence.filter { $0.kind.isImageKind }
                if !images.isEmpty {
                    VStack(alignment: .trailing, spacing: LTSpacing.xxs) {
                        ForEach(Array(images.enumerated()), id: \.element.id) { index, item in
                            VisualEvidenceChip(evidence: item, order: index, compact: true)
                        }
                    }
                }
            }
        }
        .frame(
            maxWidth: .infinity,
            alignment: message.role == .user ? .trailing : .leading
        )
    }

    /// A citation chip: label + snippet, tapping jumps to the real
    /// source (material reader page / session detail).
    @ViewBuilder
    private func citationLink(_ citation: AssistantMessageCitation) -> some View {
        Group {
            if citation.kind == .materialPage, let materialID = citation.materialID {
                NavigationLink {
                    MaterialReaderScreen(materialID: materialID)
                        .environment(environment)
                } label: {
                    citationLabel(citation)
                }
                .buttonStyle(.plain)
            } else if let sessionID = citation.sessionID {
                NavigationLink {
                    SessionDetailView(sessionID: sessionID)
                        .environment(environment)
                } label: {
                    citationLabel(citation)
                }
                .buttonStyle(.plain)
            } else {
                citationLabel(citation)
            }
        }
    }

    private func citationLabel(_ citation: AssistantMessageCitation) -> some View {
        HStack(alignment: .top, spacing: LTSpacing.xs) {
            Image(systemName: "link")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(LTColors.accentCyan)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(citation.label)
                    .font(LTTypography.button)
                    .foregroundStyle(LTColors.accentCyan)
                if !citation.snippet.isEmpty {
                    Text(citation.snippet)
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textTertiary)
                        .lineLimit(2)
                }
            }
        }
        .accessibilityLabel(Text("来源：\(citation.label)"))
    }
}
