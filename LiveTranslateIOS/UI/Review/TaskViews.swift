import SwiftUI
import UserNotifications

/// Local-notification reminders for confirmed study tasks with a due
/// date. Fully local: the lead time is a per-task device preference
/// (UserDefaults, account-scoped), the notification itself lives in the
/// system's UserNotifications center, and nothing ever reaches the
/// server. pendingConfirm candidates can never create a reminder.
///
/// Call sites: TaskDetailView toggles; TaskSaveSheet's editor callers
/// re-sync on dueAt change; completing/deleting a task cancels.
@MainActor
final class TaskReminderScheduler {
    /// Lead time choices offered in the UI.
    enum Lead: Int, CaseIterable, Identifiable {
        case atDue = 0
        case oneHourBefore = 60
        case oneDayBefore = 1440

        var id: Int { rawValue }

        var displayName: String {
            switch self {
            case .atDue: return "截止时"
            case .oneHourBefore: return "提前 1 小时"
            case .oneDayBefore: return "提前 1 天"
            }
        }
    }

    private let defaults: UserDefaults
    /// task UUID string → lead minutes. Absent = no reminder.
    private var leads: [String: Int]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let stored = try? JSONDecoder().decode([String: Int].self, from: data) {
            leads = stored
        } else {
            leads = [:]
        }
    }

    var center: UNUserNotificationCenter { .current() }

    /// Whether a reminder is currently enabled for the task.
    func isEnabled(taskID: UUID) -> Bool {
        leads[taskID.uuidString] != nil
    }

    func lead(taskID: UUID) -> Lead {
        Lead(rawValue: leads[taskID.uuidString] ?? 0) ?? .atDue
    }

    /// Enables (or updates) a reminder. Asks for notification permission
    /// on the user's explicit toggle only. Returns false when the user
    /// denied notifications.
    @discardableResult
    func enable(task: StudyTask, lead: Lead) async -> Bool {
        guard task.status != .pendingConfirm else { return false }
        guard let dueAt = task.dueAt else { return false }
        let granted = await requestAuthorizationIfNeeded()
        guard granted else { return false }
        leads[task.id.uuidString] = lead.rawValue
        persist()
        schedule(task: task, dueAt: dueAt, lead: lead)
        return true
    }

    /// Disables and cancels the reminder.
    func disable(taskID: UUID) {
        leads[taskID.uuidString] = nil
        persist()
        cancel(taskID: taskID)
    }

    /// Re-syncs a reminder after a due-date change (keeps the enabled
    /// state, reschedules at the new time).
    func reschedule(task: StudyTask) {
        guard let leadMinutes = leads[task.id.uuidString] else { return }
        cancel(taskID: task.id)
        if let dueAt = task.dueAt, task.status != .pendingConfirm {
            schedule(task: task, dueAt: dueAt, lead: Lead(rawValue: leadMinutes) ?? .atDue)
        }
    }

    private func schedule(task: StudyTask, dueAt: Date, lead: Lead) {
        let fireDate = dueAt.addingTimeInterval(-TimeInterval(lead.rawValue) * 60)
        guard fireDate > .now else { return } // a past due date never fires
        let content = UNMutableNotificationContent()
        content.title = "作业提醒"
        content.body = task.title
        content.sound = .default
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(
            identifier: Self.notificationID(task.id), content: content, trigger: trigger
        )
        center.add(request)
    }

    private func cancel(taskID: UUID) {
        center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID(taskID)])
    }

    private func requestAuthorizationIfNeeded() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default:
            return false
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(leads) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    private static func notificationID(_ taskID: UUID) -> String {
        "task.reminder.\(taskID.uuidString)"
    }

    private static let storageKey = "learning.taskReminders"
}

// MARK: - Task list

/// The 任务 section of the review center: AI candidates awaiting
/// confirmation on top, then the confirmed task list.
struct TaskListView: View {
    @Environment(AppEnvironment.self) private var environment
    @Binding var courses: [Course]
    @Binding var selectedCourseID: UUID?

