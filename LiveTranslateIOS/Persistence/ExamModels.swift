import Foundation
import SwiftData

// Exam-center entities: exams (考试), their knowledge topics (考试主题),
// study plans (学习计划), plan items (计划项目) and study activities
// (学习活动) — the layer that organizes existing tasks, cards, terms,
// materials and classroom records around exam goals.
//
// All entities follow the SessionNote/LearningModels/MaterialModels
// conventions: a stable client-generated UUID, plain UUID columns for
// source references (never SwiftData relationships — entities sync
// independently and rows may arrive before their sources), enums stored
// as rawValue string columns, and `serverVersion` cloud-sync metadata.
//
// Survival semantics (mirrors the Go server's 00012 handlers):
// - deleting a COURSE clears the exam's `courseID` (考试转入未归类) and
//   the activity's course attribution (学习历史保留);
// - deleting an EXAM cascades topics + plans + plan items, and DETACHES
//   its study activities (the real learning-time history survives);
// - deleting a PLAN cascades its items and detaches their activities.
//
// `origin == .aiCandidate` exam rows are DEVICE-LOCAL (the pendingConfirm
// task convention): they never notify the sync observer, never register
// notifications, never generate plans, and never upload — until the user
// confirms them into a real exam.

// MARK: - Enums

/// What kind of assessment an exam is.
enum ExamKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case midterm       // 期中考试
    case final         // 期末考试
    case quiz          // 小测验
    case lab           // 上机考核
    case oral          // 口试
    case report        // 课程报告
    case defense       // 答辩
    case custom        // 自定义

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .midterm: return String(localized: "期中考试")
        case .final: return String(localized: "期末考试")
        case .quiz: return String(localized: "小测验")
        case .lab: return String(localized: "上机考核")
        case .oral: return String(localized: "口试")
        case .report: return String(localized: "课程报告")
        case .defense: return String(localized: "答辩")
        case .custom: return String(localized: "自定义")
        }
    }

    var symbol: String {
        switch self {
        case .midterm, .final: return "graduationcap.fill"
        case .quiz: return "questionmark.square.dashed"
        case .lab: return "terminal.fill"
        case .oral: return "waveform"
        case .report: return "doc.text.fill"
        case .defense: return "person.2.fill"
        case .custom: return "flag.fill"
        }
    }
}

/// Exam lifecycle. `pending` = an AI-extracted candidate awaiting user
/// confirmation (device-local only).
enum ExamStatus: String, Codable, Sendable {
    case pending       // 待确认 (AI candidate, device-local)
    case scheduled     // 已安排
    case done          // 已完成
    case cancelled     // 已取消

    var displayName: String {
        switch self {
        case .pending: return String(localized: "待确认")
        case .scheduled: return String(localized: "已安排")
        case .done: return String(localized: "已完成")
        case .cancelled: return String(localized: "已取消")
        }
    }
}

/// How an exam came to exist. `aiCandidate` rows never leave the device.
enum ExamOrigin: String, Codable, Sendable {
    case manual
    case ai
}

/// A topic's study status. `mastered` is only ever set by an explicit
/// user action — never by opening a material, finishing a card or an AI
/// judgment.
enum ExamTopicStatus: String, Codable, Sendable {
    case notStarted = "not_started"
    case learning      // 正在学习
    case needsReview = "needs_review"   // 需要复习
    case mastered      // 已掌握 (user-set only)

    var displayName: String {
        switch self {
        case .notStarted: return String(localized: "尚未开始")
        case .learning: return String(localized: "正在学习")
        case .needsReview: return String(localized: "需要复习")
        case .mastered: return String(localized: "已掌握")
        }
    }
}

/// How important a topic is for the exam.
enum ExamTopicImportance: String, Codable, Sendable, CaseIterable, Identifiable {
    case low
    case normal
    case high

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .low: return String(localized: "次要")
        case .normal: return String(localized: "一般")
        case .high: return String(localized: "重点")
        }
    }
}

/// The user's own self-rating of a topic (always separate from plan
/// completion — finishing tasks is not knowing the material).
enum ExamTopicSelfRating: String, Codable, Sendable, CaseIterable, Identifiable {
    case none
    case vague         // 有印象
    case basic         // 基本理解
    case proficient    // 熟练

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return String(localized: "不熟悉")
        case .vague: return String(localized: "有印象")
        case .basic: return String(localized: "基本理解")
        case .proficient: return String(localized: "熟练")
        }
    }
}

