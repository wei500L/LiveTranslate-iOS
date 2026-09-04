import SwiftUI

/// 计划详情 — the day-by-day plan with per-item actions: 开始（真实计
/// 时）、完成、延期到明天、改日期、跳过、编辑预计时长、查看来源
/// (jump into the real content). Missed items show 未完成 — never
/// auto-failed. Pause/resume/archive + exports live in the toolbar.
struct StudyPlanDetailView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let planID: UUID

    @State private var plan: StudyPlan?
    @State private var exam: Exam?
    @State private var items: [StudyPlanItem] = []
    @State private var shareItem: SharedFile?
    @State private var editingItem: StudyPlanItem?
    @State private var isLoaded = false

    var body: some View {
        LTPage {
            ScrollView {
                VStack(alignment: .leading, spacing: LTSpacing.l) {
                    if isLoaded, let plan {
                        headerCard(plan)
                        groupedItems(plan)
                    } else if isLoaded {
                        LTEmptyState(
                            symbol: "questionmark.folder",
                            title: "计划不存在",
                            message: "这个学习计划可能已被删除"
                        )
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, LTSpacing.xl)
                    }
                }
                .padding(.horizontal, LTSpacing.screenPadding)
                .padding(.top, LTSpacing.s)
                .padding(.bottom, 90)
            }
        }
        .navigationTitle("学习计划")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let plan {
                        Button {
                            setPlanStatus(plan, plan.status == .paused ? .active : .paused)
                        } label: {
                            Label(
                                plan.status == .paused ? "恢复计划" : "暂停计划",
                                systemImage: plan.status == .paused ? "play" : "pause"
                            )
                        }
                        Button(role: .destructive) {
                            setPlanStatus(plan, .archived)
                        } label: {
                            Label("归档计划", systemImage: "archivebox")
                        }
                        Button {
                            exportPlan(plan)
                        } label: {
                            Label("导出计划（JSON）", systemImage: "curlybraces.square")
                        }
                        Button {
                            exportWeek(plan)
                        } label: {
                            Label("导出一周安排（Markdown）", systemImage: "doc.text")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(LTColors.textSecondary)
                }
                .accessibilityLabel(Text("计划操作"))
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .sheet(item: $editingItem) { item in
            NavigationStack {
                StudyPlanItemEditScreen(item: item)
                    .environment(environment)
            }
        }
        .onAppear { reload() }
    }

    // MARK: - Cards

    private func headerCard(_ plan: StudyPlan) -> some View {
        let done = items.filter { $0.status == .done }.count
        let missed = items.filter(\.isMissed).count
        return VStack(alignment: .leading, spacing: LTSpacing.xs) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.title)
                        .font(LTTypography.cardTitle)
                        .foregroundStyle(LTColors.textPrimary)
                    Text("\(items.count) 项 · 已完成 \(done)" + (missed > 0 ? " · \(missed) 项未完成" : ""))
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textSecondary)
                }
                Spacer()
                StatusChip(
                    text: plan.status.displayName,
                    tint: plan.status == .active ? LTColors.accentGreen : LTColors.textTertiary
                )
            }
            if missed > 0 {
                Text("错过的项目显示为未完成 — 可延期、跳过或重新生成计划，不会自动作废。")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.warning)
            }
        }
        .ltCard()
    }

    private func groupedItems(_ plan: StudyPlan) -> some View {
        let groups = Dictionary(grouping: items, by: \.itemDateKey)
        let todayKey = Exam.dateKey(.now)
        let sortedKeys = groups.keys.sorted()
        return VStack(alignment: .leading, spacing: LTSpacing.s) {
            ForEach(sortedKeys, id: \.self) { key in
                if let date = Exam.parseDateKey(key) {
                    HStack {
                        Text(date.formatted(date: .abbreviated, time: .omitted))
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(key < todayKey ? LTColors.warning : LTColors.textPrimary)
                        if key == todayKey {
                            StatusChip(text: "今天", tint: LTColors.accentGreen)
                        } else if key < todayKey {
                            StatusChip(text: "未完成", tint: LTColors.warning)
                        }
                        Spacer()
                        Text("\(groups[key]?.count ?? 0) 项")
                            .font(LTTypography.caption)
                            .foregroundStyle(LTColors.textTertiary)
                    }
                    VStack(spacing: LTSpacing.xs) {
                        ForEach(groups[key] ?? []) { item in
                            StudyPlanItemRow(
                                item: item,
                                onStart: { startTimer(item) },
                                onComplete: {
                                    try? environment.repository.setStudyPlanItemStatus(item, status: .done)
                                    reload()
                                },
                                onDeferTomorrow: { deferToTomorrow(item) },
                                onSkip: {
                                    try? environment.repository.setStudyPlanItemStatus(item, status: .skipped)
                                    reload()
                                },
                                onEdit: { editingItem = item }
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func startTimer(_ item: StudyPlanItem) {
        // Classroom guard (同层互斥修复): a running classroom recording
        // blocks a new study timer — classroom time NEVER becomes study
        // time, and the reverse funnel (new classroom) already pauses
        // studying. Route back to the classroom instead of silently
        // starting.
        if environment.coordinator.isRunning {
            environment.presentLive()
            return
        }
        guard !environment.studyActivityTracker.hasActiveActivity else {
            // The exactly-one invariant: the running activity UI shows
            // resume/finish; starting a second one is refused here.
            environment.flow.selectedTab = .review
            return
        }
        _ = environment.studyActivityTracker.start(StudyActivityDraft(
            planItemID: item.id,
            examID: item.examID,
            courseID: exam?.courseID,
            topicID: item.source?.topicID
        ))
        // Mark in-progress (the honest live state — visible on every
        // device after sync).
        try? environment.repository.setStudyPlanItemStatus(item, status: .inProgress)
        environment.flow.selectedTab = .review
        reload()
    }

    private func deferToTomorrow(_ item: StudyPlanItem) {
        guard let date = item.itemDate,
              let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: date) else { return }
        try? environment.repository.setStudyPlanItemStatus(item, status: .deferred)
        try? environment.repository.setStudyPlanItemDate(item, dateKey: Exam.dateKey(tomorrow))
        reload()
    }

    private func setPlanStatus(_ plan: StudyPlan, status: StudyPlanStatus) {
        try? environment.repository.setStudyPlanStatus(plan, status: status)
        if status == .archived {
            // An archived plan's reminder-visible items stay; only the
            // daily-summary relation changes (nothing to cancel — one
            // summary a day at most by design).
            LTHaptics.success()
            dismiss()
        }
        reload()
    }

    private func exportPlan(_ plan: StudyPlan) {
        guard let exam,
              let url = ExamExporter.planJSON(exam: exam, plan: plan, items: items) else { return }
        shareItem = SharedFile(url: url)
    }

    private func exportWeek(_ plan: StudyPlan) {
        let byDate = Dictionary(grouping: items, by: \.itemDateKey)
        let examTitles = { (id: UUID) -> String? in
            ((try? self.environment.repository.exam(id: id)) ?? nil)?.title
        }
        guard let url = ExamExporter.weekScheduleMarkdown(
            itemsByDate: byDate,
            startDate: Calendar.current.startOfDay(for: .now),
            examTitles: examTitles
        ) else { return }
        shareItem = SharedFile(url: url)
    }

    private func reload() {
        plan = nil
        let plans = (try? environment.repository.studyPlans(examID: nil)) ?? []
        plan = plans.first { $0.id == planID }
        guard let plan else {
            isLoaded = true
            return
        }
        exam = try? environment.repository.exam(id: plan.examID)
        items = (try? environment.repository.studyPlanItems(planID: plan.id)) ?? []
        isLoaded = true
    }
}

/// One plan-item row with its real jump target (资料页 / 课堂 / 任务 /
/// 主题 / 卡片队列) and the status actions.
struct StudyPlanItemRow: View {
    @Environment(AppEnvironment.self) private var environment
    let item: StudyPlanItem
    var onStart: () -> Void
    var onComplete: () -> Void
    var onDeferTomorrow: () -> Void
    var onSkip: () -> Void
    var onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            HStack(spacing: LTSpacing.s) {
                Image(systemName: item.kind.symbol)
                    .font(.subheadline)
                    .foregroundStyle(tint)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(LTColors.textPrimary)
                        .lineLimit(2)
                    HStack(spacing: LTSpacing.xs) {
                        Text("预计 \(item.estimatedMinutes) 分钟")
                        if item.actualMinutes > 0 {
                            Text("· 实际 \(item.actualMinutes) 分钟")
                        }
                        if item.status == .deferred { Text("· 已延期") }
                    }
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textTertiary)
                }
                Spacer()
                statusChip
            }
            HStack(spacing: LTSpacing.s) {
                if item.status == .pending || item.status == .inProgress {
                    Button(action: onStart) {
                        Label(
                            environment.studyActivityTracker.currentActivity?.planItemID == item.id
                                ? "计时中" : "开始学习",
                            systemImage: "play.fill"
                        )
                        .font(.footnote.weight(.semibold))
                        .frame(minWidth: 92, minHeight: 36)
                    }
                    .buttonStyle(LTPrimaryButtonStyle())
                }
                Menu {
                    Button(action: onComplete) { Label("完成", systemImage: "checkmark") }
                    Button(action: onDeferTomorrow) { Label("延期到明天", systemImage: "arrow.right") }
                    Menu {
                        DatePicker(
                            "选择日期",
                            selection: dateBinding,
                            displayedComponents: .date
                        )
                    } label: {
                        Label("改到其他日期", systemImage: "calendar")
                    }
                    Button(action: onSkip) { Label("跳过", systemImage: "forward") }
                    Button(action: onEdit) { Label("编辑标题和时长", systemImage: "pencil") }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.footnote)
                        .foregroundStyle(LTColors.textSecondary)
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel(Text("项目操作"))
            }
        }
        .padding(LTSpacing.m)
        .ltCard()
        .accessibilityElement(children: .combine)
    }

    private var dateBinding: Binding<Date> {
        Binding(
            get: { item.itemDate ?? .now },
            set: { newDate in
                try? environment.repository.setStudyPlanItemDate(
                    item, dateKey: Exam.dateKey(newDate)
                )
            }
        )
    }

    private var tint: Color {
        switch item.kind {
        case .material: return LTColors.accentBlue
        case .session, .review: return LTColors.accentCyan
        case .task: return LTColors.warning
        case .cards, .terms: return LTColors.accentGreen
        default: return LTColors.textSecondary
        }
    }

    @ViewBuilder
    private var statusChip: some View {
        switch item.status {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(LTColors.accentGreen)
        case .skipped:
            StatusChip(text: "已跳过", tint: LTColors.textTertiary)
        case .inProgress:
            StatusChip(text: "进行中", tint: LTColors.accentCyan)
        case .deferred:
            StatusChip(text: "已延期", tint: LTColors.warning)
        case .pending:
            if item.isMissed {
                StatusChip(text: "未完成", tint: LTColors.warning)
            } else {
                EmptyView()
            }
        }
    }
}

/// 编辑标题 / 预计时长 / 备注 (user-edited items survive replans).
struct StudyPlanItemEditScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State var item: StudyPlanItem
    @State private var title = ""
    @State private var estimatedMinutes = 30
    @State private var userNote = ""

    var body: some View {
        Form {
            Section("项目") {
                TextField("标题", text: $title)
                Stepper("预计时长：\(estimatedMinutes) 分钟", value: $estimatedMinutes, in: 5...240, step: 5)
                TextField("备注（可选）", text: $userNote, axis: .vertical)
                    .lineLimit(1...3)
            }
        }
        .navigationTitle("编辑项目")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    try? environment.repository.updateStudyPlanItem(
                        item,
                        title: title,
                        estimatedMinutes: estimatedMinutes,
                        userNote: userNote
                    )
                    dismiss()
                }
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            title = item.title
            estimatedMinutes = item.estimatedMinutes
            userNote = item.userNote
        }
    }
}
