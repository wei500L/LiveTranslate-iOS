import SwiftUI

/// Create / edit one recurring schedule. The manual-add flow stays simple:
/// course → weekday → times → recurrence → semester range → optional
/// covers → reminder. Copy support: an existing schedule seeds the form
/// with a different weekday (复制并改期).
struct ScheduleFormView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = ScheduleViewModel()

    let courses: [Course]
    /// Edit target (nil = create).
    let editing: CourseSchedule?
    /// Copy source: seeds fields but saves as a NEW row (the 复制 flow).
    let copying: CourseSchedule?

    @State private var selectedCourseID: UUID?
    @State private var weekday = 1
    @State private var startTime = Calendar.current.date(
        bySettingHour: 10, minute: 30, second: 0, of: .now
    ) ?? .now
    @State private var endTime = Calendar.current.date(
        bySettingHour: 12, minute: 5, second: 0, of: .now
    ) ?? .now
    @State private var recurrence: ScheduleRecurrence = .weekly
    /// Semester week-1 anchor (Monday). Defaults to the week of the
    /// semester start the user picks.
    @State private var weekParityAnchor = Self.defaultAnchor()
    @State private var firstWeekIsOdd = true
    @State private var semesterStart = Self.defaultSemesterStart()
    @State private var semesterEnd = Self.defaultSemesterEnd()
    @State private var timezoneID = TimeZone.current.identifier
    @State private var teacherOverride = ""
    @State private var locationOverride = ""
    @State private var note = ""
    @State private var reminderLead: ClassReminderScheduler.Lead = .fifteen
    @State private var isEnabled = true
    @State private var showTimezonePicker = false
    @State private var requestedAuthorization = false

    init(
        courses: [Course],
        editing: CourseSchedule? = nil,
        copying: CourseSchedule? = nil,
        preselectedCourseID: UUID? = nil
    ) {
        self.courses = courses
        self.editing = editing
        self.copying = copying
        if let editing {
            _selectedCourseID = State(initialValue: editing.courseID)
            _weekday = State(initialValue: editing.weekday)
            _recurrence = State(initialValue: editing.recurrence)
            _timezoneID = State(initialValue: editing.timezoneID)
            _teacherOverride = State(initialValue: editing.teacherOverride)
            _locationOverride = State(initialValue: editing.locationOverride)
            _note = State(initialValue: editing.note)
            _reminderLead = State(initialValue: ClassReminderScheduler.Lead(
                rawValue: editing.reminderLeadMins
            ) ?? .off)
            _isEnabled = State(initialValue: editing.isEnabled)
            if let anchor = editing.weekParityAnchor {
                _weekParityAnchor = State(initialValue: anchor)
            }
            _firstWeekIsOdd = State(initialValue: editing.firstWeekIsOdd)
            _semesterStart = State(initialValue: editing.semesterStart)
            _semesterEnd = State(initialValue: editing.semesterEnd)
            // Rebuild wall-clock times from the schedule's seconds.
            let tz = TimeZone(identifier: editing.timezoneID) ?? .current
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = tz
            let ref = editing.onceDate ?? .now
            let day = cal.startOfDay(for: ref)
            _startTime = State(initialValue: cal.date(
                byAdding: .second, value: editing.startSecs, to: day
            ) ?? day)
            _endTime = State(initialValue: cal.date(
                byAdding: .second, value: editing.endSecs, to: day
            ) ?? day)
        } else if let copying {
            // Copy flow: seed everything except the id (a new row results).
            _selectedCourseID = State(initialValue: copying.courseID ?? preselectedCourseID)
            _weekday = State(initialValue: copying.weekday)
            _recurrence = State(initialValue: copying.recurrence)
            _timezoneID = State(initialValue: copying.timezoneID)
            _teacherOverride = State(initialValue: copying.teacherOverride)
            _locationOverride = State(initialValue: copying.locationOverride)
            _note = State(initialValue: copying.note)
            _reminderLead = State(initialValue: ClassReminderScheduler.Lead(
                rawValue: copying.reminderLeadMins
            ) ?? .off)
            _semesterStart = State(initialValue: copying.semesterStart)
            _semesterEnd = State(initialValue: copying.semesterEnd)
            if let anchor = copying.weekParityAnchor {
                _weekParityAnchor = State(initialValue: anchor)
            }
            _firstWeekIsOdd = State(initialValue: copying.firstWeekIsOdd)
            let tz = TimeZone(identifier: copying.timezoneID) ?? .current
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = tz
            let day = cal.startOfDay(for: .now)
            _startTime = State(initialValue: cal.date(
                byAdding: .second, value: copying.startSecs, to: day
            ) ?? day)
            _endTime = State(initialValue: cal.date(
                byAdding: .second, value: copying.endSecs, to: day
            ) ?? day)
        } else {
            _selectedCourseID = State(initialValue: preselectedCourseID)
        }
    }

    var body: some View {
        LTPage {
            Form {
                Section("课程") {
                    Picker("课程", selection: $selectedCourseID) {
                        Text("选择课程").tag(UUID?.none)
                        ForEach(courses.filter { !$0.isArchived }, id: \.id) { course in
                            Text(course.name).tag(UUID?.some(course.id))
                        }
                    }
                    if let courseID = selectedCourseID,
                       let course = courses.first(where: { $0.id == courseID }) {
                        // Course defaults show as inherited values (the
                        // schedule only stores overrides).
                        LabeledContent("默认教师", value: course.teacherName.isEmpty ? "未设置" : course.teacherName)
                        LabeledContent("默认地点", value: course.location.isEmpty ? "未设置" : course.location)
                    }
                }

                Section("时间") {
                    Picker("星期", selection: $weekday) {
                        ForEach(0..<7, id: \.self) { day in
                            Text(Self.weekdayName(day)).tag(day)
                        }
                    }
                    DatePicker("开始", selection: $startTime, displayedComponents: .hourAndMinute)
                    DatePicker("结束", selection: $endTime, displayedComponents: .hourAndMinute)
                }

                Section("重复") {
                    Picker("重复方式", selection: $recurrence) {
                        ForEach(ScheduleRecurrence.allCases, id: \.self) { value in
                            Text(value.displayName).tag(value)
                        }
                    }
                    .onChange(of: recurrence) { _, newValue in
                        if newValue == .once {
                            // A one-off class runs on the picked semester
                            // start by default (editable below via once date).
                        }
                    }
                    if needsParity {
                        DatePicker(
                            "学期第一周（周一）",
                            selection: $weekParityAnchor,
                            displayedComponents: .date
                        )
                        Toggle("第一周是单周", isOn: $firstWeekIsOdd)
                    }
                    DatePicker(
                        "学期开始", selection: $semesterStart, displayedComponents: .date
                    )
                    DatePicker(
                        "学期结束", selection: $semesterEnd, displayedComponents: .date
                    )
                    Button {
                        showTimezonePicker.toggle()
                    } label: {
                        LabeledContent(
                            "课程时区",
                            value: Self.timezoneLabel(timezoneID)
                        )
                    }
                    if showTimezonePicker {
                        Picker("时区", selection: $timezoneID) {
                            ForEach(Self.commonTimezones, id: \.self) { tz in
                                Text(Self.timezoneLabel(tz)).tag(tz)
                            }
                        }
                        .pickerStyle(.inline)
                    }
                }

                Section("覆盖（可选，默认用课程信息）") {
                    TextField("教师（留空用课程默认）", text: $teacherOverride)
                    TextField("地点（留空用课程默认）", text: $locationOverride)
                    TextField("备注", text: $note)
                }

                Section("提醒") {
                    Picker("上课提醒", selection: $reminderLead) {
                        ForEach(ClassReminderScheduler.Lead.allCases, id: \.self) { lead in
                            Text(lead.displayName).tag(lead)
                        }
                    }
                    .onChange(of: reminderLead) { _, newValue in
                        if newValue != .off, !requestedAuthorization {
                            requestedAuthorization = true
                            Task {
                                await environment.classReminders.requestAuthorizationIfNeeded()
                            }
                        }
                    }
                }

                Section {
                    Toggle("启用这条日程", isOn: $isEnabled)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(editing != nil ? "编辑日程" : "添加日程")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }
                    .disabled(!isValid)
            }
        }
    }

    private var needsParity: Bool {
        switch recurrence {
        case .biweekly, .oddWeeks, .evenWeeks: return true
        case .weekly, .once: return false
        }
    }

    private var isValid: Bool {
        selectedCourseID != nil && endTime > startTime && semesterEnd >= semesterStart
    }

    private func save() {
        guard let courseID = selectedCourseID else { return }
        let tz = TimeZone(identifier: timezoneID) ?? .current
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let day = cal.startOfDay(for: startTime)
        let startSecs = Int(startTime.timeIntervalSince(day).rounded())
        let endSecs = Int(max(endTime.timeIntervalSince(day), startTime.timeIntervalSince(day)).rounded())

        let anchor: Date? = needsParity ? ScheduleCalculator.weekStart(
            of: weekParityAnchor, timeZone: tz
        ) : nil

        let draft = ScheduleDraft(
            courseID: courseID,
            weekday: weekday,
            startSecs: startSecs,
            endSecs: endSecs,
            recurrence: recurrence,
            weekParityAnchor: anchor,
            firstWeekIsOdd: firstWeekIsOdd,
            semesterStart: ScheduleCalculator.dayAnchor(semesterStart, timeZone: tz),
            semesterEnd: ScheduleCalculator.dayAnchor(semesterEnd, timeZone: tz),
            timezoneID: timezoneID,
            teacherOverride: teacherOverride,
            locationOverride: locationOverride,
            note: note,
            reminderLeadMins: reminderLead.rawValue,
            isEnabled: isEnabled,
            onceDate: nil
        )
        viewModel.attach(environment)
        if let editing {
            viewModel.updateSchedule(editing, with: draft)
        } else {
            viewModel.addSchedule(draft)
        }
        dismiss()
    }

    // MARK: - Defaults & labels (public: the image-import sheet reuses
    // the same semester/anchor/timezone defaults)

    static func defaultSemesterStartPublic() -> Date {
        defaultSemesterStart()
    }

    static func defaultSemesterEndPublic() -> Date {
        defaultSemesterEnd()
    }

    static func defaultAnchorPublic() -> Date {
        weekStartDefault()
    }

    private static func defaultSemesterStart() -> Date {
        // September 1st of the current academic year (RU semester start).
        let calendar = Calendar.current
        var comps = calendar.dateComponents([.year, .month, .day], from: .now)
        comps.month = 9
        comps.day = 1
        if let start = calendar.date(from: comps), start > .now {
            comps.year! -= 1
            return calendar.date(from: comps) ?? .now
        }
        return start ?? .now
    }

    private static func defaultSemesterEnd() -> Date {
        let calendar = Calendar.current
        let start = defaultSemesterStart()
        return calendar.date(byAdding: .month, value: 4, to: start) ?? start
    }

    private static func defaultAnchor() -> Date {
        weekStartDefault()
    }

    private static func weekStartDefault() -> Date {
        let calendar = Calendar.current
        var comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: .now)
        comps.weekday = 2
        return calendar.date(from: comps) ?? .now
    }

    static func weekdayName(_ day: Int) -> String {
        ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][day]
    }

    /// A short, safe set of timezone choices (the course location zone,
    /// the home zone, UTC) — never a hardcoded single zone.
    static var commonTimezones: [String] {
        var zones = [
            TimeZone.current.identifier,
            "Europe/Moscow",
            "Asia/Shanghai",
            "UTC"
        ]
        return Array(Set(zones)).sorted()
    }

    static func timezoneLabel(_ identifier: String) -> String {
        let tz = TimeZone(identifier: identifier)
        var seconds = 0
        if let tz {
            seconds = tz.secondsFromGMT(for: .now)
        }
        let hours = seconds / 3600
        let minutes = abs(seconds % 3600) / 60
        let offset = String(format: "%+03d:%02d", hours, minutes)
        return "\(identifier)（UTC\(offset)）"
    }
}