/// Study-plan lifecycle.
enum StudyPlanStatus: String, Codable, Sendable {
    case active
    case paused
    case archived

    var displayName: String {
        switch self {
        case .active: return String(localized: "进行中")
        case .paused: return String(localized: "已暂停")
        case .archived: return String(localized: "已归档")
        }
    }
}

/// What one plan item asks the student to do. The `source` JSON column
/// carries the jump target for each kind.
enum StudyPlanItemKind: String, Codable, Sendable {
    case material      // 阅读资料指定页面
    case session       // 回顾指定课堂
    case review        // 阅读课堂学习整理
    case task          // 完成作业
    case cards         // 复习到期卡片
    case topic         // 学习某个主题
    case terms         // 复习术语
    case practice      // 练习视觉题目或公式
    case custom        // 自定义学习项目

    var displayName: String {
        switch self {
        case .material: return String(localized: "阅读资料")
        case .session: return String(localized: "回顾课堂")
        case .review: return String(localized: "学习整理")
        case .task: return String(localized: "完成作业")
        case .cards: return String(localized: "复习卡片")
        case .topic: return String(localized: "学习主题")
        case .terms: return String(localized: "复习术语")
        case .practice: return String(localized: "练习题目")
        case .custom: return String(localized: "自定义")
        }
    }

    var symbol: String {
        switch self {
        case .material: return "book.fill"
        case .session: return "waveform"
        case .review: return "sparkles"
        case .task: return "checklist"
        case .cards: return "rectangle.on.rectangle"
        case .topic: return "lightbulb"
        case .terms: return "character.book.closed"
        case .practice: return "function"
        case .custom: return "flag"
        }
    }
}

/// Plan-item status. Missed items stay `pending` with the date in the
/// past — the UI shows 未完成 and the user chooses 延期/跳过/重排; nothing
/// auto-fails or endlessly duplicates.
enum StudyPlanItemStatus: String, Codable, Sendable {
    case pending
    case inProgress = "in_progress"
    case done
    case skipped
    case deferred     // 已延期

    var displayName: String {
        switch self {
        case .pending: return String(localized: "待开始")
        case .inProgress: return String(localized: "进行中")
        case .done: return String(localized: "已完成")
        case .skipped: return String(localized: "已跳过")
        case .deferred: return String(localized: "已延期")
        }
    }
}

/// Study-activity (真实学习计时) status. completed/abandoned are terminal.
enum StudyActivityStatus: String, Codable, Sendable {
    case inProgress = "in_progress"
    case completed
    case abandoned

    var displayName: String {
        switch self {
        case .inProgress: return String(localized: "进行中")
        case .completed: return String(localized: "已完成")
        case .abandoned: return String(localized: "已放弃")
        }
    }
}

// MARK: - Exam

/// One exam. `examDate` is the wall-clock date; `startSecs`/`endSecs` are
/// seconds since midnight (-1 = time unknown / no end) — the same
/// wall-clock convention course schedules use, so exam-day rendering
/// never mixes time zones. `sourceJSON` is the AI candidate's origin
/// snapshot (stable ids + the original relative wording); EventKit
/// identifiers and notification state NEVER enter this row (device-local
/// columns only, below).
@Model
final class Exam {
    @Attribute(.unique) var id: UUID
    /// The course this exam belongs to (nil = 未归类).
    var courseID: UUID?
    var title: String
    /// Raw value of `ExamKind`.
    var kindRaw: String
    /// Wall-clock exam date as YYYY-MM-DD (parsed helpers below).
    var examDateKey: String
    /// Seconds since midnight; -1 = time unknown.
    var startSecs: Int
    /// Seconds since midnight; -1 = no end time.
    var endSecs: Int
    var location: String
    /// 考试范围 free text (user/AI-edited).
    var scopeText: String
    var note: String
    var targetScore: String
    /// Raw value of `ExamStatus`.
    var statusRaw: String
    /// Raw value of `ExamOrigin`.
    var originRaw: String
    /// ExamSource JSON (empty = none) — the AI candidate snapshot.
    var sourceJSON: String
    var createdAt: Date
    var updatedAt: Date
    /// Cloud-sync metadata (0 = never synced).
    var serverVersion: Int

