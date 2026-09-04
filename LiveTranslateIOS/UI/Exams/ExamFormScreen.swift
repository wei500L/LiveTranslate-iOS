import SwiftUI

/// 创建/编辑考试 — the manual exam form. Handles: date can never
/// silently sit in the past (the date field clamps + warns), time is
/// optional (只保存日期), location/end optional, long titles and
/// multiline scope. Editing the date of an exam that HAS a plan flags
/// the plan for re-adjustment (the detail screen shows the prompt).
struct ExamFormScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let preselectedCourseID: UUID?
    let editing: Exam?

    @State private var title = ""
    @State private var courseID: UUID?
    @State private var kind: ExamKind = .final
    @State private var date = Date()
    @State private var hasTime = false
    @State private var time = Date()
    @State private var hasEndTime = false
    @State private var endTime = Date()
    @State private var location = ""
    @State private var scope = ""
    @State private var note = ""
    @State private var targetScore = ""

    private var courses: [Course] {
        (try? environment.repository.courses()) ?? []
    }

    var body: some View {
        Form {
            Section("考试") {
                TextField("考试名称（如 高等数学 期中考试）", text: $title)
                Picker("类型", selection: $kind) {
                    ForEach(ExamKind.allCases) { candidate in
                        Text(candidate.displayName).tag(candidate)
                    }
                }
                Picker("课程", selection: $courseID) {
                    Text("未归类").tag(UUID?.none)
                    ForEach(courses) { course in
                        Text(course.name).tag(UUID?.some(course.id))
                    }
                }
            }
            Section {
                DatePicker("日期", selection: $date, displayedComponents: .date)
                if isDateInPast {
                    Label("日期已在过去", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(LTColors.warning)
                }
                Toggle("已知开始时间", isOn: $hasTime.animation)
                if hasTime {
                    DatePicker("开始时间", selection: $time, displayedComponents: .hourAndMinute)
                    Toggle("已知结束时间", isOn: $hasEndTime.animation)
                    if hasEndTime {
                        DatePicker("结束时间", selection: $endTime, displayedComponents: .hourAndMinute)
                    }
                } else {
                    Text("时间未知时只保存日期")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textTertiary)
                }
            } header: {
                Text("时间")
            }
            Section("地点与范围") {
                TextField("地点（可选）", text: $location)
                TextField("目标成绩（可选）", text: $targetScore)
                VStack(alignment: .leading, spacing: 4) {
                    Text("考试范围")
                        .font(.footnote)
                        .foregroundStyle(LTColors.textSecondary)
                    TextEditor(text: $scope)
                        .frame(minHeight: 88)
                        .accessibilityLabel(Text("考试范围"))
                }
            }
            Section("备注") {
                TextField("备注（可选）", text: $note, axis: .vertical)
                    .lineLimit(2...4)
            }
            if editing != nil {
                Section {
                    Text("修改考试日期后，原有学习计划需要在考试详情中重新调整。")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textTertiary)
                }
            }
        }
        .navigationTitle(editing == nil ? "创建考试" : "编辑考试")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }
                    .disabled(trimmedTitle.isEmpty || isDateInPast)
            }
        }
        .onAppear { loadExisting() }
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isDateInPast: Bool {
        Calendar.current.startOfDay(for: date) < Calendar.current.startOfDay(for: .now)
    }

    private func loadExisting() {
        guard let editing, courseID == nil else { return }
        title = editing.title
        courseID = editing.courseID ?? preselectedCourseID
        kind = editing.kind
        if let date = editing.examDate {
            self.date = date
        }
        hasTime = editing.hasTime
        if hasTime, editing.startSecs >= 0 {
            time = Calendar.current.date(
                bySettingHour: editing.startSecs / 3600,
                minute: (editing.startSecs % 3600) / 60, second: 0, of: date
            ) ?? date
            if editing.endSecs > editing.startSecs {
                hasEndTime = true
                endTime = Calendar.current.date(
                    bySettingHour: editing.endSecs / 3600,
                    minute: (editing.endSecs % 3600) / 60, second: 0, of: date
                ) ?? date
            }
        }
        location = editing.location
        scope = editing.scopeText
        note = editing.note
        targetScore = editing.targetScore
    }

    private func save() {
        let calendar = Calendar.current
        var startSecs = -1
        var endSecs = -1
        if hasTime {
            let comps = calendar.dateComponents([.hour, .minute], from: time)
            startSecs = (comps.hour ?? 0) * 3600 + (comps.minute ?? 0) * 60
            if hasEndTime {
                let endComps = calendar.dateComponents([.hour, .minute], from: endTime)
                endSecs = (endComps.hour ?? 0) * 3600 + (endComps.minute ?? 0) * 60
                if endSecs <= startSecs { endSecs = -1 }
            }
        }
        let draft = ExamDraft(
            title: trimmedTitle,
            courseID: courseID,
            kind: kind,
            examDateKey: Exam.dateKey(date),
            startSecs: startSecs,
            endSecs: endSecs,
            location: location.trimmingCharacters(in: .whitespaces),
            scopeText: scope,
            note: note,
            targetScore: targetScore.trimmingCharacters(in: .whitespaces)
        )
        if let editing {
            try? environment.repository.updateExam(editing, with: draft)
            // A date change on a planned exam: re-arm the reminder (the
            // detail screen prompts for the plan adjustment).
            Task {
                let lead = environment.examReminders.lead(examID: editing.id)
                if lead != .off {
                    _ = await environment.examReminders.enable(exam: editing, lead: lead)
                }
            }
        } else {
            _ = try? environment.repository.addExam(draft)
        }
        LTHaptics.success()
        dismiss()
    }
}
