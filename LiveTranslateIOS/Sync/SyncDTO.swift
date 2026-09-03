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
}
