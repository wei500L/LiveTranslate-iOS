import SwiftUI
import Observation

/// Course detail: the course's classroom history with aggregate stats,
/// quick start for the next class, and edit / archive / delete actions.
/// All reads go through the repository; every action persists through it.
struct CourseDetailView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = CourseDetailViewModel()
    @State private var showEditForm = false
    @State private var showNewSessionSheet = false
    @State private var showDeleteConfirm = false
    @State private var sessionPendingDelete: ClassroomSession?
    @State private var shareItem: SharedFile?
    @State private var exportError = false
    @State private var failedExport: (session: ClassroomSession, format: ExportFormat)?
    /// Course-scoped flashcard review presentation.
    @State private var showingCourseReview = false
    /// Learning-material export picker.
    @State private var showingLearningExport = false

    let courseID: UUID

    var body: some View {
        LTPage {
            Group {
                if viewModel.isLoaded, viewModel.course == nil {
                    LTEmptyState(
                        symbol: "questionmark.folder",
                        title: "课程不存在",
                        message: "这门课程可能已被删除"
                    )
                } else if viewModel.isLoaded, let course = viewModel.course {
                    detailContent(course)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("课程")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: LTSpacing.m) {
                    Menu {
                        ForEach(LearningExporter.LearningExportKind.allCases) { kind in
                            Button(kind.rawValue) {
                                exportLearning(kind)
                            }
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(LTColors.textSecondary)
                    }
                    .accessibilityLabel(Text("导出学习资料"))
                    Button {
                        showEditForm = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(LTColors.textSecondary)
                    }
                    .accessibilityLabel(Text("编辑课程"))
                }
            }
        }
        .task {
            viewModel.attach(environment)
            viewModel.load(courseID: courseID)
        }
        .onAppear {
            if viewModel.isLoaded {
                viewModel.reload()
            }
        }
        .sheet(isPresented: $showEditForm) {
            if let course = viewModel.course {
                CourseFormView(course: course)
                    .environment(environment)
            }
        }
        .sheet(isPresented: $showNewSessionSheet) {
            if let course = viewModel.course {
                NewSessionSheet(preselectedCourse: course)
                    .environment(environment)
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .fullScreenCover(isPresented: $showingCourseReview) {
            ReviewSessionView(courseID: courseID)
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
            "删除这门课程？",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("删除课程", role: .destructive) {
                viewModel.deleteCourse()
                // Pops back — the course page no longer exists.
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("课程下的课堂记录会保留，并变为独立课堂。")
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

    // MARK: - Content

    private func detailContent(_ course: Course) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: LTSpacing.l) {
                    headerCard(course)
                    statsCard
                    learningSpaceCard
                    if viewModel.sessions.isEmpty {
                        LTEmptyState(
                            symbol: "mic",
                            title: "还没有上过这门课",
                            message: "点击下方按钮开始第一堂课"
                        )
                    } else {
                        sessionList
                    }
                }
                .padding(.horizontal, LTSpacing.screenPadding)
                .padding(.top, LTSpacing.s)
                .padding(.bottom, 90)
            }
            bottomToolbar(course)
        }
    }

    private func headerCard(_ course: Course) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            HStack(spacing: LTSpacing.m) {
                LTIconBadge(
                    symbol: LTIconography.symbol(for: course.name),
                    tint: LTCoursePalette.color(course.colorIndex)
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(course.name)
                        .font(LTTypography.cardTitle)
                        .foregroundStyle(LTColors.textPrimary)
                    if !course.teacherName.isEmpty || !course.location.isEmpty {
                        Text([course.teacherName, course.location]
                            .filter { !$0.isEmpty }
                            .joined(separator: " · "))
                            .font(LTTypography.caption)
                            .foregroundStyle(LTColors.textSecondary)
                    }
                }
                Spacer()
                if course.isArchived {
                    StatusChip(text: "已归档", tint: LTColors.textTertiary)
                }
            }
            if let lastUsed = viewModel.lastSessionDate {
                Text("最近一次：\(Format.date(lastUsed))")
                    .font(LTTypography.timestamp)
                    .foregroundStyle(LTColors.textTertiary)
            }
        }
        .ltCard()
    }

    private var statsCard: some View {
        HStack(spacing: LTSpacing.l) {
            statTile(
                value: "\(viewModel.sessions.count)",
                caption: "课堂"
            )
            statTile(
                value: Format.studyDuration(viewModel.totalDuration),
                caption: "累计时长"
            )
            statTile(
                value: "\(viewModel.totalEntries)",
                caption: "转写段落"
            )
            Spacer(minLength: 0)
        }
        .ltCard()
    }

    /// The course's learning space: real counts + entries into the review
    /// center. Visible for archived courses too (archived courses can
    /// still be reviewed); hidden entirely when the course has no
    /// learning material yet.
    @ViewBuilder
    private var learningSpaceCard: some View {
        if viewModel.hasLearningMaterial {
            VStack(alignment: .leading, spacing: LTSpacing.s) {
                LTSectionHeader(title: "学习资料")
                HStack(spacing: LTSpacing.l) {
                    Button {
                        environment.flow.selectedTab = .review
                    } label: {
                        statTile(value: "\(viewModel.courseTerms.count)", caption: "术语")
                    }
                    .buttonStyle(.plain)
                    Button {
                        environment.flow.selectedTab = .review
                    } label: {
                        statTile(
                            value: viewModel.dueCardCount > 0 ? "\(viewModel.dueCardCount)" : "0",
                            caption: "今日待复习"
                        )
                    }
                    .buttonStyle(.plain)
                    Button {
                        environment.flow.selectedTab = .review
                    } label: {
                        statTile(value: "\(viewModel.openTasks.count)", caption: "未完成任务")
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                }
                if !viewModel.recentTerms.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: LTSpacing.s) {
                            ForEach(viewModel.recentTerms) { term in
                                NavigationLink {
                                    TermDetailView(term: term, courses: viewModel.course.map { [$0] } ?? [])
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(term.russian)
                                            .font(LTTypography.caption)
                                            .foregroundStyle(LTColors.textPrimary)
                                        if !term.chinese.isEmpty {
                                            Text(term.chinese)
                                                .font(LTTypography.caption)
                                                .foregroundStyle(LTColors.textSecondary)
                                        }
                                    }
                                    .padding(.horizontal, LTSpacing.m)
                                    .padding(.vertical, LTSpacing.xs)
                                    .background(Capsule().fill(LTColors.surfacePrimary))
                                    .overlay(Capsule().strokeBorder(LTColors.border, lineWidth: 0.5))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 1)
                    }
                }
                if viewModel.dueCardCount > 0 {
                    Button {
                        showingCourseReview = true
                    } label: {
                        Label("复习本课程卡片", systemImage: "play.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: LTSpacing.minTouchTarget)
                    }
                    .buttonStyle(LTPrimaryButtonStyle())
                }
            }
            .ltCard()
        }
    }

    private func statTile(value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(LTColors.textPrimary)
            Text(caption)
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.textTertiary)
        }
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            LTSectionHeader(title: "课堂记录")
            VStack(spacing: LTSpacing.s) {
                ForEach(viewModel.sessions, id: \.id) { session in
                    NavigationLink {
                        SessionDetailView(sessionID: session.id)
                    } label: {
                        SessionCard(
                            session: session,
                            stats: viewModel.stats(for: session.id),
                            badge: viewModel.translationBadge(for: session.id),
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

    private func bottomToolbar(_ course: Course) -> some View {
        HStack(spacing: LTSpacing.m) {
            Button {
                showNewSessionSheet = true
                LTHaptics.tap()
            } label: {
                HStack(spacing: LTSpacing.xs) {
                    Image(systemName: "play.fill")
                    Text("开始下一堂课")
                }
                .font(LTTypography.button)
                .foregroundStyle(Color.black.opacity(0.85))
                .frame(maxWidth: .infinity)
                .padding(.vertical, LTSpacing.s + 2)
                .background(Capsule().fill(LTColors.accentGreen))
            }
            .disabled(environment.coordinator.isRunning)
            .opacity(environment.coordinator.isRunning ? 0.5 : 1)

            Button {
                viewModel.toggleArchive()
                LTHaptics.tap()
            } label: {
                Text(course.isArchived ? "取消归档" : "归档")
                    .font(LTTypography.button)
                    .foregroundStyle(LTColors.textPrimary)
                    .padding(.horizontal, LTSpacing.l)
                    .padding(.vertical, LTSpacing.s + 2)
                    .background(Capsule().fill(LTColors.surfaceElevated))
                    .overlay(Capsule().strokeBorder(LTColors.border, lineWidth: 0.5))
            }

            Button {
                showDeleteConfirm = true
                LTHaptics.warning()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(LTColors.destructive)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(LTColors.destructive.opacity(0.12)))
            }
            .accessibilityLabel(Text("删除课程"))
        }
        .padding(.horizontal, LTSpacing.screenPadding)
        .padding(.vertical, LTSpacing.s)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
        .overlay(alignment: .top) { Divider().overlay(LTColors.separator) }
    }

    // MARK: - Export

    /// Learning-material export (terms/cards/tasks) — real saved data
    /// only, no model calls.
    private func exportLearning(_ kind: LearningExporter.LearningExportKind) {
        guard let course = viewModel.course else { return }
        guard let url = LearningExporter.writeTemporaryFile(
            kind: kind,
            course: course,
            terms: viewModel.courseTerms,
            cards: viewModel.courseCards,
            tasks: viewModel.courseTasks
        ) else {
            exportError = true
            return
        }
        shareItem = SharedFile(url: url)
    }

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
            failedExport = (session, format)
            exportError = true
            LTHaptics.warning()
            return
        }
        shareItem = SharedFile(url: url)
    }
}