    init(
        id: UUID = UUID(),
        courseID: UUID? = nil,
        title: String,
        kind: ExamKind = .custom,
        examDateKey: String,
        startSecs: Int = -1,
        endSecs: Int = -1,
        location: String = "",
        scopeText: String = "",
        note: String = "",
        targetScore: String = "",
        status: ExamStatus = .scheduled,
        origin: ExamOrigin = .manual,
        sourceJSON: String = ""
    ) {
        self.id = id
        self.courseID = courseID
        self.title = title
        self.kindRaw = kind.rawValue
        self.examDateKey = examDateKey
        self.startSecs = startSecs
        self.endSecs = endSecs
        self.location = location
        self.scopeText = scopeText
        self.note = note
        self.targetScore = targetScore
        self.statusRaw = status.rawValue
        self.originRaw = origin.rawValue
        self.sourceJSON = sourceJSON
        self.createdAt = .now
        self.updatedAt = .now
        self.serverVersion = 0
    }

    var kind: ExamKind {
        get { ExamKind(rawValue: kindRaw) ?? .custom }
        set { kindRaw = newValue.rawValue }
    }

    var status: ExamStatus {
        get { ExamStatus(rawValue: statusRaw) ?? .scheduled }
        set { statusRaw = newValue.rawValue }
    }

    var origin: ExamOrigin {
        get { ExamOrigin(rawValue: originRaw) ?? .manual }
        set { originRaw = newValue.rawValue }
    }

    var source: ExamSource? {
        get { sourceJSON.isEmpty ? nil : ExamSource.decode(sourceJSON) }
        set { sourceJSON = newValue.map { $0.encode() } ?? "" }
    }

    /// Parsed exam date in the device calendar (nil = malformed key).
    var examDate: Date? {
        Self.parseDateKey(examDateKey)
    }

    /// The exam's start moment (date at startSecs; nil when either the
    /// date or the time is unknown — the honest countdown anchor).
    var startDateTime: Date? {
        guard let day = examDate, startSecs >= 0 else { return nil }
        return Calendar.current.date(byAdding: .second, value: startSecs, to: day)
    }

    var hasTime: Bool { startSecs >= 0 }

    /// "YYYY-MM-DD" → start-of-day Date (device calendar/timezone).
    static func parseDateKey(_ key: String) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return Calendar.current.date(from: components)
    }

    /// Date → "YYYY-MM-DD" in the device calendar.
    static func dateKey(_ date: Date) -> String {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    /// Days from today (device midnight) to the exam date. Negative when
    /// the exam has passed.
    var daysUntilExam: Int? {
        guard let date = examDate else { return nil }
        let today = Calendar.current.startOfDay(for: .now)
        let target = Calendar.current.startOfDay(for: date)
        return Calendar.current.dateComponents([.day], from: today, to: target).day
    }
}

// MARK: - ExamTopic

/// One knowledge topic of one exam (二项式定理, 傅里叶变换…).
@Model
final class ExamTopic {
    @Attribute(.unique) var id: UUID
    var examID: UUID
    var title: String
    var detail: String
    /// Raw value of `ExamTopicImportance`.
    var importanceRaw: String
    /// Raw value of `ExamTopicSelfRating`.
    var selfRatingRaw: String
    /// Raw value of `ExamTopicStatus`.
    var statusRaw: String
    /// TopicSource JSON (empty = none).
    var sourceJSON: String
    /// Whether the user edited this row (regeneration preserves it).
    var userEdited: Bool
    var createdAt: Date
    var updatedAt: Date
    var serverVersion: Int

    init(
        id: UUID = UUID(),
        examID: UUID,
        title: String,
        detail: String = "",
        importance: ExamTopicImportance = .normal,
        selfRating: ExamTopicSelfRating = .none,
        status: ExamTopicStatus = .notStarted,
        sourceJSON: String = "",
        userEdited: Bool = false
    ) {
        self.id = id
        self.examID = examID
        self.title = title
        self.detail = detail
        self.importanceRaw = importance.rawValue
        self.selfRatingRaw = selfRating.rawValue
        self.statusRaw = status.rawValue
        self.sourceJSON = sourceJSON
        self.userEdited = userEdited
        self.createdAt = .now
        self.updatedAt = .now
        self.serverVersion = 0
    }

    var importance: ExamTopicImportance {
        get { ExamTopicImportance(rawValue: importanceRaw) ?? .normal }
        set { importanceRaw = newValue.rawValue }
    }

    var selfRating: ExamTopicSelfRating {
        get { ExamTopicSelfRating(rawValue: selfRatingRaw) ?? .none }
        set { selfRatingRaw = newValue.rawValue }
    }

    var status: ExamTopicStatus {
        get { ExamTopicStatus(rawValue: statusRaw) ?? .notStarted }
        set { statusRaw = newValue.rawValue }
    }

