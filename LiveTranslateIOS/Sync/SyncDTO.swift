import Foundation

/// Wire-format DTOs for the private cloud sync protocol (`/v1`).
///
/// Everything here is an immutable, Sendable value: SwiftData models are
/// never allowed to cross an actor boundary — DTOs are constructed on the
/// main actor before being handed to the sync services.
// MARK: - Entities

enum SyncEntityType: String, Codable, Sendable {
    case session
    case entry
    case bookmark
    case favorite
    case course
    case note
    case studyReview = "study_review"
    /// Classroom image metadata. The wire name fits the server's
    /// VARCHAR(16) entity_type columns ("session_attachment" would not).
    /// Binary files travel on /v1/attachments, never through push.
    case attachment
    // Learning entities (review center). Wire names all fit the server's
    // VARCHAR(16) entity_type column.
    case term
    case studyCard = "study_card"
    case studyTask = "study_task"
    /// User correction overlay for one transcript entry (entity id ==
    /// entry id). 21 chars — fits VARCHAR(32) on the 00008 table; the
    /// change-log columns are VARCHAR(32) since 00008 as well.
    case transcriptCorrection = "transcript_correction"
    // Pre-class layer: recurring rules + dated exceptions. Wire names are
    // 15/17 chars — both fit the server's VARCHAR(32) entity_type columns.
    case courseSchedule = "course_schedule"
    case scheduleException = "schedule_exception"
    // Course-material library: imported documents (PDF/text/image) with
    // page-level extracted text, user annotations, and the course
    // assistant's threads. Wire names are 8/13/19/16/17 chars — all fit
    // the VARCHAR(32) entity_type columns.
    case material
    case materialPage = "material_page"
    case materialAnnotation = "material_annotation"
    case assistantThread = "assistant_thread"
    case assistantMessage = "assistant_message"
    // Exam center: exams, topics, study plans, plan items and study
    // activities. Wire names are 4/10/10/15/14 chars — all fit the
    // server's VARCHAR(32) entity_type columns.
    case exam
    case examTopic = "exam_topic"
    case studyPlan = "study_plan"
    case studyPlanItem = "study_plan_item"
    case studyActivity = "study_activity"
}

enum SyncOperation: String, Codable, Sendable {
    case upsert
    case delete
}

// MARK: - Auth

struct SyncDeviceDTO: Codable, Sendable, Equatable {
    var clientDeviceId: String
    var displayName: String
    var appVersion: String
}

struct SyncTokenPairDTO: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String
    var tokenType: String
    var expiresIn: Int
    var userId: UUID
    var isNewUser: Bool?
    /// The public user projection (present on login/verify responses from
    /// the Go server; carries the email after an email change).
    var user: SyncPublicUserDTO?

    enum CodingKeys: String, CodingKey {
        case accessToken, refreshToken, tokenType, expiresIn, userId, isNewUser, user
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        refreshToken = try container.decode(String.self, forKey: .refreshToken)
        tokenType = try container.decodeIfPresent(String.self, forKey: .tokenType) ?? "Bearer"
        expiresIn = try container.decodeIfPresent(Int.self, forKey: .expiresIn) ?? 900
        userId = try container.decode(UUID.self, forKey: .userId)
        isNewUser = try container.decodeIfPresent(Bool.self, forKey: .isNewUser)
        user = try container.decodeIfPresent(SyncPublicUserDTO.self, forKey: .user)
    }

    init(accessToken: String, refreshToken: String, tokenType: String = "Bearer",
         expiresIn: Int = 900, userId: UUID, isNewUser: Bool? = nil,
         user: SyncPublicUserDTO? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenType = tokenType
        self.expiresIn = expiresIn
        self.userId = userId
        self.isNewUser = isNewUser
        self.user = user
    }
}

struct SyncMeDTO: Codable, Sendable, Equatable {
    var userId: UUID
    var displayLabel: String
}

// MARK: - Server capabilities (GET /v1/auth/capabilities)

/// The server's PUBLIC registration/sign-in posture. Drives the auth UI:
/// whether the 注册 tab exists, whether an invitation code is required.
/// Never trusts a locally hardcoded "registration is open".
struct SyncCapabilitiesDTO: Decodable, Sendable, Equatable {
    var registration: String
    var requiresInvitation: Bool
    var passwordLogin: Bool
    var appleLogin: Bool
    var maintenance: Bool
    var minClientSchemaVersion: Int?
    var maxClientSchemaVersion: Int?

    /// Parsed registration mode with a safe default.
    var registrationMode: RegistrationMode {
        RegistrationMode(rawValue: registration) ?? .disabled
    }
}

enum RegistrationMode: String, Sendable {
    case open
    case inviteOnly = "invite_only"
    case disabled
}

/// The public user projection (PATCH /v1/me and the login payloads).
/// Everything except userId decodes optionally.
struct SyncPublicUserDTO: Decodable, Sendable {
    var userId: UUID
    var email: String?
    var displayName: String?
    var status: String?
    var emailVerified: Bool?

    private enum CodingKeys: String, CodingKey {
        case userId, email, displayName, status, emailVerified
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = try c.decode(UUID.self, forKey: .userId)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        emailVerified = try c.decodeIfPresent(Bool.self, forKey: .emailVerified)
    }
}

// MARK: - Account profile (GET /v1/me)

/// The enriched 账号与安全 payload. Every field except userId decodes
/// optionally so an older server (or the Python service) still works.
struct SyncMeProfileDTO: Decodable, Sendable {
    var userId: UUID
    var displayLabel: String
    var displayName: String?
    var email: String?
    var emailVerified: Bool?
    var providers: [String]?
    var hasPassword: Bool?
    var appleBound: Bool?
    var createdAt: Date?
    var lastLoginAt: Date?
    var deviceCount: Int?
    var liveSessions: Int?

    private enum CodingKeys: String, CodingKey {
        case userId, displayLabel, displayName, email, emailVerified
        case providers, hasPassword, appleBound, createdAt, lastLoginAt
        case deviceCount, liveSessions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = try c.decode(UUID.self, forKey: .userId)
        displayLabel = try c.decode(String.self, forKey: .displayLabel)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        emailVerified = try c.decodeIfPresent(Bool.self, forKey: .emailVerified)
        providers = try c.decodeIfPresent([String].self, forKey: .providers)
        hasPassword = try c.decodeIfPresent(Bool.self, forKey: .hasPassword)
        appleBound = try c.decodeIfPresent(Bool.self, forKey: .appleBound)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        lastLoginAt = try c.decodeIfPresent(Date.self, forKey: .lastLoginAt)
        deviceCount = try c.decodeIfPresent(Int.self, forKey: .deviceCount)
        liveSessions = try c.decodeIfPresent(Int.self, forKey: .liveSessions)
    }
}

// MARK: - Push

