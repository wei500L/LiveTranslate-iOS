import Foundation
import SwiftData

/// Metadata asset for one classroom's raw recording. The FILE lives under
/// `SessionRecordings` (Application Support/Sessions/<sessionID>/) and is
/// only reachable through this model — views never concatenate the
/// `raw.wav` path themselves. Rows are device-local: recordings never sync
/// (only text and study material do), so there is no serverVersion.
///
/// Lifecycle:
/// - created by the live coordinator when recording starts;
/// - `isComplete` flips when the WAV writer patches its header on a clean
///   stop. A row found with `isComplete == false` (app killed mid-class)
///   still points at whatever bytes reached disk — playback tolerates a
///   zero-sized RIFF header by trusting the actual file length;
/// - deleting the recording (storage management) deletes the FILE but
///   keeps the row with `isDeleted` — transcript time metadata survives
///   and the play affordance disappears honestly;
/// - deleting the session deletes row + file together.
@Model
final class SessionRecording {
    @Attribute(.unique) var id: UUID
    /// == ClassroomSession.id (one recording per session, structurally).
    var sessionID: UUID
    /// File name inside the session's recording directory ("raw.wav").
    /// The player resolves the format from the extension + metadata, never
    /// from a hardcoded path.
    var fileName: String
    /// MIME-ish format tag, e.g. "audio/wav". Future compressed formats
    /// are distinguished here, not by branch-on-path.
    var format: String
    var sampleRate: Int
    var channelCount: Int
    var bitsPerSample: Int
    /// Recorded duration in seconds (from the writer's frame count; for
    /// an incomplete file, whatever frames reached disk).
    var duration: TimeInterval
    /// Size in bytes at the last known write (the file may be larger if
    /// the app died before the row was updated — storage stats read the
    /// real file size).
    var fileSize: Int64
    /// False while recording; true after a clean stop.
    var isComplete: Bool
    /// True after the user deleted the audio (row + time metadata stay,
    /// the file is gone). A deleted recording never shows a play button.
    var isDeleted: Bool
    /// Waveform downsample state (see RecordingWaveformStore). Empty =
    /// not yet computed.
    var waveformStatusRaw: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        fileName: String = "raw.wav",
        format: String = "audio/wav",
        sampleRate: Int = 16_000,
        channelCount: Int = 1,
        bitsPerSample: Int = 16,
        duration: TimeInterval = 0,
        fileSize: Int64 = 0,
        isComplete: Bool = false,
        isDeleted: Bool = false,
        waveformStatus: SessionRecording.WaveformStatus = .notGenerated
    ) {
        self.id = id
        self.sessionID = sessionID
        self.fileName = fileName
        self.format = format
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitsPerSample = bitsPerSample
        self.duration = duration
        self.fileSize = fileSize
        self.isComplete = isComplete
        self.isDeleted = isDeleted
        self.waveformStatusRaw = waveformStatus.rawValue
        self.createdAt = .now
        self.updatedAt = .now
    }

    /// Waveform precompute lifecycle. `generating` is device-local and
    /// transient; the computed buckets cache on disk (never in the row).
    enum WaveformStatus: String, Codable, Sendable {
        case notGenerated
        case generating
        case generated
        case failed
    }

    var waveformStatus: WaveformStatus {
        get { WaveformStatus(rawValue: waveformStatusRaw) ?? .notGenerated }
        set { waveformStatusRaw = newValue.rawValue }
    }

    var mimeTypeHint: String { format }
}

