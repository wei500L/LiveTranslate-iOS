import SwiftUI
import PhotosUI

/// 课表图片导入 flow: pick an image → parse → review candidates one by
/// one (edit/match to an existing course/fix times/flag uncertainty) →
/// save. NOTHING is written before the user taps 保存 — no Course, no
/// CourseSchedule, no notification, no sync. Missing semester range is
/// asked for explicitly when the model saw none.
struct ScheduleImageImportView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = ScheduleViewModel()

    let courses: [Course]

    @State private var pickerItem: PhotosPickerItem?
    @State private var imageData: Data?
    @State private var isParsing = false
    @State private var parseError: String?
    @State private var parsed: ScheduleImageParser.Parsed?
    /// Draft candidates (user-editable; drops are the 丢弃 action).
    @State private var drafts: [ScheduleImageParser.Candidate] = []
    /// Per-draft course assignment: existing course id or new-course name.
    @State private var assignment: [UUID: CourseAssignment] = [:]
    /// Semester range the user supplied (required before save).
    @State private var semesterStart = ScheduleFormView.defaultSemesterStartPublic()
    @State private var semesterEnd = ScheduleFormView.defaultSemesterEndPublic()
    @State private var weekParityAnchor = ScheduleFormView.defaultAnchorPublic()
    @State private var firstWeekIsOdd = true
    @State private var timezoneID = TimeZone.current.identifier
    @State private var reminderLead: ClassReminderScheduler.Lead = .fifteen
    @State private var didSave = false

    /// What a draft saves into: an existing course or a new one.
    enum CourseAssignment: Hashable {
        case existing(UUID)
        case new(String)
    }

    var body: some View {
        LTPage {
            Group {
                if drafts.isEmpty {
                    pickSection
                } else {
                    reviewSection
                }
            }
        }
        .navigationTitle("课表图片导入")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                if !drafts.isEmpty {
                    Button("保存") { save() }
                        .disabled(!canSave)
                }
            }
        }
        .task {
            viewModel.attach(environment)
            await viewModel.reload()
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await loadPicked(item) }
        }
        .alert("解析失败", isPresented: Binding(
            get: { parseError != nil },
            set: { if !$0 { parseError = nil } }
        )) {
            Button("好", role: .cancel) { parseError = nil }
        } message: {
            Text(parseError ?? "")
        }
    }

    // MARK: - Pick

    private var pickSection: some View {
        ScrollView {
            VStack(spacing: LTSpacing.l) {
                LTEmptyState(
                    symbol: "photo.on.rectangle",
                    title: "选择课程表图片",
                    message: "相册截图或纸质课表照片都可以。解析后每一条都会让你确认。"
                )
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label("选择图片", systemImage: "photo")
                        .font(LTTypography.button)
                        .foregroundStyle(Color.black.opacity(0.85))
                        .frame(maxWidth: .infinity, minHeight: LTSpacing.minTouchTarget)
                }
                .buttonStyle(LTPrimaryButtonStyle())
                .padding(.horizontal, LTSpacing.xl)
                .disabled(isParsing)

                if isParsing {
                    ProgressView("正在解析课表…")
                }
                if let parsed, let missing = parsed.missingInfo, drafts.isEmpty,
                   parsed.candidates.isEmpty {
                    Text(missing)
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textTertiary)
                }
            }
            .padding(LTSpacing.screenPadding)
        }
    }

    // MARK: - Review

    private var reviewSection: some View {
        Form {
            Section {
                if let missing = parsed?.missingInfo, !missing.isEmpty {
                    // The model saw gaps — surface them verbatim.
                    Text(missing)
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.warning)
                }
                Text("共 \(drafts.count) 条候选，请逐条确认。不确定的字段已标记。")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textTertiary)
            }

            Section("学期范围（必填）") {
                DatePicker("学期开始", selection: $semesterStart, displayedComponents: .date)
                DatePicker("学期结束", selection: $semesterEnd, displayedComponents: .date)
                DatePicker("第一周（周一）", selection: $weekParityAnchor, displayedComponents: .date)
                Toggle("第一周是单周", isOn: $firstWeekIsOdd)
                Picker("课程时区", selection: $timezoneID) {
                    ForEach(ScheduleFormView.commonTimezones, id: \.self) { tz in
                        Text(ScheduleFormView.timezoneLabel(tz)).tag(tz)
                    }
                }
                Picker("上课提醒", selection: $reminderLead) {
                    ForEach(ClassReminderScheduler.Lead.allCases, id: \.self) { lead in
                        Text(lead.displayName).tag(lead)
                    }
                }
            }

            Section("课程安排") {
                ForEach($drafts) { $draft in
                    draftRow($draft)
                }
                .onDelete { offsets in
                    drafts.remove(atOffsets: offsets)
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func draftRow(_ draft: Binding<ScheduleImageParser.Candidate>) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            let d = draft.wrappedValue
            // Uncertainty flags — text, never color-only.
            if d.timeUncertain || d.parityUncertain || d.locationUncertain || d.teacherUncertain {
                VStack(alignment: .leading, spacing: 2) {
                    if d.timeUncertain { Text("⚠️ 时间不确定，请核对") }
                    if d.parityUncertain { Text("⚠️ 单双周不明确，默认每周") }
                    if d.locationUncertain { Text("⚠️ 教室无法识别") }
                    if d.teacherUncertain { Text("⚠️ 教师姓名可能有误") }
                }
                .font(LTTypography.timestamp)
                .foregroundStyle(LTColors.warning)
            }

            TextField("课程名称", text: draft.courseName)
                .font(LTTypography.cardTitle)

            Picker("归属课程", selection: Binding(
                get: { assignment[d.id] ?? defaultAssignment(for: d) },
                set: { assignment[d.id] = $0 }
            )) {
                Text("新建课程").tag(CourseAssignment.new(d.courseName))
                ForEach(courses.filter { !$0.isArchived }, id: \.id) { course in
                    Text(course.name).tag(CourseAssignment.existing(course.id))
                }
            }

            Picker("星期", selection: draft.weekday) {
                ForEach(0..<7, id: \.self) { day in
                    Text(ScheduleFormView.weekdayName(day)).tag(day)
                }
            }
            HStack {
                timeField("开始", secs: draft.startSecs)
                timeField("结束", secs: draft.endSecs)
            }
            Picker("重复", selection: draft.recurrence) {
                ForEach(ScheduleRecurrence.allCases, id: \.self) { value in
                    Text(value.displayName).tag(value)
                }
            }
            TextField("教师（可选）", text: draft.teacher)
            TextField("教室（可选）", text: draft.location)
        }
        .padding(.vertical, 2)
    }

    private func timeField(_ label: String, secs: Binding<Int>) -> some View {
        HStack(spacing: LTSpacing.xs) {
            Text(label)
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.textTertiary)
            TextField("", text: Binding(
                get: { Self.formatSecs(secs.wrappedValue) },
                set: { text in
                    if let parsed = ScheduleImageParser.parseTime(text) {
                        secs.wrappedValue = parsed
                    }
                }
            ))
            .keyboardType(.numbersAndPunctuation)
            .multilineTextAlignment(.trailing)
        }
    }

    /// Default course resolution: exact name match → existing, else new.
    private func defaultAssignment(for draft: ScheduleImageParser.Candidate) -> CourseAssignment {
        if let match = courses.first(where: {
            $0.name.trimmingCharacters(in: .whitespaces)
                == draft.courseName.trimmingCharacters(in: .whitespaces)
        }) {
            return .existing(match.id)
        }
        return .new(draft.courseName)
    }

    // MARK: - Parse & save

    private func loadPicked(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            parseError = "无法读取图片"
            return
        }
        imageData = data
        isParsing = true
        defer { isParsing = false }
        let parser = ScheduleImageParser(
            service: environment.attachmentAnalysisService
        )
        do {
            let result = try await parser.parse(
                imageData: data, imageMIME: "image/jpeg"
            )
            parsed = result
            drafts = result.candidates
        } catch {
            parseError = error.localizedDescription
        }
    }

    private var canSave: Bool {
        !drafts.filter(\.isViable).isEmpty
            && semesterEnd >= semesterStart
            && timezoneOK
    }

    private var timezoneOK: Bool { TimeZone(identifier: timezoneID) != nil }

    /// Saves ONLY on the explicit tap: viable drafts become schedules
    /// (creating missing courses first through the normal repository
    /// chain), each with the semester range + reminder the user set.
    /// Sync and reminder scheduling follow automatically — the draft
    /// state never touched the store before this point.
    private func save() {
        guard let environment else { return }
        let tz = TimeZone(identifier: timezoneID) ?? .current
        let anchor = ScheduleCalculator.weekStart(of: weekParityAnchor, timeZone: tz)

        for draft in drafts where draft.isViable {
            let courseID: UUID
            switch assignment[draft.id] ?? defaultAssignment(for: draft) {
            case .existing(let id):
                courseID = id
            case .new(let name):
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                // Re-check against existing (the user may have typed an
                // existing name in the new-course slot).
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
                recurrence: draft.recurrence,
                weekParityAnchor: draft.recurrence == .weekly || draft.recurrence == .once
                    ? nil : anchor,
                firstWeekIsOdd: firstWeekIsOdd,
                semesterStart: ScheduleCalculator.dayAnchor(semesterStart, timeZone: tz),
                semesterEnd: ScheduleCalculator.dayAnchor(semesterEnd, timeZone: tz),
                timezoneID: timezoneID,
                teacherOverride: teacherOverrideFor(draft, course),
                locationOverride: locationOverrideFor(draft, course),
                reminderLeadMins: reminderLead.rawValue
            )
            viewModel.addSchedule(draftSchedule)
        }
        didSave = true
        dismiss()
    }

    /// Overrides ride only when they differ from the course default (an
    /// AI-created course stores teacher/location directly; a matched
    /// existing course keeps its own defaults unless the row differs).
    private func teacherOverrideFor(
        _ draft: ScheduleImageParser.Candidate, _ course: Course?
    ) -> String {
        let name = draft.teacher.trimmingCharacters(in: .whitespaces)
        if let course, name == course.teacherName { return "" }
        return name
    }

    private func locationOverrideFor(
        _ draft: ScheduleImageParser.Candidate, _ course: Course?
    ) -> String {
        let place = draft.location.trimmingCharacters(in: .whitespaces)
        if let course, place == course.location { return "" }
        return place
    }

    private static func formatSecs(_ secs: Int) -> String {
        String(format: "%02d:%02d", secs / 3600, (secs % 3600) / 60)
    }
}
