import Foundation
import SwiftData

// Learning entities for the review center. All three follow the
// SessionNote/SessionAttachment conventions: a stable client-generated
// UUID, plain UUID columns for source references (never SwiftData
// relationships — entities sync independently and rows may arrive before
// their sources), and `serverVersion` cloud-sync metadata.
//
// Learning material survives its sources: deleting a course clears the
// `courseID` reference (never the row); deleting a session or attachment
// leaves the row and its dangling refs — the UI shows 来源已不存在.
//
// AI provenance: candidates the user has not confirmed yet are marked
// `origin == .aiDraft` on StudyTask (and exist only as unsaved preview
// structs for cards) and are NEVER enqueued for sync; the server rejects
// unknown statuses defensively.

/// Learning status of a glossary term. Purely user-observable progress —
/// not part of any scheduling algorithm.
enum GlossaryTermStatus: String, Codable, Sendable {
    case new
    case learning
    case familiar
    case mastered
}

/// A saved Russian term with its Chinese meaning, optional explanation
/// and the classroom sources it came from.
///
/// `sourceSessionIDsJSON` holds a JSON array of session UUID strings —
/// the term's accumulated classroom sources (the first save stores one;
/// a user-confirmed merge of a duplicate appends more). `sessionID` /
/// `sourceEntryID` / `sourceAttachmentID` / `sourceReviewID` keep the
/// PRIMARY source for one-tap jumps back into the classroom.
@Model
final class GlossaryTerm {
    @Attribute(.unique) var id: UUID
    /// The Russian word/phrase (the term's identity within a course).
    var russian: String
    /// Chinese meaning.
    var chinese: String
    /// Short explanation (from AI or the user).
    var explanation: String
    /// Optional part of speech ("сущ.", "гл." …); empty = not set.
    var partOfSpeech: String
    /// The user's own memory hint / note; never touched by AI.
    var userNote: String
    /// Course this term belongs to (nil = 未分类).
    var courseID: UUID?
    /// PRIMARY source session (nil = manually created).
    var sessionID: UUID?
    /// PRIMARY source transcript entry (nil = not from a paragraph).
    var sourceEntryID: UUID?
    /// PRIMARY source attachment (nil = not from an image).
    var sourceAttachmentID: UUID?
    /// PRIMARY source study review (nil = not from an AI review).
    var sourceReviewID: UUID?
    /// JSON array of session UUID strings — accumulated sources.
    var sourceSessionIDsJSON: String
    var isFavorite: Bool
    /// Raw value of `GlossaryTermStatus`.
    var statusRaw: String
    var createdAt: Date
    var updatedAt: Date
    /// Cloud-sync metadata (0 = never synced).
    var serverVersion: Int

    init(
        id: UUID = UUID(),
        russian: String,
        chinese: String = "",
        explanation: String = "",
        partOfSpeech: String = "",
        userNote: String = "",
        courseID: UUID? = nil,
        sessionID: UUID? = nil,
        sourceEntryID: UUID? = nil,
        sourceAttachmentID: UUID? = nil,
        sourceReviewID: UUID? = nil,
        sourceSessionIDs: [UUID] = [],
        isFavorite: Bool = false,
        status: GlossaryTermStatus = .new,
        serverVersion: Int = 0
    ) {
        self.id = id
        self.russian = russian
        self.chinese = chinese
        self.explanation = explanation
        self.partOfSpeech = partOfSpeech
        self.userNote = userNote
        self.courseID = courseID
        self.sessionID = sessionID
        self.sourceEntryID = sourceEntryID
        self.sourceAttachmentID = sourceAttachmentID
        self.sourceReviewID = sourceReviewID
        if let data = try? JSONEncoder().encode(sourceSessionIDs),
           let json = String(data: data, encoding: .utf8) {
            self.sourceSessionIDsJSON = json
        } else {
            self.sourceSessionIDsJSON = "[]"
        }
        self.isFavorite = isFavorite
        self.statusRaw = status.rawValue
        self.createdAt = .now
        self.updatedAt = .now
        self.serverVersion = serverVersion
    }