struct SyncPushPayloadDTO: Codable, Sendable, Equatable {
    // session
    var title: String?
    var startedAt: Date?
    var endedAt: Date?
    var duration: Double?
    var sessionStatus: String?
    var abnormalTermination: Bool?
    var sourceLanguage: String?
    var targetLanguage: String?
    // entry
    var sessionId: UUID?
    var sequenceId: Int?
    var startOffset: Double?
    var endOffset: Double?
    var russianText: String?
    var chineseText: String?
    var translationStatus: String?
    /// Provenance of the entry's audio position (audio | legacy).
    /// Absent keeps the server value (default legacy server-side).
    var timeSource: String?
    // bookmark / favorite
    var entryId: UUID?
    var isBookmarked: Bool?
    var isFavorite: Bool?
    // session → course reference. Absent (nil) keeps the server value;
    // `UUID.nilSentinel` explicitly clears it (see the repository's
    // sentinel documentation).
    var courseId: UUID?
    // course (name rides on title)
    var teacher: String?
    var location: String?
    var colorIndex: Int?
    var isArchived: Bool?
    // note
    var noteText: String?
    var anchorEntryId: UUID?
    /// The note's classroom-relative position (live time or playback
    /// position when taken). Absent keeps the server value.
    var noteTimeOffset: Double?
    // study review (entity id == session id). Only terminal states with
    // content are ever pushed — generating/partial progress is local.
    var reviewStatus: String?
    var reviewContent: String?
    var reviewGeneratedContent: String?
    var reviewModel: String?
    var reviewGeneratedAt: Date?
    var reviewSourceUpdatedAt: Date?
    // session attachment (classroom image). title rides `title`; the
    // structured analysis rides as a JSON STRING in `attachmentAnalysis`
    // (same convention as reviewContent) — the server casts it into a
    // JSONB column, and a string field keeps record decode failures from
    // one malformed nested object from rejecting the whole record.
    var attachmentKind: String?
    var attachmentMime: String?
    var attachmentWidth: Int?
    var attachmentHeight: Int?
    var attachmentFileSize: Int64?
    var attachmentHash: String?
    var attachmentCapturedAt: Date?
    var attachmentCaption: String?
    var attachmentSortIndex: Int?
    var attachmentTransform: String?
    var attachmentAnalysisStatus: String?
    var attachmentAnalysis: String?
    var attachmentOcrText: String?
    // learning entities (review center). Shared reference fields ride
    // courseId/sessionId/entryId plus the source* fields below; the task
    // title rides `title`. termSourceSessions is a JSON array of session
    // UUID strings (the term's accumulated classroom sources) — the same
    // string-in convention as attachmentAnalysis.
    var termRussian: String?
    var termChinese: String?
    var termExplanation: String?
    var termPartOfSpeech: String?
    var termUserNote: String?
    var termSourceSessions: String?
    var termFavorite: Bool?
    var termStatus: String?
    var cardFront: String?
    var cardBack: String?
    var cardType: String?
    var cardUserNote: String?
    var cardOrigin: String?
    var cardStage: String?
    var cardReviewCount: Int?
    var cardIntervalHours: Int?
    var cardDueAt: Date?
    var cardLastReviewedAt: Date?
    var cardLastGrade: String?
    var taskDetail: String?
    var taskDueAt: Date?
    var taskPriority: String?
    var taskStatus: String?
    var taskOrigin: String?
    var taskUncertainty: String?
    var taskUserNote: String?
    var taskCompletedAt: Date?
    // Shared source references for term/card/task. Absent (nil) keeps the
    // server value; `UUID.nilSentinel` explicitly clears it.
    var sourceAttachmentId: UUID?
    var sourceReviewId: UUID?
    var sourceTermId: UUID?
    // transcript_correction (entity id == entry id; the corrected texts
    // ride their own fields — the model's originals stay immutable).
    var correctionRussian: String?
    /// nil = "the user never corrected the Chinese" (keeps model output);
    /// a JSON-encoded empty string deliberately blanks it.
    var correctionChinese: String?
    var correctionModifiedAt: Date?
    var correctionNeedsRetranslation: Bool?
    // course_schedule. The course reference rides the shared courseId
    // sentinel field. Times are wall-clock seconds since midnight in the
    // schedule's timezone; dates ride as "YYYY-MM-DD" strings (the
    // schedule's timezone rules the calendar). Reminder lead: -1 none |
    // 0 at start | >0 minutes before.
    var scheduleWeekday: Int?
    var scheduleStartSecs: Int?
    var scheduleEndSecs: Int?
    var scheduleRecurrence: String?
    var scheduleParityAnchor: String?
    var scheduleFirstWeekIsOdd: Bool?
    var scheduleSemesterStart: String?
    var scheduleSemesterEnd: String?
    var scheduleTimezone: String?
    var scheduleTeacher: String?
    var scheduleLocation: String?
    var scheduleNote: String?
    var scheduleReminderMins: Int?
    var scheduleEnabled: Bool?
    var scheduleOnceDate: String?
    // session schedule linkage: occurrence key + planned start of the
    // class a session belongs to. Written once at session creation.
    var scheduleOccurrenceKey: String?
    var schedulePlannedStart: Date?
    // Shared schedule reference: the schedule that owns an exception, and
    // the schedule a session was started from. Absent (nil) keeps the
    // server value; `UUID.nilSentinel` explicitly clears it.
    var scheduleId: UUID?
    // schedule_exception: originalDate "YYYY-MM-DD" ("" = ad-hoc extra).
    var scheduleOriginalDate: String?
    var scheduleExceptionKind: String?
    var scheduleChangedStart: Int?
    var scheduleChangedEnd: Int?
    var scheduleMovedToDate: String?
    // course material (teacher handout / problem set / document). title
    // rides the shared `title` field; the course/session/occurrence links
    // ride the shared courseId/sessionId/scheduleOccurrenceKey fields
    // (sentinel rule); the structured digest rides as a JSON STRING in
    // `materialDigest` (same convention as attachmentAnalysis). The
    // ORIGINAL FILE never rides push — it travels on /v1/materials.
    // A LINK material (format "link") carries no file: sourceURL is
    // insert-only identity, sharedText is full desired state (empty
    // string clears, absent keeps).
    var materialKind: String?
    var materialMime: String?
    var materialFileName: String?
    var materialFormat: String?
    var materialFileSize: Int64?
    var materialHash: String?
    var materialPageCount: Int?
    var materialSourceURL: String?
    var materialSharedText: String?
    var materialExtraction: String?
    var materialDigestStatus: String?
    var materialDigest: String?
    var materialDigestModel: String?
    var materialDigestAt: Date?
    var materialDigestSourceHash: String?
    var materialLastReadPage: Int?
    var materialLastOpenedAt: Date?
    // material page: the parent material rides the shared `materialId`
    // reference; extraction and OCR text ride separate fields (never
    // merged — the same layering the local rows keep).
    var materialId: UUID?
    var materialPageNumber: Int?
    var materialPageText: String?
    var materialPageOCR: String?
    var materialPageOCRStatus: String?
    // material annotation: kind (note/bookmark) + the shared noteText for
    // the note body; the page rides the shared materialPageNumber.
    var materialAnnotationKind: String?
    // course assistant: the thread's parent rides `threadId`; a message's
    // question scope rides the shared materialId/sessionId/materialPageNumber
    // fields; the answer's citations ride as a JSON STRING in
    // `assistantCitations`. Visual Q&A adds the turn mode, the evidence
    // snapshot (JSON string — stable ids + normalized crops, never image
    // bytes), the structured answer payload (JSON string) and the answer
    // model name.
    var threadId: UUID?
    var assistantRole: String?
    var assistantText: String?
    var assistantCitations: String?
    var assistantMode: String?
    var assistantEvidence: String?
    var assistantAnswer: String?
    var assistantModel: String?
    // exam center (00012). Titles ride the shared `title`; the course
    // reference rides the shared courseId sentinel; dates are
    // YYYY-MM-DD strings; times are wall-clock seconds since midnight
    // (-1 = unknown). Source snapshots ride as JSON STRINGS.
    var examKind: String?
    var examDate: String?
    var examStartSecs: Int?
    var examEndSecs: Int?
    var examLocation: String?
    var examScope: String?
    var examNote: String?
    var examTargetScore: String?
    var examStatus: String?
    var examOrigin: String?
    var examSource: String?
    var topicDetail: String?
    var topicImportance: String?
    var topicSelfRating: String?
    var topicStatus: String?
    var topicSource: String?
    var topicUserEdited: Bool?
    var planStartDate: String?
    var planEndDate: String?
    var planWeekdayMinutes: Int?
    var planWeekendMinutes: Int?
    var planRestDays: String?
    var planFinishEarlyDays: Int?
    var planIncludeCards: Bool?
    var planIncludeTasks: Bool?
    var planIncludeMaterials: Bool?
    var planIncludeSessions: Bool?
    var planFocusTopics: String?
    var planBlockedTimes: String?
    var planStatus: String?
    var planItemDate: String?
    var planItemKind: String?
    var planItemEstimatedMinutes: Int?
    var planItemActualMinutes: Int?
    var planItemStatus: String?
    var planItemStatusChangedAt: Date?
    var planItemOrder: Int?
    var planItemSource: String?
    var planItemUserNote: String?
    var planItemUserEdited: Bool?
    var activityStatus: String?
    var activityStartedAt: Date?
    var activityEndedAt: Date?
    var activityDurationSeconds: Int?
    var activityNote: String?
    // Shared exam-family references. Absent (nil) keeps the server value;
    // `UUID.nilSentinel` explicitly clears it.
    var examId: UUID?
    var planId: UUID?
    var planItemId: UUID?
    var topicId: UUID?
}

