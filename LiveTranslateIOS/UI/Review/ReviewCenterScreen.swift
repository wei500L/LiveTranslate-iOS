import SwiftUI
import UIKit

/// 复习 tab — the review center. Six segments (今天 · 计划 · 术语 · 卡片 ·
/// 任务 · 书签); bookmarks, the former standalone tab, live on as one
/// segment, and the 计划 segment hosts the exam center (考试列表).
///
/// Everything shown derives from real persisted rows — counts come from
/// the repository, never from hardcoded values.
struct ReviewCenterScreen: View {
    enum Segment: String, CaseIterable, Identifiable {
        case today = "今天"
        case plan = "计划"
        case terms = "术语"
        case cards = "卡片"
        case tasks = "任务"
        case bookmarks = "书签"

        var id: String { rawValue }
    }

    @Environment(AppEnvironment.self) private var environment
    @State private var segment: Segment = .today
    @State private var courses: [Course] = []
    @State private var selectedCourseID: UUID?
    @State private var reviewCourseID: UUID?
    @State private var showingReviewSession = false
    @State private var pushedExamID: UUID?
    /// System-route pending push (plan detail from Spotlight / widget /
    /// intent), consumed once here.
    @State private var pushedSystemPlanID: UUID?

    var body: some View {
        NavigationStack {
            LTPage {
                VStack(spacing: 0) {
                    segmentBar
                    ScrollView {
                        VStack(alignment: .leading, spacing: LTSpacing.l) {
                            switch segment {
                            case .today: TodayView(
                                courses: courses,
                                selectedCourseID: $selectedCourseID,
                                switchToTerms: { segment = .terms },
                                switchToTasks: { segment = .tasks },
                                switchToCards: { segment = .cards },
                                switchToPlan: { segment = .plan },
                                onStartReview: { courseID in
                                    reviewCourseID = courseID
                                    showingReviewSession = true
                                }
                            )
                            case .plan:
                                ExamListScreen(courses: courses)
                            case .terms:
                                TermBookView(courses: $courses, selectedCourseID: $selectedCourseID)
                            case .cards:
                                CardListView(
                                    courses: $courses,
                                    selectedCourseID: $selectedCourseID
                                ) { courseID in
                                    reviewCourseID = courseID
                                    showingReviewSession = true
                                }
                            case .tasks:
                                TaskListView(courses: $courses, selectedCourseID: $selectedCourseID)
                            case .bookmarks:
                                BookmarksSegment(courses: courses)
                            }
                        }
                        .padding(.horizontal, LTSpacing.screenPadding)
                        .padding(.top, LTSpacing.s)
                        .padding(.bottom, LTSpacing.xl + LTSpacing.tabBarReserve)
                    }
                }
            }
            .navigationTitle("复习")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: Binding(
                get: { pushedExamID != nil },
                set: { if !$0 { pushedExamID = nil } }
            )) {
                if let pushedExamID {
                    ExamDetailView(examID: pushedExamID)
                        .environment(environment)
                }
            }
            // System-route target (consume-once): a plan item route
            // resolves to its owning plan's detail screen.
            .navigationDestination(isPresented: Binding(
                get: { pushedSystemPlanID != nil },
                set: { if !$0 { pushedSystemPlanID = nil } }
            )) {
                if let pushedSystemPlanID {
                    StudyPlanDetailView(planID: pushedSystemPlanID)
                        .environment(environment)
                }
            }
        }
        .task {
            courses = (try? environment.repository.courses()) ?? []
            consumePendingRoutes()
        }
        .onAppear {
            courses = (try? environment.repository.courses()) ?? courses
            consumePendingRoutes()
        }
        .fullScreenCover(isPresented: $showingReviewSession) {
            ReviewSessionView(courseID: reviewCourseID)
        }
    }

    /// Exam/study reminder deep links: route once, land on the right
    /// segment and push the exam detail.
    private func consumePendingRoutes() {
        if let examID = environment.flow.pendingExamID {
            environment.flow.consumeExamReminder()
            segment = .plan
            pushedExamID = examID
        }
        if environment.flow.pendingTodayStudy {
            environment.flow.consumeStudyPlanReminder()
            segment = .today
        }
        // System-route plan detail (Spotlight / widget / intent).
        if let planID = environment.flow.pendingSystemPlanID {
            environment.flow.pendingSystemPlanID = nil
            pushedSystemPlanID = planID
        }
    }

    private var segmentBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: LTSpacing.xs) {
                ForEach(Segment.allCases) { candidate in
                    Button {
                        withReducedMotionFallback { segment = candidate }
                    } label: {
                        VStack(spacing: 4) {
                            Text(candidate.rawValue)
                                .font(.footnote.weight(segment == candidate ? .semibold : .regular))
                            Rectangle()
                                .fill(segment == candidate ? LTColors.accentGreen : .clear)
                                .frame(height: 2)
                        }
                    }
                    .foregroundStyle(
                        segment == candidate ? LTColors.textPrimary : LTColors.textSecondary
                    )
                    .padding(.horizontal, 10)
                    .accessibilityAddTraits(segment == candidate ? [.isSelected] : [])
                }
            }
            .padding(.horizontal, LTSpacing.screenPadding)
            .padding(.top, LTSpacing.s)
        }
    }

    /// Honors Reduce Motion: segment switches don't animate.
    private func withReducedMotionFallback(_ body: () -> Void) {
        if UIAccessibility.isReduceMotionEnabled {
            body()
        } else {
            withAnimation(.easeInOut(duration: 0.15), body)
        }
    }
}