    var status: GlossaryTermStatus {
        get { GlossaryTermStatus(rawValue: statusRaw) ?? .new }
        set { statusRaw = newValue.rawValue }
    }

    /// Decoded accumulated source sessions (invalid JSON decodes to the
    /// primary session or an empty list — never crashes).
    var sourceSessionIDs: [UUID] {
        guard let data = sourceSessionIDsJSON.data(using: .utf8),
              let ids = try? JSONDecoder().decode([UUID].self, from: data) else {
            if let sessionID { return [sessionID] }
            return []
        }
        return ids
    }
}

/// Card types that map to genuinely different review uses. `qa` is the
/// generic fallback; `ru2zh`/`zh2ru` are term-direction cards.
enum StudyCardType: String, Codable, Sendable, CaseIterable {
    case ru2zh
    case zh2ru
    case qa
    case concept
    case formula
    case code

    var displayName: String {
        switch self {
        case .ru2zh: return "俄→中"
        case .zh2ru: return "中→俄"
        case .qa: return "问答"
        case .concept: return "概念"
        case .formula: return "公式"
        case .code: return "代码"
        }
    }
}

/// Scheduling stage of a card (simplified SM-2). `new` cards have never
/// been reviewed; `learning` cards are on short (sub-day) intervals;
/// `young` on multi-day intervals; `mastered` survived a long interval.
enum StudyCardStage: String, Codable, Sendable {
    case new
    case learning
    case young
    case mature
}

/// The four review grades the UI offers.
enum StudyCardGrade: String, Codable, Sendable, CaseIterable {
    case forgot
    case hard
    case good
    case easy
}

/// How a card was created.
enum StudyCardOrigin: String, Codable, Sendable {
    case manual
    case ai
}

/// A flashcard with its spaced-repetition state.
///
/// Scheduling (simplified SM-2, fully explainable): every review with a
/// grade updates `stage`, `intervalHours` and `dueAt`; `lastGrade` and
/// `lastReviewedAt` record the most recent answer. Content edits never
/// reset the schedule — the user is asked explicitly instead.
@Model
final class StudyCard {
    @Attribute(.unique) var id: UUID
    var front: String
    var back: String
    /// Raw value of `StudyCardType`.
    var typeRaw: String
    /// Raw value of `StudyCardOrigin`.
    var originRaw: String
    var userNote: String
    /// Course this card belongs to (nil = 未分类).
    var courseID: UUID?
    /// Optional source session / entry / attachment / term.
    var sessionID: UUID?
    var sourceEntryID: UUID?
    var sourceAttachmentID: UUID?
    var sourceTermID: UUID?
    // --- Scheduling state ---
    /// Raw value of `StudyCardStage`.
    var stageRaw: String
    var reviewCount: Int
    /// Current interval in hours (0 until the first review).
    var intervalHours: Int
    /// When this card is next due (nil = never scheduled = due now).
    var dueAt: Date?
    var lastReviewedAt: Date?
    /// Raw value of `StudyCardGrade` ("" = never reviewed).
    var lastGradeRaw: String
    var createdAt: Date
    var updatedAt: Date
    /// Cloud-sync metadata (0 = never synced).
    var serverVersion: Int

