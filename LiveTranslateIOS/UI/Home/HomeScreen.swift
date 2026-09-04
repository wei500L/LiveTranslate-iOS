import SwiftUI

/// Home tab (reference image 1): brand header, greeting, start-classroom
/// card, real readiness state, recent classrooms and study statistics.
struct HomeScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var viewModel = HomeViewModel()
    @State private var showNewSessionSheet = false
    @State private var showModelManagement = false
    /// 待阅读资料 push (the restrained materials entry).
    @State private var pushingMaterials = false
    /// 智能收件箱 push (only while unprocessed items exist).
    @State private var pushingInbox = false
    /// Course to preselect in the new-classroom sheet (quick start fall-
    /// back when the one-tap path is not safe).
    @State private var pendingCourse: Course?
    /// The pre-class layer: next-class card + reminder-tap routing.
    @State private var scheduleViewModel = ScheduleViewModel()
    @State private var pendingExtraStart: ScheduleCalculator.Occurrence?
    @State private var minuteTimer: Timer?

    var body: some View {
        NavigationStack {
            LTPage {
                ScrollView {
                    VStack(spacing: LTSpacing.l) {
                        header
                        if viewModel.hasOngoingSession && !environment.flow.isLivePresented {
                            ongoingBanner
                        }
                        startCard
                        if environment.inbox.pendingCount > 0 {
                            inboxSection
                        }
                        if scheduleViewModel.isLoaded, scheduleViewModel.nextOccurrence != nil {
                            nextClassSection
                        }
                        if let exam = nextExam {
                            nextExamSection(exam)
                        }
                        quickStartSection
                        statusSection
                        if viewModel.isLoaded && viewModel.hasTodayReview {
                            todayReviewSection
                        }
                        if viewModel.isLoaded && viewModel.unreadMaterialCount > 0 {
                            unreadMaterialsSection
                        }
                        recentSection
                        statsSection
                    }
                    .padding(.horizontal, LTSpacing.screenPadding)
                    .padding(.top, LTSpacing.s)
                    .padding(.bottom, LTSpacing.xl)
                }
            }
            .sheet(isPresented: $showNewSessionSheet) {
                NewSessionSheet(preselectedCourse: pendingCourse)
                    .environment(environment)
                    .onDisappear { pendingCourse = nil }
            }
            .navigationDestination(isPresented: $showModelManagement) {
                ModelManagementScreen()
            }
            .navigationDestination(for: ScheduleRoute.self) { route in
                ScheduleScreen()
            }
            .confirmationDialog(
                "这堂课已有课堂记录",
                isPresented: Binding(
                    get: { pendingExtraStart != nil },
                    set: { if !$0 { pendingExtraStart = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("再开一堂") {
                    if let occurrence = pendingExtraStart {
                        Task { await scheduleViewModel.startOccurrence(occurrence, force: true) }
                    }
                    pendingExtraStart = nil
                }
                Button("取消", role: .cancel) { pendingExtraStart = nil }
            } message: {
                Text("该日程已关联一堂结束的课堂。是否为同一次课再创建一堂记录？")
            }
        }
        .task {
            viewModel.attach(environment)
            scheduleViewModel.attach(environment)
            #if DEBUG
            if let greeting = environment.flow.demoGreeting {
                viewModel.greetingOverride = greeting
            }
            #endif
            await viewModel.reload()
            await scheduleViewModel.reload()
            consumePendingReminder()
        }
        .onAppear {
            // Tab switches destroy this view; refresh readiness + recents
            // (e.g. right after a classroom ended) and the next class.
            #if DEBUG
            if environment.flow.pendingDemoScreen == .newSession {
                environment.flow.pendingDemoScreen = nil
                showNewSessionSheet = true
            }
            #endif
            startMinuteTimer()
            environment.inbox.reload()
            // Inbox item routes are consumed on every appear (the route
            // may arrive while home is already alive, e.g. from a detail
            // view's 收件箱分享 jump) — consume-once by flag.
            consumeInboxRoute()
            Task { await viewModel.reload() }
            Task { await scheduleViewModel.reload() }
        }
        .onDisappear {
            minuteTimer?.invalidate()
            minuteTimer = nil
        }
        // Network reachability is live state (the coordinator owns the
        // monitor); the readiness card must follow it instead of showing
        // the launch-time snapshot forever.
        .onChange(of: environment.coordinator.isNetworkAvailable) { _, _ in
            Task { await viewModel.reload() }
        }
    }

    // MARK: - Next class (下一堂课)

    /// The reminder-tap route target: AppFlow parks the tapped
    /// occurrence key; HomeScreen resolves it and runs the same
    /// controlled start chain. Consume-once.
    private func consumePendingReminder() {
        if let key = environment.flow.pendingClassOccurrenceKey {
            environment.flow.consumeClassReminder()
            if let occurrence = scheduleViewModel.occurrences.first(where: {
                $0.occurrenceKey == key
            }) {
                Task {
                    let fallback = await scheduleViewModel.startOccurrence(occurrence)
                    if fallback != nil, case .finishedSession = scheduleViewModel.startState(for: occurrence) {
                        pendingExtraStart = occurrence
                    }
                }
            }
            // An unresolvable key (schedule deleted, out of window) just
            // lands on the home tab — the next-class card is visible.
        }
    }

    private var nextClassSection: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            LTSectionHeader(title: "下一堂课")
            if let next = scheduleViewModel.nextOccurrence {
                ScheduleOccurrenceCard(
                    occurrence: next,
                    courseName: scheduleViewModel.course(for: next)?.name ?? "课程",
                    teacher: scheduleViewModel.teacher(for: next),
                    location: scheduleViewModel.location(for: next),
                    colorIndex: scheduleViewModel.course(for: next)?.colorIndex ?? 0,
                    relativeLabel: scheduleViewModel.relativeLabel(for: next),
                    startState: scheduleViewModel.startState(for: next),
                    isNext: true,
                    onStart: { startNext(next) },
                    onOpenSchedule: nil
                )
                // Course-task linkage: unfinished tasks of this course.
                let openTasks = scheduleViewModel.openTaskCount(for: next)
                if openTasks > 0 {
                    HStack(spacing: LTSpacing.xs) {
                        Image(systemName: "checklist")
                            .font(.system(size: 11))
                        Text("本课程有 \(openTasks) 项未完成作业")
                            .font(LTTypography.caption)
                        Spacer()
                        Button("查看") {
                            environment.flow.selectedTab = .review
                        }
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.accentGreen)
                        .buttonStyle(.plain)
                    }
                    .foregroundStyle(LTColors.textSecondary)
                }
                NavigationLink(value: ScheduleRoute.timetable) {
                    Text("查看课程表")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func startNext(_ occurrence: ScheduleCalculator.Occurrence) {
        Task {
            let fallback = await scheduleViewModel.startOccurrence(occurrence)
            if fallback != nil, case .finishedSession = scheduleViewModel.startState(for: occurrence) {
                pendingExtraStart = occurrence
            }
        }
    }

    /// An internal route asked for one inbox item (e.g. the review
    /// center's 今天 segment): push the inbox and open that item.
    /// Consume-once.
    private func consumeInboxRoute() {
        guard let id = environment.flow.pendingInboxItemID else { return }
        environment.flow.consumeInboxItemRoute()
        environment.inbox.reload()
        pendingInboxItemID = id
        pushingInbox = true
    }

    /// Inbox item pushed from a route (in addition to the section's own
    /// push binding).
    @State private var pendingInboxItemID: UUID?

    /// Minute-level refresh for the next-class relative label.
    private func startMinuteTimer() {
        minuteTimer?.invalidate()
        minuteTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in scheduleViewModel.tick() }
        }
    }

    // MARK: - Next exam (下一场考试 — real near exams only)

    /// The nearest scheduled exam within 14 days (real rows only — none
    /// in that window, no card).
    private var nextExam: Exam? {
        let exams = (try? environment.repository.exams(
            courseID: nil, includeCandidates: false
        )) ?? []
        return exams
            .filter { exam in
                guard exam.status == .scheduled, let days = exam.daysUntilExam else { return false }
                return days >= 0 && days <= 14
            }
            .min { lhs, rhs in
                (lhs.examDate ?? .distantFuture) < (rhs.examDate ?? .distantFuture)
            }
    }

    private func nextExamSection(_ exam: Exam) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            LTSectionHeader(title: "下一场考试")
            NavigationLink {
                ExamDetailView(examID: exam.id)
                    .environment(environment)
            } label: {
                HStack(spacing: LTSpacing.m) {
                    LTIconBadge(symbol: exam.kind.symbol, tint: LTColors.accentGreen, size: 38)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(exam.title)
                            .font(.cardTitle)
                            .foregroundStyle(LTColors.textPrimary)
                            .lineLimit(1)
                        Text(examSubtitle(exam))
                            .font(LTTypography.caption)
                            .foregroundStyle(LTColors.textSecondary)
                    }
                    Spacer()
                    Text(examCountdown(exam))
                        .font(.system(.headline, design: .rounded).monospacedDigit())
                        .foregroundStyle(LTColors.warning)
                }
                .ltCard()
            }
            .buttonStyle(.plain)
        }
    }

    private func examSubtitle(_ exam: Exam) -> String {
        var parts: [String] = [exam.kind.displayName]
        if let date = exam.examDate {
            parts.append(date.formatted(date: .abbreviated, time: .omitted))
        }
        if !exam.location.isEmpty { parts.append(exam.location) }
        return parts.joined(separator: " · ")
    }

    private func examCountdown(_ exam: Exam) -> String {
        guard let days = exam.daysUntilExam else { return "" }
        switch days {
        case 0: return "今天"
        case 1: return "明天"
        default: return "\(days) 天"
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: LTSpacing.xs) {
                        Text("LiveTranslate")
                            .font(LTTypography.pageTitle)
                            .foregroundStyle(LTColors.textPrimary)
                        // Real state, not decoration: the chip only shows
                        // while a recognition runtime is actually installed.
                        if viewModel.isLoaded && viewModel.anyBackendInstalled {
                            StatusChip(text: "本地模式", tint: LTColors.accentGreen)
                        }
                    }
                    Text(viewModel.greetingSubtitle)
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textTertiary)
                }
                Spacer()
                NavigationLink {
                    SettingsScreen(embedsInStack: false)
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(LTColors.textSecondary)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(LTColors.surfacePrimary))
                        .overlay(Circle().strokeBorder(LTColors.border, lineWidth: 0.5))
                        .frame(width: LTSpacing.minTouchTarget, height: LTSpacing.minTouchTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text("设置"))
            }
            Text(viewModel.greeting)
                .font(.system(.largeTitle, design: .default).weight(.bold))
                .foregroundStyle(LTColors.textPrimary)
        }
    }

    // MARK: - Today's review (only with real pending content)

    /// Restrained home entry into the review center: real numbers, only
    /// visible when there is something to do.
    private var todayReviewSection: some View {
        Button {
            environment.flow.selectedTab = .review
        } label: {
            VStack(alignment: .leading, spacing: LTSpacing.s) {
                HStack(spacing: LTSpacing.m) {
                    LTIconBadge(symbol: "graduationcap.fill", tint: LTColors.accentGreen, size: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("今日复习")
                            .font(.cardTitle)
                            .foregroundStyle(LTColors.textPrimary)
                        Text(viewModel.todayReviewSummary)
                            .font(.footnote)
                            .foregroundStyle(LTColors.textSecondary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(LTColors.textTertiary)
                }
            }
            .padding(LTSpacing.l)
            .ltCard()
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("打开复习中心"))
    }

    /// 待阅读资料 — a restrained entry that only exists when imported
    /// materials have never been opened. Tapping opens the global
    /// material library (全部资料) via the records tab's push.
    private var unreadMaterialsSection: some View {
        Button {
            pushingMaterials = true
        } label: {
            VStack(alignment: .leading, spacing: LTSpacing.s) {
                HStack(spacing: LTSpacing.m) {
                    LTIconBadge(symbol: "books.vertical", tint: LTColors.accentBlue, size: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("待阅读资料")
                            .font(.cardTitle)
                            .foregroundStyle(LTColors.textPrimary)
                        Text("\(viewModel.unreadMaterialCount) 份资料还没有读过")
                            .font(.footnote)
                            .foregroundStyle(LTColors.textSecondary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(LTColors.textTertiary)
                }
            }
            .padding(LTSpacing.l)
            .ltCard()
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("打开课程资料库"))
        .navigationDestination(isPresented: $pushingMaterials) {
            CourseMaterialLibraryScreen(courseID: nil)
                .environment(environment)
        }
    }

    // MARK: - Shared inbox (智能收件箱 — only while items need work)

    /// The inbox entry exists ONLY when there are unprocessed shared
    /// items (the same restraint as 待阅读资料): empty inbox, no card.
    private var inboxSection: some View {
        Button {
            pushingInbox = true
        } label: {
            VStack(alignment: .leading, spacing: LTSpacing.s) {
                HStack(spacing: LTSpacing.m) {
                    LTIconBadge(symbol: "tray.full", tint: LTColors.accentCyan, size: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("收件箱")
                            .font(.cardTitle)
                            .foregroundStyle(LTColors.textPrimary)
                        Text("有 \(environment.inbox.pendingCount) 项分享待整理")
                            .font(.footnote)
                            .foregroundStyle(LTColors.textSecondary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(LTColors.textTertiary)
                }
            }
            .padding(LTSpacing.l)
            .ltCard()
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("打开收件箱整理分享内容"))
        .navigationDestination(isPresented: $pushingInbox) {
            InboxScreen(initialItemID: pendingInboxItemID)
                .environment(environment)
        }
    }

    // MARK: - Ongoing banner

    @ViewBuilder
    private var ongoingBanner: some View {
        if viewModel.hasOngoingSession && !environment.flow.isLivePresented {
            Button {
                environment.presentLive()
            } label: {
                HStack(spacing: LTSpacing.s) {
                    LTActivityDot(active: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("课堂进行中")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(LTColors.textPrimary)
                        Text(
                            "\(environment.coordinator.state.phase.localizedLabel) · 已进行 \(Format.clock(environment.coordinator.state.elapsed))"
                        )
                        .font(LTTypography.timestamp)
                        .foregroundStyle(LTColors.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(LTColors.accentGreen)
                }
                .ltCard()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("课堂进行中，点击回到课堂"))
        }
    }

    // MARK: - Start card

    private var startCard: some View {
        Button {
            if viewModel.hasOngoingSession {
                environment.presentLive()
            } else {
                showNewSessionSheet = true
            }
        } label: {
            HStack(spacing: LTSpacing.m) {
                micIcon
                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.hasOngoingSession ? "回到课堂" : "开始新课堂")
                        .font(LTTypography.cardTitle)
                        .foregroundStyle(LTColors.textPrimary)
                    Text("实时翻译 · 语音转写 · 双语对照")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textSecondary)
                }
                Spacer()
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(LTColors.accentGreen.opacity(0.9))
            }
            .ltCard(padding: LTSpacing.l)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("开始新课堂"))
    }

    /// Mic glyph in a green-tinted circle. A single static glow shadow —
    /// no animation loop, so it never competes with GPU work.
    private var micIcon: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(LTColors.accentGreen)
            .frame(width: 52, height: 52)
            .background(
                Circle().fill(
                    LinearGradient(
                        colors: [LTColors.accentGreen.opacity(0.28), LTColors.accentGreen.opacity(0.12)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
            )
            .overlay(Circle().strokeBorder(LTColors.accentGreen.opacity(0.35), lineWidth: 0.5))
            .shadow(color: LTColors.accentGreen.opacity(0.30), radius: 9)
    }

    // MARK: - Quick start (courses)

    /// Recurring courses, one tap away. Only rendered when the user has
    /// actually created courses — a fresh install sees nothing new here.
    @ViewBuilder
    private var quickStartSection: some View {
        if !viewModel.quickStartCourses.isEmpty {
            VStack(alignment: .leading, spacing: LTSpacing.s) {
                LTSectionHeader(title: "快捷开课")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: LTSpacing.s) {
                        ForEach(viewModel.quickStartCourses, id: \.id) { course in
                            quickStartChip(course)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }

    private func quickStartChip(_ course: Course) -> some View {
        Button {
            Task {
                if let fallback = await viewModel.quickStart(course) {
                    pendingCourse = fallback
                    showNewSessionSheet = true
                }
            }
        } label: {
            HStack(spacing: LTSpacing.s) {
                LTIconBadge(
                    symbol: LTIconography.symbol(for: course.name),
                    tint: LTCoursePalette.color(course.colorIndex),
                    size: 34
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(course.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(LTColors.textPrimary)
                        .lineLimit(1)
                    if !course.teacherName.isEmpty {
                        Text(course.teacherName)
                            .font(LTTypography.timestamp)
                            .foregroundStyle(LTColors.textTertiary)
                            .lineLimit(1)
                    }
                }
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(LTColors.accentGreen.opacity(0.85))
            }
            .padding(LTSpacing.m)
            .background(RoundedRectangle(cornerRadius: LTRadius.medium).fill(LTColors.surfacePrimary.opacity(0.85)))
            .overlay(RoundedRectangle(cornerRadius: LTRadius.medium).strokeBorder(LTColors.border, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("开始\(course.name)课堂"))
        .accessibilityHint(Text("双击直接开始这堂课"))
    }

    // MARK: - Status

    private var statusSection: some View {
        let items = viewModel.readinessItems
        return VStack(alignment: .leading, spacing: LTSpacing.s) {
            LTSectionHeader(title: "当前状态")
            VStack(spacing: 0) {
                HStack {
                    if viewModel.isLoaded && viewModel.isFullyReady
                        && environment.coordinator.isNetworkAvailable {
                        Label("全部就绪", systemImage: "checkmark.seal.fill")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(LTColors.accentGreen)
                    } else {
                        Label("尚未全部就绪", systemImage: "exclamationmark.circle")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(LTColors.warning)
                    }
                    Spacer()
                }
                .padding(.horizontal, LTSpacing.m)
                .padding(.top, LTSpacing.m)
                .padding(.bottom, LTSpacing.xs)

                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    readinessRow(item)
                    if index < items.count - 1 {
                        Divider()
                            .overlay(LTColors.separator)
                            .padding(.leading, LTSpacing.l)
                    }
                }
                .padding(.bottom, LTSpacing.s)
            }
            .ltCard(padding: 0)
        }
    }

    private func readinessRow(_ item: HomeViewModel.ReadinessItem) -> some View {
        Button {
            switch item.action {
            case .modelManagement:
                showModelManagement = true
            case .systemSettings:
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            case .translationSettings:
                // Land on the 我的 tab, where the translation API
                // section lives.
                environment.flow.selectedTab = .profile
            case nil:
                break
            }
        } label: {
            HStack(spacing: LTSpacing.s) {
                statusDot(item.state)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.subheadline)
                        .foregroundStyle(LTColors.textPrimary)
                    Text(item.detail)
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textSecondary)
                }
                Spacer()
                if item.action != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(LTColors.textTertiary)
                }
            }
            .padding(.horizontal, LTSpacing.m)
            .padding(.vertical, LTSpacing.xs + 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(item.action == nil)
        .accessibilityHint(item.action == nil ? Text("") : Text("双击前往处理"))
    }

    private func statusDot(_ state: HomeViewModel.ReadinessItem.State) -> some View {
        let tint: Color = switch state {
        case .ok: LTColors.accentGreen
        case .warning: LTColors.warning
        case .unavailable: LTColors.destructive
        }
        return Image(systemName: state == .ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .font(.system(size: 16))
            .foregroundStyle(tint)
    }

    // MARK: - Recent

    @ViewBuilder
    private var recentSection: some View {
        if !viewModel.recentSessions.isEmpty {
            VStack(alignment: .leading, spacing: LTSpacing.s) {
                LTSectionHeader(title: "最近课堂")
                VStack(spacing: LTSpacing.s) {
                    ForEach(viewModel.recentSessions) { summary in
                        NavigationLink {
                            SessionDetailView(sessionID: summary.id)
                        } label: {
                            recentRow(summary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func recentRow(_ summary: HomeViewModel.SessionSummary) -> some View {
        HStack(spacing: LTSpacing.m) {
            LTIconBadge(
                symbol: LTIconography.symbol(for: summary.title),
                tint: LTIconography.tint(for: summary.title),
                size: 38
            )
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: LTSpacing.xs) {
                    Text(summary.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(LTColors.textPrimary)
                        .lineLimit(1)
                    if summary.abnormalTermination {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(LTColors.warning)
                            .accessibilityLabel(Text("异常终止"))
                    }
                }
                HStack(spacing: LTSpacing.xs) {
                    Text(Format.date(summary.startTime))
                    Text(Format.clock(summary.duration))
                    Text("\(summary.entryCount) 段")
                }
                .font(LTTypography.timestamp)
                .foregroundStyle(LTColors.textTertiary)
            }
            Spacer()
            if summary.hasFailedTranslations {
                Text("部分翻译失败")
                    .font(LTTypography.timestamp)
                    .foregroundStyle(LTColors.warning)
            }
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(LTColors.textTertiary)
        }
        .ltCard()
        .accessibilityElement(children: .combine)
    }

    // MARK: - Stats

    @ViewBuilder
    private var statsSection: some View {
        if viewModel.isLoaded {
            VStack(alignment: .leading, spacing: LTSpacing.s) {
                LTSectionHeader(title: "今日学习")
                if viewModel.weekSessionCount == 0 && viewModel.todayTotalSeconds < 1 {
                    LTEmptyState(
                        symbol: "chart.bar",
                        title: "还没有学习记录",
                        message: "完成第一堂课后，这里会展示今日时长与近七天的分布"
                    )
                } else {
                    VStack(spacing: LTSpacing.m) {
                        HStack(spacing: LTSpacing.l) {
                            statTile(
                                value: Format.studyDuration(viewModel.todayTotalSeconds),
                                caption: "今日累计时长"
                            )
                            statTile(
                                value: "\(viewModel.weekSessionCount)",
                                caption: "本周课堂"
                            )
                            Spacer(minLength: 0)
                        }
                        weekBars
                    }
                    .ltCard()
                }
            }
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

    /// Simple 7-day distribution (oldest → today) from real session
    /// durations. No data renders as minimal baseline bars.
    private var weekBars: some View {
        let labels = viewModel.dailyLabels
        return HStack(alignment: .bottom, spacing: 10) {
            ForEach(0..<7, id: \.self) { index in
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(
                            index == 6
                                ? LTColors.accentGreen.opacity(0.9)
                                : LTColors.accentCyan.opacity(0.35)
                        )
                        .frame(width: 22, height: barHeight(index))
                    Text(labels[index])
                        .font(.system(size: 9))
                        .foregroundStyle(LTColors.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("\(labels[index]) \(Int(viewModel.dailyMinutes[index].rounded())) 分钟"))
            }
        }
        .frame(height: 64)
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let minutes = index < viewModel.dailyMinutes.count ? viewModel.dailyMinutes[index] : 0
        let fraction = max(0.08, minutes / viewModel.maxDailyMinutes)
        return 40 * fraction
    }
}