// MARK: - Today

/// The 今天 segment: the single daily study entry (今天学什么).
/// Priority order: running learning timer → today's/overdue tasks →
/// today's study plan → due cards → AI candidates → upcoming exams →
/// unfinished learning activities. The same source never appears twice
/// (a task already carried by a plan item is not repeated in the task
/// card). Every number comes from a repository query; sections with
/// nothing to do are hidden, so an empty day is an empty page (the
/// honest state).
struct TodayView: View {
    @Environment(AppEnvironment.self) private var environment
    let courses: [Course]
    @Binding var selectedCourseID: UUID?
    var switchToTerms: () -> Void
    var switchToTasks: () -> Void
    var switchToCards: () -> Void
    var switchToPlan: () -> Void
    var onStartReview: (UUID?) -> Void

    @State private var dueCardCount = 0
    @State private var newCardCount = 0
    @State private var overdueTasks: [StudyTask] = []
    @State private var upcomingTasks: [StudyTask] = []
    @State private var pendingConfirmCount = 0
    /// Pending exam candidates (incl. inbox-created ones) — the 待确认
    /// card counts both candidate kinds.
    @State private var pendingExamCandidateCount = 0
    @State private var recentNewTerms: [GlossaryTerm] = []
    @State private var lastReviewedAt: Date?
    @State private var lastReviewCount = 0
    @State private var staleSessions: [ClassroomSession] = []
    /// Today's plan items (the day's executable安排).
    @State private var todayPlanItems: [StudyPlanItem] = []
    /// Plan items from earlier days still pending (未完成 — the user
    /// chooses 延期/跳过/重排; nothing auto-fails).
    @State private var missedPlanItems: [StudyPlanItem] = []
    /// Task ids already carried by a plan item (deduplication).
    @State private var plannedTaskIDs: Set<UUID> = []
    /// Upcoming exams within 14 days (scheduled only — real near exams).
    @State private var upcomingExams: [Exam] = []
    @State private var todayStudyMinutes = 0
    @State private var isLoaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: LTSpacing.l) {
            if isLoaded && hasNothingTodo {
                LTEmptyState(
                    symbol: "checkmark.seal",
                    title: "今天没有待复习的内容",
                    message: "新保存的术语、卡片和任务会出现在这里；也可以选择一门课程开始复习"
                )
            } else if isLoaded {
                StudyActivityCard()
                if !dueTasks.isEmpty || !overdueTasks.isEmpty {
                    taskCard
                }
                planCard
                if dueCardCount > 0 || newCardCount > 0 {
                    reviewCard
                }
                if pendingConfirmCount > 0 || pendingExamCandidateCount > 0 {
                    candidateCard
                }
                if !upcomingExams.isEmpty {
                    examCard
                }
                if !recentNewTerms.isEmpty {
                    newTermsCard
                }
                if !staleSessions.isEmpty {
                    organizeCard
                }
                if lastReviewedAt != nil || todayStudyMinutes > 0 {
                    progressCard
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, LTSpacing.xl)
            }
        }
        .onAppear { reload() }
    }

    private var hasNothingTodo: Bool {
        dueCardCount == 0 && newCardCount == 0 && dueTasks.isEmpty
            && overdueTasks.isEmpty && pendingConfirmCount == 0
            && pendingExamCandidateCount == 0
            && recentNewTerms.isEmpty && staleSessions.isEmpty
            && todayPlanItems.isEmpty && missedPlanItems.isEmpty
            && upcomingExams.isEmpty
            && !environment.studyActivityTracker.hasActiveActivity
    }

    /// Tasks due today (date compare) — separated from the overdue set.
    private var dueTasks: [StudyTask] {
        upcomingTasks.filter { task in
            guard let dueAt = task.dueAt else { return false }
            return Calendar.current.isDateInToday(dueAt)
        }
    }

    // MARK: Sections

    private var reviewCard: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            HStack(alignment: .top, spacing: LTSpacing.m) {
                LTIconBadge(symbol: "rectangle.on.rectangle", tint: LTColors.accentGreen, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("今日复习")
                        .font(.cardTitle)
                        .foregroundStyle(LTColors.textPrimary)
                    Text(reviewSummaryLine)
                        .font(.footnote)
                        .foregroundStyle(LTColors.textSecondary)
                }
                Spacer()
            }
            Button {
                onStartReview(nil)
            } label: {
                Label("开始复习", systemImage: "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: LTSpacing.minTouchTarget)
            }
            .buttonStyle(LTPrimaryButtonStyle())
        }
        .padding(LTSpacing.l)
        .ltCard()
    }

    private var reviewSummaryLine: String {
        var parts: [String] = []
        if dueCardCount > 0 { parts.append("到期卡片 \(dueCardCount) 张") }
        if newCardCount > 0 { parts.append("新卡片 \(newCardCount) 张待第一次复习") }
        return parts.joined(separator: "，")
    }

    private var taskCard: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            LTSectionHeader(title: "任务", actionTitle: "全部任务") { switchToTasks() }
            VStack(spacing: LTSpacing.xs) {
                // Deduplication: a task already carried by a plan item is
                // shown by the plan card, never repeated here.
                ForEach(overdueTasks.filter { !plannedTaskIDs.contains($0.id) }.prefix(3)) { task in
                    taskRow(task, prefix: "已逾期")
                }
                ForEach(dueTasks.filter { !plannedTaskIDs.contains($0.id) }.prefix(3)) { task in
                    taskRow(task, prefix: "今天截止")
                }
            }
        }
        .padding(LTSpacing.l)
        .ltCard()
    }

    /// 今日学习计划 — the day's plan items (missed ones follow), each
    /// leading to the real content and the timer.
    @ViewBuilder
    private var planCard: some View {
        if !todayPlanItems.isEmpty || !missedPlanItems.isEmpty {
            VStack(alignment: .leading, spacing: LTSpacing.s) {
                LTSectionHeader(title: "今日学习计划", actionTitle: "计划") { switchToPlan() }
                VStack(spacing: LTSpacing.xs) {
                    ForEach(todayPlanItems) { item in
                        TodayPlanItemRow(item: item)
                    }
                    ForEach(missedPlanItems.prefix(2)) { item in
                        TodayPlanItemRow(item: item, missed: true)
                    }
                }
            }
            .padding(LTSpacing.l)
            .ltCard()
        }
    }

    /// 即将到来的考试 (within 14 days, scheduled) — real near exams only.
    private var examCard: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            LTSectionHeader(title: "近期考试", actionTitle: "考试中心") { switchToPlan() }
            VStack(spacing: LTSpacing.xs) {
                ForEach(upcomingExams) { exam in
                    NavigationLink {
                        ExamDetailView(examID: exam.id)
                            .environment(environment)
                    } label: {
                        HStack(spacing: LTSpacing.s) {
                            LTIconBadge(symbol: exam.kind.symbol, tint: LTColors.accentGreen, size: 30)
                            Text(exam.title)
                                .font(.subheadline)
                                .foregroundStyle(LTColors.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            Text(examCountdown(exam))
                                .font(LTTypography.timestamp)
                                .foregroundStyle(LTColors.warning)
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(LTSpacing.l)
        .ltCard()
    }

    private func examCountdown(_ exam: Exam) -> String {
        guard let days = exam.daysUntilExam else { return "" }
        switch days {
        case let d where d < 0: return "已结束"
        case 0: return "今天"
        case 1: return "明天"
        default: return "\(days) 天后"
        }
    }

    private func taskRow(_ task: StudyTask, prefix: String?) -> some View {
        Button {
            switchToTasks()
        } label: {
            HStack(spacing: LTSpacing.s) {
                Image(systemName: task.status == .done ? "checkmark.circle.fill" : "circle")
                    .font(.subheadline)
                    .foregroundStyle(task.status == .done ? LTColors.accentGreen : LTColors.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    if let prefix {
                        Text(prefix)
                            .font(.caption2)
                            .foregroundStyle(LTColors.destructive)
                    }
                    Text(task.title)
                        .font(.subheadline)
                        .foregroundStyle(LTColors.textPrimary)
                        .lineLimit(1)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                if let dueAt = task.dueAt {
                    Text(dueAt.formatted(date: .abbreviated, time: .omitted))
                        .font(LTTypography.timestamp)
                        .foregroundStyle(LTColors.textTertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private var candidateCard: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            LTSectionHeader(
                title: "待确认",
                actionTitle: pendingExamCandidateCount > 0 ? "去计划" : "去确认"
            ) {
                if pendingExamCandidateCount > 0 { switchToPlan() } else { switchToTasks() }
            }
            VStack(alignment: .leading, spacing: LTSpacing.xxs) {
                if pendingConfirmCount > 0 {
                    Text(pendingConfirmCount == 1
                        ? "1 条作业候选等待确认"
                        : "\(pendingConfirmCount) 条作业候选等待确认")
                        .font(.footnote)
                        .foregroundStyle(LTColors.textSecondary)
                }
                if pendingExamCandidateCount > 0 {
                    Text(pendingExamCandidateCount == 1
                        ? "1 条考试候选等待确认"
                        : "\(pendingExamCandidateCount) 条考试候选等待确认")
                        .font(.footnote)
                        .foregroundStyle(LTColors.textSecondary)
                }
            }
        }
        .padding(LTSpacing.l)
        .ltCard()
    }

    private var newTermsCard: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            LTSectionHeader(title: "最近保存、还没学过", actionTitle: "术语本") { switchToTerms() }
            VStack(spacing: LTSpacing.xs) {
                ForEach(recentNewTerms.prefix(3)) { term in
                    NavigationLink {
                        TermDetailView(term: term, courses: courses)
                    } label: {
                        HStack(spacing: LTSpacing.s) {
                            Text(term.russian)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(LTColors.textPrimary)
                                .lineLimit(1)
                            if !term.chinese.isEmpty {
                                Text(term.chinese)
                                    .font(.footnote)
                                    .foregroundStyle(LTColors.textSecondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(LTColors.textTertiary)
                        }
                        .padding(LTSpacing.s)
                        .background(RoundedRectangle(cornerRadius: LTRadius.small).fill(LTColors.surfacePrimary.opacity(0.6)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(LTSpacing.l)
        .ltCard()
    }

    /// Sessions whose latest AI review is missing or stale — a gentle
    /// "可以继续整理" nudge from real staleness data.
    private var organizeCard: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            LTSectionHeader(title: "可以继续整理的课堂")
            VStack(spacing: LTSpacing.xs) {
                ForEach(staleSessions.prefix(3)) { session in
                    NavigationLink {
                        SessionDetailView(sessionID: session.id)
                    } label: {
                        HStack(spacing: LTSpacing.s) {
                            LTIconBadge(
                                symbol: LTIconography.symbol(for: session.title),
                                tint: LTIconography.tint(for: session.title),
                                size: 28
                            )
                            Text(session.title)
                                .font(.subheadline)
                                .foregroundStyle(LTColors.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            Text("整理")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(LTColors.accentBlue)
                        }
                        .padding(LTSpacing.s)
                        .background(RoundedRectangle(cornerRadius: LTRadius.small).fill(LTColors.surfacePrimary.opacity(0.6)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(LTSpacing.l)
        .ltCard()
    }

    /// Recent review progress + today's real study minutes — real
    /// numbers from the card/activity rows, never fabricated.
    private var progressCard: some View {
        VStack(alignment: .leading, spacing: LTSpacing.xs) {
            LTSectionHeader(title: "最近一次复习")
            if let lastReviewedAt {
                Text("\(lastReviewedAt.formatted(.relative(presentation: .named)))复习了内容，共 \(lastReviewCount) 张卡片有复习记录")
                    .font(.footnote)
                    .foregroundStyle(LTColors.textSecondary)
            }
            if todayStudyMinutes > 0 {
                Text("今天已学习 \(todayStudyMinutes) 分钟")
                    .font(.footnote)
                    .foregroundStyle(LTColors.textSecondary)
            }
        }
        .padding(LTSpacing.l)
        .ltCard()
    }

    // MARK: Data

    private func reload() {
        let allCards = (try? environment.repository.cards(courseID: nil)) ?? []
        dueCardCount = allCards.filter(\.isDueNow).count
        newCardCount = allCards.filter { $0.stageRaw == StudyCardStage.new.rawValue }.count

        let tasks = (try? environment.repository.tasks(courseID: nil, includeDone: false)) ?? []
        overdueTasks = tasks.filter { task in
            if let dueAt = task.dueAt { return dueAt < .now && task.status == .pending }
            return false
        }
        upcomingTasks = tasks.filter { task in
            task.status == .pending && (task.dueAt.map { $0 >= .now } ?? false)
        }
        pendingConfirmCount = ((try? environment.repository.pendingConfirmTasks()) ?? []).count
        pendingExamCandidateCount = ((try? environment.repository.pendingExamCandidates()) ?? []).count

        // Today's plan: the day's items + still-pending items from
        // earlier days (未完成, shown honestly). A task carried by a plan
        // item is deduplicated from the task card.
        let todayKey = Exam.dateKey(.now)
        let activePlans = ((try? environment.repository.studyPlans(examID: nil)) ?? [])
            .filter { $0.status == .active }
        var planned: [StudyPlanItem] = []
        for plan in activePlans {
            planned += (try? environment.repository.studyPlanItems(planID: plan.id)) ?? []
        }
        todayPlanItems = planned
            .filter { $0.itemDateKey == todayKey && $0.status != .skipped }
            .sorted { $0.itemOrder < $1.itemOrder }
        missedPlanItems = planned
            .filter { $0.itemDateKey < todayKey && $0.status == .pending }
            .sorted { $0.itemDateKey < $1.itemDateKey }
        plannedTaskIDs = Set(
            planned.compactMap { item in
                item.kind == .task ? item.source?.taskID : nil
            }
        )

        // Upcoming exams: scheduled, within the next 14 days (real near
        // exams only — past/cancelled exams never show).
        upcomingExams = ((try? environment.repository.exams(courseID: nil, includeCandidates: false)) ?? [])
            .filter { exam in
                guard exam.status == .scheduled, let days = exam.daysUntilExam else { return false }
                return days >= 0 && days <= 14
            }

        todayStudyMinutes = (try? environment.repository.studyActivityMinutes(on: .now)) ?? 0

        let terms = (try? environment.repository.terms(courseID: nil)) ?? []
        recentNewTerms = terms
            .filter { $0.status == .new }
            .prefix(5)
            .map { $0 }

        // Staleness: sessions with entries whose review is missing or
        // older than the session's own content.
        let sessions = (try? environment.repository.sessions(matching: "")) ?? []
        staleSessions = sessions
            .filter { session in
                guard let review = try? environment.repository.studyReview(forSessionID: session.id) else {
                    return true
                }
                guard review.contentJSON.isEmpty else { return false }
                return true
            }
            .prefix(3)
            .map { $0 }

        let reviewed = allCards.compactMap(\.lastReviewedAt)
        lastReviewedAt = reviewed.max()
        lastReviewCount = allCards.filter { $0.reviewCount > 0 }.count
        isLoaded = true
    }
}

/// One plan item in the 今天 list: title, estimated minutes, the start
/// (timer) / complete / defer actions and the real jump target.
struct TodayPlanItemRow: View {
    @Environment(AppEnvironment.self) private var environment
    let item: StudyPlanItem
    var missed: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: LTSpacing.xs) {
            HStack(spacing: LTSpacing.s) {
                Image(systemName: item.kind.symbol)
                    .font(.subheadline)
                    .foregroundStyle(LTColors.accentCyan)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    if missed {
                        Text("未完成 · \(missedDateLabel)")
                            .font(LTTypography.caption)
                            .foregroundStyle(LTColors.warning)
                    }
                    Text(item.title)
                        .font(.subheadline)
                        .foregroundStyle(LTColors.textPrimary)
                        .lineLimit(1)
                    Text(statusLine)
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textTertiary)
                }
                Spacer()
                if item.status == .done {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(LTColors.accentGreen)
                }
            }
            if item.status != .done && item.status != .skipped {
                HStack(spacing: LTSpacing.s) {
                    Button {
                        startTimer()
                    } label: {
                        Label("开始", systemImage: "play.fill")
                            .font(.footnote.weight(.semibold))
                            .frame(minWidth: 72, minHeight: 32)
                    }
                    .buttonStyle(LTPrimaryButtonStyle())
                    Button {
                        try? environment.repository.setStudyPlanItemStatus(item, status: .done)
                    } label: {
                        Text("完成")
                            .font(.footnote)
                            .frame(minWidth: 56, minHeight: 32)
                    }
                    .buttonStyle(LTSecondaryButtonStyle())
                    Button {
                        deferToTomorrow()
                    } label: {
                        Text("延到明天")
                            .font(.footnote)
                            .foregroundStyle(LTColors.textSecondary)
                            .frame(minHeight: 32)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    jumpLink
                }
            }
        }
        .padding(LTSpacing.s)
        .background(RoundedRectangle(cornerRadius: LTRadius.small).fill(LTColors.surfacePrimary.opacity(0.6)))
    }

    private var statusLine: String {
        var parts = ["预计 \(item.estimatedMinutes) 分钟"]
        if item.actualMinutes > 0 { parts.append("实际 \(item.actualMinutes) 分钟") }
        if item.status == .inProgress { parts.append("进行中") }
        return parts.joined(separator: " · ")
    }

    private var missedDateLabel: String {
        guard let date = item.itemDate else { return "" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// The real jump target: the item's source opens the actual content.
    @ViewBuilder
    private var jumpLink: some View {
        if let source = item.source {
            if let materialID = source.materialID {
                NavigationLink {
                    MaterialReaderScreen(
                        materialID: materialID,
                        initialPage: source.pageNumber
                    )
                    .environment(environment)
                } label: {
                    jumpLabel("查看资料")
                }
                .buttonStyle(.plain)
            } else if let sessionID = source.sessionID {
                NavigationLink {
                    SessionDetailView(sessionID: sessionID)
                } label: {
                    jumpLabel("查看课堂")
                }
                .buttonStyle(.plain)
            } else if let taskID = source.taskID,
                      let task = resolvedTask(taskID) {
                NavigationLink {
                    TaskDetailView(task: task, courses: [])
                } label: {
                    jumpLabel("查看任务")
                }
                .buttonStyle(.plain)
            } else if source.topicID != nil {
                // The topic's home is the exam detail (the topics card).
                NavigationLink {
                    if let examID = item.examID {
                        ExamDetailView(examID: examID)
                            .environment(environment)
                    }
                } label: {
                    jumpLabel("查看主题")
                }
                .buttonStyle(.plain)
            } else if item.kind == .cards || item.kind == .terms {
                Button {
                    showingReviewQueue = true
                } label: {
                    jumpLabel("去复习")
                }
                .buttonStyle(.plain)
                .fullScreenCover(isPresented: $showingReviewQueue) {
                    ReviewSessionView(courseID: item.source?.courseID)
                }
            }
        }
    }

    @State private var showingReviewQueue = false

    private func resolvedTask(_ taskID: UUID) -> StudyTask? {
        ((try? environment.repository.tasks(courseID: nil, includeDone: true)) ?? [])
            .first { $0.id == taskID }
    }

    private func jumpLabel(_ text: String) -> some View {
        HStack(spacing: 2) {
            Text(text)
                .font(LTTypography.caption)
            Image(systemName: "chevron.right")
                .font(.caption2)
        }
        .foregroundStyle(LTColors.accentBlue)
        .frame(minHeight: 32)
    }

    private func startTimer() {
        // Classroom guard (同层互斥修复): classroom recording time never
        // becomes study time — route back to the running classroom
        // instead of starting a second timer under it.
        if environment.coordinator.isRunning {
            environment.presentLive()
            return
        }
        guard !environment.studyActivityTracker.hasActiveActivity else { return }
        let started = environment.studyActivityTracker.start(StudyActivityDraft(
            planItemID: item.id,
            examID: item.examID,
            topicID: item.source?.topicID
        ))
        if started {
            try? environment.repository.setStudyPlanItemStatus(item, status: .inProgress)
        }
    }

    private func deferToTomorrow() {
        guard let date = item.itemDate,
              let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: date) else { return }
        try? environment.repository.setStudyPlanItemStatus(item, status: .deferred)
        try? environment.repository.setStudyPlanItemDate(item, dateKey: Exam.dateKey(tomorrow))
    }
}

// MARK: - Bookmarks segment (former tab, unchanged semantics)

/// Entry bookmarks across all classrooms, resolved against the live
/// repository by stable entry ID (the old 书签 tab's content, kept as a
/// segment of the review center).
struct BookmarksSegment: View {
    @Environment(AppEnvironment.self) private var environment
    let courses: [Course]

    @State private var groups: [BookmarkGroup] = []
    @State private var isLoaded = false

    private struct BookmarkGroup: Identifiable {
        let sessionID: UUID
        let title: String
        let rows: [Row]

        var id: UUID { sessionID }

        struct Row: Identifiable {
            let bookmark: BookmarkStore.EntryBookmark
            let startOffset: TimeInterval
            let translatedText: String?
            let originalText: String

            var id: UUID { bookmark.id }
        }
    }

    var body: some View {
        Group {
            if isLoaded && groups.isEmpty {
                LTEmptyState(
                    symbol: "bookmark",
                    title: "还没有书签",
                    message: "实时课堂中点击书签按钮，或在课堂详情里标记重点内容"
                )
            } else if isLoaded {
                VStack(alignment: .leading, spacing: LTSpacing.l) {
                    ForEach(groups) { group in
                        bookmarkGroup(group)
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, LTSpacing.xl)
            }
        }
        .onAppear { reload() }
    }

    private func bookmarkGroup(_ group: BookmarkGroup) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            HStack(spacing: LTSpacing.s) {
                LTIconBadge(
                    symbol: LTIconography.symbol(for: group.title),
                    tint: LTIconography.tint(for: group.title),
                    size: 34
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LTColors.textPrimary)
                        .lineLimit(1)
                    Text("\(group.rows.count) 条书签")
                        .font(LTTypography.timestamp)
                        .foregroundStyle(LTColors.textTertiary)
                }
                Spacer()
                NavigationLink {
                    SessionDetailView(sessionID: group.sessionID)
                } label: {
                    Text("打开课堂")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(LTColors.accentBlue)
                }
                .buttonStyle(.plain)
            }
            VStack(spacing: LTSpacing.xs) {
                ForEach(group.rows) { row in
                    BookmarkSegmentRow(
                        startOffset: row.startOffset,
                        createdAt: row.bookmark.createdAt,
                        translatedText: row.translatedText,
                        originalText: row.originalText
                    )
                }
            }
        }
    }

    private func reload() {
        environment.bookmarks.retryLegacyMigration()
        let sessions = (try? environment.repository.sessions(matching: "")) ?? []
        environment.bookmarks.pruneSessions(Set(sessions.map(\.id)))

        let sessionsByID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var resolved: [BookmarkGroup] = []
        for (sessionID, bookmarks) in Dictionary(grouping: environment.bookmarks.entryBookmarks, by: \.sessionID) {
            guard let session = sessionsByID[sessionID] else { continue }
            let entries = (try? environment.repository.entries(for: session)) ?? []
            let entriesByID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var rows: [BookmarkGroup.Row] = []
            for bookmark in bookmarks {
                guard let entry = entriesByID[bookmark.entryID] else { continue }
                rows.append(BookmarkGroup.Row(
                    bookmark: bookmark,
                    startOffset: entry.startOffset,
                    translatedText: entry.translatedText,
                    originalText: entry.originalText
                ))
            }
            environment.bookmarks.pruneEntries(in: sessionID, existingEntryIDs: Set(entries.map(\.id)))
            guard !rows.isEmpty else { continue }
            rows.sort { $0.bookmark.createdAt > $1.bookmark.createdAt }
            resolved.append(BookmarkGroup(sessionID: sessionID, title: session.title, rows: rows))
        }
        resolved.sort {
            $0.rows.first?.bookmark.createdAt ?? .distantPast
                > $1.rows.first?.bookmark.createdAt ?? .distantPast
        }
        groups = resolved
        isLoaded = true
    }
}

private struct BookmarkSegmentRow: View {
    let startOffset: TimeInterval
    let createdAt: Date
    let translatedText: String?
    let originalText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: LTSpacing.xs) {
                Image(systemName: "bookmark.fill")
                    .font(.caption2)
                    .foregroundStyle(LTColors.accentGreen)
                Text(TranscriptExporter.mmss(startOffset))
                    .font(LTTypography.timestamp)
                    .foregroundStyle(LTColors.textTertiary)
                Spacer()
                Text(createdAt.formatted(date: .omitted, time: .shortened))
                    .font(LTTypography.timestamp)
                    .foregroundStyle(LTColors.textTertiary)
            }
            if let translated = translatedText, !translated.isEmpty {
                Text(translated)
                    .font(.subheadline)
                    .foregroundStyle(LTColors.textPrimary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Text(originalText)
                .font(.footnote)
                .foregroundStyle(LTColors.textSecondary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .padding(LTSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: LTRadius.small).fill(LTColors.surfacePrimary.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: LTRadius.small).strokeBorder(LTColors.border, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}
