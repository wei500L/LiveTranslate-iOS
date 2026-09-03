import SwiftUI
import Observation

/// Presentation model for classroom-recording playback: mirrors the
/// playback service state, maps playback time ↔ transcript entries,
/// notes, attachments and bookmarks, and owns the auto-follow behavior
/// (manual scroll suspends it until the user returns to the current
/// position).
@MainActor
@Observable
final class PlaybackViewModel {
    private var environment: AppEnvironment?
    private(set) var session: ClassroomSession?
    private(set) var recording: SessionRecording?

    var entries: [TranscriptEntry] = []
    var notes: [SessionNote] = []
    var attachments: [SessionAttachment] = []
    /// Entry id → its correction (effective-text lookups).
    private(set) var correctionsByEntryID: [UUID: TranscriptCorrection] = [:]

    private(set) var isLoaded = false
    /// True once the user scrolled away from the follow position; the
    /// “回到当前内容” affordance appears.
    var isFollowSuspended = false
    /// SequenceID the transcript list should scroll to (jump requests
    /// from notes/attachments/search landings).
    var pendingScrollTarget: Int?

    // MARK: - Effective text (single rule, shared with detail reading)

    func effectiveRussian(_ entry: TranscriptEntry) -> String {
        entry.effectiveRussianText(correction: correctionsByEntryID[entry.id])
    }

    func effectiveChinese(_ entry: TranscriptEntry) -> String? {
        entry.effectiveChineseText(correction: correctionsByEntryID[entry.id])
    }

    func isCorrected(_ entry: TranscriptEntry) -> Bool {
        entry.isCorrected(correction: correctionsByEntryID[entry.id])
    }

    // MARK: - Lifecycle

    func attach(_ environment: AppEnvironment) {
        self.environment = environment
    }