    init(
        id: UUID = UUID(),
        front: String,
        back: String,
        type: StudyCardType = .qa,
        origin: StudyCardOrigin = .manual,
        userNote: String = "",
        courseID: UUID? = nil,
        sessionID: UUID? = nil,
        sourceEntryID: UUID? = nil,
        sourceAttachmentID: UUID? = nil,
        sourceTermID: UUID? = nil,
        stage: StudyCardStage = .new,
        reviewCount: Int = 0,
        intervalHours: Int = 0,
        dueAt: Date? = nil,
        lastReviewedAt: Date? = nil,
        lastGrade: StudyCardGrade? = nil,
        serverVersion: Int = 0
    ) {
        self.id = id
        self.front = front
        self.back = back
        self.typeRaw = type.rawValue
        self.originRaw = origin.rawValue
        self.userNote = userNote
        self.courseID = courseID
        self.sessionID = sessionID
        self.sourceEntryID = sourceEntryID
        self.sourceAttachmentID = sourceAttachmentID
        self.sourceTermID = sourceTermID
        self.stageRaw = stage.rawValue
        self.reviewCount = reviewCount
        self.intervalHours = intervalHours
        self.dueAt = dueAt
        self.lastReviewedAt = lastReviewedAt
        self.lastGradeRaw = lastGrade?.rawValue ?? ""
        self.createdAt = .now
        self.updatedAt = .now
        self.serverVersion = serverVersion
    }

    var type: StudyCardType {
        get { StudyCardType(rawValue: typeRaw) ?? .qa }
        set { typeRaw = newValue.rawValue }
    }

    var origin: StudyCardOrigin {
        get { StudyCardOrigin(rawValue: originRaw) ?? .manual }
        set { originRaw = newValue.rawValue }
    }

    var stage: StudyCardStage {
        get { StudyCardStage(rawValue: stageRaw) ?? .new }
        set { stageRaw = newValue.rawValue }
    }

    var lastGrade: StudyCardGrade? {
        get { StudyCardGrade(rawValue: lastGradeRaw) }
        set { lastGradeRaw = newValue?.rawValue ?? "" }
    }

    /// True when the card is scheduled and due (due now when never
    /// scheduled but already reviewed at least once is NOT due — new
    /// cards enter the queue only via their first explicit review).
    var isDueNow: Bool {
        guard stageRaw != StudyCardStage.new.rawValue else { return false }
        guard let dueAt else { return false }
        return dueAt <= .now
    }
}

/// Lifecycle of a study task. `pendingConfirm` is the AI-candidate state:
/// the row exists only on the device that ran the review and is never
/// pushed until the user confirms it (confirmed → `pending`).
enum StudyTaskStatus: String, Codable, Sendable {
    case pending
    case pendingConfirm = "pending_confirm"
    case done
    case ignored
}

enum StudyTaskPriority: String, Codable, Sendable, CaseIterable {
    case low
    case normal
    case high

    var displayName: String {
        switch self {
        case .low: return "低"
        case .normal: return "普通"
        case .high: return "高"
        }
    }
}

enum StudyTaskOrigin: String, Codable, Sendable {
    case manual
    case ai
}

/// An assignment or todo extracted from a classroom (or written by the
/// user). AI-extracted candidates stay `pendingConfirm` until the user
/// confirms them; only confirmed tasks appear in the review center and
/// home, and only confirmed tasks are ever pushed to the server.
@Model
final class StudyTask {
    @Attribute(.unique) var id: UUID
    var title: String
    var detail: String
    /// Raw value of `StudyTaskPriority`.
    var priorityRaw: String
    /// Raw value of `StudyTaskStatus`.
    var statusRaw: String
    /// Raw value of `StudyTaskOrigin`.
    var originRaw: String
    /// Free-text note on how certain the AI was ("" for manual tasks).
    var uncertainty: String
    var userNote: String
    var dueAt: Date?
    var completedAt: Date?
    /// Course this task belongs to (nil = 未分类).
    var courseID: UUID?
    /// Optional source session / entry / attachment / review.
    var sessionID: UUID?
    var sourceEntryID: UUID?
    var sourceAttachmentID: UUID?
    var sourceReviewID: UUID?
    var createdAt: Date
    var updatedAt: Date
    /// Cloud-sync metadata (0 = never synced).
    var serverVersion: Int