    /// The AI candidate's origin snapshot; nil = the user added the topic
    /// by hand (the same accessor shape Exam exposes).
    var source: ExamSource? {
        get { sourceJSON.isEmpty ? nil : ExamSource.decode(sourceJSON) }
        set { sourceJSON = newValue.map { $0.encode() } ?? "" }
    }
}

// MARK: - StudyPlan

/// One study plan for one exam, generated by the deterministic local
/// planner (`StudyPlanGenerator` — explainable, never the model) after a
/// user-confirmed preview.
@Model
final class StudyPlan {
    @Attribute(.unique) var id: UUID
    var examID: UUID
    var title: String
    /// Wall-clock start/end dates as YYYY-MM-DD keys.
    var startDateKey: String
    var endDateKey: String
    /// Weekday daily capacity in minutes (0 = no study that weekday).
    var weekdayMinutes: Int
    /// Weekend daily capacity in minutes.
    var weekendMinutes: Int
    /// Weekday numbers (1–7, Sunday=1) the user rests — JSON array string.
    var restDaysJSON: String
    /// Finish the first pass N days before the exam (final-review days).
    var finishEarlyDays: Int
    var includeCards: Bool
    var includeTasks: Bool
    var includeMaterials: Bool
    var includeSessions: Bool
    /// Focus topic-id JSON array string ("" = none).
    var focusTopicsJSON: String
    /// Blocked time-ranges JSON string ("" = none) — planner avoids them.
    var blockedTimesJSON: String
    /// Raw value of `StudyPlanStatus`.
    var statusRaw: String
    var createdAt: Date
    var updatedAt: Date
    var serverVersion: Int

    init(
        id: UUID = UUID(),
        examID: UUID,
        title: String,
        startDateKey: String,
        endDateKey: String,
        weekdayMinutes: Int = 60,
        weekendMinutes: Int = 90,
        restDaysJSON: String = "[]",
        finishEarlyDays: Int = 1,
        includeCards: Bool = true,
        includeTasks: Bool = true,
        includeMaterials: Bool = true,
        includeSessions: Bool = true,
        focusTopicsJSON: String = "[]",
        blockedTimesJSON: String = "[]",
        status: StudyPlanStatus = .active
    ) {
        self.id = id
        self.examID = examID
        self.title = title
        self.startDateKey = startDateKey
        self.endDateKey = endDateKey
        self.weekdayMinutes = weekdayMinutes
        self.weekendMinutes = weekendMinutes
        self.restDaysJSON = restDaysJSON
        self.finishEarlyDays = finishEarlyDays
        self.includeCards = includeCards
        self.includeTasks = includeTasks
        self.includeMaterials = includeMaterials
        self.includeSessions = includeSessions
        self.focusTopicsJSON = focusTopicsJSON
        self.blockedTimesJSON = blockedTimesJSON
        self.statusRaw = status.rawValue
        self.createdAt = .now
        self.updatedAt = .now
        self.serverVersion = 0
    }

    var status: StudyPlanStatus {
        get { StudyPlanStatus(rawValue: statusRaw) ?? .active }
        set { statusRaw = newValue.rawValue }
    }

    var restDays: [Int] {
        get {
            guard let data = restDaysJSON.data(using: .utf8),
                  let days = try? JSONDecoder().decode([Int].self, from: data)
            else { return [] }
            return days
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                restDaysJSON = String(data: data, encoding: .utf8) ?? "[]"
            }
        }
    }

    var focusTopics: [UUID] {
        get {
            guard let data = focusTopicsJSON.data(using: .utf8),
                  let topics = try? JSONDecoder().decode([UUID].self, from: data)
            else { return [] }
            return topics
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                focusTopicsJSON = String(data: data, encoding: .utf8) ?? "[]"
            }
        }
    }

    var startDate: Date? { Exam.parseDateKey(startDateKey) }
    var endDate: Date? { Exam.parseDateKey(endDateKey) }
}

// MARK: - StudyPlanItem

