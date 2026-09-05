import SwiftUI

// MARK: - Transcript feed (lyric-style)

/// The bilingual feed: current Chinese translation in focus, Russian
/// beneath it, completed history dimming progressively. Auto-follows the
/// focus until the user scrolls away; a 回到当前内容 pill restores it.
struct TranscriptFeed: View {
    let viewModel: LiveViewModel
    let reduceMotion: Bool

    var body: some View {
        // The outer GeometryReader supplies the viewport height so the
        // bottom marker's offset can be judged as "at (or near) the feed
        // end" — this is what auto-follow keys off.
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: LTSpacing.l) {
                        ForEach(viewModel.entries, id: \.sequenceID) { entry in
                            LiveLyricRow(
                                entry: entry,
                                viewModel: viewModel,
                                reduceMotion: reduceMotion
                            )
                            .id(entry.sequenceID)
                        }
                        if viewModel.isCollectingSpeech {
                            collectingIndicator
                        }
                        // Bottom marker: reports its Y in the scroll content
                        // space; near the viewport bottom == still following.
                        GeometryReader { marker in
                            Color.clear.preference(
                                key: TranscriptBottomKey.self,
                                value: marker.frame(in: .named(TranscriptFeed.scrollSpace)).minY
                            )
                        }
                        .frame(height: 1)
                        .id(TranscriptFeed.bottomID)
                    }
                    .padding(.horizontal, LTSpacing.screenPadding)
                    .padding(.top, LTSpacing.s)
                    .padding(.bottom, 60)
                }
                .coordinateSpace(name: TranscriptFeed.scrollSpace)
                .onPreferenceChange(TranscriptBottomKey.self) { markerMinY in
                    // The marker sits at ≈viewportHeight when fully scrolled
                    // down, and grows beyond it as the user scrolls up, so
                    // (viewportHeight - markerY) is ≈0 at the feed end and
                    // negative when reading history.
                    viewModel.updateScrollPosition(minY: viewport.size.height - markerMinY)
                }
                .overlay(alignment: .bottom) {
                    if !viewModel.isFollowing && !viewModel.entries.isEmpty {
                        Button {
                            viewModel.resumeFollowing()
                            scrollToCurrent(proxy)
                        } label: {
                            Label("回到当前内容", systemImage: "arrow.down.to.line")
                                .font(.footnote.weight(.medium))
                                .padding(.horizontal, LTSpacing.m)
                                .padding(.vertical, LTSpacing.xs + 2)
                                .background(Capsule().fill(.ultraThinMaterial))
                                .overlay(Capsule().strokeBorder(LTColors.border, lineWidth: 0.5))
                                .shadow(color: LTShadow.floating, radius: 8, y: 3)
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, LTSpacing.s)
                        .accessibilityLabel(Text("回到当前内容"))
                    }
                }
                .onChange(of: viewModel.currentSequenceID) { _, _ in
                    if viewModel.isFollowing {
                        scrollToCurrent(proxy)
                    }
                }
                .onChange(of: viewModel.entries.count) { _, _ in
                    if viewModel.isFollowing {
                        scrollToCurrent(proxy)
                    }
                }
            }
        }
    }

    /// Smooth scroll to the focused entry; positional movement only (no
    /// per-row animation), so streaming text updates never jump.
    private func scrollToCurrent(_ proxy: ScrollViewProxy) {
        guard let current = viewModel.currentSequenceID else { return }
        if reduceMotion {
            proxy.scrollTo(current, anchor: .center)
        } else {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
                proxy.scrollTo(current, anchor: .center)
            }
        }
    }

    private var collectingIndicator: some View {
        HStack(spacing: LTSpacing.s) {
            LTActivityDot(active: true, tint: LTColors.accentCyan)
            Text("正在收集语音…")
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.textSecondary)
        }
        .padding(.vertical, LTSpacing.xs)
        .id(TranscriptFeed.collectingID)
    }

    fileprivate static let bottomID = "transcript-bottom"
    fileprivate static let collectingID = "transcript-collecting"
    fileprivate static let scrollSpace = "transcript-scroll"
}

private struct TranscriptBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Lyric row

/// One bilingual entry. Chinese is the first visual hierarchy, Russian the
/// second; the focused entry is the brightest and largest.
struct LiveLyricRow: View {
    let entry: LiveTranscriptItem
    let viewModel: LiveViewModel
    let reduceMotion: Bool

    private var isCurrent: Bool { viewModel.isCurrent(entry) }

    private var opacity: Double {
        if isCurrent { return 1 }
        guard let distance = viewModel.focusDistance(of: entry) else { return 0.5 }
        return viewModel.historyOpacity(distance)
    }