    func load(sessionID: UUID) {
        guard let environment else { return }
        let all = (try? environment.repository.sessions(matching: "")) ?? []
        guard let session = all.first(where: { $0.id == sessionID }) else {
            self.session = nil
            recording = nil
            entries = []
            notes = []
            attachments = []
            correctionsByEntryID = [:]
            isLoaded = true
            return
        }
        self.session = session
        recording = try? environment.repository.recording(sessionID: sessionID)
        entries = (try? environment.repository.entries(for: session)) ?? []
        notes = (try? environment.repository.notes(forSessionID: sessionID)) ?? []
        attachments = (try? environment.repository.attachments(forSessionID: sessionID)) ?? []
        let corrections = (try? environment.repository.corrections(forSessionID: sessionID)) ?? []
        correctionsByEntryID = Dictionary(
            corrections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        isLoaded = true
        // Restore auto-follow state on reload.
        isFollowSuspended = false
    }

    func reload() {
        if let id = session?.id { load(sessionID: id) }
    }

    // MARK: - Playback wiring

    var playback: ClassroomPlaybackService? {
        environment?.playback
    }

    var waveform: [Float] {
        guard let recording, let store = environment?.waveformStore else { return [] }
        return store.waveform(for: recording)
    }

    /// Loads the recording into the engine (if playable) and kicks off the
    /// waveform precompute. Returns false when no playable recording
    /// exists (the UI shows an honest reason instead).
    @discardableResult
    func loadRecording() -> Bool {
        guard let environment, let recording, !recording.isDeleted else { return false }
        guard SessionRecordings.recordingFileExists(sessionID: recording.sessionID) else {
            return false
        }
        environment.playback.load(recording: recording)
        environment.waveformStore.generateIfNeeded(
            for: recording, repository: environment.repository
        )
        return true
    }

    /// Jump from a transcript entry to its sound: 1.5 s of context before
    /// the utterance, clamped to ≥ 0. Returns false when nothing is
    /// loaded (the caller shows the honest hint).
    @discardableResult
    func playFrom(entry: TranscriptEntry) -> Bool {
        guard let playback, recording != nil, session != nil else { return false }
        // Legacy/inferred positions carry real offsets but no sample
        // provenance — still the best available anchor, the UI marks it.
        let target = max(0, entry.startOffset - 1.5)
        playback.seek(to: target)
        playback.play()
        isFollowSuspended = false
        pendingScrollTarget = entry.sequenceID
        return true
    }

    // MARK: - Recording-to-transcript mapping

    /// The entry the playback head is currently inside. Overlaps choose
    /// the entry that started most recently (the one being spoken); gaps
    /// keep the last entry (stable highlight — no flicker over silence).
    var currentEntry: TranscriptEntry? {
        guard let playback, recording != nil, !entries.isEmpty else { return nil }
        let time = playback.currentTime
        let ordered = entries.sorted { $0.sequenceID < $1.sequenceID }
        // Inside an entry window?
        if let inside = ordered.last(where: { $0.startOffset <= time && time < $0.endOffset }) {
            return inside
        }
        // Between entries: keep the last one that already started.
        return ordered.last(where: { $0.startOffset <= time })
    }

    /// Whether the transcript list should auto-scroll to `currentEntry`.
    /// Suspended once the user scrolls away — until they tap 回到当前内容.
    var shouldAutoFollow: Bool {
        !isFollowSuspended && currentEntry != nil
    }

    func resumeFollowing() {
        isFollowSuspended = false
        if let entry = currentEntry {
            pendingScrollTarget = entry.sequenceID
        }
    }

    // MARK: - Timeline markers (notes / attachments / bookmarks)

    /// One time-axis marker over the playback timeline.
    struct TimelineMarker: Identifiable, Equatable {
        enum Kind: Equatable {
            case note
            case attachment
            case bookmark
        }

        var id: String { "\(kindIndex)-\(offset)" }
        var kind: Kind
        var kindIndex: Int
        var offset: TimeInterval
        var entrySequenceID: Int?
    }

    /// Markers aggregated for the timeline strip: note/attachment offsets
    /// (anchor offset, else captured/created-relative), plus bookmarked
    /// entries. Markers within 2 s of each other collapse to the first
    /// (the list above disambiguates).
    var timelineMarkers: [TimelineMarker] {
        guard let session else { return [] }
        var markers: [TimelineMarker] = []
        let entriesByID = Dictionary(
            entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        for (index, note) in notes.enumerated() {
            let offset: TimeInterval
            if let recorded = note.timeOffset {
                offset = max(0, recorded)
            } else if let anchor = note.anchorEntryID, let entry = entriesByID[anchor] {
                offset = entry.startOffset
            } else {
                offset = max(0, note.createdAt.timeIntervalSince(session.startTime))
            }
            markers.append(TimelineMarker(
                kind: .note, kindIndex: index, offset: offset,
                entrySequenceID: note.anchorEntryID.flatMap { entriesByID[$0]?.sequenceID }
            ))
        }
        for (index, attachment) in attachments.enumerated() {
            let offset: TimeInterval
            if let anchor = attachment.anchorEntryID, let entry = entriesByID[anchor] {
                offset = entry.startOffset
            } else {
                offset = max(0, attachment.capturedAt.timeIntervalSince(session.startTime))
            }
            markers.append(TimelineMarker(
                kind: .attachment, kindIndex: index, offset: offset,
                entrySequenceID: attachment.anchorEntryID.flatMap { entriesByID[$0]?.sequenceID }
            ))
        }
        if let environment {
            for entry in entries where environment.bookmarks.isBookmarked(entryID: entry.id) {
                markers.append(TimelineMarker(
                    kind: .bookmark, kindIndex: entry.sequenceID, offset: entry.startOffset,
                    entrySequenceID: entry.sequenceID
                ))
            }
        }
        // Aggregate: sort by offset, collapse anything within 2 s of the
        // kept marker into it.
        let sorted = markers.sorted { $0.offset < $1.offset }
        var aggregated: [TimelineMarker] = []
        for marker in sorted {
            if let last = aggregated.last, marker.offset - last.offset < 2 { continue }
            aggregated.append(marker)
        }
        return aggregated
    }

    /// Notes/attachments to jump to when a marker is tapped.
    func noteAttachment(for marker: TimelineMarker) -> MarkerTarget? {
        switch marker.kind {
        case .note:
            guard notes.indices.contains(marker.kindIndex) else { return nil }
            return .note(notes[marker.kindIndex])
        case .attachment:
            guard attachments.indices.contains(marker.kindIndex) else { return nil }
            return .attachment(attachments[marker.kindIndex])
        case .bookmark:
            return nil
        }
    }

    enum MarkerTarget {
        case note(SessionNote)
        case attachment(SessionAttachment)
    }
}