struct SyncPushItemDTO: Codable, Sendable {
    var operationId: UUID
    var entityType: SyncEntityType
    var entityId: UUID
    var operation: SyncOperation
    var baseVersion: Int
    var clientUpdatedAt: Date
    var payload: SyncPushPayloadDTO
}

struct SyncPushRequestDTO: Codable, Sendable {
    var schemaVersion = 1
    var operations: [SyncPushItemDTO]
}

enum SyncPushStatus: String, Codable, Sendable {
    case accepted
    case conflict
    case rejected
    case retryableError = "retryable_error"
}

/// The server's current record, attached to `conflict` results so the
/// client can merge and re-submit with a fresh base version. Also used as
/// the local carrier for the guest-data migration (rows copied from the
/// guest store travel as records with serverVersion 0).
struct SyncServerRecordDTO: Codable, Sendable {
    var id: UUID?
    var title: String?
    var startedAt: Date?
    var endedAt: Date?
    var duration: Double?
    var sessionStatus: String?
    var abnormalTermination: Bool?
    var sessionId: UUID?
    var sequenceId: Int?
    var startOffset: Double?
    var endOffset: Double?
    var russianText: String?
    var chineseText: String?
    var translationStatus: String?
    var timeSource: String?
    var entryId: UUID?
    var isBookmarked: Bool?
    var isFavorite: Bool?
    var courseId: UUID?
    var teacher: String?
    var location: String?
    var colorIndex: Int?
    var isArchived: Bool?
    var noteText: String?
    var anchorEntryId: UUID?
    var noteTimeOffset: Double?
    var reviewStatus: String?
    var reviewContent: String?
    var reviewGeneratedContent: String?
    var reviewModel: String?
    var reviewGeneratedAt: Date?
    var reviewSourceUpdatedAt: Date?
    var attachmentKind: String?
    var attachmentMime: String?
    var attachmentWidth: Int?
    var attachmentHeight: Int?
    var attachmentFileSize: Int64?
    var attachmentHash: String?
    var attachmentCapturedAt: Date?
    var attachmentCaption: String?
    var attachmentSortIndex: Int?
    var attachmentTransform: String?
    var attachmentAnalysisStatus: String?
    var attachmentAnalysis: String?
    var attachmentOcrText: String?
    // learning entities (review center) — names mirror the push payload
    // so one CodingKeys set covers records and conflict payloads.
    var termRussian: String?
    var termChinese: String?
    var termExplanation: String?
    var termPartOfSpeech: String?
    var termUserNote: String?
    var termSourceSessions: String?
    var termFavorite: Bool?
    var termStatus: String?
    var cardFront: String?
    var cardBack: String?
    var cardType: String?
    var cardUserNote: String?
    var cardOrigin: String?
    var cardStage: String?
    var cardReviewCount: Int?
    var cardIntervalHours: Int?
    var cardDueAt: Date?
    var cardLastReviewedAt: Date?
    var cardLastGrade: String?
    var taskDetail: String?
    var taskDueAt: Date?
    var taskPriority: String?
    var taskStatus: String?
    var taskOrigin: String?
    var taskUncertainty: String?
    var taskUserNote: String?
    var taskCompletedAt: Date?
    var sourceAttachmentId: UUID?
    var sourceReviewId: UUID?
    var sourceTermId: UUID?
    var correctionRussian: String?
    var correctionChinese: String?
    var correctionModifiedAt: Date?
    var correctionNeedsRetranslation: Bool?
    // course_schedule / schedule_exception — names mirror the push payload
    // (scheduleXxx family) so one CodingKeys set covers records and
    // conflict payloads. Dates are "YYYY-MM-DD" strings.
    var scheduleWeekday: Int?
    var scheduleStartSecs: Int?
    var scheduleEndSecs: Int?
    var scheduleRecurrence: String?
    var scheduleParityAnchor: String?
    var scheduleFirstWeekIsOdd: Bool?
    var scheduleSemesterStart: String?
    var scheduleSemesterEnd: String?
    var scheduleTimezone: String?
    var scheduleTeacher: String?
    var scheduleLocation: String?
    var scheduleNote: String?
    var scheduleReminderMins: Int?
    var scheduleEnabled: Bool?
    var scheduleOnceDate: String?
    var scheduleOccurrenceKey: String?
    var schedulePlannedStart: Date?
    var scheduleId: UUID?
    var scheduleOriginalDate: String?
    var scheduleExceptionKind: String?
    var scheduleChangedStart: Int?
    var scheduleChangedEnd: Int?
    var scheduleMovedToDate: String?
    // course material library — names mirror the push payload (materialXxx
    // family) so one CodingKeys set covers records and conflict payloads.
    var materialKind: String?
    var materialMime: String?
    var materialFileName: String?
    var materialFormat: String?
    var materialFileSize: Int64?
    var materialHash: String?
    var materialPageCount: Int?
    var materialSourceURL: String?
    var materialSharedText: String?
    var materialExtraction: String?
    var materialDigestStatus: String?
    var materialDigest: String?
    var materialDigestModel: String?
    var materialDigestAt: Date?
    var materialDigestSourceHash: String?
    var materialLastReadPage: Int?
    var materialLastOpenedAt: Date?
    var materialId: UUID?
    var materialPageNumber: Int?
    var materialPageText: String?
    var materialPageOCR: String?
    var materialPageOCRStatus: String?
    var materialAnnotationKind: String?
    var threadId: UUID?
    var assistantRole: String?
    var assistantText: String?
    var assistantCitations: String?
    var assistantMode: String?
    var assistantEvidence: String?
    var assistantAnswer: String?
    var assistantModel: String?
    // exam center — names mirror the push payload (examXxx / topicXxx /
    // planXxx / planItemXxx / activityXxx families) so one CodingKeys set
    // covers records and conflict payloads.
    var examKind: String?
    var examDate: String?
    var examStartSecs: Int?
    var examEndSecs: Int?
    var examLocation: String?
    var examScope: String?
    var examNote: String?
    var examTargetScore: String?
    var examStatus: String?
    var examOrigin: String?
    var examSource: String?
    var topicDetail: String?
    var topicImportance: String?
    var topicSelfRating: String?
    var topicStatus: String?
    var topicSource: String?
    var topicUserEdited: Bool?
    var planStartDate: String?
    var planEndDate: String?
    var planWeekdayMinutes: Int?
    var planWeekendMinutes: Int?
    var planRestDays: String?
    var planFinishEarlyDays: Int?
    var planIncludeCards: Bool?
    var planIncludeTasks: Bool?
    var planIncludeMaterials: Bool?
    var planIncludeSessions: Bool?
    var planFocusTopics: String?
    var planBlockedTimes: String?
    var planStatus: String?
    var planItemDate: String?
    var planItemKind: String?
    var planItemEstimatedMinutes: Int?
    var planItemActualMinutes: Int?
    var planItemStatus: String?
    var planItemStatusChangedAt: Date?
    var planItemOrder: Int?
    var planItemSource: String?
    var planItemUserNote: String?
    var planItemUserEdited: Bool?
    var activityStatus: String?
    var activityStartedAt: Date?
    var activityEndedAt: Date?
    var activityDurationSeconds: Int?
    var activityNote: String?
    var examId: UUID?
    var planId: UUID?
    var planItemId: UUID?
    var topicId: UUID?
    var serverVersion: Int
    var deleted: Bool

