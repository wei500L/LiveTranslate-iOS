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
    @FocusState private var searchFocused: Bool

    let sessionID: UUID

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
        }
        .onAppear {
            // Refresh on back-navigation (e.g. retry happened elsewhere).
            if viewModel.isLoaded {
                viewModel.reload()
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .alert("导出失败", isPresented: $exportFailed) {
            Button("好", role: .cancel) {}
        } message: {
            Text("无法生成导出文件，请重试。原文内容仍保存在本地。")
        }
    }

    // MARK: - Content

    private func detailContent(_ session: ClassroomSession) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: LTSpacing.l) {
                        headerCard(session)
                        searchCard
                        modeChips
                        transcriptList
                    }
                    .padding(.horizontal, LTSpacing.screenPadding)
                    .padding(.top, LTSpacing.s)
                    .padding(.bottom, 90)
                }
                .onChange(of: viewModel.currentMatchIndex) { _, _ in
                    scrollToMatch(proxy)
                }
            }
            bottomToolbar
        }
    }

    // MARK: - Header

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
                    LabeledRow(label: "识别模式", value: backendName(session))
                    if !session.computePreference.isEmpty {
                        LabeledRow(label: "计算配置", value: session.computePreference)
                    }
                    if !session.translationModel.isEmpty {
                        LabeledRow(label: "翻译模型", value: session.translationModel)
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
                            onToggleBookmark: { _ = viewModel.toggleBookmark(entry) }
                        )
                        .id(entry.sequenceID)
                    }
                }
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
                export(format: .markdown)
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
                Menu("导出为") {
                    ForEach(ExportFormat.allCases) { format in
                        Button(format.displayName) { export(format: format) }
                    }
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
        Menu {
            ForEach(ExportFormat.allCases) { format in
                Button(format.displayName) { export(format: format) }
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(LTColors.textSecondary)
        }
        .accessibilityLabel(Text("导出或分享"))
    }

    // MARK: - Export

    private func export(format: ExportFormat) {
        Task {
            if let url = await viewModel.exportURL(format: format) {
                shareItem = SharedFile(url: url)
            } else {
                exportFailed = true
            }
        }
    }
}

// MARK: - Entry row

/// Chinese first, Russian beneath, timestamp on a left timeline node,
/// bookmark star on the right, search hits highlighted.
private struct DetailEntryRow: View {
    let entry: TranscriptEntry
    let displayMode: SessionDetailViewModel.DisplayMode
    let query: String
    let isMatch: Bool
    let isMatchFocused: Bool
    let isBookmarked: Bool
    let onToggleBookmark: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: LTSpacing.m) {
            timeline

            VStack(alignment: .leading, spacing: LTSpacing.xs) {
                if displayMode != .russian, let translated = entry.translatedText, !translated.isEmpty {
                    Text(HighlightedText.build(translated, query: query))
                        .font(.subheadline)
                        .foregroundStyle(LTColors.textPrimary)
                        .textSelection(.enabled)
                }
                if displayMode != .chinese {
                    Text(HighlightedText.build(entry.originalText, query: query))
                        .font(.footnote)
                        .foregroundStyle(LTColors.textSecondary)
                        .textSelection(.enabled)
                }
                if displayMode == .chinese, entry.translatedText == nil {
                    Text(translationStateText)
                        .font(LTTypography.caption)
                        .foregroundStyle(entry.status == .failed ? LTColors.warning : LTColors.textTertiary)
                }
                if entry.status == .failed {
                    Text("翻译失败 · 俄语原文已保存，可在“更多”中重试")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.warning.opacity(0.85))
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
            Button("复制中文") {
                if let translated = entry.translatedText {
                    UIPasteboard.general.string = translated
                }
            }
            Button("复制俄语") {
                UIPasteboard.general.string = entry.originalText
            }
            Button(isBookmarked ? "取消书签" : "标记书签") {
                onToggleBookmark()
            }
        }
    }

    private var timeline: some View {
        VStack(spacing: 0) {
            Text(TranscriptExporter.mmss(entry.startOffset))
                .font(LTTypography.timestamp)
                .foregroundStyle(LTColors.textTertiary)
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