/// User correction overlay for ONE transcript entry — the model's original
/// ASR/translation output is never overwritten:
/// - `TranscriptEntry.originalText` stays the model's Russian forever;
/// - `TranscriptEntry.translatedText` stays the model's translation;
/// - this row carries ONLY the user's edited versions.
///
/// The effective text shown by every reader (search, export, AI material,
/// review, copy) is `effectiveRussianText/effectiveChineseText` — the
/// single rule lives in this file; call sites never re-derive it.
///
/// Sync: entity `transcript_correction`, one row per entry (entity id ==
/// entry id). Deleting the row (or a server tombstone) means "revert to
/// the model's original" — it never resurrects spontaneously, because the
/// delete bumps the server version and a stale push conflicts.
@Model
final class TranscriptCorrection {
    /// == TranscriptEntry.id (one correction per entry, structurally).
    @Attribute(.unique) var id: UUID
    var sessionID: UUID
    /// User-corrected Russian (empty = the correction to Russian was
    /// cleared; the model original then applies).
    var russianText: String
    /// User-corrected Chinese. nil = the user never touched the Chinese
    /// (the model translation applies); empty string = the user DELIBERATELY
    /// blanked it (an effective empty translation — still not silently
    /// discarded, and restorable).
    var chineseText: String?
    /// When the user last saved this correction (conflict tiebreaker:
    /// newer wins).
    var modifiedAt: Date
    /// True when the user asked for a re-translation of the corrected
    /// Russian and it has not landed yet (presentation hint, never auto).
    var needsRetranslation: Bool
    /// A remote correction lost the newer-modifiedAt race but differs
    /// substantially: the loser's text is preserved here verbatim so the
    /// user can adopt it deliberately. Nil once resolved.
    var conflictJSON: String?
    var createdAt: Date
    var updatedAt: Date
    /// Cloud-sync metadata (0 = never synced).
    var serverVersion: Int

    init(
        id: UUID,
        sessionID: UUID,
        russianText: String = "",
        chineseText: String? = nil,
        modifiedAt: Date = .now,
        needsRetranslation: Bool = false,
        conflictJSON: String? = nil,
        serverVersion: Int = 0
    ) {
        self.id = id
        self.sessionID = sessionID
        self.russianText = russianText
        self.chineseText = chineseText
        self.modifiedAt = modifiedAt
        self.needsRetranslation = needsRetranslation
        self.conflictJSON = conflictJSON
        self.createdAt = .now
        self.updatedAt = .now
        self.serverVersion = serverVersion
    }
}

// MARK: - Effective text (single source of truth)

/// The one place that decides which text a reader sees. Rules:
/// - a correction field that is non-empty (Russian) / non-nil (Chinese)
///   replaces the model's field;
/// - a blank Russian correction falls back to the model Russian (an
///   accidental blank never wipes a paragraph);
/// - a nil Chinese correction falls back to the model translation; a
///   deliberate empty-string correction shows as an empty translation;
/// - the model's own fields are always directly accessible for the
///   correction editor and the raw-JSON export.
///
/// Attach this to the entry via `entry.correction` — a transient,
/// repository-populated reference (SwiftData relationship avoided to keep
/// corrections deletable without touching the immutable entry row).
extension TranscriptEntry {
    /// Effective Russian: the user's correction when present, else the
    /// model's original. Never empty when the model text is non-empty.
    func effectiveRussianText(correction: TranscriptCorrection?) -> String {
        guard let correction else { return originalText }
        let trimmed = correction.russianText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? originalText : trimmed
    }

    /// Effective Chinese: nil when neither the correction nor the model
    /// translation exists; the correction (even a deliberate blank) when
    /// the user saved one; otherwise the model translation.
    func effectiveChineseText(correction: TranscriptCorrection?) -> String? {
        guard let correction else { return translatedText }
        guard correction.chineseText != nil else { return translatedText }
        return correction.chineseText
    }

    /// True when any user correction meaningfully differs from the model
    /// output (drives the 已修正 marker; a correction that matches the
    /// model exactly is not worth a badge).
    func isCorrected(correction: TranscriptCorrection?) -> Bool {
        guard let correction else { return false }
        let russianEdited = !correction.russianText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && correction.russianText.trimmingCharacters(in: .whitespacesAndNewlines) != originalText
        let chineseEdited = correction.chineseText != nil
            && correction.chineseText != translatedText
        return russianEdited || chineseEdited
    }
}