// MARK: - View model

/// Presentation model for the course detail screen: the course row, its
/// sessions (newest first) and per-session aggregates for the cards.
@MainActor
@Observable
final class CourseDetailViewModel {
    private var environment: AppEnvironment?

    private(set) var course: Course?
    private(set) var sessions: [ClassroomSession] = []
    private(set) var totalDuration: TimeInterval = 0
    private(set) var totalEntries = 0
    private(set) var lastSessionDate: Date?
    private var statsBySessionID: [UUID: RecordsViewModel.SessionStats] = [:]
    var isLoaded = false

    func attach(_ environment: AppEnvironment) {
        self.environment = environment
    }

    func load(courseID: UUID) {
        guard let environment else { return }
        course = try? environment.repository.course(id: courseID)
        sessions = ((try? environment.repository.sessions(matching: "")) ?? [])
            .filter { $0.courseID == courseID }

        var stats: [UUID: RecordsViewModel.SessionStats] = [:]
        var duration: TimeInterval = 0
        var entries = 0
        var lastDate: Date?
        for session in sessions {
            let sessionEntries = (try? environment.repository.entries(for: session)) ?? []
            var item = RecordsViewModel.SessionStats()
            item.totalEntries = sessionEntries.count
            for entry in sessionEntries {
                switch entry.status {
                case .completed: item.completedEntries += 1
                case .failed: item.failedEntries += 1
                case .pending: item.pendingEntries += 1
                case .notConfigured: item.failedEntries += 1
                case .skipped: item.skippedEntries += 1
                }
            }
            stats[session.id] = item
            duration += max(session.duration, 0)
            entries += sessionEntries.count
            if lastDate == nil || session.startTime > lastDate! {
                lastDate = session.startTime
            }
        }
        statsBySessionID = stats
        totalDuration = duration
        totalEntries = entries
        lastSessionDate = lastDate
        // Learning space: the course's REAL saved learning material —
        // terms, cards and tasks that live in the review center.
        courseTerms = (try? environment.repository.terms(courseID: id)) ?? []
        courseCards = (try? environment.repository.cards(courseID: id)) ?? []
        courseTasks = (try? environment.repository.tasks(courseID: id, includeDone: true)) ?? []
        isLoaded = true
    }