/// One dated deviation of a schedule (停课 / 调课 / 临时加课).
struct ScheduleExceptionSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = ScheduleViewModel()

    let schedule: CourseSchedule
    /// Edit target (nil = create).
    let editing: ScheduleException?

    @State private var kind: ScheduleExceptionKind = .cancelled
    @State private var originalDate = Date()
    @State private var hasNewTime = false
    @State private var changedStart = Date()
    @State private var changedEnd = Date()
    @State private var hasMovedDate = false
    @State private var movedToDate = Date()
    @State private var locationOverride = ""
    @State private var teacherOverride = ""
    @State private var note = ""

    init(schedule: CourseSchedule, editing: ScheduleException? = nil) {
        self.schedule = schedule
        self.editing = editing
        if let editing {
            _kind = State(initialValue: editing.kind)
            _originalDate = State(initialValue: editing.originalDate ?? .now)
            if let start = editing.changedStart {
                let tz = TimeZone(identifier: schedule.timezoneID) ?? .current
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = tz
                let day = cal.startOfDay(for: editing.originalDate ?? .now)
                _changedStart = State(initialValue: cal.date(byAdding: .second, value: start, to: day) ?? day)
                _hasNewTime = State(initialValue: true)
            }
            if let end = editing.changedEnd {
                let tz = TimeZone(identifier: schedule.timezoneID) ?? .current
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = tz
                let day = cal.startOfDay(for: editing.originalDate ?? .now)
                _changedEnd = State(initialValue: cal.date(byAdding: .second, value: end, to: day) ?? day)
            }
            if let moved = editing.movedToDate {
                _movedToDate = State(initialValue: moved)
                _hasMovedDate = State(initialValue: true)
            }
            _locationOverride = State(initialValue: editing.locationOverride)
            _teacherOverride = State(initialValue: editing.teacherOverride)
            _note = State(initialValue: editing.note)
        }
    }

    var body: some View {
        LTPage {
            Form {
                Section {
                    Picker("类型", selection: $kind) {
                        ForEach(ScheduleExceptionKind.allCases, id: \.self) { value in
                            Text(value.displayName).tag(value)
                        }
                    }
                    if kind != .adHoc {
                        DatePicker("原定日期", selection: $originalDate, displayedComponents: .date)
                    }
                }

                if kind != .cancelled {
                    Section("调整") {
                        if kind == .timeChanged {
                            Toggle("调整时间", isOn: $hasNewTime)
                            if hasNewTime {
                                DatePicker("新开始", selection: $changedStart, displayedComponents: .hourAndMinute)
                                DatePicker("新结束", selection: $changedEnd, displayedComponents: .hourAndMinute)
                            }
                            Toggle("调整日期", isOn: $hasMovedDate)
                            if hasMovedDate {
                                DatePicker("改到", selection: $movedToDate, displayedComponents: .date)
                            }
                        } else {
                            // ad_hoc: the extra class's own date + times.
                            DatePicker("日期", selection: $movedToDate, displayedComponents: .date)
                            DatePicker("开始", selection: $changedStart, displayedComponents: .hourAndMinute)
                            DatePicker("结束", selection: $changedEnd, displayedComponents: .hourAndMinute)
                        }
                    }
                }

                Section("本次覆盖（可选）") {
                    TextField("地点", text: $locationOverride)
                    TextField("教师", text: $teacherOverride)
                    TextField("说明", text: $note)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(editing != nil ? "编辑例外" : "添加例外")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }
                    .disabled(!isValid)
            }
        }
    }

    private var isValid: Bool {
        if kind == .adHoc { return true }
        if kind == .timeChanged && hasNewTime && changedEnd <= changedStart { return false }
        return true
    }

    private func save() {
        let tz = TimeZone(identifier: schedule.timezoneID) ?? .current
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        func secs(of date: Date, on day: Date) -> Int {
            let startOfDay = cal.startOfDay(for: day)
            return Int(date.timeIntervalSince(startOfDay).rounded())
        }

        var changedStartSecs: Int?
        var changedEndSecs: Int?
        var movedDate: Date?
        var original: Date?

        switch kind {
        case .cancelled:
            original = ScheduleCalculator.dayAnchor(originalDate, timeZone: tz)
        case .timeChanged:
            original = ScheduleCalculator.dayAnchor(originalDate, timeZone: tz)
            if hasNewTime {
                changedStartSecs = secs(of: changedStart, on: originalDate)
                changedEndSecs = secs(of: changedEnd, on: originalDate)
            }
            if hasMovedDate {
                movedDate = ScheduleCalculator.dayAnchor(movedToDate, timeZone: tz)
            }
        case .adHoc:
            movedDate = ScheduleCalculator.dayAnchor(movedToDate, timeZone: tz)
            changedStartSecs = secs(of: changedStart, on: movedToDate)
            changedEndSecs = secs(of: changedEnd, on: movedToDate)
            // Ad-hoc rides movedToDate as the extra day (originalDate nil).
            movedDate = movedDate
        }

        let draft = ScheduleExceptionDraft(
            scheduleID: schedule.id,
            courseID: schedule.courseID,
            originalDate: original,
            kind: kind,
            changedStart: changedStartSecs,
            changedEnd: changedEndSecs,
            movedToDate: kind == .adHoc
                ? ScheduleCalculator.dayAnchor(movedToDate, timeZone: tz)
                : movedDate,
            locationOverride: locationOverride,
            teacherOverride: teacherOverride,
            note: note
        )
        viewModel.attach(environment)
        if let editing {
            viewModel.updateException(editing, with: draft)
        } else {
            viewModel.addException(draft)
        }
        dismiss()
    }
}