    /// Memberwise initializer (the Decodable conformance below suppresses
    /// the automatic one).
    init(
        id: UUID? = nil,
        title: String? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        duration: Double? = nil,
        sessionStatus: String? = nil,
        abnormalTermination: Bool? = nil,
        sessionId: UUID? = nil,
        sequenceId: Int? = nil,
        startOffset: Double? = nil,
        endOffset: Double? = nil,
        russianText: String? = nil,
        chineseText: String? = nil,
        translationStatus: String? = nil,
        timeSource: String? = nil,
        entryId: UUID? = nil,
        isBookmarked: Bool? = nil,
        isFavorite: Bool? = nil,
        courseId: UUID? = nil,
        teacher: String? = nil,
        location: String? = nil,
        colorIndex: Int? = nil,
        isArchived: Bool? = nil,
        noteText: String? = nil,
        anchorEntryId: UUID? = nil,
        noteTimeOffset: Double? = nil,
        reviewStatus: String? = nil,
        reviewContent: String? = nil,
        reviewGeneratedContent: String? = nil,
        reviewModel: String? = nil,
        reviewGeneratedAt: Date? = nil,
        reviewSourceUpdatedAt: Date? = nil,
        attachmentKind: String? = nil,
        attachmentMime: String? = nil,
        attachmentWidth: Int? = nil,
        attachmentHeight: Int? = nil,
        attachmentFileSize: Int64? = nil,
        attachmentHash: String? = nil,
        attachmentCapturedAt: Date? = nil,
        attachmentCaption: String? = nil,
        attachmentSortIndex: Int? = nil,
        attachmentTransform: String? = nil,
        attachmentAnalysisStatus: String? = nil,
        attachmentAnalysis: String? = nil,
        attachmentOcrText: String? = nil,
        termRussian: String? = nil,
        termChinese: String? = nil,
        termExplanation: String? = nil,
        termPartOfSpeech: String? = nil,
        termUserNote: String? = nil,
        termSourceSessions: String? = nil,
        termFavorite: Bool? = nil,
        termStatus: String? = nil,
        cardFront: String? = nil,
        cardBack: String? = nil,
        cardType: String? = nil,
        cardUserNote: String? = nil,
        cardOrigin: String? = nil,
        cardStage: String? = nil,
        cardReviewCount: Int? = nil,
        cardIntervalHours: Int? = nil,
        cardDueAt: Date? = nil,
        cardLastReviewedAt: Date? = nil,
        cardLastGrade: String? = nil,
        taskDetail: String? = nil,
        taskDueAt: Date? = nil,
        taskPriority: String? = nil,
        taskStatus: String? = nil,
        taskOrigin: String? = nil,
        taskUncertainty: String? = nil,
        taskUserNote: String? = nil,
        taskCompletedAt: Date? = nil,
        sourceAttachmentId: UUID? = nil,
        sourceReviewId: UUID? = nil,
        sourceTermId: UUID? = nil,
        correctionRussian: String? = nil,
        correctionChinese: String? = nil,
        correctionModifiedAt: Date? = nil,
        correctionNeedsRetranslation: Bool? = nil,
        scheduleWeekday: Int? = nil,
        scheduleStartSecs: Int? = nil,
        scheduleEndSecs: Int? = nil,
        scheduleRecurrence: String? = nil,
        scheduleParityAnchor: String? = nil,
        scheduleFirstWeekIsOdd: Bool? = nil,
        scheduleSemesterStart: String? = nil,
        scheduleSemesterEnd: String? = nil,
        scheduleTimezone: String? = nil,
        scheduleTeacher: String? = nil,
        scheduleLocation: String? = nil,
        scheduleNote: String? = nil,
        scheduleReminderMins: Int? = nil,
        scheduleEnabled: Bool? = nil,
        scheduleOnceDate: String? = nil,
        scheduleOccurrenceKey: String? = nil,
        schedulePlannedStart: Date? = nil,
        scheduleId: UUID? = nil,
        scheduleOriginalDate: String? = nil,
        scheduleExceptionKind: String? = nil,
        scheduleChangedStart: Int? = nil,
        scheduleChangedEnd: Int? = nil,
        scheduleMovedToDate: String? = nil,
        materialKind: String? = nil,
        materialMime: String? = nil,
        materialFileName: String? = nil,
        materialFormat: String? = nil,
        materialFileSize: Int64? = nil,
        materialHash: String? = nil,
        materialPageCount: Int? = nil,
        materialSourceURL: String? = nil,
        materialSharedText: String? = nil,
        materialExtraction: String? = nil,
        materialDigestStatus: String? = nil,
        materialDigest: String? = nil,
        materialDigestModel: String? = nil,
        materialDigestAt: Date? = nil,
        materialDigestSourceHash: String? = nil,
        materialLastReadPage: Int? = nil,
        materialLastOpenedAt: Date? = nil,
        materialId: UUID? = nil,
        materialPageNumber: Int? = nil,
        materialPageText: String? = nil,
        materialPageOCR: String? = nil,
        materialPageOCRStatus: String? = nil,
        materialAnnotationKind: String? = nil,
        threadId: UUID? = nil,
        assistantRole: String? = nil,
        assistantText: String? = nil,
        assistantCitations: String? = nil,
        assistantMode: String? = nil,
        assistantEvidence: String? = nil,
        assistantAnswer: String? = nil,
        assistantModel: String? = nil,
        examKind: String? = nil,
        examDate: String? = nil,
        examStartSecs: Int? = nil,
        examEndSecs: Int? = nil,
        examLocation: String? = nil,
        examScope: String? = nil,
        examNote: String? = nil,
        examTargetScore: String? = nil,
        examStatus: String? = nil,
        examOrigin: String? = nil,
        examSource: String? = nil,
        topicDetail: String? = nil,
        topicImportance: String? = nil,
        topicSelfRating: String? = nil,
        topicStatus: String? = nil,
        topicSource: String? = nil,
        topicUserEdited: Bool? = nil,
        planStartDate: String? = nil,
        planEndDate: String? = nil,
        planWeekdayMinutes: Int? = nil,
        planWeekendMinutes: Int? = nil,
        planRestDays: String? = nil,
        planFinishEarlyDays: Int? = nil,
        planIncludeCards: Bool? = nil,
        planIncludeTasks: Bool? = nil,
        planIncludeMaterials: Bool? = nil,
        planIncludeSessions: Bool? = nil,
        planFocusTopics: String? = nil,
        planBlockedTimes: String? = nil,
        planStatus: String? = nil,
        planItemDate: String? = nil,
        planItemKind: String? = nil,
        planItemEstimatedMinutes: Int? = nil,
        planItemActualMinutes: Int? = nil,
        planItemStatus: String? = nil,
        planItemStatusChangedAt: Date? = nil,
        planItemOrder: Int? = nil,
        planItemSource: String? = nil,
        planItemUserNote: String? = nil,
        planItemUserEdited: Bool? = nil,
        activityStatus: String? = nil,
        activityStartedAt: Date? = nil,
        activityEndedAt: Date? = nil,
        activityDurationSeconds: Int? = nil,
        activityNote: String? = nil,
        examId: UUID? = nil,
        planId: UUID? = nil,
        planItemId: UUID? = nil,
        topicId: UUID? = nil,
        serverVersion: Int = 0,
        deleted: Bool = false
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.duration = duration
        self.sessionStatus = sessionStatus
        self.abnormalTermination = abnormalTermination
        self.sessionId = sessionId
        self.sequenceId = sequenceId
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.russianText = russianText
        self.chineseText = chineseText
        self.translationStatus = translationStatus
        self.entryId = entryId
        self.isBookmarked = isBookmarked
        self.isFavorite = isFavorite
        self.courseId = courseId
        self.teacher = teacher
        self.location = location
        self.colorIndex = colorIndex
        self.isArchived = isArchived
        self.noteText = noteText
        self.anchorEntryId = anchorEntryId
        self.noteTimeOffset = noteTimeOffset
        self.reviewStatus = reviewStatus
        self.reviewContent = reviewContent
        self.reviewGeneratedContent = reviewGeneratedContent
        self.reviewModel = reviewModel
        self.reviewGeneratedAt = reviewGeneratedAt
        self.reviewSourceUpdatedAt = reviewSourceUpdatedAt
        self.attachmentKind = attachmentKind
        self.attachmentMime = attachmentMime
        self.attachmentWidth = attachmentWidth
        self.attachmentHeight = attachmentHeight
        self.attachmentFileSize = attachmentFileSize
        self.attachmentHash = attachmentHash
        self.attachmentCapturedAt = attachmentCapturedAt
        self.attachmentCaption = attachmentCaption
        self.attachmentSortIndex = attachmentSortIndex
        self.attachmentTransform = attachmentTransform
        self.attachmentAnalysisStatus = attachmentAnalysisStatus
        self.attachmentAnalysis = attachmentAnalysis
        self.attachmentOcrText = attachmentOcrText
        self.termRussian = termRussian
        self.termChinese = termChinese
        self.termExplanation = termExplanation
        self.termPartOfSpeech = termPartOfSpeech
        self.termUserNote = termUserNote
        self.termSourceSessions = termSourceSessions
        self.termFavorite = termFavorite
        self.termStatus = termStatus
        self.cardFront = cardFront
        self.cardBack = cardBack
        self.cardType = cardType
        self.cardUserNote = cardUserNote
        self.cardOrigin = cardOrigin
        self.cardStage = cardStage
        self.cardReviewCount = cardReviewCount
        self.cardIntervalHours = cardIntervalHours
        self.cardDueAt = cardDueAt
        self.cardLastReviewedAt = cardLastReviewedAt
        self.cardLastGrade = cardLastGrade
        self.taskDetail = taskDetail
        self.taskDueAt = taskDueAt
        self.taskPriority = taskPriority
        self.taskStatus = taskStatus
        self.taskOrigin = taskOrigin
        self.taskUncertainty = taskUncertainty
        self.taskUserNote = taskUserNote
        self.taskCompletedAt = taskCompletedAt
        self.sourceAttachmentId = sourceAttachmentId
        self.sourceReviewId = sourceReviewId
        self.sourceTermId = sourceTermId
        self.correctionRussian = correctionRussian
        self.correctionChinese = correctionChinese
        self.correctionModifiedAt = correctionModifiedAt
        self.correctionNeedsRetranslation = correctionNeedsRetranslation
        self.scheduleWeekday = scheduleWeekday
        self.scheduleStartSecs = scheduleStartSecs
        self.scheduleEndSecs = scheduleEndSecs
        self.scheduleRecurrence = scheduleRecurrence
        self.scheduleParityAnchor = scheduleParityAnchor
        self.scheduleFirstWeekIsOdd = scheduleFirstWeekIsOdd
        self.scheduleSemesterStart = scheduleSemesterStart
        self.scheduleSemesterEnd = scheduleSemesterEnd
        self.scheduleTimezone = scheduleTimezone
        self.scheduleTeacher = scheduleTeacher
        self.scheduleLocation = scheduleLocation
        self.scheduleNote = scheduleNote
        self.scheduleReminderMins = scheduleReminderMins
        self.scheduleEnabled = scheduleEnabled
        self.scheduleOnceDate = scheduleOnceDate
        self.scheduleOccurrenceKey = scheduleOccurrenceKey
        self.schedulePlannedStart = schedulePlannedStart
        self.scheduleId = scheduleId
        self.scheduleOriginalDate = scheduleOriginalDate
        self.scheduleExceptionKind = scheduleExceptionKind
        self.scheduleChangedStart = scheduleChangedStart
        self.scheduleChangedEnd = scheduleChangedEnd
        self.scheduleMovedToDate = scheduleMovedToDate
        self.materialKind = materialKind
        self.materialMime = materialMime
        self.materialFileName = materialFileName
        self.materialFormat = materialFormat
        self.materialFileSize = materialFileSize
        self.materialHash = materialHash
        self.materialPageCount = materialPageCount
        self.materialSourceURL = materialSourceURL
        self.materialSharedText = materialSharedText
        self.materialExtraction = materialExtraction
        self.materialDigestStatus = materialDigestStatus
        self.materialDigest = materialDigest
        self.materialDigestModel = materialDigestModel
        self.materialDigestAt = materialDigestAt
        self.materialDigestSourceHash = materialDigestSourceHash
        self.materialLastReadPage = materialLastReadPage
        self.materialLastOpenedAt = materialLastOpenedAt
        self.materialId = materialId
        self.materialPageNumber = materialPageNumber
        self.materialPageText = materialPageText
        self.materialPageOCR = materialPageOCR
        self.materialPageOCRStatus = materialPageOCRStatus
        self.materialAnnotationKind = materialAnnotationKind
        self.threadId = threadId
        self.assistantRole = assistantRole
        self.assistantText = assistantText
        self.assistantCitations = assistantCitations
        self.assistantMode = assistantMode
        self.assistantEvidence = assistantEvidence
        self.assistantAnswer = assistantAnswer
        self.assistantModel = assistantModel
        self.examKind = examKind
        self.examDate = examDate
        self.examStartSecs = examStartSecs
        self.examEndSecs = examEndSecs
        self.examLocation = examLocation
        self.examScope = examScope
        self.examNote = examNote
        self.examTargetScore = examTargetScore
        self.examStatus = examStatus
        self.examOrigin = examOrigin
        self.examSource = examSource
        self.topicDetail = topicDetail
        self.topicImportance = topicImportance
        self.topicSelfRating = topicSelfRating
        self.topicStatus = topicStatus
        self.topicSource = topicSource
        self.topicUserEdited = topicUserEdited
        self.planStartDate = planStartDate
        self.planEndDate = planEndDate
        self.planWeekdayMinutes = planWeekdayMinutes
        self.planWeekendMinutes = planWeekendMinutes
        self.planRestDays = planRestDays
        self.planFinishEarlyDays = planFinishEarlyDays
        self.planIncludeCards = planIncludeCards
        self.planIncludeTasks = planIncludeTasks
        self.planIncludeMaterials = planIncludeMaterials
        self.planIncludeSessions = planIncludeSessions
        self.planFocusTopics = planFocusTopics
        self.planBlockedTimes = planBlockedTimes
        self.planStatus = planStatus
        self.planItemDate = planItemDate
        self.planItemKind = planItemKind
        self.planItemEstimatedMinutes = planItemEstimatedMinutes
        self.planItemActualMinutes = planItemActualMinutes
        self.planItemStatus = planItemStatus
        self.planItemStatusChangedAt = planItemStatusChangedAt
        self.planItemOrder = planItemOrder
        self.planItemSource = planItemSource
        self.planItemUserNote = planItemUserNote
        self.planItemUserEdited = planItemUserEdited
        self.activityStatus = activityStatus
        self.activityStartedAt = activityStartedAt
        self.activityEndedAt = activityEndedAt
        self.activityDurationSeconds = activityDurationSeconds
        self.activityNote = activityNote
        self.examId = examId
        self.planId = planId
        self.planItemId = planItemId
        self.topicId = topicId
        self.serverVersion = serverVersion
        self.deleted = deleted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        duration = try container.decodeIfPresent(Double.self, forKey: .duration)
        sessionStatus = try container.decodeIfPresent(String.self, forKey: .sessionStatus)
        abnormalTermination = try container.decodeIfPresent(Bool.self, forKey: .abnormalTermination)
        sessionId = try container.decodeIfPresent(UUID.self, forKey: .sessionId)
        sequenceId = try container.decodeIfPresent(Int.self, forKey: .sequenceId)
        startOffset = try container.decodeIfPresent(Double.self, forKey: .startOffset)
        endOffset = try container.decodeIfPresent(Double.self, forKey: .endOffset)
        russianText = try container.decodeIfPresent(String.self, forKey: .russianText)
        chineseText = try container.decodeIfPresent(String.self, forKey: .chineseText)
        translationStatus = try container.decodeIfPresent(String.self, forKey: .translationStatus)
        timeSource = try container.decodeIfPresent(String.self, forKey: .timeSource)
        entryId = try container.decodeIfPresent(UUID.self, forKey: .entryId)
        isBookmarked = try container.decodeIfPresent(Bool.self, forKey: .isBookmarked)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite)
        courseId = try container.decodeIfPresent(UUID.self, forKey: .courseId)
        teacher = try container.decodeIfPresent(String.self, forKey: .teacher)
        location = try container.decodeIfPresent(String.self, forKey: .location)
        colorIndex = try container.decodeIfPresent(Int.self, forKey: .colorIndex)
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived)
        noteText = try container.decodeIfPresent(String.self, forKey: .noteText)
        anchorEntryId = try container.decodeIfPresent(UUID.self, forKey: .anchorEntryId)
        noteTimeOffset = try container.decodeIfPresent(Double.self, forKey: .noteTimeOffset)
        reviewStatus = try container.decodeIfPresent(String.self, forKey: .reviewStatus)
        reviewContent = try container.decodeIfPresent(String.self, forKey: .reviewContent)
        reviewGeneratedContent = try container.decodeIfPresent(String.self, forKey: .reviewGeneratedContent)
        reviewModel = try container.decodeIfPresent(String.self, forKey: .reviewModel)
        reviewGeneratedAt = try container.decodeIfPresent(Date.self, forKey: .reviewGeneratedAt)
        reviewSourceUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .reviewSourceUpdatedAt)
        attachmentKind = try container.decodeIfPresent(String.self, forKey: .attachmentKind)
        attachmentMime = try container.decodeIfPresent(String.self, forKey: .attachmentMime)
        attachmentWidth = try container.decodeIfPresent(Int.self, forKey: .attachmentWidth)
        attachmentHeight = try container.decodeIfPresent(Int.self, forKey: .attachmentHeight)
        attachmentFileSize = try container.decodeIfPresent(Int64.self, forKey: .attachmentFileSize)
        attachmentHash = try container.decodeIfPresent(String.self, forKey: .attachmentHash)
        attachmentCapturedAt = try container.decodeIfPresent(Date.self, forKey: .attachmentCapturedAt)
        attachmentCaption = try container.decodeIfPresent(String.self, forKey: .attachmentCaption)
        attachmentSortIndex = try container.decodeIfPresent(Int.self, forKey: .attachmentSortIndex)
        attachmentTransform = try container.decodeIfPresent(String.self, forKey: .attachmentTransform)
        attachmentAnalysisStatus = try container.decodeIfPresent(String.self, forKey: .attachmentAnalysisStatus)
        attachmentAnalysis = try container.decodeIfPresent(String.self, forKey: .attachmentAnalysis)
        attachmentOcrText = try container.decodeIfPresent(String.self, forKey: .attachmentOcrText)
        termRussian = try container.decodeIfPresent(String.self, forKey: .termRussian)
        termChinese = try container.decodeIfPresent(String.self, forKey: .termChinese)
        termExplanation = try container.decodeIfPresent(String.self, forKey: .termExplanation)
        termPartOfSpeech = try container.decodeIfPresent(String.self, forKey: .termPartOfSpeech)
        termUserNote = try container.decodeIfPresent(String.self, forKey: .termUserNote)
        termSourceSessions = try container.decodeIfPresent(String.self, forKey: .termSourceSessions)
        termFavorite = try container.decodeIfPresent(Bool.self, forKey: .termFavorite)
        termStatus = try container.decodeIfPresent(String.self, forKey: .termStatus)
        cardFront = try container.decodeIfPresent(String.self, forKey: .cardFront)
        cardBack = try container.decodeIfPresent(String.self, forKey: .cardBack)
        cardType = try container.decodeIfPresent(String.self, forKey: .cardType)
        cardUserNote = try container.decodeIfPresent(String.self, forKey: .cardUserNote)
        cardOrigin = try container.decodeIfPresent(String.self, forKey: .cardOrigin)
        cardStage = try container.decodeIfPresent(String.self, forKey: .cardStage)
        cardReviewCount = try container.decodeIfPresent(Int.self, forKey: .cardReviewCount)
        cardIntervalHours = try container.decodeIfPresent(Int.self, forKey: .cardIntervalHours)
        cardDueAt = try container.decodeIfPresent(Date.self, forKey: .cardDueAt)
        cardLastReviewedAt = try container.decodeIfPresent(Date.self, forKey: .cardLastReviewedAt)
        cardLastGrade = try container.decodeIfPresent(String.self, forKey: .cardLastGrade)
        taskDetail = try container.decodeIfPresent(String.self, forKey: .taskDetail)
        taskDueAt = try container.decodeIfPresent(Date.self, forKey: .taskDueAt)
        taskPriority = try container.decodeIfPresent(String.self, forKey: .taskPriority)
        taskStatus = try container.decodeIfPresent(String.self, forKey: .taskStatus)
        taskOrigin = try container.decodeIfPresent(String.self, forKey: .taskOrigin)
        taskUncertainty = try container.decodeIfPresent(String.self, forKey: .taskUncertainty)
        taskUserNote = try container.decodeIfPresent(String.self, forKey: .taskUserNote)
        taskCompletedAt = try container.decodeIfPresent(Date.self, forKey: .taskCompletedAt)
        sourceAttachmentId = try container.decodeIfPresent(UUID.self, forKey: .sourceAttachmentId)
        sourceReviewId = try container.decodeIfPresent(UUID.self, forKey: .sourceReviewId)
        sourceTermId = try container.decodeIfPresent(UUID.self, forKey: .sourceTermId)
        correctionRussian = try container.decodeIfPresent(String.self, forKey: .correctionRussian)
        correctionChinese = try container.decodeIfPresent(String.self, forKey: .correctionChinese)
        correctionModifiedAt = try container.decodeIfPresent(Date.self, forKey: .correctionModifiedAt)
        correctionNeedsRetranslation = try container.decodeIfPresent(Bool.self, forKey: .correctionNeedsRetranslation)
        scheduleWeekday = try container.decodeIfPresent(Int.self, forKey: .scheduleWeekday)
        scheduleStartSecs = try container.decodeIfPresent(Int.self, forKey: .scheduleStartSecs)
        scheduleEndSecs = try container.decodeIfPresent(Int.self, forKey: .scheduleEndSecs)
        scheduleRecurrence = try container.decodeIfPresent(String.self, forKey: .scheduleRecurrence)
        scheduleParityAnchor = try container.decodeIfPresent(String.self, forKey: .scheduleParityAnchor)
        scheduleFirstWeekIsOdd = try container.decodeIfPresent(Bool.self, forKey: .scheduleFirstWeekIsOdd)
        scheduleSemesterStart = try container.decodeIfPresent(String.self, forKey: .scheduleSemesterStart)
        scheduleSemesterEnd = try container.decodeIfPresent(String.self, forKey: .scheduleSemesterEnd)
        scheduleTimezone = try container.decodeIfPresent(String.self, forKey: .scheduleTimezone)
        scheduleTeacher = try container.decodeIfPresent(String.self, forKey: .scheduleTeacher)
        scheduleLocation = try container.decodeIfPresent(String.self, forKey: .scheduleLocation)
        scheduleNote = try container.decodeIfPresent(String.self, forKey: .scheduleNote)
        scheduleReminderMins = try container.decodeIfPresent(Int.self, forKey: .scheduleReminderMins)
        scheduleEnabled = try container.decodeIfPresent(Bool.self, forKey: .scheduleEnabled)
        scheduleOnceDate = try container.decodeIfPresent(String.self, forKey: .scheduleOnceDate)
        scheduleOccurrenceKey = try container.decodeIfPresent(String.self, forKey: .scheduleOccurrenceKey)
        schedulePlannedStart = try container.decodeIfPresent(Date.self, forKey: .schedulePlannedStart)
        scheduleId = try container.decodeIfPresent(UUID.self, forKey: .scheduleId)
        scheduleOriginalDate = try container.decodeIfPresent(String.self, forKey: .scheduleOriginalDate)
        scheduleExceptionKind = try container.decodeIfPresent(String.self, forKey: .scheduleExceptionKind)
        scheduleChangedStart = try container.decodeIfPresent(Int.self, forKey: .scheduleChangedStart)
        scheduleChangedEnd = try container.decodeIfPresent(Int.self, forKey: .scheduleChangedEnd)
        scheduleMovedToDate = try container.decodeIfPresent(String.self, forKey: .scheduleMovedToDate)
        materialKind = try container.decodeIfPresent(String.self, forKey: .materialKind)
        materialMime = try container.decodeIfPresent(String.self, forKey: .materialMime)
        materialFileName = try container.decodeIfPresent(String.self, forKey: .materialFileName)
        materialFormat = try container.decodeIfPresent(String.self, forKey: .materialFormat)
        materialFileSize = try container.decodeIfPresent(Int64.self, forKey: .materialFileSize)
        materialHash = try container.decodeIfPresent(String.self, forKey: .materialHash)
        materialPageCount = try container.decodeIfPresent(Int.self, forKey: .materialPageCount)
        materialSourceURL = try container.decodeIfPresent(String.self, forKey: .materialSourceURL)
        materialSharedText = try container.decodeIfPresent(String.self, forKey: .materialSharedText)
        materialExtraction = try container.decodeIfPresent(String.self, forKey: .materialExtraction)
        materialDigestStatus = try container.decodeIfPresent(String.self, forKey: .materialDigestStatus)
        materialDigest = try container.decodeIfPresent(String.self, forKey: .materialDigest)
        materialDigestModel = try container.decodeIfPresent(String.self, forKey: .materialDigestModel)
        materialDigestAt = try container.decodeIfPresent(Date.self, forKey: .materialDigestAt)
        materialDigestSourceHash = try container.decodeIfPresent(String.self, forKey: .materialDigestSourceHash)
        materialLastReadPage = try container.decodeIfPresent(Int.self, forKey: .materialLastReadPage)
        materialLastOpenedAt = try container.decodeIfPresent(Date.self, forKey: .materialLastOpenedAt)
        materialId = try container.decodeIfPresent(UUID.self, forKey: .materialId)
        materialPageNumber = try container.decodeIfPresent(Int.self, forKey: .materialPageNumber)
        materialPageText = try container.decodeIfPresent(String.self, forKey: .materialPageText)
        materialPageOCR = try container.decodeIfPresent(String.self, forKey: .materialPageOCR)
        materialPageOCRStatus = try container.decodeIfPresent(String.self, forKey: .materialPageOCRStatus)
        materialAnnotationKind = try container.decodeIfPresent(String.self, forKey: .materialAnnotationKind)
        threadId = try container.decodeIfPresent(UUID.self, forKey: .threadId)
        assistantRole = try container.decodeIfPresent(String.self, forKey: .assistantRole)
        assistantText = try container.decodeIfPresent(String.self, forKey: .assistantText)
        assistantCitations = try container.decodeIfPresent(String.self, forKey: .assistantCitations)
        assistantMode = try container.decodeIfPresent(String.self, forKey: .assistantMode)
        assistantEvidence = try container.decodeIfPresent(String.self, forKey: .assistantEvidence)
        assistantAnswer = try container.decodeIfPresent(String.self, forKey: .assistantAnswer)
        assistantModel = try container.decodeIfPresent(String.self, forKey: .assistantModel)
        examKind = try container.decodeIfPresent(String.self, forKey: .examKind)
        examDate = try container.decodeIfPresent(String.self, forKey: .examDate)
        examStartSecs = try container.decodeIfPresent(Int.self, forKey: .examStartSecs)
        examEndSecs = try container.decodeIfPresent(Int.self, forKey: .examEndSecs)
        examLocation = try container.decodeIfPresent(String.self, forKey: .examLocation)
        examScope = try container.decodeIfPresent(String.self, forKey: .examScope)
        examNote = try container.decodeIfPresent(String.self, forKey: .examNote)
        examTargetScore = try container.decodeIfPresent(String.self, forKey: .examTargetScore)
        examStatus = try container.decodeIfPresent(String.self, forKey: .examStatus)
        examOrigin = try container.decodeIfPresent(String.self, forKey: .examOrigin)
        examSource = try container.decodeIfPresent(String.self, forKey: .examSource)
        topicDetail = try container.decodeIfPresent(String.self, forKey: .topicDetail)
        topicImportance = try container.decodeIfPresent(String.self, forKey: .topicImportance)
        topicSelfRating = try container.decodeIfPresent(String.self, forKey: .topicSelfRating)
        topicStatus = try container.decodeIfPresent(String.self, forKey: .topicStatus)
        topicSource = try container.decodeIfPresent(String.self, forKey: .topicSource)
        topicUserEdited = try container.decodeIfPresent(Bool.self, forKey: .topicUserEdited)
        planStartDate = try container.decodeIfPresent(String.self, forKey: .planStartDate)
        planEndDate = try container.decodeIfPresent(String.self, forKey: .planEndDate)
        planWeekdayMinutes = try container.decodeIfPresent(Int.self, forKey: .planWeekdayMinutes)
        planWeekendMinutes = try container.decodeIfPresent(Int.self, forKey: .planWeekendMinutes)
        planRestDays = try container.decodeIfPresent(String.self, forKey: .planRestDays)
        planFinishEarlyDays = try container.decodeIfPresent(Int.self, forKey: .planFinishEarlyDays)
        planIncludeCards = try container.decodeIfPresent(Bool.self, forKey: .planIncludeCards)
        planIncludeTasks = try container.decodeIfPresent(Bool.self, forKey: .planIncludeTasks)
        planIncludeMaterials = try container.decodeIfPresent(Bool.self, forKey: .planIncludeMaterials)
        planIncludeSessions = try container.decodeIfPresent(Bool.self, forKey: .planIncludeSessions)
        planFocusTopics = try container.decodeIfPresent(String.self, forKey: .planFocusTopics)
        planBlockedTimes = try container.decodeIfPresent(String.self, forKey: .planBlockedTimes)
        planStatus = try container.decodeIfPresent(String.self, forKey: .planStatus)
        planItemDate = try container.decodeIfPresent(String.self, forKey: .planItemDate)
        planItemKind = try container.decodeIfPresent(String.self, forKey: .planItemKind)
        planItemEstimatedMinutes = try container.decodeIfPresent(Int.self, forKey: .planItemEstimatedMinutes)
        planItemActualMinutes = try container.decodeIfPresent(Int.self, forKey: .planItemActualMinutes)
        planItemStatus = try container.decodeIfPresent(String.self, forKey: .planItemStatus)
        planItemStatusChangedAt = try container.decodeIfPresent(Date.self, forKey: .planItemStatusChangedAt)
        planItemOrder = try container.decodeIfPresent(Int.self, forKey: .planItemOrder)
        planItemSource = try container.decodeIfPresent(String.self, forKey: .planItemSource)
        planItemUserNote = try container.decodeIfPresent(String.self, forKey: .planItemUserNote)
        planItemUserEdited = try container.decodeIfPresent(Bool.self, forKey: .planItemUserEdited)
        activityStatus = try container.decodeIfPresent(String.self, forKey: .activityStatus)
        activityStartedAt = try container.decodeIfPresent(Date.self, forKey: .activityStartedAt)
        activityEndedAt = try container.decodeIfPresent(Date.self, forKey: .activityEndedAt)
        activityDurationSeconds = try container.decodeIfPresent(Int.self, forKey: .activityDurationSeconds)
        activityNote = try container.decodeIfPresent(String.self, forKey: .activityNote)
        examId = try container.decodeIfPresent(UUID.self, forKey: .examId)
        planId = try container.decodeIfPresent(UUID.self, forKey: .planId)
        planItemId = try container.decodeIfPresent(UUID.self, forKey: .planItemId)
        topicId = try container.decodeIfPresent(UUID.self, forKey: .topicId)
        serverVersion = try container.decodeIfPresent(Int.self, forKey: .serverVersion) ?? 0
        deleted = try container.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
    }
}

