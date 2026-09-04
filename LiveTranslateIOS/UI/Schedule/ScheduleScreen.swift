import SwiftUI

/// Navigation route values into the timetable (from the home next-class
/// card and the course list).
enum ScheduleRoute: Hashable {
    case timetable
}

/// 课程表: today / this-week views of computed occurrences. Not a dense
/// grid — a reading list grouped by day, with the next class prominent,
/// cancelled/adjusted states as TEXT (never color-only), and the same
/// controlled start chain the home screen uses. Reached from the course
/// list (no new bottom tab).
struct ScheduleScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = ScheduleViewModel()
    @State private var mode: Mode = .today
    @State private var showAddSheet = false
    /// 创建考试 sheet (the exam entry on the timetable).
    @State private var showingExamForm = false
    @State private var showImageImport = false
    @State private var shareItem: SharedFile?
    /// Finished-session prompt target (创建额外课堂 flow).
    @State private var pendingExtraStart: ScheduleCalculator.Occurrence?
    @State private var minuteTimer: Timer?
    /// 课前资料 of the tapped next class (sheet target).
    @State private var preClassMaterials: [CourseMaterial] = []

    enum Mode: String, CaseIterable, Identifiable {
        case today
        case week

        var id: String { rawValue }

        var title: String {
            switch self {
            case .today: return "今天"
            case .week: return "本周"
            }
        }
    }

    var body: some View {
        LTPage {
            Group {
                if !viewModel.isLoaded {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.schedules.isEmpty {
                    emptyState
                } else {
                    content
                }
            }
        }
        .navigationTitle("课程表")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showAddSheet = true
                    } label: {
                        Label("手动添加日程", systemImage: "plus")
                    }
                    Button {
                        showImageImport = true
                    } label: {
                        Label("从课表图片导入", systemImage: "photo.on.rectangle")
                    }
                    Button {
                        showingExamForm = true
                    } label: {
                        Label("创建考试", systemImage: "graduationcap")
                    }
                    Button {
                        exportICS()
                    } label: {
                        Label("导出 .ics 日历", systemImage: "calendar.badge.arrow.up")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(LTColors.textSecondary)
                }
                .accessibilityLabel(Text("课程表操作"))
            }
        }
        .task {
            viewModel.attach(environment)
            await viewModel.reload()
            weekExams = (try? environment.repository.exams(
                courseID: nil, includeCandidates: false
            )) ?? []
        }
        .onAppear {
            startMinuteTimer()
        }
        .onDisappear {
            minuteTimer?.invalidate()
            minuteTimer = nil
        }
        .sheet(isPresented: $showAddSheet) {
            NavigationStack {
                ScheduleFormView(courses: viewModel.courses)
                    .environment(environment)
            }
        }
        .sheet(isPresented: $showImageImport) {
            NavigationStack {
                ScheduleImageImportView(courses: viewModel.courses)
                    .environment(environment)
            }
        }
        .sheet(isPresented: $showingExamForm) {
            NavigationStack {
                ExamFormScreen(preselectedCourseID: nil, editing: nil)
                    .environment(environment)
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .sheet(isPresented: Binding(
            get: { !preClassMaterials.isEmpty },
            set: { if !$0 { preClassMaterials = [] } }
        )) {
            NavigationStack {
                LTPage {
                    ScrollView {
                        VStack(spacing: LTSpacing.s) {
                            ForEach(preClassMaterials) { material in
                                NavigationLink {
                                    MaterialReaderScreen(materialID: material.id)
                                        .environment(environment)
                                } label: {
                                    MaterialRow(material: material)
                                }
                                .buttonStyle(.plain)
                                .ltCard(padding: LTSpacing.m)
                            }
                        }
                        .padding(.horizontal, LTSpacing.screenPadding)
                        .padding(.top, LTSpacing.s)
                    }
                }
                .navigationTitle("课前资料")
                .navigationBarTitleDisplayMode(.inline)
            }
            .environment(environment)
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
                    forceStartOccurrence(occurrence)
                }
                pendingExtraStart = nil
            }
            Button("取消", role: .cancel) { pendingExtraStart = nil }
        } message: {
            Text("该日程已关联一堂结束的课堂。是否为同一次课再创建一堂记录？")
        }
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(spacing: LTSpacing.l) {
                modePicker
                if let next = viewModel.nextOccurrence, mode == .today {
                    nextClassCard(next)
                }
                switch mode {
                case .today:
                    todayList
                case .week:
                    weekList
                }
            }
            .padding(.horizontal, LTSpacing.screenPadding)
            .padding(.top, LTSpacing.s)
            .padding(.bottom, 90)
        }
        .refreshable {
            await viewModel.reload()
        }
    }

    private var modePicker: some View {
        HStack(spacing: LTSpacing.s) {
            ForEach(Mode.allCases) { candidate in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { mode = candidate }
                } label: {
                    Text(candidate.title)
                        .font(.subheadline.weight(mode == candidate ? .semibold : .regular))
                        .foregroundStyle(mode == candidate ? Color.black.opacity(0.85) : LTColors.textSecondary)
                        .padding(.horizontal, LTSpacing.l)
                        .padding(.vertical, LTSpacing.xs + 2)
                        .background(Capsule().fill(mode == candidate ? LTColors.accentGreen : LTColors.surfaceElevated))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(candidate.title))
            }
            Spacer()
        }
    }

    /// The next class — prominent, with the start button. 课前资料 shows
    /// when materials are linked to this occurrence; reading them never
    /// touches the recording chain.
    private func nextClassCard(_ occurrence: ScheduleCalculator.Occurrence) -> some View {
        ScheduleOccurrenceCard(
            occurrence: occurrence,
            courseName: viewModel.course(for: occurrence)?.name ?? "课程",
            teacher: viewModel.teacher(for: occurrence),
            location: viewModel.location(for: occurrence),
            colorIndex: viewModel.course(for: occurrence)?.colorIndex ?? 0,
            relativeLabel: viewModel.relativeLabel(for: occurrence),
            startState: viewModel.startState(for: occurrence),
            isNext: true,
            onStart: { start(occurrence) },
            onOpenSchedule: nil,
            preClassMaterialCount: preClassMaterialCount(for: occurrence),
            onOpenPreClassMaterials: { openPreClassMaterials(for: occurrence) }
        )
    }

    /// Materials linked to one occurrence (课前资料) — a repository read,
    /// no materialization.
    private func preClassMaterialCount(for occurrence: ScheduleCalculator.Occurrence) -> Int {
        ((try? environment.repository.materials(occurrenceKey: occurrence.occurrenceKey)) ?? [])
            .count
    }

    /// Opens the occurrence's 课前资料 in the reader (first material; the
    /// library's filter handles the rest).
    private func openPreClassMaterials(for occurrence: ScheduleCalculator.Occurrence) {
        preClassMaterials = (try? environment.repository.materials(
            occurrenceKey: occurrence.occurrenceKey
        )) ?? []
    }

    private var todayList: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            LTSectionHeader(title: "今日课程")
            if viewModel.todayOccurrences.isEmpty {
                Text("今天没有课")
                    .font(LTTypography.body)
                    .foregroundStyle(LTColors.textTertiary)
                    .ltCard()
            } else {
                VStack(spacing: LTSpacing.s) {
                    ForEach(viewModel.todayOccurrences) { occurrence in
                        occurrenceRow(occurrence)
                    }
                }
            }
        }
    }

    private var weekList: some View {
        VStack(alignment: .leading, spacing: LTSpacing.m) {
            LTSectionHeader(title: "本周课程")
            if viewModel.occurrences.isEmpty {
                Text("本周没有课")
                    .font(LTTypography.body)
                    .foregroundStyle(LTColors.textTertiary)
                    .ltCard()
            } else {
                ForEach(viewModel.weekDays, id: \.day) { group in
                    if !group.items.isEmpty || !exams(on: group.day).isEmpty {
                        VStack(alignment: .leading, spacing: LTSpacing.s) {
                            HStack(spacing: LTSpacing.s) {
                                Text(Self.dayLabel(group.day))
                                    .font(LTTypography.cardTitle)
                                    .foregroundStyle(LTColors.textPrimary)
                                if !exams(on: group.day).isEmpty {
                                    // 考试标记 — visually distinct from
                                    // class occurrences (different symbol
                                    // + chip, never a mixed row).
                                    Label(
                                        exams(on: group.day).count == 1 ? "1 场考试" : "\(exams(on: group.day).count) 场考试",
                                        systemImage: "graduationcap.fill"
                                    )
                                    .font(LTTypography.caption)
                                    .foregroundStyle(LTColors.warning)
                                }
                            }
                            VStack(spacing: LTSpacing.s) {
                                ForEach(group.items) { occurrence in
                                    occurrenceRow(occurrence)
                                }
                                ForEach(exams(on: group.day)) { exam in
                                    examMarker(exam)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func occurrenceRow(_ occurrence: ScheduleCalculator.Occurrence) -> some View {
        ScheduleOccurrenceCard(
            occurrence: occurrence,
            courseName: viewModel.course(for: occurrence)?.name ?? "课程",
            teacher: viewModel.teacher(for: occurrence),
            location: viewModel.location(for: occurrence),
            colorIndex: viewModel.course(for: occurrence)?.colorIndex ?? 0,
            relativeLabel: viewModel.relativeLabel(for: occurrence),
            startState: viewModel.startState(for: occurrence),
            isNext: false,
            onStart: { start(occurrence) },
            onOpenSchedule: nil
        )
    }

    // MARK: - Exam markers (课程表上的考试 — distinct from classes)

    /// Scheduled exams on one calendar day.
    @State private var weekExams: [Exam] = []

    private func exams(on day: Date) -> [Exam] {
        let key = Exam.dateKey(day)
        return weekExams.filter { $0.examDateKey == key && $0.status == .scheduled }
    }

    /// One exam marker row — clearly an exam (not a class occurrence):
    /// its own symbol, chip and no start button.
    private func examMarker(_ exam: Exam) -> some View {
        NavigationLink {
            ExamDetailView(examID: exam.id)
                .environment(environment)
        } label: {
            HStack(spacing: LTSpacing.m) {
                LTIconBadge(symbol: exam.kind.symbol, tint: LTColors.warning, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: LTSpacing.xs) {
                        Text(exam.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(LTColors.textPrimary)
                            .lineLimit(1)
                        StatusChip(text: "考试", tint: LTColors.warning)
                    }
                    Text(exam.hasTime
                        ? String(format: "%02d:%02d 开始", exam.startSecs / 3600, (exam.startSecs % 3600) / 60)
                        : "时间待定")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(LTColors.textTertiary)
            }
            .padding(LTSpacing.m)
            .ltCard()
        }
        .buttonStyle(.plain)
    }

    /// The controlled start entry (also the finished-session prompt).
    private func start(_ occurrence: ScheduleCalculator.Occurrence) {
        Task {
            let fallback = await viewModel.startOccurrence(occurrence)
            if fallback != nil, case .finishedSession = viewModel.startState(for: occurrence) {
                // The view model declined silently because a finished
                // session exists — surface the prompt.
                pendingExtraStart = occurrence
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: LTSpacing.l) {
            LTEmptyState(
                symbol: "calendar",
                title: "还没有课程表",
                message: "添加固定日程后，会在这里看到每天的课程"
            )
            VStack(spacing: LTSpacing.s) {
                Button {
                    showAddSheet = true
                } label: {
                    Label("手动添加日程", systemImage: "plus")
                        .font(LTTypography.button)
                        .foregroundStyle(Color.black.opacity(0.85))
                        .frame(maxWidth: .infinity, minHeight: LTSpacing.minTouchTarget)
                }
                .buttonStyle(LTPrimaryButtonStyle())
                Button {
                    showImageImport = true
                } label: {
                    Label("从课表图片导入", systemImage: "photo.on.rectangle")
                        .font(LTTypography.button)
                        .foregroundStyle(LTColors.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: LTSpacing.minTouchTarget)
                }
                .buttonStyle(LTSecondaryButtonStyle())
            }
            .padding(.horizontal, LTSpacing.xl)
        }
    }

    // MARK: - Timer & helpers

    /// Minute-level refresh for relative labels (no per-second countdown).
    private func startMinuteTimer() {
        minuteTimer?.invalidate()
        minuteTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in viewModel.tick() }
        }
    }

    private static func dayLabel(_ day: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        if Calendar.current.isDateInToday(day) {
            return "今天 · " + formatter.weekdaySymbols[Calendar.current.component(.weekday, from: day) - 1]
        }
        formatter.dateFormat = "M月d日 EEE"
        return formatter.string(from: day)
    }

    // MARK: - Export

    private func exportICS() {
        let exporter = ScheduleICSExporter(
            schedules: viewModel.schedules,
            exceptions: viewModel.exceptions,
            courses: viewModel.courses
        )
        if let url = exporter.writeTemporaryFile() {
            shareItem = SharedFile(url: url)
        }
    }
}

/// One occurrence card — the shared row of the timetable, the home
/// next-class area and (compact) the course detail. Status is TEXT, never
/// color-only: 停课 / 调课 / 正在上课 / 已结束 all render literally.
struct ScheduleOccurrenceCard: View {
    let occurrence: ScheduleCalculator.Occurrence
    let courseName: String
    let teacher: String
    let location: String
    let colorIndex: Int
    let relativeLabel: String
    let startState: ScheduleViewModel.OccurrenceStartState
    let isNext: Bool
    let onStart: () -> Void
    /// nil hides the chevron (the home card deep-links instead).
    let onOpenSchedule: (() -> Void)?
    /// 课前资料 count (materials linked to this occurrence); 0 hides the
    /// line. Opening a material never touches recording/ASR.
    var preClassMaterialCount: Int = 0
    var onOpenPreClassMaterials: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            HStack(alignment: .top, spacing: LTSpacing.m) {
                // Time block (schedule timezone wall clock).
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.time(occurrence.start))
                        .font(.system(.body, design: .rounded).weight(.semibold).monospacedDigit())
                        .foregroundStyle(LTColors.textPrimary)
                    if occurrence.effectiveEndSecs > occurrence.effectiveStartSecs {
                        Text(Self.time(occurrence.end))
                            .font(LTTypography.caption.monospacedDigit())
                            .foregroundStyle(LTColors.textTertiary)
                    }
                }
                .frame(width: 56, alignment: .leading)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: LTSpacing.xs) {
                        Circle()
                            .fill(LTCoursePalette.color(colorIndex))
                            .frame(width: 8, height: 8)
                        Text(courseName)
                            .font(LTTypography.cardTitle)
                            .foregroundStyle(LTColors.textPrimary)
                            .lineLimit(2)
                        if occurrence.isTimeChanged {
                            StatusChip(text: "调课", tint: LTColors.accentGreen)
                        }
                        if occurrence.isAdHoc {
                            StatusChip(text: "临时加课", tint: LTColors.accentGreen)
                        }
                    }
                    if !teacher.isEmpty || !location.isEmpty {
                        Text([teacher, location].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(LTTypography.caption)
                            .foregroundStyle(LTColors.textSecondary)
                            .lineLimit(1)
                    }
                    if let note = occurrence.note, !note.isEmpty {
                        Text(note)
                            .font(LTTypography.caption)
                            .foregroundStyle(LTColors.textTertiary)
                            .lineLimit(2)
                    }
                    if preClassMaterialCount > 0 {
                        Button {
                            onOpenPreClassMaterials?()
                        } label: {
                            HStack(spacing: LTSpacing.xxs) {
                                Image(systemName: "book")
                                    .font(.system(size: 11))
                                Text("课前资料 \(preClassMaterialCount) 份")
                                    .font(LTTypography.caption)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .foregroundStyle(LTColors.accentCyan)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("查看课前资料，共 \(preClassMaterialCount) 份"))
                    }
                    HStack(spacing: LTSpacing.xs) {
                        if occurrence.isCancelled {
                            Text("已停课")
                                .font(LTTypography.caption)
                                .foregroundStyle(LTColors.textTertiary)
                        } else {
                            Text(relativeLabel)
                                .font(LTTypography.caption)
                                .foregroundStyle(statusColor)
                        }
                        if !occurrence.isCancelled {
                            startButton
                        }
                    }
                }
                Spacer(minLength: 0)
                if let onOpenSchedule {
                    Button {
                        onOpenSchedule()
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(LTColors.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("查看日程"))
                }
            }
        }
        .ltCard()
        .opacity(isEnded ? 0.6 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var isEnded: Bool {
        !occurrence.isCancelled && occurrence.end < .now && !isInProgressWithSession
    }

    private var isInProgressWithSession: Bool {
        if case .returnToSession = startState { return true }
        return false
    }

    private var statusColor: Color {
        if relativeLabel.hasPrefix("正在上课") { return LTColors.accentGreen }
        if relativeLabel.hasPrefix("已迟到") { return LTColors.warning }
        return LTColors.textTertiary
    }

    @ViewBuilder
    private var startButton: some View {
        switch startState {
        case .canStart:
            Button(action: onStart) {
                Text(isNext ? "开始记录" : "开始")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.black.opacity(0.85))
                    .padding(.horizontal, LTSpacing.m)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(LTColors.accentGreen))
            }
            .buttonStyle(.plain)
        case .returnToSession:
            Button(action: onStart) {
                Text("返回课堂")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.black.opacity(0.85))
                    .padding(.horizontal, LTSpacing.m)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(LTColors.accentBlue))
            }
            .buttonStyle(.plain)
        case .finishedSession:
            Button(action: onStart) {
                Text("再开一堂")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LTColors.textPrimary)
                    .padding(.horizontal, LTSpacing.m)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(LTColors.surfaceElevated))
                    .overlay(Capsule().strokeBorder(LTColors.border, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
    }

    private var accessibilitySummary: String {
        var parts = [courseName, Self.time(occurrence.start)]
        if occurrence.isCancelled { parts.append("已停课") }
        else { parts.append(relativeLabel) }
        if !location.isEmpty { parts.append(location) }
        return parts.joined(separator: "，")
    }

    private static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// 再开一堂 — the extra-start confirmation's controlled restart.
    private func forceStartOccurrence(_ occurrence: ScheduleCalculator.Occurrence) {
        Task { _ = await viewModel.startOccurrence(occurrence, force: true) }
    }
}
