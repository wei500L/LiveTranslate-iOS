import SwiftUI

/// Classroom detail (reference image 5): header info, bilingual transcript
/// with Chinese first on a left timeline, per-entry bookmarks, in-session
/// search with highlight and prev/next, display modes, and export/share via
/// the existing Export module. No audio playback is offered — sessions
/// store no playable audio — so the reference's player bar is replaced by
/// 搜索 / 导出 / 复制 / 书签 / 更多.
struct SessionDetailView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewModel = SessionDetailViewModel()
    @State private var shareItem: SharedFile?
    @State private var exportFailed = false
    @State private var renameDraft: String?
    /// Note editor presentation: creating (optionally anchored) or editing.
    @State private var noteEditor: NoteEditorContext?
    /// Export options sheet (scope + format).
    @State private var exportSheet = false
    /// A jump target handed over from the study-review page (pops itself
    /// and scrolls here).
    @State private var pendingReviewJump: UUID?
    @State private var pushingReview = false
    @FocusState private var searchFocused: Bool
    /// The detail scroll's proxy, captured when the reader renders (the
    /// attachments landing jump needs it from outside `detailContent`).
    @State private var detailScrollProxy: ScrollViewProxy?
    /// Learning-material save flows from transcript selections.
    @State private var termDraftBox: TermDraftBox?
    @State private var cardDraftBox: CardDraftBox?
    @State private var taskDraftBox: TaskDraftBox?
    /// Manual correction editor (long-press 转录校正).
    @State private var correctionEntry: TranscriptEntry?
    /// Full playback page presentation.
    @State private var pushingPlayback = false
    /// Entry to hand the playback page (jump landed from search/review).
    @State private var pendingPlaybackEntryID: UUID?
    /// Honesty affordance: a play request with no recording on disk.
    @State private var noRecordingHint = false

    let sessionID: UUID
    /// Opens the study-review page right away (search hit landing).
    var openReviewOnLoad = false
    /// Scrolls to the 板书与图片 section on load (attachment search hit).
    var openAttachmentsOnLoad = false

    /// What the note editor sheet is editing (Identifiable so it can drive
    /// `sheet(item:)`).
    struct NoteEditorContext: Identifiable {
        let note: SessionNote?
        let anchorEntry: TranscriptEntry?
        var id: String {
            note?.id.uuidString ?? "new-\(anchorEntry?.id.uuidString ?? "unanchored")"
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
                    detailContent(session)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("课堂详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                favoriteButton
                exportMenu
            }
        }
        .task {
            viewModel.attach(environment)
            viewModel.load(sessionID: sessionID)
            if openReviewOnLoad, viewModel.hasReviewResult {
                pushingReview = true
            }
            // Prepare the playback engine when a recording exists so the
            // mini player is immediately usable (load is cheap; decode
            // happens lazily by AVAudioPlayer on first play).
            _ = viewModel.ensureRecordingLoaded()
        }
        .onChange(of: viewModel.isLoaded) { _, loaded in
            guard loaded, openAttachmentsOnLoad else { return }
            // Give the scroll content one layout pass before jumping.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                withAnimation(LTMotion.resolved(reduceMotion)) {
                    detailScrollProxy?.scrollTo(attachmentSectionAnchor, anchor: .top)
                }
            }
        }
        .navigationDestination(isPresented: $pushingReview) {
            StudyReviewView(
                sessionID: sessionID,
                onJumpToEntry: { entryID in
                    pendingReviewJump = entryID
                    pushingReview = false
                }
            )
            .environment(environment)
        }
        .navigationDestination(isPresented: $pushingPlayback) {
            SessionPlaybackView(
                sessionID: sessionID,
                initialEntryID: pendingPlaybackEntryID
            )
            .environment(environment)
        }
        .onAppear {
            // Refresh on back-navigation (e.g. retry happened elsewhere).
            if viewModel.isLoaded {
                viewModel.reload()
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: item.allURLs)
        }
        .sheet(isPresented: $exportSheet) {
            if let session = viewModel.session {
                ExportOptionsSheet(
                    hasReview: viewModel.hasReviewResult,
                    attachmentCount: viewModel.attachments.count
                ) { scope, format, attachmentFiles in
                    Task {
                        await export(
                            session: session, scope: scope, format: format,
                            attachmentFiles: attachmentFiles
                        )
                    }
                }
                .environment(environment)
            }
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
        .sheet(item: $correctionEntry) { entry in
            TranscriptCorrectionView(sessionID: sessionID, entry: entry)
                .environment(environment)
                .onDisappear { viewModel.reload() }
        }
        .sheet(item: $noteEditor) { context in
            if let session = viewModel.session {
                NoteEditorView(
                    session: session,
                    note: context.note,
                    anchorEntry: context.anchorEntry
                )
                .environment(environment)
                .onDisappear { viewModel.reload() }
            }
        }
        .alert("导出失败", isPresented: $exportFailed) {
            Button("好", role: .cancel) {}
        } message: {
            Text("无法生成导出文件，请重试。原文内容仍保存在本地。")
        }
        .alert("本堂课没有录音", isPresented: $noRecordingHint) {
            Button("好", role: .cancel) {}
        } message: {
            Text("无法播放声音，文字记录不受影响。")
        }
    }

    private let attachmentSectionAnchor = "attachment-section-anchor"

    // MARK: - Content

    private func detailContent(_ session: ClassroomSession) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: LTSpacing.l) {
                        headerCard(session)
                        reviewCard
                        attachmentsCard(session)
                            .id(attachmentSectionAnchor)
                        notesCard
                        searchCard
                        modeChips
                        transcriptList
                    }
                    .padding(.horizontal, LTSpacing.screenPadding)
                    .padding(.top, LTSpacing.s)
                    .padding(.bottom, 90)
                }
                .onAppear { detailScrollProxy = proxy }
                .onChange(of: viewModel.currentMatchIndex) { _, _ in
                    scrollToMatch(proxy)
                }
                .onChange(of: viewModel.pendingScrollTarget) { _, target in
                    guard let target else { return }
                    withAnimation(LTMotion.resolved(reduceMotion)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                    viewModel.pendingScrollTarget = nil
                }
                .onChange(of: pendingReviewJump) { _, entryID in
                    guard let entryID else { return }
                    if let entry = viewModel.entries.first(where: { $0.id == entryID }) {
                        viewModel.pendingScrollTarget = entry.sequenceID
                    }
                    pendingReviewJump = nil
                }
            }
            if viewModel.hasPlayableRecording {
                SessionMiniPlayerView(sessionID: sessionID) {
                    pendingPlaybackEntryID = nil
                    pushingPlayback = true
                }
            }
            bottomToolbar
        }
    }

    // MARK: - Header

    /// 板书与图片: the class's image materials. Any change (add, edit,
    /// re-analysis) refreshes the study-review staleness hint.
    private func attachmentsCard(_ session: ClassroomSession) -> some View {
        AttachmentSectionView(
            session: session,
            attachments: viewModel.attachments,
            onAttachmentSetChanged: { viewModel.reload() }
        )
    }

    private func headerCard(_ session: ClassroomSession) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: LTSpacing.xs) {
                Text(session.title)
                    .font(LTTypography.cardTitle)
                    .foregroundStyle(LTColors.textPrimary)
                    .lineLimit(2)
                if session.abnormalTermination {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(LTColors.warning)
                        .accessibilityLabel(Text("异常终止"))
                }
            }
            .contextMenu {
                Button("重命名") { renameDraft = session.title }
            }

            HStack(spacing: LTSpacing.s) {
                infoPill(icon: "calendar", text: Format.date(session.startTime))
                infoPill(icon: "clock", text: Format.clock(session.duration))
                infoPill(icon: "globe", text: "俄语 → 中文")
            }

            HStack(spacing: LTSpacing.s) {
                StatusChip(text: sessionStatusText, tint: sessionStatusTint)
                translationStatusChip
                Spacer()
            }

            DisclosureGroup("更多信息") {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledRow(label: "开始时间", value: Format.time(session.startTime))
                    if let end = session.endTime {
                        LabeledRow(label: "结束时间", value: Format.time(end))
                    }
                    // Schedule attribution (schedule-launched sessions):
                    // the planned class time vs the actual recording.
                    if let planned = session.plannedStart {
                        LabeledRow(
                            label: "计划上课",
                            value: Format.date(planned) + " " + Format.time(planned)
                        )
                    }
                    if session.occurrenceKey != nil {
                        LabeledRow(label: "来源", value: "来自课程表日程")
                    }
                    LabeledRow(label: "识别模式", value: backendName(session))
                    if !session.computePreference.isEmpty {
                        LabeledRow(label: "计算配置", value: session.computePreference)
                    }
                    if !session.translationModel.isEmpty {
                        LabeledRow(label: "翻译模型", value: session.translationModel)
                    }
                    // Honest absence: no fake disabled player.
                    if viewModel.recording == nil {
                        LabeledRow(label: "录音", value: "本堂课未保存录音")
                    } else if viewModel.recording?.isDeleted == true {
                        LabeledRow(label: "录音", value: "录音已删除 · 文字记录保留")
                    }
                }
                .padding(.top, LTSpacing.xs)
            }
            .font(.subheadline)
            .tint(LTColors.accentBlue)
        }
        .ltCard()
        .alert("重命名课堂", isPresented: Binding(
            get: { renameDraft != nil },
            set: { if !$0 { renameDraft = nil } }
        )) {
            TextField("课堂名称", text: Binding(
                get: { renameDraft ?? session.title },
                set: { renameDraft = $0 }
            ))
            Button("保存") {
                if let draft = renameDraft {
                    viewModel.rename(to: draft)
                }
                renameDraft = nil
                viewModel.reload()
            }
            Button("取消", role: .cancel) { renameDraft = nil }
        }
    }

    private func infoPill(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text(text)
                .font(LTTypography.timestamp)
        }
        .foregroundStyle(LTColors.textSecondary)
        .padding(.horizontal, LTSpacing.xs + 2)
        .padding(.vertical, 4)
        .background(Capsule().fill(LTColors.surfaceElevated.opacity(0.6)))
    }

    private var sessionStatusText: String {
        guard let session = viewModel.session else { return "" }
        if session.abnormalTermination { return "异常终止" }
        if session.endTime == nil { return "进行中" }
        return "已完成"
    }

    private var sessionStatusTint: Color {
        guard let session = viewModel.session else { return .secondary }
        if session.abnormalTermination { return LTColors.warning }
        if session.endTime == nil { return LTColors.accentCyan }
        return LTColors.accentGreen
    }

    @ViewBuilder
    private var translationStatusChip: some View {
        if viewModel.entries.isEmpty {
            StatusChip(text: "无内容", tint: LTColors.textTertiary)
        } else if viewModel.isEntirelySkipped {
            StatusChip(text: "实时翻译已关闭", tint: LTColors.textTertiary)
        } else if viewModel.failedCount > 0 {
            StatusChip(text: "部分翻译失败", tint: LTColors.warning)
        } else if viewModel.translatedFraction >= 1 {
            StatusChip(text: "已翻译", tint: LTColors.accentGreen)
        } else {
            StatusChip(text: "翻译 \(Format.percent(viewModel.translatedFraction))", tint: LTColors.accentBlue)
        }
        Text("\(viewModel.entries.count) 段")
            .font(LTTypography.timestamp)
            .foregroundStyle(LTColors.textTertiary)
    }

    private func backendName(_ session: ClassroomSession) -> String {
        ASRBackendKind(rawValue: session.asrBackend)?.userTitle ?? session.asrBackend
    }

    // MARK: - Study review

    /// Entry point to the classroom's AI study review. The whole review
    /// lives on its own pushed page; this card shows the honest current
    /// state (including in-flight progress and staleness).
    private var reviewCard: some View {
        Button {
            pushingReview = true
            LTHaptics.tap()
        } label: {
            HStack(spacing: LTSpacing.m) {
                LTIconBadge(
                    symbol: "sparkles",
                    tint: viewModel.reviewCardTint,
                    size: 38
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text("学习整理")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LTColors.textPrimary)
                    Text(viewModel.reviewCardDetail)
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textSecondary)
                        .lineLimit(2)
                }
                Spacer()
                if viewModel.isReviewStale && viewModel.hasReviewResult {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.caption)
                        .foregroundStyle(LTColors.warning)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(LTColors.textTertiary)
            }
            .ltCard()
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("双击打开学习整理"))
    }

    // MARK: - Notes

    /// The classroom's own notes: user-typed, optionally anchored to a
    /// transcript line. Tapping an anchored note jumps to that line.
    @ViewBuilder
    private var notesCard: some View {
        if !viewModel.notes.isEmpty {
            VStack(alignment: .leading, spacing: LTSpacing.s) {
                HStack(spacing: LTSpacing.xs) {
                    LTSectionHeader(title: "课堂笔记")
                    Text("\(viewModel.notes.count)")
                        .font(LTTypography.timestamp)
                        .foregroundStyle(LTColors.textTertiary)
                    Spacer()
                    Button {
                        noteEditor = NoteEditorContext(note: nil, anchorEntry: nil)
                    } label: {
                        Label("添加", systemImage: "plus")
                            .font(LTTypography.caption.weight(.semibold))
                            .foregroundStyle(LTColors.accentBlue)
                    }
                }
                VStack(spacing: LTSpacing.s) {
                    ForEach(viewModel.notes, id: \.id) { note in
                        noteRow(note)
                    }
                }
            }
        }
    }

    private func noteRow(_ note: SessionNote) -> some View {
        HStack(alignment: .top, spacing: LTSpacing.s) {
            Image(systemName: "pencil.line")
                .font(.caption)
                .foregroundStyle(LTColors.warning)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(viewModel.noteTimestamp(note))
                    .font(LTTypography.timestamp)
                    .foregroundStyle(LTColors.textTertiary)
                Text(note.text)
                    .font(.subheadline)
                    .foregroundStyle(LTColors.textPrimary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(LTSpacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: LTRadius.small)
                .fill(LTColors.surfacePrimary.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: LTRadius.small)
                .strokeBorder(LTColors.warning.opacity(0.18), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if viewModel.anchorEntry(for: note) != nil {
                viewModel.jumpToAnchor(of: note)
                LTHaptics.tap()
            }
        }
        .contextMenu {
            Button("编辑笔记") {
                noteEditor = NoteEditorContext(note: note, anchorEntry: nil)
            }
            if viewModel.anchorEntry(for: note) != nil {
                Button("跳到对应段落") {
                    viewModel.jumpToAnchor(of: note)
                }
                Button("取消锚定") {
                    viewModel.detachAnchor(of: note)
                }
            }
            if viewModel.hasPlayableRecording, viewModel.notePlaybackOffset(note) != nil {
                Button {
                    if let offset = viewModel.notePlaybackOffset(note) {
                        _ = viewModel.playFrom(offset: offset)
                    }
                } label: {
                    Label("播放录音位置", systemImage: "play")
                }
            }
            Button("删除笔记", role: .destructive) {
                viewModel.deleteNote(note)
            }
            Divider()
            Button {
                cardDraftBox = CardDraftBox(draft: CardDraft(
                    front: note.text, back: "",
                    courseID: viewModel.session?.courseID,
                    sessionID: sessionID,
                    sourceEntryID: note.anchorEntryID
                ))
            } label: {
                Label("制作卡片", systemImage: "rectangle.on.rectangle")
            }
            Button {
                taskDraftBox = TaskDraftBox(draft: TaskDraft(
                    title: String(note.text.prefix(120)),
                    courseID: viewModel.session?.courseID,
                    sessionID: sessionID,
                    sourceEntryID: note.anchorEntryID
                ))
            } label: {
                Label("创建任务", systemImage: "checklist")
            }
        }
        .accessibilityHint(Text(viewModel.anchorEntry(for: note) != nil ? "双击跳到对应段落" : ""))
    }

    // MARK: - Search

    private var searchCard: some View {
        VStack(spacing: LTSpacing.xs) {
            HStack(spacing: LTSpacing.s) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundStyle(LTColors.textTertiary)
                TextField("搜索本课内容（中文或俄语）", text: $viewModel.searchQuery)
                    .font(.subheadline)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($searchFocused)
                    .onChange(of: viewModel.searchQuery) { _, _ in
                        viewModel.searchDidChange()
                    }
                if !viewModel.searchQuery.isEmpty {
                    Button {
                        viewModel.searchQuery = ""
                        viewModel.searchDidChange()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(LTColors.textTertiary)
                    }
                    .accessibilityLabel(Text("清除搜索"))
                }
            }
            .padding(LTSpacing.m)
            .background(RoundedRectangle(cornerRadius: LTRadius.small).fill(LTColors.surfacePrimary))
            .overlay(RoundedRectangle(cornerRadius: LTRadius.small).strokeBorder(LTColors.border, lineWidth: 0.5))

            if viewModel.matchCount > 0 {
                HStack(spacing: LTSpacing.s) {
                    Text("第 \(viewModel.currentMatchIndex + 1)/\(viewModel.matchCount) 条")
                        .font(LTTypography.timestamp)
                        .foregroundStyle(LTColors.textSecondary)
                    Spacer()
                    Button {
                        viewModel.previousMatch()
                    } label: {
                        Image(systemName: "chevron.up.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(LTColors.accentBlue.opacity(0.85))
                    }
                    .accessibilityLabel(Text("上一个结果"))
                    Button {
                        viewModel.nextMatch()
                    } label: {
                        Image(systemName: "chevron.down.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(LTColors.accentBlue.opacity(0.85))
                    }
                    .accessibilityLabel(Text("下一个结果"))
                }
                .padding(.horizontal, LTSpacing.xxs)
            }
        }
    }

    // MARK: - Mode chips

    private var modeChips: some View {
        HStack(spacing: LTSpacing.s) {
            ForEach(SessionDetailViewModel.DisplayMode.allCases) { mode in
                let isSelected = viewModel.displayMode == mode
                Button {
                    viewModel.displayMode = mode
                } label: {
                    Text(mode.title)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(isSelected ? LTColors.accentCyan : LTColors.textSecondary)
                        .padding(.horizontal, LTSpacing.m)
                        .padding(.vertical, LTSpacing.xs + 1)
                        .background(Capsule().fill(isSelected ? LTColors.accentCyan.opacity(0.15) : LTColors.surfacePrimary))
                        .overlay(Capsule().strokeBorder(isSelected ? LTColors.accentCyan.opacity(0.4) : LTColors.border, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
            Spacer()
            Button {
                viewModel.showBookmarksOnly.toggle()
            } label: {
                Image(systemName: viewModel.showBookmarksOnly ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 13))
                    .foregroundStyle(viewModel.showBookmarksOnly ? LTColors.accentGreen : LTColors.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("仅看书签"))
        }
    }

    // MARK: - Transcript

    private var transcriptList: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            LTSectionHeader(title: "双语对照")
            if viewModel.visibleEntries.isEmpty {
                LTEmptyState(
                    symbol: "text.bubble",
                    title: viewModel.showBookmarksOnly ? "还没有书签" : "没有转写内容",
                    message: viewModel.showBookmarksOnly
                        ? "点击每段右侧的书签按钮，标记重点内容"
                        : "这堂课没有识别到语音内容"
                )
            } else {
                LazyVStack(alignment: .leading, spacing: LTSpacing.m) {
                    ForEach(viewModel.visibleEntries, id: \.sequenceID) { entry in
                        DetailEntryRow(
                            entry: entry,
                            displayMode: viewModel.displayMode,
                            query: viewModel.searchQuery,
                            isMatch: viewModel.isMatch(entry),
                            isMatchFocused: viewModel.isMatchFocused(entry),
                            isBookmarked: viewModel.isBookmarked(entry),
                            isCorrected: viewModel.isCorrected(entry),
                            hasRecording: viewModel.hasPlayableRecording,
                            effectiveChineseText: viewModel.effectiveChinese(entry),
                            effectiveRussianText: viewModel.effectiveRussian(entry),
                            anchoredNotes: viewModel.notes(anchoredTo: entry),
                            onToggleBookmark: { _ = viewModel.toggleBookmark(entry) },
                            onAddNote: {
                                noteEditor = NoteEditorContext(note: nil, anchorEntry: entry)
                            },
                            onPlayFrom: {
                                if !viewModel.playFrom(entry: entry) {
                                    noRecordingHint = true
                                }
                            },
                            onCorrect: { correctionEntry = entry },
                            onExpandPlayback: {
                                pendingPlaybackEntryID = entry.id
                                _ = viewModel.playFrom(entry: entry)
                                pushingPlayback = true
                            },
                            onSaveTerm: {
                                termDraftBox = TermDraftBox(draft: TermDraft(
                                    russian: viewModel.effectiveRussian(entry),
                                    chinese: viewModel.effectiveChinese(entry) ?? "",
                                    courseID: viewModel.session?.courseID,
                                    sessionID: sessionID,
                                    sourceEntryID: entry.id
                                ))
                            },
                            onMakeCard: {
                                cardDraftBox = CardDraftBox(draft: CardDraft(
                                    front: viewModel.effectiveRussian(entry),
                                    back: viewModel.effectiveChinese(entry) ?? "",
                                    courseID: viewModel.session?.courseID,
                                    sessionID: sessionID,
                                    sourceEntryID: entry.id
                                ))
                            },
                            onCreateTask: {
                                taskDraftBox = TaskDraftBox(draft: TaskDraft(
                                    title: (viewModel.effectiveChinese(entry)
                                        ?? viewModel.effectiveRussian(entry))
                                        .prefix(120).description,
                                    courseID: viewModel.session?.courseID,
                                    sessionID: sessionID,
                                    sourceEntryID: entry.id
                                ))
                            }
                        )
                        .id(entry.sequenceID)
                    }
                }
            }
            if viewModel.notes.isEmpty {
                // First-class note entry when no notes exist yet (otherwise
                // the notes card above carries the 添加 button).
                Button {
                    noteEditor = NoteEditorContext(note: nil, anchorEntry: nil)
                } label: {
                    Label("添加笔记", systemImage: "square.and.pencil")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(LTColors.accentBlue)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func scrollToMatch(_ proxy: ScrollViewProxy) {
        guard viewModel.matchCount > 0 else { return }
        let targetID = viewModel.matchIDs[viewModel.currentMatchIndex]
        if reduceMotion {
            proxy.scrollTo(targetID, anchor: .center)
        } else {
            withAnimation(LTMotion.quick) {
                proxy.scrollTo(targetID, anchor: .center)
            }
        }
    }

    // MARK: - Bottom toolbar

    private var bottomToolbar: some View {
        HStack(spacing: 0) {
            bottomButton(symbol: "magnifyingglass", label: "搜索") {
                searchFocused = true
            }
            bottomButton(symbol: "square.and.arrow.up", label: "导出") {
                exportSheet = true
            }
            bottomButton(symbol: "doc.on.doc", label: "复制") {
                viewModel.copyTranscript()
                LTHaptics.success()
            }
            bottomButton(
                symbol: viewModel.showBookmarksOnly ? "bookmark.fill" : "bookmark",
                label: "重点"
            ) {
                viewModel.showBookmarksOnly.toggle()
            }
            bottomButton(symbol: "ellipsis", label: "更多", showMenu: true)
        }
        .padding(.vertical, LTSpacing.xs + 2)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
        .overlay(alignment: .top) { Divider().overlay(LTColors.separator) }
    }

    @ViewBuilder
    private func bottomButton(
        symbol: String, label: String, showMenu: Bool = false, action: @escaping () -> Void = {}
    ) -> some View {
        if showMenu {
            Menu {
                Button {
                    exportSheet = true
                } label: {
                    Label("导出…", systemImage: "square.and.arrow.up")
                }
                Button {
                    Task { await viewModel.retranslateFailed() }
                } label: {
                    Label(
                        viewModel.failedCount > 0 ? "重试失败的翻译 (\(viewModel.failedCount))" : "没有需要重试的翻译",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                .disabled(viewModel.failedCount == 0 || viewModel.isRetranslating)
                Button {
                    if let session = viewModel.session {
                        renameDraft = session.title
                    }
                } label: {
                    Label("重命名", systemImage: "pencil")
                }
            } label: {
                bottomButtonLabel(symbol: symbol, label: label)
            }
        } else {
            Button(action: action) {
                bottomButtonLabel(symbol: symbol, label: label)
            }
            .buttonStyle(.plain)
        }
    }

    private func bottomButtonLabel(symbol: String, label: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
            Text(label)
                .font(.system(size: 10))
        }
        .foregroundStyle(LTColors.textSecondary)
        .frame(maxWidth: .infinity)
        .frame(minHeight: LTSpacing.minTouchTarget)
        .padding(.vertical, LTSpacing.xxs)
        .contentShape(Rectangle())
    }

    // MARK: - Toolbar

    private var favoriteButton: some View {
        Button {
            viewModel.toggleFavorite()
            LTHaptics.tap()
        } label: {
            Image(systemName: viewModel.isFavorite ? "star.fill" : "star")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(viewModel.isFavorite ? LTColors.warning : LTColors.textSecondary)
        }
        .accessibilityLabel(Text(viewModel.isFavorite ? "取消收藏" : "收藏"))
    }

    private var exportMenu: some View {
        Button {
            exportSheet = true
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(LTColors.textSecondary)
        }
        .accessibilityLabel(Text("导出或分享"))
    }

    // MARK: - Export

    private func export(
        session: ClassroomSession, scope: ExportScope, format: ExportFormat,
        attachmentFiles: SessionExport.AttachmentFileOption = .none
    ) async {
        let entries = (try? environment.repository.entries(for: session)) ?? []
        let notes = (try? environment.repository.notes(forSessionID: session.id)) ?? []
        let attachments = (try? environment.repository.attachments(forSessionID: session.id)) ?? []
        let corrections = (try? environment.repository.corrections(forSessionID: session.id)) ?? []
        let review: StudyReviewContent?
        if scope == .reviewOnly || scope == .fullMaterial {
            review = (try? environment.repository.studyReview(forSessionID: session.id))
                .flatMap { StudyReviewContent.decode($0.contentJSON) }
        } else {
            review = nil
        }
        let urls = await SessionExport.writeTemporaryFiles(
            session: session,
            entries: entries,
            notes: notes,
            scope: scope,
            review: review,
            attachments: attachments,
            corrections: corrections,
            attachmentFiles: attachmentFiles,
            format: format,
            fallbackBackend: environment.settings.preferredBackend
        )
        guard let first = urls.first else {
            exportFailed = true
            LTHaptics.warning()
            return
        }
        // 课堂资料包: the document plus any image copies share together.
        shareItem = SharedFile(url: first, companions: Array(urls.dropFirst()))
    }
}

// MARK: - Entry row

/// Chinese first, Russian beneath, timestamp on a left timeline node,
/// bookmark star on the right, search hits highlighted. Notes anchored to
/// the entry render inline beneath the text with a note-tinted marker.
/// The texts shown are the EFFECTIVE ones (correction-aware); the 已修正
/// marker appears only when a correction meaningfully differs. The
/// timestamp is tappable when a recording exists (jump to sound); the
/// context menu adds 从这里播放 / 校正这段文字 / 展开回放.
private struct DetailEntryRow: View {
    let entry: TranscriptEntry
    let displayMode: SessionDetailViewModel.DisplayMode
    let query: String
    let isMatch: Bool
    let isMatchFocused: Bool
    let isBookmarked: Bool
    var isCorrected: Bool = false
    var hasRecording: Bool = false
    /// Effective texts (correction-aware) — provided by the view model.
    var effectiveChineseText: String? = nil
    var effectiveRussianText: String = ""
    var anchoredNotes: [SessionNote] = []
    var onToggleBookmark: () -> Void = {}
    var onAddNote: () -> Void = {}
    var onPlayFrom: () -> Void = {}
    var onCorrect: () -> Void = {}
    var onExpandPlayback: () -> Void = {}
    var onSaveTerm: () -> Void = {}
    var onMakeCard: () -> Void = {}
    var onCreateTask: () -> Void = {}

    private var shownChinese: String? {
        effectiveChineseText ?? entry.translatedText
    }

    private var shownRussian: String {
        effectiveRussianText.isEmpty ? entry.originalText : effectiveRussianText
    }

    var body: some View {
        HStack(alignment: .top, spacing: LTSpacing.m) {
            timeline

            VStack(alignment: .leading, spacing: LTSpacing.xs) {
                if displayMode != .russian, let translated = shownChinese, !translated.isEmpty {
                    Text(HighlightedText.build(translated, query: query))
                        .font(.subheadline)
                        .foregroundStyle(LTColors.textPrimary)
                        .textSelection(.enabled)
                }
                if displayMode != .chinese {
                    Text(HighlightedText.build(shownRussian, query: query))
                        .font(.footnote)
                        .foregroundStyle(LTColors.textSecondary)
                        .textSelection(.enabled)
                }
                if displayMode == .chinese, shownChinese == nil {
                    Text(translationStateText)
                        .font(LTTypography.caption)
                        .foregroundStyle(entry.status == .failed ? LTColors.warning : LTColors.textTertiary)
                }
                if entry.status == .failed {
                    Text("翻译失败 · 俄语原文已保存，可在“更多”中重试")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.warning.opacity(0.85))
                }
                if isCorrected {
                    Text("已修正")
                        .font(LTTypography.timestamp)
                        .foregroundStyle(LTColors.accentCyan.opacity(0.9))
                }
                ForEach(anchoredNotes, id: \.id) { note in
                    inlineNote(note)
                }
            }
            Spacer(minLength: 0)

            Button(action: {
                onToggleBookmark()
                LTHaptics.tap()
            }) {
                Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 13))
                    .foregroundStyle(isBookmarked ? LTColors.accentGreen : LTColors.textTertiary)
                    .frame(width: LTSpacing.minTouchTarget, height: LTSpacing.minTouchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(isBookmarked ? "取消书签" : "标记书签"))
        }
        .padding(LTSpacing.s)
        .background(
            RoundedRectangle(cornerRadius: LTRadius.small)
                .fill(isMatchFocused ? LTColors.accentCyan.opacity(0.08) : LTColors.surfacePrimary.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: LTRadius.small)
                .strokeBorder(
                    isMatchFocused ? LTColors.accentCyan.opacity(0.45) : LTColors.border,
                    lineWidth: isMatchFocused ? 1 : 0.5
                )
        )
        .contextMenu {
            if hasRecording {
                Button(action: onPlayFrom) {
                    Label("从这里播放", systemImage: "play")
                }
                Button(action: onExpandPlayback) {
                    Label("展开完整回放", systemImage: "waveform")
                }
            }
            Button(action: onCorrect) {
                Label("校正这段文字", systemImage: "pencil.line")
            }
            Button("复制中文") {
                if let translated = shownChinese {
                    UIPasteboard.general.string = translated
                }
            }
            Button("复制俄语") {
                UIPasteboard.general.string = shownRussian
            }
            Button(isBookmarked ? "取消书签" : "标记书签") {
                onToggleBookmark()
            }
            Button("添加笔记") {
                onAddNote()
            }
            Divider()
            Button(action: onSaveTerm) {
                Label("保存为术语", systemImage: "character.book.closed")
            }
            Button(action: onMakeCard) {
                Label("制作学习卡片", systemImage: "rectangle.on.rectangle")
            }
            Button(action: onCreateTask) {
                Label("创建任务", systemImage: "checklist")
            }
        }
    }

    /// An anchored note shown beneath its transcript line — the review-time
    /// payoff of taking notes in class.
    private func inlineNote(_ note: SessionNote) -> some View {
        HStack(alignment: .top, spacing: LTSpacing.xs) {
            Rectangle()
                .fill(LTColors.warning.opacity(0.55))
                .frame(width: 2)
            Text(note.text)
                .font(.footnote)
                .foregroundStyle(LTColors.warning.opacity(0.95))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 1)
        .accessibilityLabel(Text("笔记：\(note.text)"))
    }

    private var timeline: some View {
        VStack(spacing: 0) {
            Text(TranscriptExporter.mmss(entry.startOffset))
                .font(LTTypography.timestamp)
                .foregroundStyle(hasRecording ? LTColors.accentCyan : LTColors.textTertiary)
                .padding(.bottom, 4)
            Circle()
                .fill(isMatchFocused ? LTColors.accentCyan : LTColors.textTertiary.opacity(0.7))
                .frame(width: isMatchFocused ? 8 : 5, height: isMatchFocused ? 8 : 5)
                .shadow(color: isMatchFocused ? LTColors.accentCyan.opacity(0.6) : .clear, radius: 4)
            Rectangle()
                .fill(LTColors.separator)
                .frame(width: 1)
                .frame(maxHeight: .infinity)
                .padding(.top, 4)
        }
        .frame(width: 40)
        .contentShape(Rectangle())
        .onTapGesture {
            // Tapping the timestamp jumps to the sound (only when the
            // class actually has a recording — otherwise inert, no fake
            // button).
            if hasRecording { onPlayFrom() }
        }
        .accessibilityHidden(true)
    }

    private var translationStateText: String {
        switch entry.status {
        case .pending: return "翻译未完成"
        case .failed: return "翻译失败 · 原文已保存"
        case .notConfigured: return "翻译服务未配置 · 原文已保存"
        case .skipped: return "实时翻译已关闭"
        case .completed: return ""
        }
    }
}

// MARK: - Search highlighting

/// Case-insensitive highlight over both Chinese and Russian text.
enum HighlightedText {
    static func build(_ text: String, query rawQuery: String) -> AttributedString {
        let query = rawQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, !text.isEmpty else { return AttributedString(text) }

        var result = AttributedString()
        var remaining = Substring(text)
        let options: String.CompareOptions = [.caseInsensitive]
        while let range = remaining.range(of: query, options: options) {
            if range.lowerBound > remaining.startIndex {
                result.append(AttributedString(remaining[remaining.startIndex..<range.lowerBound]))
            }
            var match = AttributedString(String(remaining[range]))
            match.backgroundColor = LTColors.accentCyan.opacity(0.32)
            result.append(match)
            remaining = remaining[range.upperBound...]
        }
        result.append(AttributedString(remaining))
        return result
    }
}