    init(
        id: UUID = UUID(),
        title: String,
        detail: String = "",
        priority: StudyTaskPriority = .normal,
        status: StudyTaskStatus = .pending,
        origin: StudyTaskOrigin = .manual,
        uncertainty: String = "",
        userNote: String = "",
        dueAt: Date? = nil,
        completedAt: Date? = nil,
        courseID: UUID? = nil,
        sessionID: UUID? = nil,
        sourceEntryID: UUID? = nil,
        sourceAttachmentID: UUID? = nil,
        sourceReviewID: UUID? = nil,
        serverVersion: Int = 0
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.priorityRaw = priority.rawValue
        self.statusRaw = status.rawValue
        self.originRaw = origin.rawValue
        self.uncertainty = uncertainty
        self.userNote = userNote
        self.dueAt = dueAt
        self.completedAt = completedAt
        self.courseID = courseID
        self.sessionID = sessionID
        self.sourceEntryID = sourceEntryID
        self.sourceAttachmentID = sourceAttachmentID
        self.sourceReviewID = sourceReviewID
        self.createdAt = .now
        self.updatedAt = .now
        self.serverVersion = serverVersion
    }

    var status: StudyTaskStatus {
        get { StudyTaskStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    var priority: StudyTaskPriority {
        get { StudyTaskPriority(rawValue: priorityRaw) ?? .normal }
        set { priorityRaw = newValue.rawValue }
    }

    var origin: StudyTaskOrigin {
        get { StudyTaskOrigin(rawValue: originRaw) ?? .manual }
        set { originRaw = newValue.rawValue }
    }
}

// MARK: - Scheduling (simplified SM-2)

/// A deterministic, explainable interval schedule. No floating-point
/// ease factors, no deck-level matrix — the rules fit on one screen:
///
/// - forgot: back to learning, 10-minute intervals, review again this
///   session;
/// - hard:   keep the stage, interval × 1.2  (learning: 1 h);
/// - good:   learning → 8 h → young 1 d → ×2.5 up to 180 d;
/// - easy:   same as good but ×4 (min 2 d), stage advances sooner.
///
/// All intervals are whole hours so the synced value stays exact.
enum StudyCardScheduler {
    /// Maximum interval (days).
    static let maxIntervalDays = 180
    static let maxIntervalHours = maxIntervalDays * 24

    /// Applies one review and mutates the card's scheduling fields.
    /// Returns false when the grade string is unknown (no change).
    @discardableResult
    static func apply(_ grade: StudyCardGrade, to card: StudyCard, at date: Date = .now) -> Bool {
        card.reviewCount += 1
        card.lastReviewedAt = date
        card.lastGrade = grade
        switch grade {
        case .forgot:
            card.stage = .learning
            card.intervalHours = 0
            card.dueAt = date.addingTimeInterval(10 * 60)
        case .hard:
            if card.stage == .new { card.stage = .learning }
            let base = card.intervalHours > 0 ? card.intervalHours : 1
            card.intervalHours = min(max(Int(Double(base) * 1.2), 1), maxIntervalHours)
            card.dueAt = date.addingTimeInterval(TimeInterval(card.intervalHours) * 3600)
        case .good, .easy:
            let multiplier: Double = grade == .easy ? 4 : 2.5
            switch card.stage {
            case .new:
                card.stage = .learning
                card.intervalHours = grade == .easy ? 24 : 8
            case .learning:
                card.stage = .young
                card.intervalHours = grade == .easy ? 48 : 24
            case .young, .mature:
                card.stage = .mature
                let base = max(card.intervalHours, 24)
                card.intervalHours = min(max(Int(Double(base) * multiplier), 48), maxIntervalHours)
            }
            card.dueAt = date.addingTimeInterval(TimeInterval(card.intervalHours) * 3600)
        }
        card.updatedAt = date
        return true
    }

    /// Schedules a brand-new card for its first review (入队).
    static func enroll(_ card: StudyCard, at date: Date = .now) {
        guard card.stageRaw == StudyCardStage.new.rawValue else { return }
        card.stage = .learning
        card.dueAt = date
        card.updatedAt = date
    }
}
