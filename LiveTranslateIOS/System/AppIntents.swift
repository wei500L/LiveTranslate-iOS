import Foundation
// @preconcurrency: AppShortcut is not Sendable in the SDK (the compiler's
// own remediation hint); the static shortcuts list is immutable.
@preconcurrency import AppIntents

/// The app's App Intents — real actions over the ACTIVE profile's data,
/// performing in the app process (the system launches the app when a
/// Siri / Shortcuts / Action Button invocation arrives). Navigation
/// intents route through the unified SystemRouteCoordinator; the
/// create-task intent writes through the real repository. The classroom
/// start intent never starts the microphone by itself: it lands on the
/// new-classroom form, whose full validation + confirmation chain runs
/// there.
///
/// App Shortcuts phrases are declared normally (AppShortcutsProvider);
/// Siri recognition is the system's call — nothing here promises a fixed
/// phrase.

// MARK: - Navigation intents

/// 打开当前课堂 — returns to the running classroom, or opens the app at
/// home when none runs (honest, no fake classroom).
struct OpenCurrentClassroomIntent: AppIntent {
    static let title: LocalizedStringResource = "打开当前课堂"
    static let description = IntentDescription("回到正在进行的课堂；没有课堂时打开首页。")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        let running = await AppIntentHost.withEnvironment { $0.coordinator.isRunning } ?? false
        await AppIntentHost.open(running ? .currentClassroom : .newSession)
        return .result()
    }
}

/// 打开下一堂课 — lands on the home tab's next-class card (the controlled
/// start chain with every permission / resource check).
struct OpenNextClassIntent: AppIntent {
    static let title: LocalizedStringResource = "查看下一堂课"
    static let description = IntentDescription("打开下一堂课的时间、地点与状态。")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await AppIntentHost.open(.nextClass)
        return .result()
    }
}

/// 准备开始下一堂课 — opens the new-classroom form (explicit confirmation
/// before the microphone starts; never a background recording).
struct PrepareNextClassIntent: AppIntent {
    static let title: LocalizedStringResource = "准备开始下一堂课"
    static let description = IntentDescription("打开新建课堂表单，确认后再开始录音。")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await AppIntentHost.open(.newSession)
        return .result()
    }
}

/// 打开今日学习 — the review center's 今天 segment.
struct OpenTodayStudyIntent: AppIntent {
    static let title: LocalizedStringResource = "打开今日学习"
    static let description = IntentDescription("查看今天的学习计划与复习安排。")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await AppIntentHost.open(.todayStudy)
        return .result()
    }
}

/// 开始或继续学习 — if a learning timer runs, continue it (route to its
/// card); otherwise land on today's study segment where the next item's
/// 开始 lives.
struct StartOrContinueStudyIntent: AppIntent {
    static let title: LocalizedStringResource = "开始学习"
    static let description = IntentDescription("继续正在计时的学习，或打开今天的学习计划。")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await AppIntentHost.open(.todayStudy)
        return .result()
    }
}

/// 开始指定的学习计划项 (Shortcuts parameterized path).
struct StartStudyItemIntent: AppIntent {
    static let title: LocalizedStringResource = "学习这个计划项"
    static let description = IntentDescription("打开该计划项所在的计划详情。")
    static let openAppWhenRun = true

    @Parameter(title: "计划项")
    var item: StudyPlanItemEntity

    init() {}
    init(item: StudyPlanItemEntity) {
        self.item = item
    }

    func perform() async throws -> some IntentResult {
        await AppIntentHost.open(.planItem(item.id))
        return .result()
    }
}

/// 打开下一场考试 (or a parameterized exam).
struct OpenNextExamIntent: AppIntent {
    static let title: LocalizedStringResource = "查看下一场考试"
    static let description = IntentDescription("打开最近一场考试的详情与倒计时。")
    static let openAppWhenRun = true