    @State private var tasks: [StudyTask] = []
    @State private var candidates: [StudyTask] = []
    @State private var searchText = ""
    @State private var includeDone = false
    @State private var editingTask: StudyTask?
    @State private var editingDraft: TaskDraft?
    @State private var showingNewTask = false
    @State private var isLoaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: LTSpacing.m) {
            filterRow
            if isLoaded && tasks.isEmpty && candidates.isEmpty {
                LTEmptyState(
                    symbol: "checklist",
                    title: "还没有任务",
                    message: "从 AI 学习整理确认作业，或在这里手动创建"
                )
            } else if isLoaded {
                if !candidates.isEmpty {
                    candidateSection
                }
                if !tasks.isEmpty {
                    VStack(spacing: LTSpacing.xs) {
                        ForEach(tasks) { task in
                            NavigationLink {
                                TaskDetailView(task: task, courses: courses)
                            } label: {
                                TaskRowView(task: task, onToggleDone: {
                                    toggleDone(task)
                                })
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button { editingTask = task } label: { Label("编辑", systemImage: "pencil") }
                                Button(role: .destructive) {
                                    try? environment.repository.deleteTask(task)
                                    reload()
                                } label: { Label("删除任务", systemImage: "trash") }
                            }
                        }
                    }
                } else if candidates.isEmpty == false {
                    // Only candidates: still show the confirmed-empty hint.
                    Text("已确认的任务会出现在这里")
                        .font(.footnote)
                        .foregroundStyle(LTColors.textTertiary)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, LTSpacing.xl)
            }
        }
        .searchable(text: $searchText, prompt: "搜索任务")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingNewTask = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("新建任务")
            }
        }
        .onAppear { reload() }
        .onChange(of: selectedCourseID) { reload() }
        .onChange(of: searchText) { reload() }
        .onChange(of: includeDone) { reload() }
        .sheet(item: $editingTask) { task in
            TaskSaveSheet(
                draft: TaskDraft(
                    title: task.title,
                    detail: task.detail,
                    priority: task.priority,
                    status: task.status,
                    origin: task.origin,
                    uncertainty: task.uncertainty,
                    userNote: task.userNote,
                    dueAt: task.dueAt,
                    courseID: task.courseID
                ),
                editingTask: task
            ) { _ in reload() }
        }
        .sheet(isPresented: $showingNewTask) {
            TaskSaveSheet(draft: TaskDraft(title: "", courseID: selectedCourseID)) { _ in reload() }
        }
    }

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: LTSpacing.s) {
                Menu {
                    Button("全部课程") { selectedCourseID = nil }
                    ForEach(courses) { course in
                        Button(course.name) { selectedCourseID = course.id }
                    }
                } label: {
                    taskChip(
                        label: selectedCourseID == nil
                            ? "全部课程"
                            : courses.first(where: { $0.id == selectedCourseID })?.name ?? "课程",
                        selected: selectedCourseID != nil
                    )
                }
                Button {
                    includeDone.toggle()
                } label: {
                    taskChip(label: includeDone ? "含已完成" : "未完成", selected: includeDone)
                }
            }
        }
    }

    private var candidateSection: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            LTSectionHeader(title: "待确认（AI 识别）")
            VStack(spacing: LTSpacing.xs) {
                ForEach(candidates) { task in
                    TaskCandidateRow(
                        task: task,
                        onConfirm: { confirm(task) },
                        onEdit: {
                            editingTask = task
                        },
                        onIgnore: { ignore(task) }
                    )
                }
            }
        }
    }

    private func taskChip(label: String, selected: Bool) -> some View {
        Text(label)
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(selected ? LTColors.accentGreen.opacity(0.18) : LTColors.surfacePrimary.opacity(0.7))
            )
            .overlay(
                Capsule().strokeBorder(selected ? LTColors.accentGreen.opacity(0.5) : LTColors.border, lineWidth: 0.5)
            )
            .foregroundStyle(selected ? LTColors.accentGreen : LTColors.textSecondary)
    }

    private func confirm(_ task: StudyTask) {
        try? environment.repository.confirmTask(task)
        LTHaptics.success()
        reload()
    }

    private func ignore(_ task: StudyTask) {
        try? environment.repository.setTaskStatus(task, status: .ignored)
        reload()
    }

    private func toggleDone(_ task: StudyTask) {
        try? environment.repository.setTaskStatus(task, status: task.status == .done ? .pending : .done)
        reload()
    }

    private func reload() {
        if searchText.isEmpty {
            tasks = (try? environment.repository.tasks(courseID: selectedCourseID, includeDone: includeDone)) ?? []
        } else {
            tasks = (try? environment.repository.tasks(matching: searchText)) ?? []
            if let selectedCourseID {
                tasks = tasks.filter { $0.courseID == selectedCourseID }
            }
            if !includeDone {
                tasks = tasks.filter { $0.status == .pending }
            }
        }
        candidates = (try? environment.repository.pendingConfirmTasks()) ?? []
        isLoaded = true
    }
}