    var body: some View {
        HStack(alignment: .top, spacing: LTSpacing.m) {
            timeline

            VStack(alignment: .leading, spacing: LTSpacing.xs) {
                if let translated = entry.translatedText, !translated.isEmpty {
                    Text(translated)
                        .font(isCurrent ? LTTypography.liveCurrentTranslation : LTTypography.liveTranslation)
                        .foregroundStyle(isCurrent ? LTColors.textPrimary : LTColors.textPrimary.opacity(0.9))
                        .textSelection(.enabled)
                        .animation(reduceMotion ? nil : LTMotion.textReveal, value: entry.translatedText)
                        .fixedSize(horizontal: false, vertical: true)
                } else if viewModel.entryPhase(entry) != .skipped {
                    // No placeholder while translation is intentionally off —
                    // the Russian original above is the whole entry.
                    translationPendingView
                }

                Text(entry.originalText)
                    .font(LTTypography.liveOriginal)
                    .foregroundStyle(LTColors.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(isCurrent ? 1 : 0.9)

                switch viewModel.entryPhase(entry) {
                case .failed:
                    translationFailedView
                case .offline:
                    translationOfflineView
                case .notConfigured:
                    Text("翻译服务未配置 · 俄语原文已保存")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.warning.opacity(0.85))
                case .translating, .translated, .skipped:
                    EmptyView()
                }
            }
            Spacer(minLength: 0)
        }
        .opacity(opacity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: isCurrent)
        .contextMenu {
            Button("复制中文") {
                if let translated = entry.translatedText {
                    ClipboardService.shared.copySensitive(translated)
                }
            }
            Button("复制俄语") {
                ClipboardService.shared.copySensitive(entry.originalText)
            }
            Button("复制双语") {
                let translated = entry.translatedText ?? ""
                ClipboardService.shared.copySensitive(
                    "\(entry.originalText)\n\(translated)"
                )
            }
            Button(viewModel.isBookmarked(entry) ? "取消书签" : "标记书签") {
                _ = viewModel.toggleBookmark(entry)
            }
            if case .failed = viewModel.entryPhase(entry) {
                Button("重试翻译") {
                    viewModel.retryTranslation(entry.sequenceID)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Left timeline: timestamp + node. The node is the one place the
    /// reference's glow is allowed on a per-entry basis — current only.
    private var timeline: some View {
        VStack(spacing: 0) {
            Text(TranscriptFeed.timestamp(for: entry.startOffset))
                .font(LTTypography.timestamp)
                .foregroundStyle(isCurrent ? LTColors.accentCyan : LTColors.textTertiary)
                .padding(.bottom, 4)
            Circle()
                .fill(isCurrent ? LTColors.accentCyan : LTColors.textTertiary.opacity(0.7))
                .frame(width: isCurrent ? 8 : 5, height: isCurrent ? 8 : 5)
                .shadow(color: isCurrent ? LTColors.accentCyan.opacity(0.7) : .clear, radius: 4)
            Rectangle()
                .fill(LTColors.separator)
                .frame(width: 1)
                .frame(maxHeight: .infinity)
                .padding(.top, 4)
        }
        .frame(width: 40)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var translationPendingView: some View {
        HStack(spacing: LTSpacing.xs) {
            Image(systemName: "hourglass")
                .font(.caption2)
                .foregroundStyle(LTColors.textTertiary)
            Text("正在翻译")
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.textTertiary)
        }
        .accessibilityLabel(Text("翻译进行中"))
    }

    /// Translation failed: the Russian original stays fully visible above;
    /// only a short hint + retry appear here.
    @ViewBuilder
    private var translationFailedView: some View {
        HStack(spacing: LTSpacing.s) {
            Text("翻译失败 · 俄语原文已保存")
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.warning)
            Button("重试翻译") {
                viewModel.retryTranslation(entry.sequenceID)
                LTHaptics.tap()
            }
            .font(LTTypography.caption.weight(.semibold))
            .foregroundStyle(LTColors.accentBlue)
        }
    }

    /// Translation failed because the network is down — not an error the
    /// user can fix by tapping: the coordinator re-enqueues automatically
    /// once connectivity returns, so no retry button here.
    private var translationOfflineView: some View {
        Text("网络不可用 · 俄语原文已保存，恢复网络后自动重试")
            .font(LTTypography.caption)
            .foregroundStyle(LTColors.warning.opacity(0.85))
    }
}

// MARK: - Notes tab

/// 课堂笔记: the user's own notes for THIS classroom, written through the
/// repository (real persistence — they survive the classroom ending and
/// sync like any other entity). A composer at the bottom keeps one-handed
/// mid-class capture; a toggle anchors the note to the transcript line
/// currently being spoken about. Captured classroom images appear as a
/// compact strip above the notes (same 学习记录 surface, no extra tab).
struct LiveNotesTab: View {
    let viewModel: LiveViewModel

    @State private var noteDraft = ""
    @State private var anchorToCurrent = true
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            attachmentStrip
            noteList
            composer
        }
        .onAppear {
            viewModel.reloadNotes()
            viewModel.reloadAttachments()
        }
    }

    /// 本堂图片: horizontal thumbnails of the classroom's images. Tap
    /// opens the full-size preview; delete via context menu. Full editing
    /// (classify, caption, analyze) lives in the session detail after class.
    @ViewBuilder
    private var attachmentStrip: some View {
        if !viewModel.sessionAttachments.isEmpty {
            VStack(alignment: .leading, spacing: LTSpacing.xs) {
                HStack(spacing: LTSpacing.xs) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textTertiary)
                    Text("本堂图片 · \(viewModel.sessionAttachments.count)")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textTertiary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: LTSpacing.s) {
                        ForEach(viewModel.sessionAttachments, id: \.id) { attachment in
                            LiveAttachmentThumbnail(attachment: attachment) {
                                viewModel.deleteAttachment(attachment)
                            }
                        }
                    }
                    .padding(.horizontal, LTSpacing.screenPadding)
                }
            }
            .padding(.top, LTSpacing.s)
        }
    }

    private var noteList: some View {
        Group {
            if viewModel.sessionNotes.isEmpty {
                VStack {
                    LTEmptyState(
                        symbol: "note.text",
                        title: "还没有笔记",
                        message: "在下方输入框随手记下老师讲的重点"
                    )
                    Spacer()
                }
                .padding(.top, LTSpacing.xl)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: LTSpacing.s) {
                        ForEach(viewModel.sessionNotes, id: \.id) { note in
                            noteRow(note)
                        }
                    }
                    .padding(LTSpacing.screenPadding)
                }
            }
        }
    }

    private func noteRow(_ note: SessionNote) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: LTSpacing.xs) {
                Text(viewModel.noteTimestamp(note))
                    .font(LTTypography.timestamp)
                    .foregroundStyle(LTColors.textTertiary)
                if viewModel.anchorEntry(for: note) != nil {
                    Label("锚定段落", systemImage: "text.bubble")
                        .font(LTTypography.timestamp)
                        .foregroundStyle(LTColors.warning.opacity(0.85))
                }
                Spacer()
            }
            Text(note.text)
                .font(.subheadline)
                .foregroundStyle(LTColors.textPrimary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(LTSpacing.m)
        .background(
            RoundedRectangle(cornerRadius: LTRadius.small)
                .fill(LTColors.surfacePrimary.opacity(0.6))
        )
        .contextMenu {
            Button("删除笔记", role: .destructive) {
                viewModel.deleteNote(note)
                LTHaptics.tap()
            }
        }
    }

    /// Bottom composer: text field + anchor toggle. Notes are persisted on
    /// send — there is no draft state kept anywhere beyond this view.
    private var composer: some View {
        VStack(spacing: LTSpacing.xs) {
            if !viewModel.entries.isEmpty {
                Button {
                    anchorToCurrent.toggle()
                    LTHaptics.tap()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: anchorToCurrent ? "link.circle.fill" : "link.circle")
                        Text(
                            anchorToCurrent
                                ? "将锚定到当前段落（\(currentAnchorLabel)）"
                                : "不锚定段落"
                        )
                    }
                    .font(LTTypography.caption)
                    .foregroundStyle(anchorToCurrent ? LTColors.warning : LTColors.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(anchorToCurrent ? "笔记将锚定到当前段落" : "笔记不锚定段落"))
            }
            HStack(spacing: LTSpacing.s) {
                TextField("记点什么…", text: $noteDraft, axis: .vertical)
                    .font(.subheadline)
                    .foregroundStyle(LTColors.textPrimary)
                    .lineLimit(1...4)
                    .padding(LTSpacing.s)
                    .background(
                        RoundedRectangle(cornerRadius: LTRadius.small)
                            .fill(LTColors.surfacePrimary)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: LTRadius.small)
                            .strokeBorder(LTColors.border, lineWidth: 0.5)
                    )
                    .focused($composerFocused)
                    .onSubmit(sendNote)

                Button(action: sendNote) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(
                            trimmedDraft.isEmpty ? LTColors.textTertiary : LTColors.accentGreen
                        )
                }
                .disabled(trimmedDraft.isEmpty)
                .accessibilityLabel(Text("保存笔记"))
            }
        }
        .padding(.horizontal, LTSpacing.screenPadding)
        .padding(.top, LTSpacing.s)
        .padding(.bottom, LTSpacing.m)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
    }

    private var trimmedDraft: String {
        noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The timestamp of the entry a new note would anchor to (informational
    /// label on the toggle).
    private var currentAnchorLabel: String {
        viewModel.currentAnchorLabel
    }

    private func sendNote() {
        guard viewModel.addNote(noteDraft, anchorToCurrent: anchorToCurrent) else { return }
        noteDraft = ""
        LTHaptics.success()
    }
}

// MARK: - Bookmarks tab (this session)

struct LiveBookmarksTab: View {
    let viewModel: LiveViewModel

    var body: some View {
        if viewModel.sessionBookmarks.isEmpty {
            VStack {
                LTEmptyState(
                    symbol: "bookmark",
                    title: "还没有书签",
                    message: "听课过程中点击下方书签按钮，标记当前重点内容"
                )
                Spacer()
            }
            .padding(.top, LTSpacing.xl)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: LTSpacing.s) {
                    ForEach(viewModel.sessionBookmarks) { resolved in
                        bookmarkRow(resolved)
                    }
                }
                .padding(LTSpacing.screenPadding)
            }
        }
    }

    private func bookmarkRow(_ resolved: LiveViewModel.ResolvedBookmark) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "bookmark.fill")
                    .font(.caption2)
                    .foregroundStyle(LTColors.accentGreen)
                Text(TranscriptFeed.timestamp(for: resolved.entry?.startOffset ?? 0))
                    .font(LTTypography.timestamp)
                    .foregroundStyle(LTColors.textTertiary)
                Spacer()
                Button {
                    remove(resolved.bookmark)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(LTColors.textTertiary)
                        .frame(
                            width: LTSpacing.minTouchTarget,
                            height: LTSpacing.minTouchTarget
                        )
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text("删除书签"))
            }
            if let entry = resolved.entry {
                if let translated = entry.translatedText, !translated.isEmpty {
                    Text(translated)
                        .font(.subheadline)
                        .foregroundStyle(LTColors.textPrimary)
                        .textSelection(.enabled)
                }
                Text(entry.originalText)
                    .font(.footnote)
                    .foregroundStyle(LTColors.textSecondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            } else {
                Text("这条内容已不可用")
                    .font(.footnote)
                    .foregroundStyle(LTColors.textTertiary)
            }
        }
        .ltCard(padding: LTSpacing.m)
    }

    private func remove(_ bookmark: BookmarkStore.EntryBookmark) {
        viewModel.removeBookmark(bookmark)
    }
}

