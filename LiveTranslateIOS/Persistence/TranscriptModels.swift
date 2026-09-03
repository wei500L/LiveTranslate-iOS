import Foundation
import SwiftData

/// A recurring course the student attends (e.g. 高等数学 II). Sessions
/// reference a course by `courseID`; deleting a course leaves its sessions
/// standalone — the reference is cleared, never cascaded.
@Model
final class Course {
    @Attribute(.unique) var id: UUID
    var name: String
    /// Optional teacher name; empty string = not set.
    var teacherName: String
    /// Optional classroom/location; empty string = not set.
    var location: String
    /// Index into the fixed course color palette (presentation only).
    var colorIndex: Int
    var isArchived: Bool
    var createdAt: Date
    var updatedAt: Date
    /// Start time of the most recent session in this course (nil until the
    /// first session) — drives the home quick-start ordering.
    var lastUsedAt: Date?
    /// Cloud-sync metadata (0 = never synced).
    var serverVersion: Int

    init(
        id: UUID = UUID(),
        name: String,
        teacherName: String = "",
        location: String = "",
        colorIndex: Int = 0,
        isArchived: Bool = false,
        lastUsedAt: Date? = nil,
        serverVersion: Int = 0
    ) {
        self.id = id
        self.name = name
        self.teacherName = teacherName
        self.location = location
        self.colorIndex = colorIndex
        self.isArchived = isArchived
        self.createdAt = .now
        self.updatedAt = .now
        self.lastUsedAt = lastUsedAt
        self.serverVersion = serverVersion
    }
}

/// One classroom session (a live translation run).
@Model
final class ClassroomSession {
    @Attribute(.unique) var id: UUID
    var title: String
    var startTime: Date
    var endTime: Date?
    var duration: TimeInterval
    var sourceLanguage: String
    var targetLanguage: String
    /// Unified model identity, always "GigaAM-v3 e2e_rnnt".
    var asrModel: String
    /// Always "e2e_rnnt".
    var asrRevision: String
    /// Raw value of `ASRBackendKind` actually used for this session.
    var asrBackend: String
    /// Manifest version / pinned revision of the installed backend.
    var modelVersion: String
    /// "cpuAndGPU" / "cpuAndNeuralEngine" / "int8-2threads" etc.
    var computePreference: String
    var translationModel: String
    var entryCount: Int
    /// True when the app was killed mid-session; set on next launch.
    var abnormalTermination: Bool
    var createdAt: Date
    var updatedAt: Date
    /// The course this session belongs to (nil = standalone session).
    /// Kept as a plain id (no SwiftData relationship): courses and sessions
    /// sync as independent entities, and a session record may arrive before
    /// its course — the id survives that ordering, the UI resolves the
    /// course at display time.
    var courseID: UUID?
    /// Cloud-sync metadata: server version of the last acknowledged push
    /// (0 = never synced). Added with a default so existing stores
    /// lightweight-migrate in place.
    var serverVersion: Int

    @Relationship(deleteRule: .cascade, inverse: \TranscriptEntry.session)
    var entries: [TranscriptEntry]

    init(
        id: UUID = UUID(),
        title: String,
        startTime: Date = .now,
        endTime: Date? = nil,
        duration: TimeInterval = 0,
        sourceLanguage: String = "ru",
        targetLanguage: String = "zh-CN",
        asrModel: String = "GigaAM-v3",
        asrRevision: String = "e2e_rnnt",
        asrBackend: String,
        modelVersion: String = "",
        computePreference: String = "",
        translationModel: String = "",
        entryCount: Int = 0,
        abnormalTermination: Bool = false,
        courseID: UUID? = nil,
        serverVersion: Int = 0
    ) {
        self.id = id
        self.title = title
        self.startTime = startTime
        self.endTime = endTime
        self.duration = duration
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.asrModel = asrModel
        self.asrRevision = asrRevision
        self.asrBackend = asrBackend
        self.modelVersion = modelVersion
        self.computePreference = computePreference
        self.translationModel = translationModel
        self.entryCount = entryCount
        self.abnormalTermination = abnormalTermination
        self.courseID = courseID
        self.createdAt = .now
        self.updatedAt = .now
        self.serverVersion = serverVersion
        self.entries = []
    }
}

/// One recognized utterance with its (possibly pending) translation.
@Model
final class TranscriptEntry {
    @Attribute(.unique) var id: UUID
    var sessionID: UUID
    /// Monotonic utterance order within the session.
    var sequenceID: Int
    var startOffset: TimeInterval
    var endOffset: TimeInterval
    var originalText: String
    var translatedText: String?
    /// pending | completed | failed | notConfigured
    var translationStatus: String
    var asrBackend: String
    var asrLatency: TimeInterval
    var asrRTF: Double
    var translationLatency: TimeInterval?
    var createdAt: Date
    /// Cloud-sync metadata (0 = never synced).
    var serverVersion: Int

    var session: ClassroomSession?

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        sequenceID: Int,
        startOffset: TimeInterval,
        endOffset: TimeInterval,
        originalText: String,
        translatedText: String? = nil,
        translationStatus: String = TranslationStatus.pending.rawValue,
        asrBackend: String,
        asrLatency: TimeInterval = 0,
        asrRTF: Double = 0,
        translationLatency: TimeInterval? = nil,
        serverVersion: Int = 0
    ) {
        self.id = id
        self.sessionID = sessionID
        self.sequenceID = sequenceID
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.originalText = originalText
        self.translatedText = translatedText
        self.translationStatus = translationStatus
        self.asrBackend = asrBackend
        self.asrLatency = asrLatency
        self.asrRTF = asrRTF
        self.translationLatency = translationLatency
        self.createdAt = .now
        self.serverVersion = serverVersion
    }
}

/// A user-typed note for one classroom session, optionally anchored to the
/// transcript entry it refers to. Anchored notes render inline under their
/// entry and can jump back to it; the anchor is metadata — the note text
/// survives even if the entry disappears (the anchor is then cleared).
@Model
final class SessionNote {
    @Attribute(.unique) var id: UUID
    var sessionID: UUID
    /// The transcript entry this note was taken about (nil = standalone).
    var anchorEntryID: UUID?
    var text: String
    var createdAt: Date
    var updatedAt: Date
    /// Cloud-sync metadata (0 = never synced).
    var serverVersion: Int

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        anchorEntryID: UUID? = nil,
        text: String,
        serverVersion: Int = 0
    ) {
        self.id = id
        self.sessionID = sessionID
        self.anchorEntryID = anchorEntryID
        self.text = text
        self.createdAt = .now
        self.updatedAt = .now
        self.serverVersion = serverVersion
    }
}

enum TranslationStatus: String, Codable, Sendable {
    case pending
    case completed
    case failed
    case notConfigured
    /// The user turned live translation off — no request was ever made for
    /// this entry. A presentation-level user-intent state: it must never be
    /// surfaced, persisted or retried as an error.
    case skipped
}

extension TranscriptEntry {
    var status: TranslationStatus {
        get { TranslationStatus(rawValue: translationStatus) ?? .pending }
        set { translationStatus = newValue.rawValue }
    }
}
