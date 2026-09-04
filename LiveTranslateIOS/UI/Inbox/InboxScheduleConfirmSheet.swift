import SwiftUI

/// 课表确认 sheet for an inbox item's schedule candidates — the SAME
/// confirmation contract as ScheduleImageImportView (nothing is written
/// before 保存; courses are created through the normal chain; schedules
/// land via ScheduleViewModel.addSchedule so sync + class reminders
/// re-arm), seeded from the inbox suggestion instead of a photo parse.
struct InboxScheduleConfirmSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let item: SharedInboxItem
    let candidates: [ScheduleCandidateSnapshot]
    /// Reports back: the schedule ids that landed (the caller ledgers the
    /// inbox operation with them).
    let onSaved: ([UUID]) -> Void

    @State private var courses: [Course] = []
    /// Rows the user kept (dropped rows save nothing).
    @State private var kept: [ScheduleCandidateSnapshot] = []
    /// Per-row course assignment: existing id or new-course name.
    @State private var assignment: [String: CourseAssignment] = [:]
    @State private var semesterStart = ScheduleFormView.defaultSemesterStartPublic()
    @State private var semesterEnd = ScheduleFormView.defaultSemesterEndPublic()
    @State private var weekParityAnchor = ScheduleFormView.defaultAnchorPublic()
    @State private var firstWeekIsOdd = true
    @State private var timezoneID = TimeZone.current.identifier
    @State private var reminderLead: ClassReminderScheduler.Lead = .off

    enum CourseAssignment: Hashable {
        case existing(UUID)
        case new(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                ForEach(Array(kept.enumerated()), id: \.offset) { index, _ in
                    candidateSection(index)
                }
                semesterSection
            }
            .navigationTitle("确认课程表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!canSave)
                }
            }
        }
        .task {
            courses = (try? environment.repository.courses()) ?? []
            kept = candidates
        }
    }

    // MARK: - Rows

    private func candidateSection(_ index: Int) -> some View {
        Section {
            let candidate = kept[index]
            Picker("星期", selection: $kept[index].weekday) {
                ForEach(1...7, id: \.self) { weekday in
                    Text(Self.weekdayName(weekday)).tag(weekday)
                }
            }
            HStack {
                timeField("开始", text: timeBinding($kept[index].startSecs))
                timeField("结束", text: timeBinding($kept[index].endSecs))
            }
            Picker("重复", selection: $kept[index].recurrenceRaw) {
                Text("每周").tag("weekly")
                Text("单周").tag("odd_weeks")
                Text("双周").tag("even_weeks")
            }
            TextField("教师（可选）", text: $kept[index].teacher)
            TextField("教室（可选）", text: $kept[index].location)
            coursePicker(candidate)
            if candidate.timeUncertain || candidate.parityUncertain {
                Text(uncertaintyLine(candidate))
                    .font(.caption)
                    .foregroundStyle(LTColors.warning)
            }
            Button(role: .destructive) {
                kept.remove(at: index)
            } label: {
                Text("丢弃这条")
            }
        } header: {
            Text(kept[index].courseName)
        }
    }

    private func coursePicker(_ candidate: ScheduleCandidateSnapshot) -> some View {
        let key = candidate.courseName
        return Picker("归属课程", selection: Binding(
            get: { assignment[key] ?? defaultAssignment(for: candidate) },
            set: { assignment[key] = $0 }
        )) {
            ForEach(courses) { course in
                Text(course.name).tag(CourseAssignment.existing(course.id))
            }
            Text("新建「\(candidate.courseName)」").tag(CourseAssignment.new(candidate.courseName))
        }
    }

    private var semesterSection: some View {
        Section {
            DatePicker("学期开始", selection: $semesterStart, displayedComponents: .date)
            DatePicker("学期结束", selection: $semesterEnd, displayedComponents: .date)
            Toggle("第一周为单周", isOn: $firstWeekIsOdd)
        } header: {
            Text("学期范围")
        } footer: {
            Text("保存后课程表会正常同步，并在下次打开 App 时重新安排上课提醒。")
        }
    }

    // MARK: - Save (the ScheduleImageImportView contract)

    private var canSave: Bool {
        !kept.filter(\.isViable).isEmpty && semesterEnd >= semesterStart
    }

    private func save() {
        let tz = TimeZone(identifier: timezoneID) ?? .current
        let anchor = ScheduleCalculator.weekStart(of: weekParityAnchor, timeZone: tz)
        var createdScheduleIDs: [UUID] = []

        for draft in kept where draft.isViable {
            let courseID: UUID
            switch assignment[draft.courseName] ?? defaultAssignment(for: draft) {
            case .existing(let id):
                courseID = id
            case .new(let name):
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                if let match = courses.first(where: {
                    $0.name.trimmingCharacters(in: .whitespaces) == trimmed
                }) {
                    courseID = match.id
                } else {
                    let courseDraft = CourseDraft(
                        name: trimmed,
                        teacherName: draft.teacher,
                        location: draft.location
                    )
                    let course = (try? environment.repository.createCourse(courseDraft))
                        ?? Course(name: trimmed, teacherName: draft.teacher, location: draft.location)
                    courseID = course.id
                }
            }
            let course = courses.first { $0.id == courseID }
            let draftSchedule = ScheduleDraft(
                courseID: courseID,
                weekday: draft.weekday,
                startSecs: draft.startSecs,
                endSecs: draft.endSecs,
                recurrence: ScheduleRecurrence(rawValue: draft.recurrenceRaw) ?? .weekly,
                weekParityAnchor: ScheduleRecurrence(rawValue: draft.recurrenceRaw) == .weekly
                    ? nil : anchor,
                firstWeekIsOdd: firstWeekIsOdd,
                semesterStart: ScheduleCalculator.dayAnchor(semesterStart, timeZone: tz),
                semesterEnd: ScheduleCalculator.dayAnchor(semesterEnd, timeZone: tz),
                timezoneID: timezoneID,
                teacherOverride: override(draft.teacher, course?.teacherName),
                locationOverride: override(draft.location, course?.location),
                reminderLeadMins: reminderLead.rawValue
            )
            // The SAME chain as ScheduleImageImportView: repository row,
            // then the class-reminder window re-arms.
            if let schedule = try? environment.repository.addSchedule(draftSchedule) {
                createdScheduleIDs.append(schedule.id)
            }
        }
        if !createdScheduleIDs.isEmpty {
            Task { await environment.refreshClassReminders() }
            onSaved(createdScheduleIDs)
        }
        dismiss()
    }

    private func override(_ value: String, _ courseDefault: String?) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if let courseDefault, trimmed == courseDefault { return "" }
        return trimmed
    }

    private func defaultAssignment(for candidate: ScheduleCandidateSnapshot) -> CourseAssignment {
        if let match = courses.first(where: {
            $0.name.trimmingCharacters(in: .whitespaces)
                == candidate.courseName.trimmingCharacters(in: .whitespaces)
        }) {
            return .existing(match.id)
        }
        return .new(candidate.courseName)
    }

    private func uncertaintyLine(_ candidate: ScheduleCandidateSnapshot) -> String {
        var parts: [String] = []
        if candidate.timeUncertain { parts.append("时间不确定") }
        if candidate.parityUncertain { parts.append("单双周不明确") }
        if candidate.teacherUncertain { parts.append("教师不确定") }
        if candidate.locationUncertain { parts.append("教室不确定") }
        return "注意：" + parts.joined(separator: "、")
    }

    // MARK: - Formatting helpers

    private func timeBinding(_ secs: Binding<Int>) -> Binding<String> {
        Binding(
            get: { Self.formatSecs(secs.wrappedValue) },
            set: { text in
                if let parsed = ScheduleImageParser.parseTime(text) {
                    secs.wrappedValue = parsed
                }
            }
        )
    }

    private func timeField(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
            TextField("HH:MM", text: text)
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
        }
    }

    static func weekdayName(_ weekday: Int) -> String {
        ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][min(max(weekday, 0), 6)]
    }

    static func formatSecs(_ secs: Int) -> String {
        String(format: "%02d:%02d", secs / 3600, (secs % 3600) / 60)
    }
}

private extension ScheduleCandidateSnapshot {
    var isViable: Bool {
        !courseName.trimmingCharacters(in: .whitespaces).isEmpty
            && endSecs > startSecs
            && weekday >= 0 && weekday <= 6
    }
}
