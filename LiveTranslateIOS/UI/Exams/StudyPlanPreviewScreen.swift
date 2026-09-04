import SwiftUI

/// 计划预览 — the deterministic algorithm's output BEFORE anything is
/// saved. Shows the day-by-day placement, the honest 容量不足 list and
/// the total minutes; 保存 creates the plan + items, 返回 changes
/// settings. When the exam already has a plan, saving offers the replan
/// diff (kept / replaced / generated).
struct StudyPlanPreviewScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let exam: Exam
    let settings: StudyPlanDraft

    @State private var output: StudyPlanGenerator.Output?
    @State private var existingPlan: StudyPlan?
    @State private var existingItems: [StudyPlanItem] = []
    @State private var isSaving = false
    @State private var saveError = false

    var body: some View {
        LTPage {
            ScrollView {
                VStack(alignment: .leading, spacing: LTSpacing.l) {
                    if let output {
                        summaryCard(output)
                        dayList(output)
                        if !output.unplaced.isEmpty {
                            unplacedCard(output)
                        }
                        if existingPlan != nil {
                            replanNote
                        }
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
            .safeAreaInset(edge: .bottom) {
                if let output {
                    Button {
                        save(output)
                    } label: {
                        Label(
                            existingPlan == nil ? "保存学习计划" : "按此调整计划",
                            systemImage: "checkmark"
                        )
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: LTSpacing.minTouchTarget)
                    }
                    .buttonStyle(LTPrimaryButtonStyle())
                    .disabled(isSaving || output.items.isEmpty)
                    .padding(.horizontal, LTSpacing.screenPadding)
                    .padding(.vertical, LTSpacing.s)
                    .background(.ultraThinMaterial)
                }
            }
        }
        .navigationTitle("计划预览")
        .navigationBarTitleDisplayMode(.inline)
        .alert("保存失败", isPresented: $saveError) {
            Button("好", role: .cancel) {}
        } message: {
            Text("计划未能保存，请重试。")
        }
        .onAppear { generate() }
    }

    // MARK: - Cards

    private func summaryCard(_ output: StudyPlanGenerator.Output) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.xs) {
            LTSectionHeader(title: "安排概览")
            Text("共 \(output.items.count) 项 · \(output.totalPlannedMinutes) 分钟")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(LTColors.textPrimary)
            Text("按每天剩余容量安排：工作日 \(settings.weekdayMinutes) 分钟，周末 \(settings.weekendMinutes) 分钟；上课时间和避开时段已扣除。")
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.textTertiary)
        }
        .ltCard()
    }

    private func dayList(_ output: StudyPlanGenerator.Output) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            LTSectionHeader(title: "每日安排")
            let plannedDays = output.daySummaries.filter { !$0.itemTitles.isEmpty }
            if plannedDays.isEmpty {
                Text("当前设置下没有可安排的日期（检查休息日与考试日期）。")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textTertiary)
            }
            VStack(spacing: LTSpacing.xs) {
                ForEach(plannedDays) { day in
                    VStack(alignment: .leading, spacing: LTSpacing.xxs) {
                        HStack {
                            Text(day.date.formatted(
                                date: .abbreviated, time: .omitted
                            ) + weekdaySuffix(day.date))
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(LTColors.textPrimary)
                            Spacer()
                            Text("\(day.plannedMinutes)/\(day.capacityMinutes) 分钟")
                                .font(LTTypography.caption.monospacedDigit())
                                .foregroundStyle(LTColors.textTertiary)
                        }
                        ForEach(day.itemTitles, id: \.self) { title in
                            Text("· " + title)
                                .font(LTTypography.caption)
                                .foregroundStyle(LTColors.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(LTSpacing.m)
                    .ltCard()
                }
            }
        }
    }

    /// The honest capacity verdict — shown, never hidden.
    private func unplacedCard(_ output: StudyPlanGenerator.Output) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.xs) {
            LTSectionHeader(title: "当前时间不足以完成全部内容")
            Text("以下内容无法在容量内安排。可以增加每天时间、减少休息日，或接受部分内容靠后。")
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.textTertiary)
            ForEach(output.unplaced, id: \.self) { line in
                Text("· " + line)
                    .font(.footnote)
                    .foregroundStyle(LTColors.warning)
            }
        }
        .ltCard()
    }

    private var replanNote: some View {
        VStack(alignment: .leading, spacing: LTSpacing.xs) {
            Label("这会替换未完成、未手动修改的项目；已完成和手动修改过的项目保持不变。", systemImage: "arrow.triangle.2.circlepath")
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.textSecondary)
        }
        .ltCard()
    }

    private func weekdaySuffix(_ date: Date) -> String {
        let symbol = Calendar.current.component(.weekday, from: date)
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        return "（\(names[symbol - 1])）"
    }

    // MARK: - Generation + save

    private func generate() {
        // Class occurrences of the exam's course block capacity (上课时
        // 间不是学习时间).
        var occurrences: [(start: Date, durationMinutes: Int)] = []
        if let courseID = exam.courseID {
            let schedules = (try? environment.repository.schedules(courseID: courseID)) ?? []
            let exceptions = (try? environment.repository.allExceptions()) ?? []
            if let examDate = exam.examDate, let startDate = Exam.parseDateKey(settings.startDateKey) {
                for schedule in schedules {
                    let window = ScheduleCalculator.occurrences(
                        of: schedule, from: startDate, to: examDate, exceptions: exceptions
                    )
                    for occurrence in window {
                        occurrences.append((
                            start: occurrence.start,
                            durationMinutes: Int(occurrence.end.timeIntervalSince(occurrence.start) / 60)
                        ))
                    }
                }
            }
        }
        var materials: [(id: UUID, title: String, pageCount: Int)] = []
        if settings.includeMaterials {
            let rows = exam.courseID.flatMap {
                try? environment.repository.materials(courseID: $0)
            } ?? []
            materials = rows.map { ($0.id, $0.title.isEmpty ? $0.originalFileName : $0.title, $0.pageCount) }
        }
        var tasks: [(id: UUID, title: String, dueAt: Date)] = []
        if settings.includeTasks {
            let rows = exam.courseID.flatMap {
                try? environment.repository.tasks(courseID: $0, includeDone: false)
            } ?? []
            tasks = rows.compactMap { task in
                guard let dueAt = task.dueAt else { return nil }
                return (task.id, task.title, dueAt)
            }
        }
        let topics = (try? environment.repository.examTopics(examID: exam.id)) ?? []
        let cards = exam.courseID.flatMap {
            try? environment.repository.cards(courseID: $0)
        } ?? []
        let input = StudyPlanGenerator.Input(
            exam: exam,
            settings: settings,
            topics: topics,
            materials: materials,
            openTasks: tasks,
            dueCardCount: cards.filter(\.isDueNow).count,
            classOccurrences: occurrences
        )
        output = StudyPlanGenerator.generate(input)
        existingPlan = (try? environment.repository.studyPlans(examID: exam.id))?
            .first { $0.status != .archived }
        existingItems = existingPlan.map {
            (try? environment.repository.studyPlanItems(planID: $0.id)) ?? []
        } ?? []
    }

    private func save(_ output: StudyPlanGenerator.Output) {
        isSaving = true
        defer { isSaving = false }
        do {
            if let existingPlan {
                // Replan: keep completed/skipped/user-edited items, replace
                // the rest with the fresh placements (the diff the note
                // above promised).
                let keptIDs = Set(
                    existingItems
                        .filter { $0.userEdited || $0.status != .pending }
                        .map(\.id)
                )
                for item in existingItems where !keptIDs.contains(item.id) {
                    try environment.repository.deleteStudyPlanItem(item)
                }
                var drafts = output.items
                for index in drafts.indices {
                    drafts[index].planID = existingPlan.id
                }
                _ = try environment.repository.addStudyPlanItems(drafts)
                try environment.repository.updateStudyPlan(existingPlan, with: settings)
            } else {
                let plan = try environment.repository.addStudyPlan(settings)
                var drafts = output.items
                for index in drafts.indices {
                    drafts[index].planID = plan.id
                }
                _ = try environment.repository.addStudyPlanItems(drafts)
            }
            LTHaptics.success()
            dismiss()
        } catch {
            saveError = true
        }
    }
}