/// One concrete planned action on one day. `source` carries the jump
/// target (material id + page, session id, task id, topic id…) so the
/// item can always open the real content.
@Model
final class StudyPlanItem {
    @Attribute(.unique) var id: UUID
    var planID: UUID
    var examID: UUID?
    /// Wall-clock plan date as YYYY-MM-DD.
    var itemDateKey: String
    var title: String
    /// Raw value of `StudyPlanItemKind`.
    var kindRaw: String
    var estimatedMinutes: Int
    var actualMinutes: Int
    /// Raw value of `StudyPlanItemStatus`.
    var statusRaw: String
    /// When the status last changed — the cross-device merge order.
    var statusChangedAt: Date?
    var itemOrder: Int
    /// PlanItemSource JSON (empty = none) — the jump target.
    var sourceJSON: String
    var userNote: String
    /// Whether the user edited this row (replanning preserves it).
    var userEdited: Bool
    var createdAt: Date
    var updatedAt: Date
    var serverVersion: Int

    init(
        id: UUID = UUID(),
        planID: UUID,
        examID: UUID? = nil,
        itemDateKey: String,
        title: String,
        kind: StudyPlanItemKind = .custom,
        estimatedMinutes: Int = 30,
        actualMinutes: Int = 0,
        status: StudyPlanItemStatus = .pending,
        statusChangedAt: Date? = nil,
        itemOrder: Int = 0,
        sourceJSON: String = "",
        userNote: String = "",
        userEdited: Bool = false
    ) {
        self.id = id
        self.planID = planID
        self.examID = examID
        self.itemDateKey = itemDateKey
        self.title = title
        self.kindRaw = kind.rawValue
        self.estimatedMinutes = estimatedMinutes
        self.actualMinutes = actualMinutes
        self.statusRaw = status.rawValue
        self.statusChangedAt = statusChangedAt
        self.itemOrder = itemOrder
        self.sourceJSON = sourceJSON
        self.userNote = userNote
        self.userEdited = userEdited
        self.createdAt = .now
        self.updatedAt = .now
        self.serverVersion = 0
    }

    var kind: StudyPlanItemKind {
        get { StudyPlanItemKind(rawValue: kindRaw) ?? .custom }
        set { kindRaw = newValue.rawValue }
    }