// MARK: - Search tab (this session)

struct LiveSearchTab: View {
    @Bindable var viewModel: LiveViewModel

    var body: some View {
        VStack(spacing: LTSpacing.s) {
            TextField("搜索本堂课的中文或俄语内容", text: $viewModel.searchQuery)
                .font(.subheadline)
                .padding(LTSpacing.m)
                .background(
                    RoundedRectangle(cornerRadius: LTRadius.small)
                        .fill(LTColors.surfacePrimary)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: LTRadius.small)
                        .strokeBorder(LTColors.border, lineWidth: 0.5)
                )
                .padding(.horizontal, LTSpacing.screenPadding)
                .padding(.top, LTSpacing.s)

            if viewModel.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                Spacer()
            } else if viewModel.searchResults.isEmpty {
                LTEmptyState(
                    symbol: "magnifyingglass",
                    title: "没有匹配的内容",
                    message: "换个关键词试试"
                )
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: LTSpacing.s) {
                        Text("共 \(viewModel.searchResults.count) 条结果")
                            .font(LTTypography.caption)
                            .foregroundStyle(LTColors.textTertiary)
                        ForEach(viewModel.searchResults, id: \.sequenceID) { entry in
                            searchRow(entry)
                        }
                    }
                    .padding(.horizontal, LTSpacing.screenPadding)
                    .padding(.bottom, LTSpacing.l)
                }
            }
        }
    }

    private func searchRow(_ entry: LiveTranscriptItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(TranscriptFeed.timestamp(for: entry.startOffset))
                .font(LTTypography.timestamp)
                .foregroundStyle(LTColors.textTertiary)
            if let translated = entry.translatedText, !translated.isEmpty {
                Text(translated)
                    .font(.subheadline)
                    .foregroundStyle(LTColors.textPrimary)
                    .textSelection(.enabled)
            }
            Text(entry.originalText)
                .font(.footnote)
                .foregroundStyle(LTColors.textSecondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(LTSpacing.m)
        .background(RoundedRectangle(cornerRadius: LTRadius.small).fill(LTColors.surfacePrimary.opacity(0.6)))
    }
}

// MARK: - Shared

extension TranscriptFeed {
    /// mm:ss within the classroom.
    static func timestamp(for offset: TimeInterval) -> String {
        let total = Int(offset.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
