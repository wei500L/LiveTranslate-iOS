import SwiftUI

/// 学习计划设置 — capacity-first form: start date, exam date (read-only
/// from the exam), weekday/weekend minutes, rest days, finish-early
/// days, content toggles, focus topics and blocked times. Saving opens
/// the PREVIEW (生成先预览，确认后才保存) — nothing persists here.
struct StudyPlanFormScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let examID: UUID

    @State private var exam: Exam?
    @State private var startDate = Calendar.current.startOfDay(for: .now)
    @State private var weekdayMinutes = 60
    @State private var weekendMinutes = 90
    @State private var restDays: Set<Int> = []
    @State private var finishEarlyDays = 1
    @State private var includeCards = true
    @State private var includeTasks = true
    @State private var includeMaterials = true
    @State private var includeSessions = true
    @State private var focusTopics: Set<UUID> = []
    @State private var topics: [ExamTopic] = []
    @State private var blockedTimes: [StudyBlockedTime] = []
    @State private var showingPreview = false
    @State private var isLoaded = false

    private let minuteOptions = [30, 45, 60, 90, 120, 180]

    var body: some View {
        LTPage {
            ScrollView {
                VStack(alignment: .leading, spacing: LTSpacing.l) {
                    if isLoaded, let exam {
                        settingsContent(exam)
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
                if isLoaded, exam != nil {
                    Button {
                        showingPreview = true
                    } label: {
                        Label("预览学习计划", systemImage: "eye")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: LTSpacing.minTouchTarget)
                    }
                    .buttonStyle(LTPrimaryButtonStyle())
                    .padding(.horizontal, LTSpacing.screenPadding)
                    .padding(.vertical, LTSpacing.s)
                    .background(.ultraThinMaterial)
                }
            }
        }
        .navigationTitle("学习计划设置")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingPreview) {
            if let exam {
                NavigationStack {
                    StudyPlanPreviewScreen(
                        exam: exam,
                        settings: buildDraft()
                    )
                    .environment(environment)
                }
            }
        }
        .onAppear { load() }
    }

    private func settingsContent(_ exam: Exam) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.l) {
            // 考试日期卡片（只读 — 计划跟随考试）。
            VStack(alignment: .leading, spacing: LTSpacing.xs) {
                LTSectionHeader(title: "目标考试")
                if let date = exam.examDate {
                    let days = exam.daysUntilExam ?? 0
                    Text("\(exam.title) · \(date.formatted(date: .long, time: .omitted))（\(days >= 0 ? "还有 \(days) 天" : "已结束")）")
                        .font(.subheadline)
                        .foregroundStyle(LTColors.textPrimary)
                }
            }
            .ltCard()

            // 每日容量 — 不要默认假设每天都有大量时间。
            VStack(alignment: .leading, spacing: LTSpacing.s) {
                LTSectionHeader(title: "每天可学习时间")
                capacityPicker("工作日", selection: $weekdayMinutes)
                capacityPicker("周末", selection: $weekendMinutes)
                Toggle(isOn: Binding(
                    get: { restDays.contains(2) },
                    set: { restDays.update(with: 2, isOn: $0) }
                )) {
                    Text("周一不安排")
                        .font(.subheadline)
                }
                weekdayToggle(1, "周日")
                weekdayToggle(7, "周六")
                Stepper("提前 \(finishEarlyDays) 天完成第一轮（留作考前复习）",
                        value: $finishEarlyDays, in: 0...7)
                    .font(.subheadline)
            }
            .ltCard()

            // 内容来源。
            VStack(alignment: .leading, spacing: LTSpacing.xs) {
                LTSectionHeader(title: "计划内容")
                toggleRow("包含到期复习卡", $includeCards, "rectangle.on.rectangle")
                toggleRow("包含未完成作业", $includeTasks, "checklist")
                toggleRow("包含课程资料阅读", $includeMaterials, "book.fill")
                toggleRow("包含课堂回顾", $includeSessions, "waveform")
            }
            .ltCard()

            // 重点主题。
            if !topics.isEmpty {
                VStack(alignment: .leading, spacing: LTSpacing.s) {
                    LTSectionHeader(title: "重点主题（优先安排）")
                    VStack(spacing: LTSpacing.xs) {
                        ForEach(topics) { topic in
                            Button {
                                if focusTopics.contains(topic.id) {
                                    focusTopics.remove(topic.id)
                                } else {
                                    focusTopics.insert(topic.id)
                                }
                            } label: {
                                HStack(spacing: LTSpacing.s) {
                                    Image(systemName: focusTopics.contains(topic.id)
                                        ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(
                                            focusTopics.contains(topic.id)
                                                ? LTColors.accentGreen : LTColors.textTertiary
                                        )
                                    Text(topic.title)
                                        .font(.subheadline)
                                        .foregroundStyle(LTColors.textPrimary)
                                    Spacer()
                                    Text(topic.importance.displayName)
                                        .font(LTTypography.caption)
                                        .foregroundStyle(LTColors.textTertiary)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(focusTopics.contains(topic.id) ? [.isSelected] : [])
                        }
                    }
                }
                .ltCard()
            }

            // 不希望安排学习的时间段。
            VStack(alignment: .leading, spacing: LTSpacing.s) {
                LTSectionHeader(title: "避开时间段（可选）")
                ForEach(blockedTimes) { blocked in
                    HStack {
                        Text(blockedLabel(blocked))
                            .font(.subheadline)
                            .foregroundStyle(LTColors.textPrimary)
                        Spacer()
                        Button(role: .destructive) {
                            blockedTimes.removeAll { $0.id == blocked.id }
                        } label: {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(LTColors.destructive)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button {
                    blockedTimes.append(StudyBlockedTime(
                        weekdays: [], startSecs: 22 * 3600, endSecs: 23 * 3600
                    ))
                } label: {
                    Label("添加时间段", systemImage: "plus")
                        .font(.footnote.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(LTColors.accentGreen)
                Text("计划按剩余容量安排，不会假设你全天有空。")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textTertiary)
            }
            .ltCard()
        }
    }

    private func capacityPicker(_ label: String, selection: Binding<Int>) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
            Spacer()
            Picker("", selection: selection) {
                ForEach(minuteOptions, id: \.self) { minutes in
                    Text("\(minutes) 分钟").tag(minutes)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    private func toggleRow(_ title: String, _ binding: Binding<Bool>, _ symbol: String) -> some View {
        Toggle(isOn: binding) {
            Label(title, systemImage: symbol)
                .font(.subheadline)
        }
    }

    private func weekdayToggle(_ weekday: Int, _ label: String) -> some View {
        Toggle(isOn: Binding(
            get: { restDays.contains(weekday) },
            set: { restDays.update(with: weekday, isOn: $0) }
        )) {
            Text("\(label)不安排")
                .font(.subheadline)
        }
    }

    private func blockedLabel(_ blocked: StudyBlockedTime) -> String {
        let days = blocked.weekdays.isEmpty
            ? "每天"
            : blocked.weekdays.map(weekdayName).joined(separator: "、")
        return "\(days) \(timeText(blocked.startSecs))–\(timeText(blocked.endSecs))"
    }

    private func weekdayName(_ weekday: Int) -> String {
        ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][max(1, weekday) - 1]
    }

    private func timeText(_ secs: Int) -> String {
        String(format: "%02d:%02d", secs / 3600, (secs % 3600) / 60)
    }

    private func buildDraft() -> StudyPlanDraft {
        StudyPlanDraft(
            examID: examID,
            title: (exam?.title ?? "考试") + " 复习计划",
            startDateKey: Exam.dateKey(startDate),
            endDateKey: exam?.examDateKey ?? Exam.dateKey(startDate),
            weekdayMinutes: weekdayMinutes,
            weekendMinutes: weekendMinutes,
            restDays: Array(restDays),
            finishEarlyDays: finishEarlyDays,
            includeCards: includeCards,
            includeTasks: includeTasks,
            includeMaterials: includeMaterials,
            includeSessions: includeSessions,
            focusTopics: Array(focusTopics),
            blockedTimes: blockedTimes
        )
    }

    private func load() {
        exam = try? environment.repository.exam(id: examID)
        topics = (try? environment.repository.examTopics(examID: examID)) ?? []
        // Default focus: high-importance topics.
        focusTopics = Set(topics.filter { $0.importance == .high }.map(\.id))
        if let existingPlan = (try? environment.repository.studyPlans(examID: examID))?.first {
            // Editing an existing plan's settings: prefill from it.
            startDate = existingPlan.startDate ?? startDate
            weekdayMinutes = existingPlan.weekdayMinutes
            weekendMinutes = existingPlan.weekendMinutes
            restDays = Set(existingPlan.restDays)
            finishEarlyDays = existingPlan.finishEarlyDays
            includeCards = existingPlan.includeCards
            includeTasks = existingPlan.includeTasks
            includeMaterials = existingPlan.includeMaterials
            includeSessions = existingPlan.includeSessions
            focusTopics = Set(existingPlan.focusTopics)
        }
        isLoaded = true
    }
}

extension Set {
    /// Toggle-style helper for rest-day sets.
    mutating func update(with element: Element, isOn: Bool) {
        if isOn {
            insert(element)
        } else {
            remove(element)
        }
    }
}
