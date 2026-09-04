import SwiftUI

/// 考试详情 — countdown (day resolution), scope, topics with self-ratings,
/// linked materials/sessions/tasks/cards, the study plan, honest
/// preparation numbers (计划完成数/实际分钟/未开始主题/到期卡片… — every
/// number explained, never an AI score), and edit/complete/cancel/delete.
struct ExamDetailView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let examID: UUID

    @State private var exam: Exam?
    @State private var course: Course?
    @State private var topics: [ExamTopic] = []
    @State private var plan: StudyPlan?
    @State private var planItems: [StudyPlanItem] = []
    @State private var linkedMaterials: [CourseMaterial] = []
    @State private var linkedSessions: [ClassroomSession] = []
    @State private var openTasks: [StudyTask] = []
    @State private var dueCardCount = 0
    /// Terminal activities NOT tied to plan items — they count toward the
    /// exam's real study minutes without double-counting (plan-item
    /// minutes already live on the items).
    @State private var standaloneActivityMinutes = 0
    @State private var showEdit = false
    @State private var showingTopicsEditor = false
    @State private var showingPlanForm = false
    @State private var showingReplanConfirm = false
    @State private var showingDeleteConfirm = false
    @State private var showingCompleteConfirm = false
    @State private var showingCalendarPicker = false
    @State private var shareItem: SharedFile?
    @State private var reminderLead: ExamReminderScheduler.Lead = .off

    var body: some View {
        LTPage {
            Group {
                if let exam {
                    ScrollView {
                        VStack(alignment: .leading, spacing: LTSpacing.l) {
                            headerCard(exam)
                            countdownCard(exam)
                            scopeCard(exam)
                            topicsCard(exam)
                            planCard(exam)
                            preparationCard(exam)
                            linkedCard(exam)
                            actionsCard(exam)
                        }
                        .padding(.horizontal, LTSpacing.screenPadding)
                        .padding(.top, LTSpacing.s)
                        .padding(.bottom, 90)
                    }
                } else {
                    LTEmptyState(
                        symbol: "questionmark.folder",
                        title: "考试不存在",
                        message: "这场考试可能已被删除"
                    )
                }
            }
        }
        .navigationTitle("考试")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showEdit = true } label: { Label("编辑考试", systemImage: "pencil") }
                    Button { exportPlanMarkdown(exam: exam) } label: {
                        Label("导出复习计划（Markdown）", systemImage: "doc.text")
                    }
                    Button { exportICS(exam: exam) } label: {
                        Label("导出 .ics", systemImage: "calendar.badge.arrow.up")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(LTColors.textSecondary)
                }
                .accessibilityLabel(Text("考试操作"))
            }
        }
        .sheet(isPresented: $showEdit) {
            NavigationStack {
                ExamFormScreen(preselectedCourseID: nil, editing: exam)
                    .environment(environment)
            }
        }
        .sheet(isPresented: $showingTopicsEditor) {
            NavigationStack {
                ExamTopicsEditor(examID: examID)
                    .environment(environment)
            }
        }
        .sheet(isPresented: $showingPlanForm) {
            NavigationStack {
                StudyPlanFormScreen(examID: examID)
                    .environment(environment)
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .confirmationDialog(
            "考试日期已变化",
            isPresented: $showingReplanConfirm,
            titleVisibility: .visible
        ) {
            Button("重新调整计划") { showingPlanForm = true }
            Button("保持原计划", role: .cancel) {}
        } message: {
            Text("原计划按旧日期生成。重新调整会保留已完成和手动修改过的项目，其余项目按新日期重新安排。")
        }
        .confirmationDialog(
            "删除这场考试？",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("删除考试", role: .destructive) { deleteExam() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("考试范围、知识主题和未完成的学习计划会一并删除；已记录的学习时长会保留（不再关联这场考试）。系统日历中的镜像事件也会一并移除。")
        }
        .confirmationDialog(
            "标记为已完成？",
            isPresented: $showingCompleteConfirm,
            titleVisibility: .visible
        ) {
            Button("已完成") { completeExam() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("已完成只是记录状态，不会删除任何内容。")
        }
        .sheet(isPresented: $showingCalendarPicker) {
            if let exam {
                ExamCalendarPickerScreen(exam: exam, courseName: course?.name)
                    .environment(environment)
            }
        }
        .onAppear {
            // Mirror honesty: events the user deleted system-side drop
            // their stale bindings (never recreated behind their back).
            ExamCalendarService.shared.pruneStaleMirrors()
            reload()
        }
    }

    // MARK: - Cards

    private func headerCard(_ exam: Exam) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            HStack(spacing: LTSpacing.m) {
                LTIconBadge(symbol: exam.kind.symbol, tint: LTColors.accentGreen)
                VStack(alignment: .leading, spacing: 3) {
                    Text(exam.title)
                        .font(LTTypography.cardTitle)
                        .foregroundStyle(LTColors.textPrimary)
                    Text(headerSubtitle(exam))
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textSecondary)
                }
                Spacer()
                if exam.status != .scheduled {
                    StatusChip(text: exam.status.displayName, tint: LTColors.textTertiary)
                }
            }
            if exam.origin == .ai, let source = exam.source {
                if source.kind == .inbox, let itemID = source.sourceID {
                    // Inbox-created candidate: jump back to the SAME
                    // shared item it came from (one item, one place).
                    Button {
                        environment.flow.openInboxItem(itemID)
                    } label: {
                        Label(
                            "识别自\(source.kindDisplayName)：\(source.originalText)",
                            systemImage: "sparkles"
                        )
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.accentCyan)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("打开收件箱中的原始分享"))
                } else {
                    Label(
                        "识别自\(source.kindDisplayName)：\(source.originalText)",
                        systemImage: "sparkles"
                    )
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.accentCyan)
                }
            }
        }
        .ltCard()
    }

    private func headerSubtitle(_ exam: Exam) -> String {
        var parts: [String] = [exam.kind.displayName]
        if let course { parts.append(course.name) }
        return parts.joined(separator: " · ")
    }

    /// Day-resolution countdown (words — a per-second ticker would be
    /// decoration, not information).
    private func countdownCard(_ exam: Exam) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.xs) {
            HStack(spacing: LTSpacing.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(countdownText(exam))
                        .font(.system(.title2, design: .rounded).weight(.bold).monospacedDigit())
                        .foregroundStyle(LTColors.textPrimary)
                    if let date = exam.examDate {
                        Text(date.formatted(date: .long, time: .omitted)
                             + (exam.hasTime
                                ? String(format: " %02d:%02d", exam.startSecs / 3600, (exam.startSecs % 3600) / 60)
                                : " · 时间待定"))
                            .font(LTTypography.caption)
                            .foregroundStyle(LTColors.textSecondary)
                    }
                }
                Spacer()
                if !exam.location.isEmpty {
                    Label(exam.location, systemImage: "mappin.and.ellipse")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textSecondary)
                }
            }
            // Reminder + calendar rows (user-armed only).
            HStack(spacing: LTSpacing.l) {
                Menu {
                    ForEach(ExamReminderScheduler.Lead.allCases) { lead in
                        Button(lead.displayName) {
                            Task {
                                reminderLead = lead
                                _ = await environment.examReminders.enable(exam: exam, lead: lead)
                            }
                        }
                    }
                } label: {
                    Label(
                        reminderLead == .off ? "考试提醒：关" : "提醒：\(reminderLead.displayName)",
                        systemImage: "bell"
                    )
                    .font(LTTypography.caption)
                    .foregroundStyle(reminderLead == .off ? LTColors.textTertiary : LTColors.accentGreen)
                }
                Button {
                    showingCalendarPicker = true
                } label: {
                    Label(
                        ExamCalendarService.shared.hasMirroredEvent(examID: exam.id)
                            ? "已加入系统日历" : "加入系统日历",
                        systemImage: "calendar"
                    )
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.accentBlue)
                }
            }
        }
        .ltCard()
    }

    private func countdownText(_ exam: Exam) -> String {
        guard let days = exam.daysUntilExam else { return "日期待定" }
        switch days {
        case let d where d < 0: return "考试已结束"
        case 0: return "就在今天"
        case 1: return "还有 1 天"
        default: return "还有 \(days) 天"
        }
    }

    @ViewBuilder
    private func scopeCard(_ exam: Exam) -> some View {
        if !exam.scopeText.isEmpty || !exam.note.isEmpty {
            VStack(alignment: .leading, spacing: LTSpacing.xs) {
                LTSectionHeader(title: "考试范围")
                if !exam.scopeText.isEmpty {
                    Text(exam.scopeText)
                        .font(.subheadline)
                        .foregroundStyle(LTColors.textPrimary)
                }
                if !exam.note.isEmpty {
                    Text(exam.note)
                        .font(.footnote)
                        .foregroundStyle(LTColors.textSecondary)
                }
                if !exam.targetScore.isEmpty {
                    Text("目标：\(exam.targetScore)")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textTertiary)
                }
            }
            .ltCard()
        }
    }

    private func topicsCard(_ exam: Exam) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            HStack {
                LTSectionHeader(title: "知识主题")
                Spacer()
                Button {
                    showingTopicsEditor = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LTColors.accentGreen)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("管理主题"))
            }
            if topics.isEmpty {
                Text("还没有主题。添加后可以生成学习计划。")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textTertiary)
            } else {
                VStack(spacing: LTSpacing.xs) {
                    ForEach(topics) { topic in
                        ExamTopicRow(topic: topic) { updatedTopic, status in
                            try? environment.repository.setExamTopicStatus(updatedTopic, status: status)
                            reload()
                        }
                    }
                }
            }
        }
        .ltCard()
    }

    private func planCard(_ exam: Exam) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            LTSectionHeader(title: "学习计划")
            if let plan {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plan.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(LTColors.textPrimary)
                        Text(planSummary(plan))
                            .font(LTTypography.caption)
                            .foregroundStyle(LTColors.textSecondary)
                    }
                    Spacer()
                    StatusChip(text: plan.status.displayName, tint: plan.status == .active ? LTColors.accentGreen : LTColors.textTertiary)
                }
                NavigationLink {
                    StudyPlanDetailView(planID: plan.id)
                        .environment(environment)
                } label: {
                    Label("查看计划", systemImage: "calendar.day.timeline.left")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(LTColors.accentBlue)
                }
                .buttonStyle(.plain)
            } else {
                Text("为主题生成可执行的学习计划：按每天可用时间安排，可随时调整。")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textTertiary)
                Button {
                    showingPlanForm = true
                } label: {
                    Label(topics.isEmpty ? "先添加主题，再生成计划" : "生成学习计划", systemImage: "wand.and.stars")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: LTSpacing.minTouchTarget)
                }
                .buttonStyle(LTPrimaryButtonStyle())
                .disabled(topics.isEmpty)
            }
        }
        .ltCard()
    }

    private func planSummary(_ plan: StudyPlan) -> String {
        let done = planItems.filter { $0.status == .done }.count
        return "\(planItems.count) 项 · 已完成 \(done) · 每天 \(plan.weekdayMinutes)–\(plan.weekendMinutes) 分钟"
    }

    /// Real, explainable preparation numbers — no AI score, no fabricated
    /// mastery; every number names its source.
    private func preparationCard(_ exam: Exam) -> some View {
        let doneItems = planItems.filter { $0.status == .done }.count
        let pendingItems = planItems.filter { $0.status == .pending || $0.status == .inProgress }.count
        let plannedMinutes = planItems.reduce(0) { $0 + $1.estimatedMinutes }
        let actualMinutes = planItems.reduce(0) { $0 + $1.actualMinutes }
        let notStarted = topics.filter { $0.status == .notStarted }.count
        let mastered = topics.filter { $0.status == .mastered }.count

        return VStack(alignment: .leading, spacing: LTSpacing.s) {
            LTSectionHeader(title: "准备情况")
            Text(preparationVerdict(doneItems: doneItems, pendingItems: pendingItems))
                .font(.footnote.weight(.medium))
                .foregroundStyle(LTColors.textPrimary)
            VStack(spacing: LTSpacing.xs) {
                prepRow(label: "计划项目", value: "完成 \(doneItems) / 共 \(planItems.count)")
                prepRow(
                    label: "学习时长",
                    value: "预计 \(plannedMinutes) 分钟 · 实际 \(actualMinutes + standaloneActivityMinutes) 分钟"
                )
                prepRow(label: "主题状态", value: "已掌握 \(mastered) · 未开始 \(notStarted) / 共 \(topics.count)")
                prepRow(label: "到期卡片", value: "\(dueCardCount) 张")
                prepRow(label: "未完成作业", value: "\(openTasks.count) 项")
                if !linkedMaterials.isEmpty {
                    prepRow(label: "课程资料", value: "\(linkedMaterials.count) 份待读")
                }
            }
        }
        .ltCard()
    }

    private func prepRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.textTertiary)
            Spacer()
            Text(value)
                .font(LTTypography.caption.monospacedDigit())
                .foregroundStyle(LTColors.textSecondary)
        }
    }

    /// The explainable verdict: derived ONLY from the numbers above.
    private func preparationVerdict(doneItems: Int, pendingItems: Int) -> String {
        guard let days = exam?.daysUntilExam else { return "日期待定，先确认考试时间" }
        if planItems.isEmpty && topics.isEmpty {
            return "还没有计划。添加主题并生成计划后，这里会显示真实的准备进度。"
        }
        if planItems.isEmpty {
            return "有主题还没有计划。"
        }
        if doneItems == planItems.count {
            return "当前计划已全部完成" + (days > 0 ? "，距考试还有 \(days) 天" : "")
        }
        let completion = Double(doneItems) / Double(max(1, planItems.count))
        if completion >= 0.7 && days >= 0 {
            return "按计划进行中（已完成 \(Int(completion * 100))%）"
        }
        if days <= 3 && pendingItems > 0 {
            return "准备不足：还有 \(pendingItems) 项未完成，距考试 \(max(days, 0)) 天"
        }
        return "进行中：\(doneItems) 项完成，\(pendingItems) 项待做"
    }

    /// Linked real content: the course's materials / sessions with plan
    /// jump targets, open tasks and the due-card queue entry.
    private func linkedCard(_ exam: Exam) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            LTSectionHeader(title: "关联内容")
            if linkedMaterials.isEmpty && linkedSessions.isEmpty && openTasks.isEmpty && dueCardCount == 0 {
                Text("这门课还没有可关联的资料或课堂")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textTertiary)
            } else {
                VStack(spacing: LTSpacing.xs) {
                    ForEach(linkedMaterials.prefix(3)) { material in
                        NavigationLink {
                            MaterialReaderScreen(materialID: material.id)
                                .environment(environment)
                        } label: {
                            linkedRow("book.fill", LTColors.accentBlue, material.title)
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(linkedSessions.prefix(3)) { session in
                        NavigationLink {
                            SessionDetailView(sessionID: session.id)
                        } label: {
                            linkedRow("waveform", LTColors.accentCyan, session.title)
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(openTasks.prefix(3)) { task in
                        NavigationLink {
                            TaskDetailView(task: task, courses: course.map { [$0] } ?? [])
                        } label: {
                            linkedRow("checklist", LTColors.warning, task.title)
                        }
                        .buttonStyle(.plain)
                    }
                    if dueCardCount > 0 {
                        Button {
                            environment.flow.selectedTab = .review
                        } label: {
                            linkedRow("rectangle.on.rectangle", LTColors.accentGreen, "到期复习卡 \(dueCardCount) 张")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .ltCard()
    }

    private func linkedRow(_ symbol: String, _ tint: Color, _ title: String) -> some View {
        HStack(spacing: LTSpacing.s) {
            Image(systemName: symbol)
                .font(.subheadline)
                .foregroundStyle(tint)
                .frame(width: 24)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(LTColors.textPrimary)
                .lineLimit(1)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(LTColors.textTertiary)
        }
        .padding(.vertical, 2)
    }

    private func actionsCard(_ exam: Exam) -> some View {
        VStack(spacing: LTSpacing.xs) {
            if exam.status == .scheduled {
                Button {
                    showingCompleteConfirm = true
                } label: {
                    Label("标记为已完成", systemImage: "checkmark.circle")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: LTSpacing.minTouchTarget)
                }
                .buttonStyle(LTSecondaryButtonStyle())
            }
            Button(role: .destructive) {
                showingDeleteConfirm = true
            } label: {
                Label("删除考试", systemImage: "trash")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: LTSpacing.minTouchTarget)
            }
            .buttonStyle(.plain)
            .foregroundStyle(LTColors.destructive)
        }
        .ltCard()
    }

    // MARK: - Actions

    private func completeExam() {
        guard let exam else { return }
        try? environment.repository.setExamStatus(exam, status: .done)
        reload()
    }

    private func deleteExam() {
        guard let exam else { return }
        // The reminder dies with the exam; the calendar mirror too.
        environment.examReminders.disable(examID: exam.id)
        ExamCalendarService.shared.removeMirroredEvent(examID: exam.id)
        try? environment.repository.deleteExam(exam)
        dismiss()
    }

    private func exportICS(exam: Exam?) {
        guard let exam, let url = ExamExporter.examICS(exam, courseName: course?.name) else { return }
        shareItem = SharedFile(url: url)
    }

    private func exportPlanMarkdown(exam: Exam?) {
        guard let exam,
              let url = ExamExporter.examPlanMarkdown(
                exam: exam, courseName: course?.name, topics: topics,
                plan: plan, items: planItems
              ) else { return }
        shareItem = SharedFile(url: url)
    }

    // MARK: - Data

    private func reload() {
        exam = try? environment.repository.exam(id: examID)
        guard let exam else { return }
        course = exam.courseID.flatMap { try? environment.repository.course(id: $0) }
        topics = (try? environment.repository.examTopics(examID: exam.id)) ?? []
        plan = (try? environment.repository.studyPlans(examID: exam.id))?.first {
            $0.status != .archived
        }
        planItems = plan.map { (try? environment.repository.studyPlanItems(planID: $0.id)) ?? [] } ?? []
        let courseID = exam.courseID
        linkedMaterials = courseID.flatMap {
            try? environment.repository.materials(courseID: $0)
        } ?? []
        linkedSessions = courseID.flatMap { id in
            try? environment.repository.sessions(matching: "").filter { session in
                session.courseID == id
            }
        } ?? []
        // Newest three sessions only (回顧最近的课堂).
        linkedSessions = Array(
            linkedSessions.sorted { $0.startTime > $1.startTime }.prefix(3)
        )
        openTasks = courseID.flatMap {
            try? environment.repository.tasks(courseID: $0, includeDone: false)
        } ?? []
        let cards = courseID.flatMap {
            try? environment.repository.cards(courseID: $0)
        } ?? []
        dueCardCount = cards.filter(\.isDueNow).count
        let activities = (try? environment.repository.studyActivities(examID: exam.id)) ?? []
        standaloneActivityMinutes = activities
            .filter { $0.isTerminal && $0.planItemID == nil }
            .reduce(0) { $0 + $1.durationSeconds / 60 }
        reminderLead = environment.examReminders.lead(examID: exam.id)
        // 考试日期变化后的计划调整提示：the plan's window no longer
        // matches the exam date — prompt ONCE per visit, never silently
        // regenerate (the user decides).
        if let plan, plan.status == .active,
           plan.endDateKey != exam.examDateKey, !didPromptReplan {
            didPromptReplan = true
            showingReplanConfirm = true
        }
    }

    @State private var didPromptReplan = false
}

/// One topic row inside the exam detail: title + importance + status
/// chip + self-rating menu (自评与计划进度分开显示).
struct ExamTopicRow: View {
    @Environment(AppEnvironment.self) private var environment
    let topic: ExamTopic
    var onStatusChange: (ExamTopic, ExamTopicStatus) -> Void

    var body: some View {
        HStack(spacing: LTSpacing.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(topic.title)
                    .font(.subheadline)
                    .foregroundStyle(LTColors.textPrimary)
                    .lineLimit(1)
                HStack(spacing: LTSpacing.xs) {
                    Text(topic.importance.displayName)
                    Text("·")
                    Text("自评：\(topic.selfRating.displayName)")
                    if let source = topic.source, source.kind != .user {
                        Text("· AI 建议已确认")
                    }
                }
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.textTertiary)
            }
            Spacer()
            Menu {
                Section("学习状态") {
                    ForEach(
                        [ExamTopicStatus.notStarted, .learning, .needsReview, .mastered],
                        id: \.rawValue
                    ) { status in
                        Button(status.displayName) {
                            onStatusChange(topic, status)
                        }
                    }
                }
                Section("自评") {
                    ForEach(ExamTopicSelfRating.allCases) { rating in
                        Button(rating.displayName) {
                            try? environment.repository.setExamTopicSelfRating(topic, rating: rating)
                        }
                    }
                }
            } label: {
                StatusChip(
                    text: topic.status.displayName,
                    tint: topic.status == .mastered
                        ? LTColors.accentGreen : LTColors.textSecondary
                )
            }
        }
        .padding(LTSpacing.s)
        .background(RoundedRectangle(cornerRadius: LTRadius.small).fill(LTColors.surfacePrimary.opacity(0.6)))
    }
}
