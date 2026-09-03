import SwiftUI

/// Create / edit course form. All fields write through the repository on
/// save (never view-only state): creating inserts a `Course`, editing
/// applies the draft to the existing row — both notify the cloud-sync
/// mutation observer.
struct CourseFormView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    /// The course being edited; nil = create.
    private let course: Course?

    @State private var name = ""
    @State private var teacher = ""
    @State private var location = ""
    @State private var colorIndex = 0
    @State private var nameError: String?
    @FocusState private var nameFocused: Bool

    private let nameLimit = 60

    init(course: Course? = nil) {
        self.course = course
    }

    var body: some View {
        NavigationStack {
            LTPage {
                ScrollView {
                    VStack(alignment: .leading, spacing: LTSpacing.l) {
                        header
                        nameSection
                        detailSection
                        colorSection
                        saveButton
                    }
                    .padding(.horizontal, LTSpacing.screenPadding)
                    .padding(.vertical, LTSpacing.l)
                }
            }
            .navigationTitle(course == nil ? "新建课程" : "编辑课程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(LTColors.textSecondary)
                    }
                    .accessibilityLabel(Text("关闭"))
                }
                ToolbarItem(placement: .keyboard) {
                    HStack {
                        Spacer()
                        Button("收起键盘") { nameFocused = false }
                            .font(.footnote)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear(perform: populateFromExisting)
    }

    private func populateFromExisting() {
        guard let course, name.isEmpty else { return }
        name = course.name
        teacher = course.teacherName
        location = course.location
        colorIndex = course.colorIndex
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(course == nil ? "为一门课程建立档案" : "调整课程信息")
                .font(.title3.weight(.bold))
                .foregroundStyle(LTColors.textPrimary)
            Text("同一门课的每堂课都会归到它名下，上课时无需再重复输入")
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.textSecondary)
        }
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: LTSpacing.xs) {
            Text("课程名称")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(LTColors.textSecondary)
            TextField("例如：高等数学 II", text: $name)
                .font(.body)
                .focused($nameFocused)
                .submitLabel(.done)
                .onSubmit { nameFocused = false }
                .onChange(of: name) { _, newValue in
                    if newValue.count > nameLimit {
                        name = String(newValue.prefix(nameLimit))
                    }
                    if nameError != nil {
                        nameError = nil
                    }
                }
                .padding(LTSpacing.m)
                .background(
                    RoundedRectangle(cornerRadius: LTRadius.small)
                        .fill(LTColors.surfacePrimary)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: LTRadius.small)
                        .strokeBorder(
                            nameError != nil ? LTColors.destructive.opacity(0.7) : LTColors.border,
                            lineWidth: 0.8
                        )
                )
            HStack {
                if let nameError {
                    Text(nameError)
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.destructive)
                }
                Spacer()
                Text("\(name.count)/\(nameLimit)")
                    .font(LTTypography.timestamp)
                    .foregroundStyle(LTColors.textTertiary)
                    .monospacedDigit()
            }
        }
    }

    private var detailSection: some View {
        VStack(spacing: 0) {
            optionalField(
                title: "教师", placeholder: "例如：Иванова М.А.", text: $teacher
            )
            Divider().overlay(LTColors.separator)
            optionalField(
                title: "地点", placeholder: "例如：主楼 304 教室", text: $location
            )
        }
        .background(RoundedRectangle(cornerRadius: LTRadius.small).fill(LTColors.surfacePrimary))
        .overlay(RoundedRectangle(cornerRadius: LTRadius.small).strokeBorder(LTColors.border, lineWidth: 0.5))
    }

    private func optionalField(title: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: LTSpacing.s) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(LTColors.textSecondary)
                .frame(width: 44, alignment: .leading)
            TextField(placeholder, text: text)
                .font(.body)
                .submitLabel(.done)
        }
        .padding(LTSpacing.m)
    }

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: LTSpacing.xs) {
            Text("课程颜色")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(LTColors.textSecondary)
            HStack(spacing: LTSpacing.m) {
                ForEach(0..<LTCoursePalette.colors.count, id: \.self) { index in
                    let isSelected = index == colorIndex
                    Button {
                        colorIndex = index
                        LTHaptics.tap()
                    } label: {
                        Circle()
                            .fill(LTCoursePalette.color(index))
                            .frame(width: isSelected ? 30 : 24, height: isSelected ? 30 : 24)
                            .overlay(
                                Circle().strokeBorder(
                                    isSelected ? LTColors.textPrimary : .clear,
                                    lineWidth: 1.5
                                )
                                .padding(-3)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("课程颜色 \(index + 1)"))
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }
                Spacer()
            }
            .padding(.vertical, LTSpacing.xs)
        }
    }

    private var saveButton: some View {
        Button {
            save()
        } label: {
            Text("保存")
        }
        .buttonStyle(LTPrimaryButtonStyle())
        .padding(.top, LTSpacing.s)
    }

    // MARK: - Actions

    private func save() {
        nameFocused = false
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            nameError = "请填写课程名称"
            LTHaptics.warning()
            return
        }
        let draft = CourseDraft(
            name: trimmed,
            teacherName: teacher.trimmingCharacters(in: .whitespacesAndNewlines),
            location: location.trimmingCharacters(in: .whitespacesAndNewlines),
            colorIndex: colorIndex
        )
        do {
            if let course {
                try environment.repository.updateCourse(course, with: draft)
            } else {
                _ = try environment.repository.createCourse(draft)
            }
            LTHaptics.success()
            dismiss()
        } catch {
            nameError = "保存失败，请重试"
            LTHaptics.warning()
        }
    }
}
