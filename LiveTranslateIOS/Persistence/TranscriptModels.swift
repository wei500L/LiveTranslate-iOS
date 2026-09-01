import Foundation
import SwiftData

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
        abnormalTermination: Bool = false
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
        self.createdAt = .now
        self.updatedAt = .now
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
        translationLatency: TimeInterval? = nil
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