    @Parameter(title: "考试")
    var exam: ExamEntity?

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        if let exam {
            await AppIntentHost.open(.exam(exam.id))
            return .result(dialog: "已打开考试详情。")
        }
        // No parameter: resolve the nearest scheduled exam from the real
        // repository (nil = honest empty dialog, never a fabricated one).
        // Note the double optional: withEnvironment returns T? and the
        // closure itself yields Exam? — two bindings flatten it.
        let next = (await AppIntentHost.withEnvironment { environment -> Exam? in
            let exams = (try? environment.repository.exams(
                courseID: nil, includeCandidates: false
            )) ?? []
            return exams
                .filter { $0.status == .scheduled && ($0.daysUntilExam ?? -1) >= 0 }
                .min {
                    ($0.examDate ?? .distantFuture) < ($1.examDate ?? .distantFuture)
                }
        }) ?? nil
        guard let next else {
            return .result(dialog: "近期没有安排的考试。")
        }
        await AppIntentHost.open(.exam(next.id))
        return .result(dialog: "已打开最近的考试。")
    }
}

/// 打开收件箱.
struct OpenInboxIntent: AppIntent {
    static let title: LocalizedStringResource = "查看收件箱"
    static let description = IntentDescription("整理从其他应用分享进来的资料与链接。")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await AppIntentHost.open(.inbox(nil))
        return .result()
    }
}

/// 打开拍摄黑板 — requires a running classroom; without one it opens the
/// new-classroom form (the camera lives inside a classroom).
struct OpenBlackboardCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "拍黑板"
    static let description = IntentDescription("在课堂上拍摄黑板与讲义。")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        let running = await AppIntentHost.withEnvironment { $0.coordinator.isRunning } ?? false
        await AppIntentHost.open(running ? .captureBlackboard : .newSession)
        return .result()
    }
}

// MARK: - Open interpreter (随身翻译)

/// 打开随身翻译页面。只导航 —— 绝不在后台开启麦克风（收音永远由
/// 页面内显式按钮触发）。
struct OpenInterpreterIntent: AppIntent {
    static let title: LocalizedStringResource = "打开随身翻译"
    static let description = IntentDescription("面对面办事口译：俄语工作人员 ⇄ 中文。")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await AppIntentHost.open(.interpreter)
        return .result()
    }
}

/// 打开办事事项列表 —— 只导航，不自动建事项、不自动开麦。
struct OpenErrandCasesIntent: AppIntent {
    static let title: LocalizedStringResource = "打开办事事项"
    static let description = IntentDescription("查看办事事项的材料清单、预约与跟进。")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await AppIntentHost.open(.errandCaseList)
        return .result()
    }
}

/// 打开下一个需要行动的办事事项 —— 只导航；标题受系统界面隐私策略
/// 门控（仅状态档不回显标题）。
struct OpenNextErrandIntent: AppIntent {
    static let title: LocalizedStringResource = "打开下一个办事事项"
    static let description = IntentDescription("直接打开最近有预约、逾期或需要跟进的办事事项。")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        let outcome: (route: SystemRouteRequest, dialog: IntentDialog)? =
            await AppIntentHost.withEnvironment { environment in
                let viewModel = ErrandViewModel()
                viewModel.attach(environment)
                viewModel.reload()
                let showsTitles = SettingsStore.shared.systemSurfacePrivacy.showsTitles
                if let highlight = viewModel.homeHighlights().first {
                    return (
                        SystemRouteRequest.errandCase(highlight.errandCase.id),
                        showsTitles
                            ? IntentDialog("已打开：\(highlight.errandCase.title)")
                            : IntentDialog("已打开办事事项")
                    )
                }
                return (SystemRouteRequest.errandCaseList, IntentDialog("当前没有需要处理的办事事项"))
            }
        guard let outcome else {
            return .result(dialog: IntentDialog("已打开办事事项"))
        }
        await AppIntentHost.open(outcome.route)
        return .result(dialog: outcome.dialog)
    }
}

// MARK: - Create task (real repository write)