    // MARK: Learning space (real saved learning material)

    var courseTerms: [GlossaryTerm] = []
    var courseCards: [StudyCard] = []
    var courseTasks: [StudyTask] = []

    /// Cards of this course due right now (includes enrolled-new).
    var dueCardCount: Int {
        courseCards.filter(\.isDueNow).count
    }

    /// Confirmed, unfinished tasks.
    var openTasks: [StudyTask] {
        courseTasks.filter { $0.status == .pending }
    }

    /// Terms saved recently, newest first.
    var recentTerms: [GlossaryTerm] {
        Array(courseTerms.prefix(5))
    }

    /// Whether the learning-space card should render at all.
    var hasLearningMaterial: Bool {
        !courseTerms.isEmpty || !courseCards.isEmpty || !courseTasks.isEmpty
    }

    func reload() {
        if let id = course?.id {
            load(courseID: id)
        }
    }

    func stats(for sessionID: UUID) -> RecordsViewModel.SessionStats {
        statsBySessionID[sessionID] ?? RecordsViewModel.SessionStats()
    }

    func translationBadge(for sessionID: UUID) -> (text: String, tint: Color) {
        let stats = stats(for: sessionID)
        if stats.totalEntries == 0 {
            return ("无内容", LTColors.textTertiary)
        }
        if stats.isEntirelySkipped {
            return ("实时翻译已关闭", LTColors.textTertiary)
        }
        if stats.hasFailures {
            return ("部分翻译失败", LTColors.warning)
        }
        if stats.isFullyTranslated {
            return ("已翻译", LTColors.accentGreen)
        }
        return ("翻译未完成", LTColors.accentBlue)
    }

    func isFavorite(_ sessionID: UUID) -> Bool {
        environment?.bookmarks.isFavorite(sessionID) ?? false
    }

    func toggleFavorite(_ sessionID: UUID) {
        environment?.bookmarks.toggleFavorite(sessionID)
    }

    // MARK: - Actions

    func toggleArchive() {
        guard let environment, let course else { return }
        var draft = CourseDraft(
            name: course.name,
            teacherName: course.teacherName,
            location: course.location,
            colorIndex: course.colorIndex
        )
        draft.isArchived = !course.isArchived
        try? environment.repository.updateCourse(course, with: draft)
        reload()
    }

    func deleteCourse() {
        guard let environment, let course else { return }
        try? environment.repository.deleteCourse(course)
    }

    func delete(_ session: ClassroomSession) {
        guard let environment else { return }
        try? environment.repository.deleteSession(session)
        reload()
    }
}
