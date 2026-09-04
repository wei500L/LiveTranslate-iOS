import Foundation

// Inbox suggestion layer — the APP-side analysis contract stored in a
// SharedInboxItem's `suggestionJSON` (the Share Extension never touches
// these types; they are not part of SharedInboxKit).
//
// Two honest layers, never blended:
// - LOCAL pre-classification (InboxClassifier): deterministic,
//   explainable, always runs, no model required;
// - AI actions (InboxSuggestionService): multi-action suggestions from
//   the existing model services; optional, may fail or be unconfigured —
//   manual classification stays fully usable.

/// The versioned suggestion payload persisted on the item.
struct InboxSuggestionPayload: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var local: InboxLocalClassification?
    var aiActions: [InboxSuggestedAction] = []
    var aiMissingInfo: String?
    /// Why the AI pass produced nothing (未配置模型 / 离线 / 解析失败).
    /// Manual flows stay available — this is an explanation, not an error
    /// the user must fix.
    var aiError: String?
    var aiRanAt: Date?

    enum CodingKeys: String, CodingKey {
        case schemaVersion, local, aiActions, aiMissingInfo, aiError, aiRanAt
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Self.currentSchemaVersion
        local = try c.decodeIfPresent(InboxLocalClassification.self, forKey: .local)
        aiActions = try c.decodeIfPresent([InboxSuggestedAction].self, forKey: .aiActions) ?? []
        aiMissingInfo = try c.decodeIfPresent(String.self, forKey: .aiMissingInfo)
        aiError = try c.decodeIfPresent(String.self, forKey: .aiError)
        aiRanAt = try c.decodeIfPresent(Date.self, forKey: .aiRanAt)
    }

    func encodedJSON() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ json: String) -> InboxSuggestionPayload? {
        guard !json.isEmpty, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(InboxSuggestionPayload.self, from: data)
    }
}

/// One AI-suggested action. Every field is a SUGGESTION the user can
/// edit/deselect before confirming; the stable `id` is the idempotency
/// key recorded in the item's operation ledger once executed.
struct InboxSuggestedAction: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var kindRaw: String
    /// Short display label (导入为课程资料 / 记录考试候选 …).
    var title: String
    var isSelected: Bool = true

    // Kind-specific details (nil elsewhere).
    /// saveAsMaterial / linkAsMaterial: suggested MaterialKind raw value.
    var materialKindRaw: String = MaterialKind.other.rawValue
    /// Suggested course association (never auto-applied when uncertain).
    var courseID: UUID?
    /// createExamCandidate details.
    var examCandidate: ExamCandidateSnapshot?
    /// createTaskCandidate details.
    var taskCandidate: TaskCandidateSnapshot?
    /// importSchedule details.
    var scheduleCandidate: ScheduleCandidateSnapshot?
    /// saveAsNote: the text to save (from the shared content).
    var noteText: String = ""

    enum CodingKeys: String, CodingKey {
        case id, kindRaw, title, isSelected, materialKindRaw, courseID
        case examCandidate, taskCandidate, scheduleCandidate, noteText
    }

    init(kind: InboxActionKind, title: String) {
        self.kindRaw = kind.rawValue
        self.title = title
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kindRaw = try c.decodeIfPresent(String.self, forKey: .kindRaw) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        isSelected = try c.decodeIfPresent(Bool.self, forKey: .isSelected) ?? true
        materialKindRaw = try c.decodeIfPresent(String.self, forKey: .materialKindRaw)
            ?? MaterialKind.other.rawValue
        courseID = try c.decodeIfPresent(UUID.self, forKey: .courseID)
        examCandidate = try c.decodeIfPresent(ExamCandidateSnapshot.self, forKey: .examCandidate)
        taskCandidate = try c.decodeIfPresent(TaskCandidateSnapshot.self, forKey: .taskCandidate)
        scheduleCandidate = try c.decodeIfPresent(
            ScheduleCandidateSnapshot.self, forKey: .scheduleCandidate
        )
        noteText = try c.decodeIfPresent(String.self, forKey: .noteText) ?? ""
    }
}

/// The action kinds an inbox item can turn into. Raw values are the
/// shared ledger contract (SharedInboxActionKindRaw).
enum InboxActionKind: String, Codable, Sendable, CaseIterable {
    case saveAsMaterial = "saveAsMaterial"
    case linkAsMaterial = "linkAsMaterial"
    case attachToSession = "attachToSession"
    case createExamCandidate = "createExamCandidate"
    case createTaskCandidate = "createTaskCandidate"
    case importSchedule = "importSchedule"
    case saveAsNote = "saveAsNote"

    var displayName: String {
        switch self {
        case .saveAsMaterial: return String(localized: "保存为课程资料", comment: "inbox action")
        case .linkAsMaterial: return String(localized: "保存为链接资料", comment: "inbox action")
        case .attachToSession: return String(localized: "存为课堂图片", comment: "inbox action")
        case .createExamCandidate: return String(localized: "创建考试候选", comment: "inbox action")
        case .createTaskCandidate: return String(localized: "创建作业候选", comment: "inbox action")
        case .importSchedule: return String(localized: "导入课程表", comment: "inbox action")
        case .saveAsNote: return String(localized: "保存为课堂笔记", comment: "inbox action")
        }
    }

    /// Whether executing this action needs the user to pick a course.
    var requiresCourse: Bool {
        switch self {
        case .saveAsMaterial, .linkAsMaterial, .attachToSession:
            return false // course is optional (未归类 allowed)
        case .createExamCandidate, .createTaskCandidate, .importSchedule:
            return false // candidates may stay unassigned
        case .saveAsNote:
            return false
        }
    }

    /// Whether executing this action needs the user to pick a classroom
    /// session (valid 归属 requirement).
    var requiresSession: Bool {
        switch self {
        case .attachToSession, .saveAsNote: return true
        default: return false
        }
    }
}

// MARK: - Candidate snapshots (wire-shaped, user-editable before confirm)

/// Exam candidate suggestion (mirrors ExamCandidateParser.Candidate).
struct ExamCandidateSnapshot: Codable, Equatable, Sendable {
    var title: String
    var kindRaw: String = ExamKind.custom.rawValue
    /// "YYYY-MM-DD" or "" (never guessed).
    var dateKey: String = ""
    /// "HH:MM" or "".
    var timeText: String = ""
    var location: String = ""
    /// Original relative wording (下周三 …), shown verbatim.
    var relativeWording: String = ""
    var scopeText: String = ""
    var requirements: String = ""
    var dateUncertain: Bool = false
    var timeUncertain: Bool = false
    var kindUncertain: Bool = false
    var locationUncertain: Bool = false
}

/// Task candidate suggestion (mirrors StudyTask pendingConfirm fields).
struct TaskCandidateSnapshot: Codable, Equatable, Sendable {
    var title: String
    var detail: String = ""
    var priorityRaw: String = "normal"
    /// ISO-8601 date, nil when the source names no deadline.
    var dueAt: Date?
    var uncertainty: String = ""
}

/// Schedule candidate suggestion (mirrors ScheduleImageParser.Candidate).
struct ScheduleCandidateSnapshot: Codable, Equatable, Sendable {
    var courseName: String
    var weekday: Int = 1
    var startSecs: Int = 0
    var endSecs: Int = 0
    var recurrenceRaw: String = "weekly"
    var teacher: String = ""
    var location: String = ""
    var timeUncertain: Bool = false
    var parityUncertain: Bool = false
    var locationUncertain: Bool = false
    var teacherUncertain: Bool = false
}