/// 快速创建任务 — title (required), optional course, optional due date.
/// Writes through the REAL repository (a confirmed pending task, origin
/// manual); never a dead form page and never sample data.
struct CreateTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "创建任务"
    static let description = IntentDescription("在 LiveTranslate 中创建一条待办任务。")

    @Parameter(title: "标题")
    var title: String

    @Parameter(title: "课程")
    var course: CourseEntity?

    @Parameter(title: "截止日期")
    var dueDate: Date?

    init() {}
    init(title: String, course: CourseEntity?, dueDate: Date?) {
        self.title = title
        self.course = course
        self.dueDate = dueDate
    }

    func perform() async throws -> some IntentResult {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .result(dialog: "任务标题不能为空。")
        }
        let created = await AppIntentHost.withEnvironment { environment -> Bool in
            let draft = TaskDraft(
                title: trimmed,
                status: .pending,
                origin: .manual,
                dueAt: dueDate,
                courseID: course?.id
            )
            return ((try? environment.repository.addTask(draft)) ?? nil) != nil
        }
        guard created == true else {
            return .result(dialog: "暂时无法创建任务，请打开 App 后重试。")
        }
        // Round 17: at the strictest surface level Siri does not read the
        // task title back aloud (the user just dictated it — no value in
        // echoing; the policy keeps spoken surfaces title-free).
        let showsTitles = await MainActor.run {
            SettingsStore.shared.systemSurfacePrivacy.showsTitles
        }
        return .result(dialog: showsTitles
            ? "已创建任务「\(trimmed)」。"
            : "已创建任务。")
    }
}

// MARK: - App Shortcuts (Siri phrases)

struct LiveTranslateShortcuts: AppShortcutsProvider {
    // AppShortcutIcon was removed from the SDK; the modern provider knob
    // is the tile color (the per-shortcut systemImageName stays below).
    static var shortcutTileColor: ShortcutTileColor {
        .blue
    }

    static let appShortcuts: [AppShortcut] = [
        AppShortcut(
            intent: OpenTodayStudyIntent(),
            phrases: [
                "在 \(.applicationName) 打开今天学习",
                "用 \(.applicationName) 看今天的学习计划"
            ],
            shortTitle: "今日学习",
            systemImageName: "graduationcap"
        ),
        AppShortcut(
            intent: OpenNextClassIntent(),
            phrases: [
                "在 \(.applicationName) 查看下一堂课",
                "用 \(.applicationName) 看下一堂课"
            ],
            shortTitle: "下一堂课",
            systemImageName: "calendar"
        ),
        AppShortcut(
            intent: OpenBlackboardCaptureIntent(),
            phrases: [
                "在 \(.applicationName) 拍黑板",
                "用 \(.applicationName) 拍黑板"
            ],
            shortTitle: "拍黑板",
            systemImageName: "camera"
        ),
        AppShortcut(
            intent: OpenInboxIntent(),
            phrases: [
                "在 \(.applicationName) 查看收件箱",
                "用 \(.applicationName) 打开收件箱"
            ],
            shortTitle: "收件箱",
            systemImageName: "tray.full"
        ),
        AppShortcut(
            intent: OpenCurrentClassroomIntent(),
            phrases: [
                "在 \(.applicationName) 打开当前课堂",
                "用 \(.applicationName) 回到课堂"
            ],
            shortTitle: "当前课堂",
            systemImageName: "waveform"
        ),
        AppShortcut(
            intent: OpenInterpreterIntent(),
            phrases: [
                "在 \(.applicationName) 打开随身翻译",
                "用 \(.applicationName) 做办事翻译"
            ],
            shortTitle: "随身翻译",
            systemImageName: "person.2.wave.2"
        ),
        AppShortcut(
            intent: OpenNextErrandIntent(),
            phrases: [
                "在 \(.applicationName) 打开下一个办事事项",
                "用 \(.applicationName) 看办事清单"
            ],
            shortTitle: "办事事项",
            systemImageName: "checklist"
        )
    ]
}