    var status: StudyPlanItemStatus {
        get { StudyPlanItemStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    var source: PlanItemSource? {
        get { sourceJSON.isEmpty ? nil : PlanItemSource.decode(sourceJSON) }
        set { sourceJSON = newValue.map { $0.encode() } ?? "" }
    }

    var itemDate: Date? { Exam.parseDateKey(itemDateKey) }

    /// Whether the item's date is before today (missed — shown 未完成,
    /// never auto-failed).
    var isMissed: Bool {
        guard let date = itemDate else { return false }
        return Calendar.current.startOfDay(for: date) < Calendar.current.startOfDay(for: .now)
            && status == .pending
    }
}

// MARK: - StudyActivity

/// One real learning-session record (真实学习计时). Pauses are excluded from
/// `durationSeconds`; background time is computed from timestamps, never
/// from a running per-second task. Append-style: completed/abandoned are
/// terminal. Exactly one in-progress activity exists at a time (the
/// repository enforces it).
@Model
final class StudyActivity {
    @Attribute(.unique) var id: UUID
    /// The plan item this activity studies (nil = free study).
    var planItemID: UUID?
    /// Detached (nil) after the exam was deleted — history survives.
    var examID: UUID?
    var courseID: UUID?
    var topicID: UUID?
    var startedAt: Date
    var endedAt: Date?
    /// Accumulated ACTIVE seconds (pauses excluded).
    var durationSeconds: Int
    /// Raw value of `StudyActivityStatus`.
    var statusRaw: String
    var note: String
    var createdAt: Date
    var updatedAt: Date
    var serverVersion: Int

    init(
        id: UUID = UUID(),
        planItemID: UUID? = nil,
        examID: UUID? = nil,
        courseID: UUID? = nil,
        topicID: UUID? = nil,
        startedAt: Date = .now,
        endedAt: Date? = nil,
        durationSeconds: Int = 0,
        status: StudyActivityStatus = .inProgress,
        note: String = ""
    ) {
        self.id = id
        self.planItemID = planItemID
        self.examID = examID
        self.courseID = courseID
        self.topicID = topicID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.statusRaw = status.rawValue
        self.note = note
        self.createdAt = .now
        self.updatedAt = .now
        self.serverVersion = 0
    }

    var status: StudyActivityStatus {
        get { StudyActivityStatus(rawValue: statusRaw) ?? .inProgress }
        set { statusRaw = newValue.rawValue }
    }

    var isTerminal: Bool {
        status == .completed || status == .abandoned
    }

    /// Live elapsed ACTIVE seconds for an in-progress activity (background
    /// time included — computed from timestamps, no per-second task).
    var liveElapsedSeconds: Int {
        guard status == .inProgress else { return durationSeconds }
        let reference = endedAt ?? min(.now, pausedAt ?? .now)
        return durationSeconds + max(0, Int(reference.timeIntervalSince(activeSince)))
    }

    // MARK: Pause bookkeeping (device-local, persisted on the row so an
    // interrupted pause survives app death; never synced semantics —
    // pauses fold into durationSeconds at pause/finish).

    /// When the current active stretch began (device pause bookkeeping).
    var activeSince: Date {
        get { _activeSince ?? startedAt }
        set { _activeSince = newValue }
    }

    private var _activeSince: Date?

    /// Pauses: latest pause moment (nil = not paused).
    var pausedAt: Date? {
        get { _pausedAt }
        set { _pausedAt = newValue }
    }

    private var _pausedAt: Date?

    /// Pauses the activity: folds the active stretch into the duration.
    func pause(at date: Date = .now) {
        guard status == .inProgress, pausedAt == nil else { return }
        durationSeconds += max(0, Int(date.timeIntervalSince(activeSince)))
        pausedAt = date
        updatedAt = .now
    }

    /// Resumes after a pause.
    func resume(at date: Date = .now) {
        guard status == .inProgress, let paused = pausedAt else { return }
        activeSince = date
        pausedAt = nil
        endedAt = nil
        updatedAt = .now
        _ = paused
    }

    /// Ends the activity: folds the active stretch, sets the terminal
    /// status (completed/abandoned) and the end time.
    func finish(status: StudyActivityStatus, at date: Date = .now) {
        guard status == .completed || status == .abandoned else { return }
        if pausedAt == nil {
            durationSeconds += max(0, Int(date.timeIntervalSince(activeSince)))
            activeSince = date
        } else {
            pausedAt = nil
        }
        endedAt = date
        self.status = status
        updatedAt = .now
    }
}

// MARK: - Source payload types (JSON columns)

/// The origin snapshot of an AI-extracted exam candidate: stable source
/// ids + the ORIGINAL wording (e.g. 下周三的期中考试) so the confirmation
/// UI can show exactly what the source said. Never image bytes, file
/// paths or raw model responses.
struct ExamSource: Codable, Sendable, Equatable {
    enum SourceKind: String, Codable, Sendable {
        case attachment    // 教师通知截图 / 黑板照片
        case material      // PDF 课程通知
        case transcript    // 课堂转录
        case note          // 用户笔记
        case assistant     // 视觉问答结果
        case inbox         // 智能收件箱（sourceID = SharedInboxItem id）
    }

    var kind: SourceKind
    /// Stable id: attachment / material / session id.
    var sourceID: UUID?
    /// The original wording the candidate was extracted from.
    var originalText: String
    /// Fields the model was not sure about ("时间不确定", "单双周不明确").
    var uncertainties: [String]

    var kindDisplayName: String {
        switch kind {
        case .attachment: return String(localized: "课堂图片")
        case .material: return String(localized: "课程资料")
        case .transcript: return String(localized: "课堂转录")
        case .note: return String(localized: "笔记")
        case .assistant: return String(localized: "问答")
        case .inbox: return String(localized: "收件箱分享")
        }
    }

    static func decode(_ json: String) -> ExamSource? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ExamSource.self, from: data)
    }

    func encode() -> String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Where an exam-topic suggestion came from.
struct TopicSource: Codable, Sendable, Equatable {
    enum SourceKind: String, Codable, Sendable {
        case user          // 手动添加
        case digest        // 资料目录
        case review        // StudyReview 重点
        case scope         // 教师明确说明的考试范围
        case assistant     // 视觉问答
    }

    var kind: SourceKind
    var sourceID: UUID?
    var originalText: String

    static func decode(_ json: String) -> TopicSource? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TopicSource.self, from: data)
    }

    func encode() -> String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// A plan item's jump target — the real content the item opens. One of
/// the reference fields is set per kind (material+page, session, task,
/// topic, card deck course). All fields are plain ids/numbers (never
/// file paths).
struct PlanItemSource: Codable, Sendable, Equatable {
    var materialID: UUID?
    var pageNumber: Int?
    var sessionID: UUID?
    var taskID: UUID?
    var topicID: UUID?
    /// Course scope for cards/terms practice.
    var courseID: UUID?
    /// Attachment (practice from a classroom image).
    var attachmentID: UUID?

    static func decode(_ json: String) -> PlanItemSource? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PlanItemSource.self, from: data)
    }

    func encode() -> String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
