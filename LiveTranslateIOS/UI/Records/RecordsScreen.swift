import SwiftUI

/// Classroom records tab (reference image 4): search, filters, sort,
/// storage usage, session cards with stable course identity, favorites and
/// a destructive-confirmed delete. No playback: sessions store no playable
/// audio in-app, so cards open the transcript instead.
struct RecordsScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var viewModel = RecordsViewModel()
    @State private var sessionPendingDelete: ClassroomSession?
    @State private var shareItem: SharedFile?
    @State private var exportError = false
    /// The failed export, kept so the alert's retry can re-run it.
    @State private var failedExport: (session: ClassroomSession, format: ExportFormat)?
    /// Debug UI demo: pushes the seeded detail screen once.
    @State private var isPushingDemoDetail = false
    @State private var demoDetailSessionID: UUID?

    var body: some View {
        NavigationStack {
            LTPage {
                ScrollView {
                    VStack(spacing: LTSpacing.l) {
                        searchField
                        filterChips
                        if !viewModel.courses.isEmpty {
                            courseChips
                        }
                        sessionList
                    }
                    .padding(.horizontal, LTSpacing.screenPadding)
                    .padding(.top, LTSpacing.s)
                    .padding(.bottom, LTSpacing.xl)
                }
            }
            .navigationTitle("课堂记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    sortMenu
                }
            }
            .navigationDestination(isPresented: $isPushingDemoDetail) {
                if let demoDetailSessionID {
                    SessionDetailView(sessionID: demoDetailSessionID)
                } else {
                    EmptyView()
                }
            }
        }
        .task {
            viewModel.attach(environment)
            viewModel.reload()
        }
        .onAppear {
            // Returning from a classroom or detail edit — refresh.
            viewModel.reload()
            #if DEBUG
            if environment.flow.pendingDemoScreen == .detail {
                environment.flow.pendingDemoScreen = nil
                demoDetailSessionID = environment.flow.demoDetailSessionID
                isPushingDemoDetail = true
            }
            #endif
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .alert("导出失败", isPresented: $exportError) {
            if failedExport != nil {
                Button("重试") {
                    let retry = failedExport
                    failedExport = nil
                    if let retry {
                        Task { await exportSession(retry.session, format: retry.format) }
                    }
                }
            }
            Button("好", role: .cancel) { failedExport = nil }
        } message: {
            Text("无法生成导出文件，请重试。课堂内容仍保存在本地。")
        }
        .confirmationDialog(
            "删除这堂课？",
            isPresented: Binding(
                get: { sessionPendingDelete != nil },
                set: { if !$0 { sessionPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除课堂", role: .destructive) {
                if let session = sessionPendingDelete {
                    viewModel.delete(session)
                }
                sessionPendingDelete = nil
            }
            Button("取消", role: .cancel) { sessionPendingDelete = nil }
        } message: {
            Text("将删除这堂课的全部转写与翻译内容，无法恢复。")
        }
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: LTSpacing.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundStyle(LTColors.textTertiary)
            TextField("搜索课堂名称或双语文本", text: $viewModel.searchQuery)
                .font(.subheadline)
                .autocorrectionDisabled()
                .onChange(of: viewModel.searchQuery) { _, _ in
                    viewModel.searchDidChange()
                }
                .submitLabel(.search)
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
        .background(
            RoundedRectangle(cornerRadius: LTRadius.medium)
                .fill(LTColors.surfacePrimary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LTRadius.medium)
                .strokeBorder(LTColors.border, lineWidth: 0.5)
        )
    }

    // MARK: - Filters

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: LTSpacing.s) {
                ForEach(RecordsViewModel.Filter.allCases) { filter in
                    let isSelected = viewModel.filter == filter
                    Button {
                        withAnimation(LTMotion.quick) { viewModel.filter = filter }
                    } label: {
                        Text(filter.title)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(isSelected ? LTColors.accentGreen : LTColors.textSecondary)
                            .padding(.horizontal, LTSpacing.m)
                            .padding(.vertical, LTSpacing.xs + 1)
                            .background(Capsule().fill(isSelected ? LTColors.accentGreen.opacity(0.16) : LTColors.surfacePrimary))
                            .overlay(Capsule().strokeBorder(isSelected ? LTColors.accentGreen.opacity(0.4) : LTColors.border, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }
            }
            .padding(.vertical, 1)
        }
    }

    // MARK: - Course chips

    /// Course navigation row: tapping opens the course detail (its
    /// classroom history, stats and quick start). Archived courses ride at
    /// the end, dimmed. Hidden entirely until the first course exists.
    private var courseChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: LTSpacing.s) {
                ForEach(viewModel.courses, id: \.id) { course in
                    NavigationLink {
                        CourseDetailView(courseID: course.id)
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(LTCoursePalette.color(course.colorIndex))
                                .frame(width: 7, height: 7)
                            Text(course.name)
                                .font(.footnote.weight(.medium))
                                .lineLimit(1)
                            if course.isArchived {
                                Text("已归档")
                                    .font(LTTypography.timestamp)
                                    .foregroundStyle(LTColors.textTertiary)
                            }
                        }
                        .foregroundStyle(LTColors.textSecondary)
                        .padding(.horizontal, LTSpacing.m)
                        .padding(.vertical, LTSpacing.xs + 1)
                        .background(Capsule().fill(LTColors.surfacePrimary))
                        .overlay(Capsule().strokeBorder(LTColors.border, lineWidth: 0.5))
                        .opacity(course.isArchived ? 0.55 : 1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("课程 \(course.name)"))
                }
            }
            .padding(.vertical, 1)
        }
    }

    // MARK: - List

    @ViewBuilder
    private var sessionList: some View {
        HStack {
            LTSectionHeader(title: "全部课堂")
            Spacer()
            // Restrained cloud-sync marker: only pending uploads or a
            // failure are worth a line here — a synced state stays silent.
            if let sync = environment.cloudSync, sync.isSignedIn {
                if sync.pendingUploadCount > 0 {
                    Text("待同步 \(sync.pendingUploadCount)")
                        .font(LTTypography.timestamp)
                        .foregroundStyle(LTColors.textTertiary)
                } else if let error = sync.lastError {
                    Text("部分内容同步失败")
                        .font(LTTypography.timestamp)
                        .foregroundStyle(LTColors.warning)
                }
            }
            // Only meaningful once something is actually on disk (fresh
            // installs and the in-memory demo store report zero).
            if viewModel.storageBytes > 0 {
                Text("存储 \(Format.bytes(viewModel.storageBytes))")
                    .font(LTTypography.timestamp)
                    .foregroundStyle(LTColors.textTertiary)
            }
        }

        if viewModel.isLoaded && viewModel.visibleSessions.isEmpty {
            LTEmptyState(
                symbol: "list.bullet.rectangle",
                title: viewModel.appliedQuery.isEmpty ? "还没有课堂记录" : "没有匹配的课堂",
                message: viewModel.appliedQuery.isEmpty
                    ? "完成第一堂课后，记录会自动保存在这里"
                    : "换个关键词，或调整筛选条件"
            )
        } else {
            VStack(spacing: LTSpacing.s) {
                ForEach(viewModel.visibleSessions, id: \.id) { session in
                    NavigationLink {
                        SessionDetailView(sessionID: session.id)
                    } label: {
                        SessionCard(
                            session: session,
                            stats: viewModel.stats(for: session.id),
                            badge: viewModel.translationBadge(for: session.id),
                            courseName: viewModel.course(for: session)?.name,
                            courseTint: viewModel.course(for: session).map {
                                LTCoursePalette.color($0.colorIndex)
                            },
                            isFavorite: viewModel.isFavorite(session.id),
                            onToggleFavorite: { viewModel.toggleFavorite(session.id) },
                            onExport: { format in
                                Task { await exportSession(session, format: format) }
                            },
                            onDelete: { sessionPendingDelete = session }
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Sort

    private var sortMenu: some View {
        Menu {
            ForEach(RecordsViewModel.SortOrder.allCases) { order in
                Button {
                    viewModel.sortOrder = order
                } label: {
                    if viewModel.sortOrder == order {
                        Label(order.title, systemImage: "checkmark")
                    } else {
                        Text(order.title)
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(LTColors.textSecondary)
        }
        .accessibilityLabel(Text("排序方式"))
    }

    // MARK: - Export

    private func exportSession(_ session: ClassroomSession, format: ExportFormat) async {
        let entries = (try? environment.repository.entries(for: session)) ?? []
        let notes = (try? environment.repository.notes(forSessionID: session.id)) ?? []
        let review = (try? environment.repository.studyReview(forSessionID: session.id))
            .flatMap { StudyReviewContent.decode($0.contentJSON) }
        guard let url = await SessionExport.writeTemporaryFile(
            session: session,
            entries: entries,
            notes: notes,
            scope: .fullMaterial,
            review: review,
            format: format,
            fallbackBackend: environment.settings.preferredBackend
        ) else {
            // Honest, user-safe failure (no paths, no stack); the alert
            // offers a retry of the same session + format.
            failedExport = (session, format)
            exportError = true
            LTHaptics.warning()
            return
        }
        shareItem = SharedFile(url: url)
    }
}

/// One classroom card (reference image 4): stable course icon derived from
/// the title, title/date/duration, translation status, favorite star and
/// a more-actions menu. When the session belongs to a course, a colored
/// tag shows it (the course's own color — not a title hash).
struct SessionCard: View {
    let session: ClassroomSession
    let stats: RecordsViewModel.SessionStats
    let badge: (text: String, tint: Color)
    var courseName: String? = nil
    var courseTint: Color? = nil
    var isFavorite: Bool = false
    var onToggleFavorite: () -> Void = {}
    var onExport: (ExportFormat) -> Void = { _ in }
    var onDelete: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: LTSpacing.m) {
            LTIconBadge(
                symbol: courseName.map { _ in "book.fill" }
                    ?? LTIconography.symbol(for: session.title),
                tint: courseTint ?? LTIconography.tint(for: session.title)
            )

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: LTSpacing.xs) {
                    Text(session.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LTColors.textPrimary)
                        .lineLimit(2)
                    if session.abnormalTermination {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(LTColors.warning)
                            .accessibilityLabel(Text("异常终止"))
                    }
                    Spacer(minLength: 0)
                    favoriteButton
                }

                HStack(spacing: LTSpacing.s) {
                    if let courseName {
                        HStack(spacing: 3) {
                            if let courseTint {
                                Circle()
                                    .fill(courseTint)
                                    .frame(width: 5, height: 5)
                            }
                            Text(courseName)
                        }
                    }
                    Text(Format.date(session.startTime))
                    Text(Format.clock(session.duration))
                    Text("\(stats.totalEntries) 段")
                }
                .font(LTTypography.timestamp)
                .foregroundStyle(LTColors.textTertiary)

                HStack(spacing: LTSpacing.s) {
                    StatusChip(text: badge.text, tint: badge.tint)
                    Spacer()
                    moreMenu
                }
            }
        }
        .padding(LTSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: LTRadius.medium).fill(LTColors.surfacePrimary.opacity(0.85)))
        .overlay(RoundedRectangle(cornerRadius: LTRadius.medium).strokeBorder(LTColors.border, lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: LTRadius.medium))
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("双击打开课堂详情"))
    }

    private var favoriteButton: some View {
        Button(action: {
            onToggleFavorite()
            LTHaptics.tap()
        }) {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .font(.system(size: 14))
                .foregroundStyle(isFavorite ? LTColors.warning : LTColors.textTertiary)
                .frame(width: LTSpacing.minTouchTarget, height: LTSpacing.minTouchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(isFavorite ? "取消收藏" : "收藏"))
    }

    /// Single entry point per action: the star owns favorite toggling, this
    /// menu owns export and delete (no duplicate affordances).
    private var moreMenu: some View {
        Menu {
            Menu("导出") {
                ForEach(ExportFormat.allCases) { format in
                    Button(format.displayName) { onExport(format) }
                }
            }
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("删除", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(LTColors.textSecondary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(LTColors.surfaceElevated.opacity(0.7)))
                .frame(width: LTSpacing.minTouchTarget, height: LTSpacing.minTouchTarget)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("更多操作"))
    }
}
