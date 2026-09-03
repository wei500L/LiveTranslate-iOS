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
}
