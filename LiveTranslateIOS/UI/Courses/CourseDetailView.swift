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
    /// The course's schedule list (固定日程) + the shared pre-class engine.
    @State private var scheduleViewModel = ScheduleViewModel()
    @State private var showScheduleForm = false
    @State private var editingSchedule: CourseSchedule?
    @State private var copyingSchedule: CourseSchedule?
    @State private var exceptionTarget: CourseSchedule?
    @State private var editingException: ScheduleException?
    @State private var schedulePendingDelete: CourseSchedule?
    @State private var icsShareItem: SharedFile?
    @State private var minuteTimer: Timer?
    /// 课程资料库 push (the materials card).
    @State private var pushingMaterials = false

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
            scheduleViewModel.attach(environment)
            await scheduleViewModel.reload()
        }
        .onAppear {
            if viewModel.isLoaded {
                viewModel.reload()
            }
        }
        .sheet(isPresented: $showScheduleForm) {
            NavigationStack {
                ScheduleFormView(courses: viewModel.course.map { [$0] } ?? [])
                    .environment(environment)
            }
            .presentationDetents([.large])
        }
        .sheet(item: $editingSchedule) { schedule in
            NavigationStack {
                ScheduleFormView(
                    courses: viewModel.course.map { [$0] } ?? [], editing: schedule
                )
                .environment(environment)
            }
        }
        .sheet(item: $copyingSchedule) { schedule in
            NavigationStack {
                ScheduleFormView(
                    courses: viewModel.course.map { [$0] } ?? [], copying: schedule
                )
                .environment(environment)
            }
        }
        .sheet(item: $exceptionTarget) { schedule in
            NavigationStack {
                ScheduleExceptionSheet(schedule: schedule)
                    .environment(environment)
            }
        }
        .sheet(item: $icsShareItem) { item in
            ShareSheet(items: [item.url])
        }
        .confirmationDialog(
            "删除这条日程？",
            isPresented: Binding(
                get: { schedulePendingDelete != nil },
                set: { if !$0 { schedulePendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除日程", role: .destructive) {
                if let schedule = schedulePendingDelete {
                    scheduleViewModel.deleteSchedule(schedule)
                }
                schedulePendingDelete = nil
            }
            Button("取消", role: .cancel) { schedulePendingDelete = nil }
        } message: {
            Text("固定的重复规则会停止并删除；已关联的历史课堂保留。")
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
        .sheet(isPresented: $showingExamForm) {
            NavigationStack {
                ExamFormScreen(preselectedCourseID: courseID, editing: nil)
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
                    schedulesCard
                    materialsCard(course)
                    examsCard
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
        .onAppear { startMinuteTimer() }
        .onDisappear {
            minuteTimer?.invalidate()
            minuteTimer = nil
        }
    }

    /// 课程资料 card: the course's material library entry + the honest
    /// 课前资料 line when materials are linked to the next class.
    private func materialsCard(_ course: Course) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            HStack(spacing: LTSpacing.m) {
                LTIconBadge(symbol: "books.vertical", tint: LTColors.accentBlue, size: 38)
                VStack(alignment: .leading, spacing: LTSpacing.xxs) {
                    Text("课程资料")
                        .font(LTTypography.cardTitle)
                        .foregroundStyle(LTColors.textPrimary)
                    Text(materialsDetailLine)
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textTertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LTColors.textTertiary)
            }
            if !viewModel.preClassMaterials.isEmpty {
                HStack(spacing: LTSpacing.xs) {
                    Image(systemName: "book")
                        .font(.system(size: 12))
                        .foregroundStyle(LTColors.accentCyan)
                    Text("课前资料 \(viewModel.preClassMaterials.count) 份")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.accentCyan)
                }
            }
        }
        .ltCard()
        .contentShape(Rectangle())
        .onTapGesture {
            pushingMaterials = true
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("课程资料，\(materialsDetailLine)"))
        .navigationDestination(isPresented: $pushingMaterials) {
            CourseMaterialLibraryScreen(courseID: course.id)
                .environment(environment)
        }
    }

    private var materialsDetailLine: String {
        let count = viewModel.courseMaterials.count
        if count == 0 {
            return "导入讲义、习题或阅读材料"
        }
        return count == 1 ? "1 份资料" : "\(count) 份资料"
    }

    /// 考试与计划 card: this course's exams (nearest first, with the
    /// day countdown) and a one-tap 创建考试. Hidden when the course has
    /// no exams and shows a restrained entry line instead — never a fake
    /// exam summary.
    @State private var courseExams: [Exam] = []

    private var examsCard: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            HStack {
                LTSectionHeader(title: "考试与计划")
                Spacer()
                Button {
                    showingExamForm = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LTColors.accentGreen)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("创建考试"))
            }
            if courseExams.isEmpty {
                Text("还没有安排考试")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textTertiary)
            } else {
                VStack(spacing: LTSpacing.xs) {
                    ForEach(courseExams.filter { $0.status == .scheduled }.prefix(3)) { exam in
                        NavigationLink {
                            ExamDetailView(examID: exam.id)
                                .environment(environment)
                        } label: {
                            HStack(spacing: LTSpacing.s) {
                                LTIconBadge(symbol: exam.kind.symbol, tint: LTColors.accentGreen, size: 28)
                                Text(exam.title)
                                    .font(.subheadline)
                                    .foregroundStyle(LTColors.textPrimary)
                                    .lineLimit(1)
                                Spacer()
                                Text(exam.daysUntilExam.map { days in
                                    days < 0 ? "已结束" : days == 0 ? "今天" : "\(days) 天后"
                                } ?? "")
                                    .font(LTTypography.timestamp)
                                    .foregroundStyle(
                                        (exam.daysUntilExam ?? 99) <= 3
                                            ? LTColors.warning : LTColors.textTertiary
                                    )
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                    }
                    let finished = courseExams.filter { $0.status != .scheduled }.count
                    if finished > 0 {
                        Text("已结束/取消 \(finished) 场")
                            .font(LTTypography.caption)
                            .foregroundStyle(LTColors.textTertiary)
                    }
                }
            }
        }
        .ltCard()
        .onAppear {
            courseExams = (try? environment.repository.exams(
                courseID: courseID, includeCandidates: false
            )) ?? []
        }
    }

    @State private var showingExamForm = false

    /// The course's recurring schedules (固定日程): every weekly slot as
    /// its own row (周一 10:30–12:05 · 仅单周), with pause / edit / 停课调课
    /// / copy / delete. The next class of THIS course and its remaining
    /// semester count ride on top.
    private var schedulesCard: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            HStack {
                LTSectionHeader(title: "固定日程")
                Spacer()
                Button {
                    showScheduleForm = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LTColors.accentGreen)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("添加日程"))
            }
            if scheduleViewModel.schedules.filter({ $0.courseID == courseID }).isEmpty {
                VStack(spacing: LTSpacing.xs) {
                    Text("还没有固定日程")
                        .font(LTTypography.body)
                        .foregroundStyle(LTColors.textTertiary)
                    Text("添加后可收到上课提醒，从课程表一键开课")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, LTSpacing.m)
            } else {
                VStack(spacing: LTSpacing.s) {
                    if let next = nextCourseOccurrence {
                        ScheduleOccurrenceCard(
                            occurrence: next,
                            courseName: viewModel.course?.name ?? "课程",
                            teacher: scheduleViewModel.teacher(for: next),
                            location: scheduleViewModel.location(for: next),
                            colorIndex: viewModel.course?.colorIndex ?? 0,
                            relativeLabel: scheduleViewModel.relativeLabel(for: next),
                            startState: scheduleViewModel.startState(for: next),
                            isNext: true,
                            onStart: { startOccurrence(next) },
                            onOpenSchedule: nil
                        )
                    }
                    ForEach(
                        scheduleViewModel.schedules.filter { $0.courseID == courseID },
                        id: \.id
                    ) { schedule in
                        scheduleRow(schedule)
                    }
                }
                if nextCourseOccurrence != nil {
                    Text("本学期剩余 \(remainingCount) 次课")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textTertiary)
                }
            }
            // .ics export of this course's schedule.
            Button {
                exportCourseICS()
            } label: {
                Label("导出课程日程（.ics）", systemImage: "calendar.badge.arrow.up")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textSecondary)
            }
            .buttonStyle(.plain)
            .disabled(scheduleViewModel.schedules.filter { $0.courseID == courseID }.isEmpty)
        }
        .ltCard()
    }

    /// One schedule rule row: 周一 10:30–12:05 · 仅单周（下拉操作）.
    private func scheduleRow(_ schedule: CourseSchedule) -> some View {
        HStack(spacing: LTSpacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(scheduleLine(schedule))
                    .font(LTTypography.cardTitle)
                    .foregroundStyle(schedule.isEnabled ? LTColors.textPrimary : LTColors.textTertiary)
                HStack(spacing: LTSpacing.xs) {
                    Text(schedule.recurrence.displayName)
                    if !schedule.teacherOverride.isEmpty || !schedule.locationOverride.isEmpty {
                        Text("·")
                        Text(
                            [schedule.teacherOverride, schedule.locationOverride]
                                .filter { !$0.isEmpty }.joined(separator: " ")
                        )
                    }
                    if schedule.reminderLeadMins >= 0 {
                        Text("· 提醒 \(reminderLabel(schedule.reminderLeadMins))")
                    }
                }
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.textTertiary)
            }
            Spacer()
            if !schedule.isEnabled {
                StatusChip(text: "已暂停", tint: LTColors.textTertiary)
            }
            Menu {
                Button {
                    editingSchedule = schedule
                } label: {
                    Label("编辑日程", systemImage: "pencil")
                }
                Button {
                    copyingSchedule = schedule
                } label: {
                    Label("复制为新日程", systemImage: "doc.on.doc")
                }
                Button {
                    exceptionTarget = schedule
                } label: {
                    Label("停课或调课", systemImage: "calendar.badge.minus")
                }
                Button {
                    scheduleViewModel.setScheduleEnabled(
                        schedule, isEnabled: !schedule.isEnabled
                    )
                } label: {
                    Label(
                        schedule.isEnabled ? "暂停日程" : "恢复日程",
                        systemImage: schedule.isEnabled ? "pause" : "play"
                    )
                }
                Button(role: .destructive) {
                    schedulePendingDelete = schedule
                } label: {
                    Label("删除日程", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(LTColors.textSecondary)
                    .frame(width: 34, height: 34)
            }
            .accessibilityLabel(Text("日程操作"))
        }
        .padding(.vertical, 2)
    }

    private func scheduleLine(_ schedule: CourseSchedule) -> String {
        let tz = TimeZone(identifier: schedule.timezoneID) ?? .current
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let ref = schedule.onceDate ?? .now
        let day = cal.startOfDay(for: ref)
        let start = cal.date(byAdding: .second, value: schedule.startSecs, to: day) ?? day
        let end = cal.date(byAdding: .second, value: schedule.endSecs, to: day) ?? day
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "HH:mm"
        let dayName = ScheduleFormView.weekdayName(schedule.weekday)
        if schedule.recurrence == .once, let once = schedule.onceDate {
            let dayFormatter = DateFormatter()
            dayFormatter.locale = Locale(identifier: "zh_CN")
            dayFormatter.dateFormat = "M月d日"
            return "\(dayName) \(formatter.string(from: start))–\(formatter.string(from: end))"
                + "（\(dayFormatter.string(from: once))）"
        }
        return "\(dayName) \(formatter.string(from: start))–\(formatter.string(from: end))"
    }

    private func reminderLabel(_ minutes: Int) -> String {
        if minutes == 0 { return "上课时" }
        if minutes >= 60 { return "提前 \(minutes / 60) 小时" }
        return "提前 \(minutes) 分钟"
    }

    /// The next upcoming occurrence of THIS course.
    private var nextCourseOccurrence: ScheduleCalculator.Occurrence? {
        scheduleViewModel.occurrences.first {
            $0.courseID == courseID && !$0.isCancelled && $0.end > scheduleViewModel.now
        }
    }

    /// Remaining class count this semester (non-cancelled, from today).
    private var remainingCount: Int {
        scheduleViewModel.occurrences.filter {
            $0.courseID == courseID && !$0.isCancelled && $0.end > scheduleViewModel.now
        }.count
    }

    private func startOccurrence(_ occurrence: ScheduleCalculator.Occurrence) {
        Task { _ = await scheduleViewModel.startOccurrence(occurrence) }
    }

    private func exportCourseICS() {
        let exporter = ScheduleICSExporter(
            schedules: scheduleViewModel.schedules.filter { $0.courseID == courseID },
            exceptions: scheduleViewModel.exceptions.filter { $0.courseID == courseID },
            courses: viewModel.course.map { [$0] } ?? []
        )
        if let url = exporter.writeTemporaryFile() {
            icsShareItem = SharedFile(url: url)
        }
    }

    private func startMinuteTimer() {
        minuteTimer?.invalidate()
        minuteTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in scheduleViewModel.tick() }
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

    /// Learning-material export (terms/cards/tasks/materials) — real
    /// saved data only, no model calls.
    private func exportLearning(_ kind: LearningExporter.LearningExportKind) {
        guard let course = viewModel.course else { return }
        guard let url = LearningExporter.writeTemporaryFile(
            kind: kind,
            course: course,
            terms: viewModel.courseTerms,
            cards: viewModel.courseCards,
            tasks: viewModel.courseTasks,
            materials: viewModel.courseMaterials,
            repository: environment.repository
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
        let corrections = (try? environment.repository.corrections(forSessionID: session.id)) ?? []
        guard let url = await SessionExport.writeTemporaryFile(
            session: session,
            entries: entries,
            notes: notes,
            scope: .fullMaterial,
            review: review,
            corrections: corrections,
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
        // Course materials (资料库).
        courseMaterials = (try? environment.repository.materials(courseID: id)) ?? []
        isLoaded = true
    }

    // MARK: Learning space (real saved learning material)

    var courseTerms: [GlossaryTerm] = []
    var courseCards: [StudyCard] = []
    var courseTasks: [StudyTask] = []

    // MARK: Course materials (资料库)

    var courseMaterials: [CourseMaterial] = []

    /// Materials linked to the NEXT class occurrence (课前资料).
    var preClassMaterials: [CourseMaterial] {
        guard let nextKey = nextOccurrenceKey else { return [] }
        return courseMaterials.filter { $0.occurrenceKey == nextKey }
    }

    /// The next occurrence key of THIS course (materials' 课前资料 link
    /// resolves against the same computed occurrences the timetable
    /// uses).
    var nextOccurrenceKey: String? {
        guard let environment, let courseID = course?.id else { return nil }
        let schedules = (try? environment.repository.schedules(courseID: courseID)) ?? []
        guard !schedules.isEmpty else { return nil }
        let exceptions = (try? environment.repository.allExceptions()) ?? []
        let window = Calendar.current.date(byAdding: .day, value: 14, to: .now) ?? .now
        var upcoming: [ScheduleCalculator.Occurrence] = []
        for schedule in schedules {
            upcoming.append(contentsOf: ScheduleCalculator.occurrences(
                of: schedule, from: .now, to: window, exceptions: exceptions
            ))
        }
        return upcoming
            .filter { !$0.isCancelled }
            .min { $0.start < $1.start }?
            .occurrenceKey
    }

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