/// One AI candidate: confirm / edit / ignore, with the uncertainty note
/// and the source classroom visible before deciding.
struct TaskCandidateRow: View {
    @Environment(AppEnvironment.self) private var environment
    let task: StudyTask
    let onConfirm: () -> Void
    let onEdit: () -> Void
    let onIgnore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: LTSpacing.xs) {
                StatusChip(text: "AI 识别", tint: LTColors.accentBlue)
                Spacer()
                if let dueAt = task.dueAt {
                    Text("截止 \(dueAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(LTTypography.timestamp)
                        .foregroundStyle(LTColors.textTertiary)
                }
            }
            Text(task.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LTColors.textPrimary)
            if !task.uncertainty.isEmpty {
                Text(task.uncertainty)
                    .font(.footnote)
                    .foregroundStyle(LTColors.textSecondary)
            }
            sourceRow
            HStack(spacing: LTSpacing.s) {
                Button(action: onConfirm) {
                    Label("确认", systemImage: "checkmark")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(LTPrimaryButtonStyle())
                Button(action: onEdit) {
                    Text("编辑")
                        .font(.footnote.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(LTSecondaryButtonStyle())
                Button(action: onIgnore) {
                    Text("忽略")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(LTColors.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(LTSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ltCard()
    }

    @ViewBuilder
    private var sourceRow: some View {
        if let sessionID = task.sessionID,
           let session = (try? environment.repository.sessions(matching: ""))?
               .first(where: { $0.id == sessionID }) {
            NavigationLink {
                SessionDetailView(sessionID: sessionID)
            } label: {
                Label("查看课堂依据：\(session.title)", systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(LTColors.accentBlue)
            }
            .buttonStyle(.plain)
        }
    }
}

/// One confirmed task row: checkbox, title, due chip.
struct TaskRowView: View {
    let task: StudyTask
    let onToggleDone: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: LTSpacing.m) {
            Button(action: onToggleDone) {
                Image(systemName: task.status == .done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(task.status == .done ? LTColors.accentGreen : LTColors.textTertiary)
            }
            .accessibilityLabel(task.status == .done ? "标记未完成" : "标记完成")
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(task.status == .done ? LTColors.textTertiary : LTColors.textPrimary)
                    .strikethrough(task.status == .done)
                    .lineLimit(2)
                HStack(spacing: LTSpacing.s) {
                    if let dueAt = task.dueAt {
                        StatusChip(
                            text: dueChipText(dueAt),
                            tint: chipTint(dueAt)
                        )
                    }
                    if task.priority == .high {
                        StatusChip(text: "高优先", tint: LTColors.destructive)
                    }
                    if task.status == .ignored {
                        StatusChip(text: "已忽略", tint: LTColors.textTertiary)
                    }
                }
            }
            Spacer()
        }
        .padding(LTSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ltCard()
        .accessibilityElement(children: .combine)
    }

    private func dueChipText(_ dueAt: Date) -> String {
        if task.status == .done { return "已完成" }
        if dueAt < .now { return "已逾期" }
        return dueAt.formatted(.relative(presentation: .named))
    }

    private func chipTint(_ dueAt: Date) -> Color {
        if task.status == .done { return LTColors.accentGreen }
        if dueAt < .now { return LTColors.destructive }
        if dueAt.timeIntervalSinceNow < 24 * 3600 { return LTColors.warning }
        return LTColors.textSecondary
    }
}

// MARK: - Task detail

/// One task: content, status transitions, reminder toggle (local
/// notifications), source jump, edit, delete.
struct TaskDetailView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let task: StudyTask
    let courses: [Course]

    @State private var editing = false
    @State private var showDeleteConfirm = false
    @State private var reminderEnabled = false
    @State private var reminderLead: TaskReminderScheduler.Lead = .atDue
    @State private var status: StudyTaskStatus = .pending

    var body: some View {
        LTPage {
            ScrollView {
                VStack(alignment: .leading, spacing: LTSpacing.l) {
                    headerCard
                    actionsCard
                    sourceCard
                }
                .padding(.horizontal, LTSpacing.screenPadding)
                .padding(.top, LTSpacing.s)
                .padding(.bottom, LTSpacing.xl)
            }
        }
        .navigationTitle("任务")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { editing = true } label: { Label("编辑", systemImage: "pencil") }
                    Button(role: .destructive) { showDeleteConfirm = true } label: {
                        Label("删除任务", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onAppear {
            status = task.status
            reminderEnabled = environment.taskReminders.isEnabled(taskID: task.id)
            reminderLead = environment.taskReminders.lead(taskID: task.id)
        }
        .sheet(isPresented: $editing) {
            TaskSaveSheet(
                draft: TaskDraft(
                    title: task.title,
                    detail: task.detail,
                    priority: task.priority,
                    status: task.status,
                    origin: task.origin,
                    uncertainty: task.uncertainty,
                    userNote: task.userNote,
                    dueAt: task.dueAt,
                    courseID: task.courseID
                ),
                editingTask: task
            ) { _ in
                status = task.status
                // A due-date change re-syncs the reminder (when enabled).
                environment.taskReminders.reschedule(task: task)
            }
        }
        .confirmationDialog("删除这个任务？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除任务", role: .destructive) {
                environment.taskReminders.disable(taskID: task.id)
                try? environment.repository.deleteTask(task)
                dismiss()
            }
        } message: {
            Text("无法撤销。")
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            Text(task.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(LTColors.textPrimary)
                .textSelection(.enabled)
            if !task.detail.isEmpty {
                Text(task.detail)
                    .font(.subheadline)
                    .foregroundStyle(LTColors.textSecondary)
                    .textSelection(.enabled)
            }
            if !task.userNote.isEmpty {
                Text(task.userNote)
                    .font(.footnote)
                    .foregroundStyle(LTColors.textTertiary)
                    .textSelection(.enabled)
            }
            HStack(spacing: LTSpacing.s) {
                StatusChip(text: statusChipName, tint: statusChipTint)
                if let dueAt = task.dueAt {
                    StatusChip(
                        text: "截止 \(dueAt.formatted(date: .abbreviated, time: .shortened))",
                        tint: dueAt < .now && status == .pending ? LTColors.destructive : LTColors.accentBlue
                    )
                }
                if let courseID = task.courseID,
                   let course = courses.first(where: { $0.id == courseID }) {
                    StatusChip(text: course.name, tint: LTColors.textSecondary)
                }
                if task.origin == .ai {
                    StatusChip(text: "AI 识别", tint: LTColors.accentCyan)
                }
            }
            if let completedAt = task.completedAt, status == .done {
                Text("完成于 \(completedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(LTTypography.timestamp)
                    .foregroundStyle(LTColors.textTertiary)
            }
        }
        .padding(LTSpacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ltCard()
    }

    private var statusChipName: String {
        switch status {
        case .pendingConfirm: return "待确认"
        case .pending: return "待完成"
        case .done: return "已完成"
        case .ignored: return "已忽略"
        }
    }

    private var statusChipTint: Color {
        switch status {
        case .pendingConfirm: return LTColors.accentBlue
        case .pending: return LTColors.warning
        case .done: return LTColors.accentGreen
        case .ignored: return LTColors.textTertiary
        }
    }

    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            LTSectionHeader(title: "操作")
            Button {
                let next: StudyTaskStatus = status == .done ? .pending : .done
                try? environment.repository.setTaskStatus(task, status: next)
                if next == .done {
                    environment.taskReminders.disable(taskID: task.id)
                    reminderEnabled = false
                }
                status = task.status
            } label: {
                Label(
                    status == .done ? "标记为未完成" : "标记为已完成",
                    systemImage: status == .done ? "arrow.uturn.backward" : "checkmark.circle"
                )
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: LTSpacing.minTouchTarget)
            }
            // Type-erase: the two styles are distinct ButtonStyle types
            // and cannot meet in a plain ternary.
            .buttonStyle(
                status == .done
                    ? LTAnyButtonStyle(LTSecondaryButtonStyle())
                    : LTAnyButtonStyle(LTPrimaryButtonStyle())
            )

            if status != .done, task.dueAt != nil {
                Toggle(isOn: $reminderEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("本地提醒")
                            .font(.subheadline)
                        Text("到截止时间前在本地通知，不上传服务器")
                            .font(.caption2)
                            .foregroundStyle(LTColors.textTertiary)
                    }
                }
                .onChange(of: reminderEnabled) { _, enabled in
                    Task {
                        if enabled {
                            let ok = await environment.taskReminders.enable(task: task, lead: reminderLead)
                            if !ok { reminderEnabled = false }
                        } else {
                            environment.taskReminders.disable(taskID: task.id)
                        }
                    }
                }
                if reminderEnabled {
                    Picker("提醒时间", selection: $reminderLead) {
                        ForEach(TaskReminderScheduler.Lead.allCases) { lead in
                            Text(lead.displayName).tag(lead)
                        }
                    }
                    .onChange(of: reminderLead) { _, lead in
                        Task {
                            let ok = await environment.taskReminders.enable(task: task, lead: lead)
                            if !ok { reminderEnabled = false }
                        }
                    }
                }
            }
        }
        .padding(LTSpacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ltCard()
    }

    @ViewBuilder
    private var sourceCard: some View {
        if task.sessionID != nil || task.sourceReviewID != nil {
            VStack(alignment: .leading, spacing: LTSpacing.s) {
                LTSectionHeader(title: "来源")
                if let sessionID = task.sessionID,
                   let session = (try? environment.repository.sessions(matching: ""))?
                       .first(where: { $0.id == sessionID }) {
                    NavigationLink {
                        SessionDetailView(sessionID: sessionID)
                    } label: {
                        Label("课堂：\(session.title)", systemImage: "waveform")
                            .font(.subheadline)
                            .foregroundStyle(LTColors.accentBlue)
                    }
                    .buttonStyle(.plain)
                } else if task.sessionID != nil {
                    Label("来源课堂已删除", systemImage: "waveform.slash")
                        .font(.subheadline)
                        .foregroundStyle(LTColors.textTertiary)
                }
            }
            .padding(LTSpacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .ltCard()
        }
    }
}

