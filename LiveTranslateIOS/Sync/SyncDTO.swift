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

    enum CodingKeys: String, CodingKey {
        case accessToken, refreshToken, tokenType, expiresIn, userId, isNewUser
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        refreshToken = try container.decode(String.self, forKey: .refreshToken)
        tokenType = try container.decodeIfPresent(String.self, forKey: .tokenType) ?? "Bearer"
        expiresIn = try container.decodeIfPresent(Int.self, forKey: .expiresIn) ?? 900
        userId = try container.decode(UUID.self, forKey: .userId)
        isNewUser = try container.decodeIfPresent(Bool.self, forKey: .isNewUser)
    }

    init(accessToken: String, refreshToken: String, tokenType: String = "Bearer",
         expiresIn: Int = 900, userId: UUID, isNewUser: Bool? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenType = tokenType
        self.expiresIn = expiresIn
        self.userId = userId
        self.isNewUser = isNewUser
    }
}

struct SyncMeDTO: Codable, Sendable, Equatable {
    var userId: UUID
    var displayLabel: String
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
/// client can merge and re-submit with a fresh base version.
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
