import SwiftUI

/// Source references a piece of learning material came from. All fields
/// optional — a manually-created term has none, an AI-review term has
/// review + entry refs, a blackboard-formula card has an attachment ref.
/// Derived material keeps these so the user can always jump back to the
/// classroom (dangling refs display 来源已不存在).
struct LearningSourceRef: Sendable, Equatable {
    var courseID: UUID?
    var sessionID: UUID?
    var entryID: UUID?
    var attachmentID: UUID?
    var reviewID: UUID?
    var termID: UUID?

    init(
        courseID: UUID? = nil,
        sessionID: UUID? = nil,
        entryID: UUID? = nil,
        attachmentID: UUID? = nil,
        reviewID: UUID? = nil,
        termID: UUID? = nil
    ) {
        self.courseID = courseID
        self.sessionID = sessionID
        self.entryID = entryID
        self.attachmentID = attachmentID
        self.reviewID = reviewID
        self.termID = termID
    }
}

// MARK: - Course picker (shared by the three forms)

/// Compact course selector: a menu row + optional "未分类". Reads courses
/// through the environment repository on appear.
struct LearningCoursePicker: View {
    @Environment(AppEnvironment.self) private var environment
    @Binding var courseID: UUID?
    @State private var courses: [Course] = []

    var body: some View {
        Menu {
            Button("未分类") { courseID = nil }
            ForEach(courses) { course in
                Button(course.name) { courseID = course.id }
            }
        } label: {
            HStack {
                Text("所属课程")
                    .font(.subheadline)
                Spacer()
                Text(currentName)
                    .font(.subheadline)
                    .foregroundStyle(LTColors.textSecondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(LTColors.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .onAppear { courses = (try? environment.repository.courses()) ?? [] }
    }

    private var currentName: String {
        guard let courseID,
              let course = courses.first(where: { $0.id == courseID }) else {
            return "未分类"
        }
        return course.name
    }
}

// MARK: - Term save sheet

/// Create/edit a glossary term. Saving runs the dedup check against the
/// same course: an existing normalized match offers 查看 / 合并来源 /
/// 仍要保存 — the user's existing chinese/explanation/note is never
/// silently overwritten.
struct TermSaveSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var draft: TermDraft
    @State private var duplicate: GlossaryTerm?
    @State private var showDuplicateAlert = false

    /// Called after a successful save (the caller can toast/refresh).
    var onSaved: ((GlossaryTerm) -> Void)?

    init(draft: TermDraft = TermDraft(russian: ""), onSaved: ((GlossaryTerm) -> Void)? = nil) {
        _draft = State(initialValue: draft)
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            LTPage {
                Form {
                    Section("术语") {
                        TextField("俄语原词", text: $draft.russian)
                            .autocorrectionDisabled()
                        TextField("中文含义", text: $draft.chinese)
                        TextField("词性（可选，如 сущ.）", text: $draft.partOfSpeech)
                    }
                    Section("解释与备注") {
                        TextField("解释（AI 提取或自己补充）", text: $draft.explanation, axis: .vertical)
                            .lineLimit(2...5)
                        TextField("我的记忆提示（可选）", text: $draft.userNote, axis: .vertical)
                            .lineLimit(1...3)
                    }
                    Section {
                        LearningCoursePicker(courseID: $draft.courseID)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("保存术语")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(draft.russian.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("该课程已有这个术语", isPresented: $showDuplicateAlert) {
                Button("查看已有术语") { showExisting() }
                Button("合并来源") { mergeIntoDuplicate() }
                Button("仍要保存", role: .destructive) { forceSave() }
                Button("取消", role: .cancel) {}
            } message: {
                if let duplicate {
                    Text("「\(duplicate.russian)」已保存在此课程。可以查看它、把本次来源合并进去，或另存为独立词条。")
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func save() {
        draft.russian = draft.russian.trimmingCharacters(in: .whitespacesAndNewlines)
        // Dedup within the same course (normalized russian match).
        // (try? already flattens the optional return — one binding.)
        if let existing = try? environment.repository.findTerm(
            courseID: draft.courseID, russian: draft.russian
        ) {
            duplicate = existing
            showDuplicateAlert = true
            return
        }
        forceSave()
    }

    private func forceSave() {
        if let term = try? environment.repository.addTerm(draft) {
            LTHaptics.success()
            onSaved?(term)
        }
        dismiss()
    }

    private func mergeIntoDuplicate() {
        guard let duplicate else { return }
        try? environment.repository.mergeTermSources(
            duplicate,
            sessionID: draft.sessionID,
            entryID: draft.sourceEntryID,
            attachmentID: draft.sourceAttachmentID
        )
        LTHaptics.success()
        onSaved?(duplicate)
        dismiss()
    }

    private func showExisting() {
        // Keep the sheet open with the duplicate loaded for editing.
        if let duplicate {
            draft = TermDraft(
                russian: duplicate.russian,
                chinese: duplicate.chinese,
                explanation: duplicate.explanation,
                partOfSpeech: duplicate.partOfSpeech,
                userNote: duplicate.userNote,
                courseID: duplicate.courseID
            )
        }
    }
}

// MARK: - Card save sheet

/// Create/edit a study card. Used from terms (一键制卡), key points,
/// transcript selections, image formulas and manual creation.
struct CardSaveSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var draft: CardDraft

    var onSaved: ((StudyCard) -> Void)?

    init(draft: CardDraft = CardDraft(front: "", back: ""), onSaved: ((StudyCard) -> Void)? = nil) {
        _draft = State(initialValue: draft)
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            LTPage {
                Form {
                    Section("卡片内容") {
                        TextField("正面（问题 / 俄语）", text: $draft.front, axis: .vertical)
                            .lineLimit(1...4)
                        TextField("背面（答案 / 中文）", text: $draft.back, axis: .vertical)
                            .lineLimit(1...6)
                        Picker("类型", selection: $draft.type) {
                            ForEach(StudyCardType.allCases, id: \.self) { type in
                                Text(type.displayName).tag(type)
                            }
                        }
                    }
                    Section("备注（可选）") {
                        TextField("只给自己看的提示", text: $draft.userNote, axis: .vertical)
                            .lineLimit(1...3)
                    }
                    Section {
                        LearningCoursePicker(courseID: $draft.courseID)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("制作卡片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        draft.front = draft.front.trimmingCharacters(in: .whitespacesAndNewlines)
                        draft.back = draft.back.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let card = try? environment.repository.addCard(draft) {
                            LTHaptics.success()
                            onSaved?(card)
                        }
                        dismiss()
                    }
                    .disabled(draft.front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || draft.back.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Task save sheet

/// Create/edit a study task. AI candidates arrive as drafts with
/// `status: .pendingConfirm` plus an uncertainty note — the user edits
/// and confirms here (confirm = first push to the sync pipeline).
struct TaskSaveSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var draft: TaskDraft
    /// True when editing an existing (possibly pendingConfirm) task.
    let editingTask: StudyTask?

    var onSaved: ((StudyTask) -> Void)?

    init(draft: TaskDraft = TaskDraft(title: ""), editingTask: StudyTask? = nil, onSaved: ((StudyTask) -> Void)? = nil) {
        _draft = State(initialValue: draft)
        self.editingTask = editingTask
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            LTPage {
                Form {
                    Section("任务") {
                        TextField("标题", text: $draft.title)
                        TextField("详细说明（可选）", text: $draft.detail, axis: .vertical)
                            .lineLimit(1...4)
                        DatePicker("截止时间", selection: Binding(
                            get: { draft.dueAt ?? Date().addingTimeInterval(24 * 3600) },
                            set: { draft.dueAt = $0 }
                        ), displayedComponents: [.date, .hourAndMinute])
                        Toggle("无截止时间", isOn: Binding(
                            get: { draft.dueAt == nil },
                            set: { draft.dueAt = $0 ? nil : Date().addingTimeInterval(24 * 3600) }
                        ))
                        Picker("优先级", selection: $draft.priority) {
                            ForEach(StudyTaskPriority.allCases, id: \.self) { priority in
                                Text(priority.displayName).tag(priority)
                            }
                        }
                    }
                    Section {
                        LearningCoursePicker(courseID: $draft.courseID)
                        TextField("我的备注（可选）", text: $draft.userNote, axis: .vertical)
                            .lineLimit(1...3)
                    }
                    if !draft.uncertainty.isEmpty {
                        Section("AI 识别依据") {
                            Text(draft.uncertainty)
                                .font(.footnote)
                                .foregroundStyle(LTColors.textSecondary)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(editingTask == nil ? "新建任务" : "编辑任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func save() {
        draft.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let editingTask {
            try? environment.repository.updateTask(editingTask, with: draft)
            onSaved?(editingTask)
        } else if let task = try? environment.repository.addTask(draft) {
            onSaved?(task)
        }
        LTHaptics.success()
        dismiss()
    }
}