struct SyncPushItemResultDTO: Codable, Sendable {
    var operationId: UUID
    var status: SyncPushStatus
    var serverVersion: Int?
    var serverUpdatedAt: Date?
    var errorCode: String?
    var serverRecord: SyncServerRecordDTO?
}

struct SyncPushResponseDTO: Codable, Sendable {
    var schemaVersion: Int
    var results: [SyncPushItemResultDTO]
}

// MARK: - Pull

struct SyncPullChangeDTO: Codable, Sendable {
    var changeSequence: Int
    var entityType: SyncEntityType
    var entityId: UUID
    var operation: SyncOperation
    var serverVersion: Int
    var record: SyncServerRecordDTO?
}

struct SyncPullResponseDTO: Codable, Sendable {
    var schemaVersion: Int
    var changes: [SyncPullChangeDTO]
    var nextCursor: Int
    var hasMore: Bool
}

struct SyncStatusResponseDTO: Codable, Sendable {
    var schemaVersion: Int
    var changeLogTail: Int
    var sessionCount: Int
    var entryCount: Int
    var courseCount: Int?
    var noteCount: Int?
    var reviewCount: Int?
    var attachmentCount: Int?
    var termCount: Int?
    var studyCardCount: Int?
    var studyTaskCount: Int?
    var transcriptCorrectionCount: Int?
    var courseScheduleCount: Int?
    var scheduleExceptionCount: Int?
    var materialCount: Int?
    var materialPageCount: Int?
    var materialAnnotationCount: Int?
    var assistantThreadCount: Int?
    var assistantMessageCount: Int?
    var examCount: Int?
    var examTopicCount: Int?
    var studyPlanCount: Int?
    var studyPlanItemCount: Int?
    var studyActivityCount: Int?
}
