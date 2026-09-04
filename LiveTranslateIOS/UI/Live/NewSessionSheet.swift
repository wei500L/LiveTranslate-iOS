import SwiftUI
import AVFoundation

/// New-classroom form (reference image 2). Presented as a sheet from the
/// home start card (optionally with a preselected course — quick start /
/// course detail); on 开始课堂 it validates, starts the real pipeline
/// coordinator and hands over to the full-screen classroom.
struct NewSessionSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    /// Course preselected by the caller (home quick start / course detail).
    /// The user can still switch or clear it in the form.
    private let preselectedCourse: Course?

    @State private var name = ""
    @State private var isStarting = false
    @State private var nameError: String?
    /// Start-chain validation / launch failure (distinct from nameError so
    /// the two never fight over the same slot).
    @State private var startError: String?
    @State private var micAuthorized = true
    @State private var preferredBackendInstalled = true
    @State private var isRequestingPermission = false
    @State private var showModelManagement = false
    @State private var showCourseForm = false
    /// Courses loaded from the repository; refreshed on appear so a newly
    /// created course appears immediately.
    @State private var courses: [Course] = []
    /// The course this classroom belongs to (nil = standalone).
    @State private var selectedCourseID: UUID?
    /// Set only after a successful coordinator start; the classroom is
    /// presented from onDisappear, once this sheet has fully animated out.
    @State private var shouldOpenLive = false
    @FocusState private var nameFieldFocused: Bool

    private let nameLimit = 60

    init(preselectedCourse: Course? = nil) {
        self.preselectedCourse = preselectedCourse
    }

    var body: some View {
        NavigationStack {
            LTPage {
                ScrollView {
                    VStack(alignment: .leading, spacing: LTSpacing.l) {
                        titleBlock
                        suggestedScheduleSection
                        courseSection
                        nameSection
                        directionSection
                        liveSettingsSection
                        storageSection
                        startButton
                    }
                    .padding(.horizontal, LTSpacing.screenPadding)
                    .padding(.vertical, LTSpacing.l)
                }
            }
            .navigationTitle("新建课堂")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showModelManagement) {
                ModelManagementScreen()
            }
            .sheet(isPresented: $showCourseForm) {
                CourseFormView()
                    .environment(environment)
            }
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
                    .disabled(isStarting || isRequestingPermission)
                }
                ToolbarItem(placement: .keyboard) {
                    HStack {
                        Spacer()
                        Button("收起键盘") { nameFieldFocused = false }
                            .font(.footnote)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        // No dismissal path — interactive or otherwise — while a start (or
        // the system permission dialog) is in flight, so no task can end up
        // writing @State after the sheet is gone.
        .interactiveDismissDisabled(isStarting || isRequestingPermission)
        .onDisappear {
            // Present the classroom only after the sheet has fully
            // dismissed: requesting the full-screen cover mid-dismissal can
            // be dropped by UIKit ("attempt to present while a presentation
            // is in progress"). shouldOpenLive is set only by a successful
            // start(), so a cancelled sheet (xmark, swipe-down, or a push
            // inside this stack) never triggers this.
            if shouldOpenLive {
                environment.presentLive()
            }
            if studyPauseContinuation != nil {
                // The sheet was dismissed with the prompt open: treat as
                // cancel so the continuation never leaks.
                resolveStudyPause(.cancel)
            }
        }
        .confirmationDialog(
            "有正在计时的学习活动",
            isPresented: $showingStudyPausePrompt,
            titleVisibility: .visible
        ) {
            Button("暂停学习并开始课堂") { resolveStudyPause(.pause) }
            Button("结束学习并开始课堂") { resolveStudyPause(.finish) }
            Button("保持计时并开始课堂") { resolveStudyPause(.keepRunning) }
            Button("暂不开课", role: .cancel) { resolveStudyPause(.cancel) }
        } message: {
            Text("课堂录音时间不会计入学习时长。")
        }
        .task {
            // Debug UI demo: prefill the classroom name for deterministic
            // screenshots. Production always starts empty.
            #if DEBUG
            if name.isEmpty, let prefill = environment.flow.demoPrefilledSessionName {
                name = prefill
            }
            #endif
            loadCourses()
            if selectedCourseID == nil, let course = preselectedCourse {
                selectCourse(course, prefillName: name.isEmpty)
            }
            // Near-time class suggestions (suggestion-only; the user picks).
            if selectedCourseID == nil && name.isEmpty {
                loadSuggestedOccurrences()
            }
            // The demo environment short-circuits real permission state so
            // the sheet never depends on (or prompts) the microphone.
            if environment.capabilities.assumesMicrophoneAuthorized {
                micAuthorized = true
            } else {
                micAuthorized = AVAudioApplication.shared.recordPermission == .granted
            }
            preferredBackendInstalled = await environment.engineManager.isInstalled(
                environment.settings.preferredBackend
            )
        }
        .onChange(of: showCourseForm) { _, showing in
            if !showing {
                // A course may have just been created — refresh the chips.
                loadCourses()
            }
        }
    }

    // MARK: - Header

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("为新课堂命名")
                .font(.title3.weight(.bold))
                .foregroundStyle(LTColors.textPrimary)
            Text("俄语授课将被实时转写并翻译成中文，全程自动保存")
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.textSecondary)
        }
    }

    // MARK: - Course

    /// Auto-suggested classes near now (upcoming / in progress / just
    /// ended, per the ScheduleViewModel windows). SUGGESTIONS ONLY —
    /// tapping fills the course + name (the class's own default title);
    /// overlapping candidates all show so the user picks, never a silent
    /// guess, and nothing auto-starts.
    @State private var suggestedOccurrences: [ScheduleCalculator.Occurrence] = []
    @State private var suggestedCourseNames: [UUID: String] = [:]
    @State private var suggestedLocations: [UUID: String] = [:]

    @ViewBuilder
    private var suggestedScheduleSection: some View {
        if !suggestedOccurrences.isEmpty {
            VStack(alignment: .leading, spacing: LTSpacing.xs) {
                Text("按当前时间，这些课可能正在上课")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textTertiary)
                ForEach(suggestedOccurrences.prefix(3)) { occurrence in
                    Button {
                        applySuggestion(occurrence)
                    } label: {
                        HStack(spacing: LTSpacing.s) {
                            Image(systemName: "clock.badge.checkmark")
                                .font(.system(size: 12))
                                .foregroundStyle(LTColors.accentGreen)
                            Text(suggestedCourseNames[occurrence.courseID ?? UUID()] ?? "课程")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(LTColors.textPrimary)
                            if let location = suggestedLocations[occurrence.scheduleID],
                               !location.isEmpty {
                                Text(location)
                                    .font(.footnote)
                                    .foregroundStyle(LTColors.textTertiary)
                            }
                            Spacer()
                            Text("使用")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(LTColors.accentGreen)
                        }
                        .padding(.horizontal, LTSpacing.m)
                        .padding(.vertical, LTSpacing.xs + 1)
                        .background(RoundedRectangle(cornerRadius: LTRadius.small)
                            .fill(LTColors.surfacePrimary))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func applySuggestion(_ occurrence: ScheduleCalculator.Occurrence) {
        guard let courseID = occurrence.courseID,
              let course = courses.first(where: { $0.id == courseID })
        else { return }
        selectCourse(course, prefillName: true)
    }

    private func loadSuggestedOccurrences() {
        let model = ScheduleViewModel()
        model.attach(environment)
        Task {
            await model.reload()
            let suggestions = model.suggestOccurrencesForNewSession()
            suggestedOccurrences = suggestions
            var names: [UUID: String] = [:]
            var locations: [UUID: String] = [:]
            for occurrence in suggestions {
                if let courseID = occurrence.courseID,
                   let course = try? environment.repository.course(id: courseID) {
                    names[courseID] = course.name
                }
                locations[occurrence.scheduleID] = model.location(for: occurrence)
            }
            suggestedCourseNames = names
            suggestedLocations = locations
        }
    }

    /// Course picker: chips of the user's courses plus standalone and a
    /// create entry. Selecting a course pre-fills the session name (still
    /// editable) — repeated weekly classes need zero typing.
    private var courseSection: some View {
        VStack(alignment: .leading, spacing: LTSpacing.xs) {
            Text("所属课程")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(LTColors.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: LTSpacing.s) {
                    courseChip(
                        title: "不归属课程",
                        tint: LTColors.textTertiary,
                        isSelected: selectedCourseID == nil
                    ) {
                        selectedCourseID = nil
                    }
                    ForEach(courses, id: \.id) { course in
                        courseChip(
                            title: course.name,
                            tint: LTCoursePalette.color(course.colorIndex),
                            isSelected: selectedCourseID == course.id,
                            isArchived: course.isArchived
                        ) {
                            selectCourse(course, prefillName: false)
                        }
                    }
                    Button {
                        showCourseForm = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                            Text("新建课程")
                        }
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(LTColors.accentBlue)
                        .padding(.horizontal, LTSpacing.m)
                        .padding(.vertical, LTSpacing.xs + 1)
                        .background(Capsule().strokeBorder(LTColors.accentBlue.opacity(0.4), lineWidth: 0.8))
                    }
                    .accessibilityLabel(Text("新建课程"))
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func courseChip(
        title: String,
        tint: Color,
        isSelected: Bool,
        isArchived: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            withAnimation(LTMotion.quick) { action() }
            LTHaptics.tap()
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(tint)
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? LTColors.textPrimary : LTColors.textSecondary)
            .padding(.horizontal, LTSpacing.m)
            .padding(.vertical, LTSpacing.xs + 1)
            .background(Capsule().fill(isSelected ? tint.opacity(0.16) : LTColors.surfacePrimary))
            .overlay(Capsule().strokeBorder(isSelected ? tint.opacity(0.5) : LTColors.border, lineWidth: 0.6))
            .opacity(isArchived && !isSelected ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// Selecting a course pre-fills an empty name field with the course
    /// name and the date (a per-class default the user can still edit).
    private func selectCourse(_ course: Course, prefillName: Bool) {
        selectedCourseID = course.id
        if prefillName || name.isEmpty {
            name = Self.defaultSessionTitle(for: course)
            nameError = nil
        }
    }

    private static func defaultSessionTitle(for course: Course) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return "\(course.name) · \(formatter.string(from: .now))"
    }

    private func loadCourses() {
        courses = (try? environment.repository.courses()) ?? []
        // A preselected course that no longer exists (deleted elsewhere)
        // falls back to standalone.
        if let id = selectedCourseID, !courses.contains(where: { $0.id == id }) {
            selectedCourseID = nil
        }
    }

    // MARK: - Name

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: LTSpacing.xs) {
            Text("课堂名称")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(LTColors.textSecondary)
            TextField("例如：高等数学 · 第三章", text: $name)
                .font(.body)
                .focused($nameFieldFocused)
                .submitLabel(.done)
                .onSubmit { nameFieldFocused = false }
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

    // MARK: - Direction

    private var directionSection: some View {
        VStack(alignment: .leading, spacing: LTSpacing.xs) {
            Text("翻译方向")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(LTColors.textSecondary)
            HStack(spacing: LTSpacing.s) {
                directionBadge(text: "俄语", symbol: "globe.europe.africa.fill")
                Image(systemName: "arrow.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(LTColors.accentGreen)
                directionBadge(text: "简体中文", symbol: "character.book.closed.fill")
                Spacer()
                Text("当前版本固定")
                    .font(LTTypography.timestamp)
                    .foregroundStyle(LTColors.textTertiary)
            }
            .padding(LTSpacing.m)
            .background(
                RoundedRectangle(cornerRadius: LTRadius.small)
                    .fill(LTColors.surfacePrimary)
            )
            .overlay(RoundedRectangle(cornerRadius: LTRadius.small).strokeBorder(LTColors.border, lineWidth: 0.5))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("翻译方向固定为俄语到简体中文"))
    }

    private func directionBadge(text: String, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.caption)
            Text(text)
                .font(.subheadline.weight(.medium))
        }
        .foregroundStyle(LTColors.textPrimary)
    }

    // MARK: - Core settings

    private var liveSettingsSection: some View {
        VStack(spacing: 0) {
            Toggle(isOn: liveTranslationBinding) {
                settingLabel(
                    title: "实时翻译",
                    detail: "关闭后仅转写并保存俄语原文；重新开启只对新段落生效",
                    symbol: "translate"
                )
            }
            .tint(LTColors.accentGreen)
            .padding(LTSpacing.m)
            Divider().overlay(LTColors.separator)
            settingRow(
                title: "自动保存",
                detail: "俄语原文识别后立即保存在本地，无法关闭",
                symbol: "externaldrive.badge.checkmark",
                trailing: StatusChip(text: "已开启", tint: LTColors.accentGreen)
            )
            Divider().overlay(LTColors.separator)
            localASRRow
        }
        .background(RoundedRectangle(cornerRadius: LTRadius.small).fill(LTColors.surfacePrimary))
        .overlay(RoundedRectangle(cornerRadius: LTRadius.small).strokeBorder(LTColors.border, lineWidth: 0.5))
    }

    /// 本地转写 state is bound to the real install state; tapping when not
    /// ready routes to model management.
    @ViewBuilder
    private var localASRRow: some View {
        HStack(spacing: LTSpacing.s) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 15))
                .foregroundStyle(LTColors.accentCyan)
            VStack(alignment: .leading, spacing: 1) {
                Text("本地转写")
                    .font(.subheadline)
                    .foregroundStyle(LTColors.textPrimary)
                Text(preferredBackendInstalled ? "本地模式 · 已就绪" : "语言资源未准备好")
                    .font(LTTypography.caption)
                    .foregroundStyle(preferredBackendInstalled ? LTColors.textSecondary : LTColors.warning)
            }
            Spacer()
            if preferredBackendInstalled {
                StatusChip(text: "本地转写可用", tint: LTColors.accentGreen)
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(LTColors.textTertiary)
            }
        }
        .padding(LTSpacing.m)
        .contentShape(Rectangle())
        .onTapGesture {
            if !preferredBackendInstalled {
                showModelManagement = true
            }
        }
        .accessibilityHint(preferredBackendInstalled ? Text("") : Text("语言资源未安装，双击前往语言资源管理"))
    }

    // MARK: - Mic

    private var storageSection: some View {
        HStack(spacing: LTSpacing.s) {
            Image(systemName: "mic.badge.plus")
                .font(.system(size: 15))
                .foregroundStyle(micAuthorized ? LTColors.accentGreen : LTColors.warning)
            VStack(alignment: .leading, spacing: 1) {
                Text("麦克风来源")
                    .font(.subheadline)
                    .foregroundStyle(LTColors.textPrimary)
                Text(micAuthorized ? currentMicRoute : "未授权 · 请先在系统设置中允许麦克风")
                    .font(LTTypography.caption)
                    .foregroundStyle(micAuthorized ? LTColors.textSecondary : LTColors.warning)
            }
            Spacer()
            if !micAuthorized {
                Button("前往授权") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(LTColors.accentBlue)
            }
        }
        .padding(LTSpacing.m)
        .background(RoundedRectangle(cornerRadius: LTRadius.small).fill(LTColors.surfacePrimary))
        .overlay(RoundedRectangle(cornerRadius: LTRadius.small).strokeBorder(LTColors.border, lineWidth: 0.5))
    }

    private var currentMicRoute: String {
        let inputs = AVAudioSession.sharedInstance().currentRoute.inputs
        if let input = inputs.first {
            return input.portType == .builtInMic ? "iPhone 麦克风" : input.portName
        }
        return "iPhone 麦克风"
    }

    // MARK: - Start

    private var startButton: some View {
        VStack(spacing: LTSpacing.s) {
            if let startError {
                Text(startError)
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.destructive)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                Task { await start() }
            } label: {
                HStack(spacing: LTSpacing.s) {
                    if isStarting || isRequestingPermission {
                        ProgressView()
                            .tint(Color.black.opacity(0.7))
                    } else {
                        Image(systemName: "play.fill")
                    }
                    Text(isStarting ? "正在进入课堂…" : "开始课堂")
                }
            }
            .buttonStyle(LTPrimaryButtonStyle())
            .disabled(isStarting || isRequestingPermission)
        }
        .padding(.top, LTSpacing.s)
    }

    // MARK: - Actions

    private var liveTranslationBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.liveTranslationEnabled },
            set: { environment.settings.liveTranslationEnabled = $0 }
        )
    }

    private func settingLabel(title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: LTSpacing.s) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(LTColors.accentCyan)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(LTColors.textPrimary)
                Text(detail)
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textSecondary)
            }
        }
    }

    private func settingRow(title: String, detail: String, symbol: String, trailing: some View) -> some View {
        HStack(spacing: LTSpacing.s) {
            settingLabel(title: title, detail: detail, symbol: symbol)
            Spacer()
            trailing
        }
        .padding(LTSpacing.m)
    }

    /// The full validation chain from the spec: name → active-session guard
    /// → study-activity guard (pause prompt) → mic permission → local
    /// resources → start. Re-entrancy guarded so rapid double-taps can
    /// never create two sessions or two starts.
    private func start() async {
        guard !isStarting && !isRequestingPermission else { return }
        nameFieldFocused = false
        startError = nil

        // 0. Learning-timer guard: a running study activity is offered a
        //    pause/finish choice — starting the classroom recording
        //    proceeds only after the user decides (the classroom's own
        //    time never counts as study time).
        if environment.studyActivityTracker.hasActiveActivity {
            guard await confirmStudyPause() else { return }
        }

        // 1. Name.
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            nameError = "请填写课堂名称"
            LTHaptics.warning()
            return
        }

        // 2. Active-session guard (double start / re-entry). A collapsed
        // classroom keeps running behind the home tab, so starting a second
        // one must be refused explicitly.
        guard !environment.coordinator.isRunning else {
            startError = "已有一堂课正在进行，请先结束当前课堂"
            LTHaptics.warning()
            return
        }

        // 3. Microphone permission (request if undetermined). The demo
        //    environment opts out — it must never raise the system prompt.
        if environment.capabilities.requestsMicrophonePermission {
            if AVAudioApplication.shared.recordPermission == .undetermined {
                isRequestingPermission = true
                let granted = await AudioCaptureService.recordPermission()
                isRequestingPermission = false
                micAuthorized = granted
            } else {
                micAuthorized = AVAudioApplication.shared.recordPermission == .granted
            }
        } else {
            micAuthorized = true
        }
        guard micAuthorized else {
            startError = "需要麦克风权限才能录制课堂，请在系统设置中开启"
            LTHaptics.warning()
            return
        }

        // 4. Local language resources.
        var resourcesReady = preferredBackendInstalled
        if !resourcesReady {
            resourcesReady = await environment.engineManager.isInstalled(
                environment.settings.preferredBackend
            )
        }
        guard resourcesReady else {
            startError = "语言资源尚未安装，请在“我的 → 语言资源管理”中完成下载"
            LTHaptics.warning()
            return
        }

        // 5. Start the real pipeline. Failure is detected via the
        // coordinator's resulting state (engine load / VAD / mic capture
        // all surface as non-running phases): on failure the sheet stays
        // up with a retryable error — the button is never left dead.
        isStarting = true
        LTHaptics.success()
        await environment.coordinator.start(
            title: trimmedName, courseID: selectedCourseID, schedule: nil
        )
        isStarting = false

        if environment.coordinator.isRunning {
            // Classroom created and the coordinator is live. The classroom
            // screen is presented from onDisappear, once this sheet has
            // fully animated out (see above).
            shouldOpenLive = true
            dismiss()
        } else {
            startError = "课堂启动失败，请重试；若反复失败，请在“我的 → 语言资源管理”中检查语言资源。"
            LTHaptics.warning()
        }
    }

    /// The study-activity prompt: pause (recording and studying are
    /// different activities — the classroom recording never counts as
    /// study time), finish, or cancel the classroom start. Returns
    /// whether the classroom start should proceed.
    private enum StudyPauseChoice {
        case pause, finish, keepRunning, cancel
    }

    private func confirmStudyPause() async -> Bool {
        return await withCheckedContinuation { continuation in
            studyPauseContinuation = continuation
            showingStudyPausePrompt = true
        }
    }

    @State private var showingStudyPausePrompt = false
    @State private var studyPauseContinuation: CheckedContinuation<Bool, Never>?

    private func resolveStudyPause(_ choice: StudyPauseChoice) {
        showingStudyPausePrompt = false
        let proceed: Bool
        switch choice {
        case .pause:
            environment.studyActivityTracker.pause()
            proceed = true
        case .finish:
            environment.studyActivityTracker.complete()
            proceed = true
        case .keepRunning:
            // The user keeps the timer running — allowed, but honest:
            // classroom time still never counts as study time.
            proceed = true
        case .cancel:
            proceed = false
        }
        studyPauseContinuation?.resume(returning: proceed)
        studyPauseContinuation = nil
    }
}
