import Foundation
import SwiftData

/// SwiftData-backed implementation of `ClassroomRepositoryProtocol`.
///
/// All access is MainActor-isolated: SwiftData models are not Sendable, so
/// every read and write happens on the main actor, matching how the UI
/// consumes them.
enum RepositoryError: Error {
    /// The session a write targets does not exist locally.
    case sessionMissing
}

/// Raw-recording storage (written by the live coordinator while 保存原始
/// 录音 is on). Deleting a session removes its recording directory too —
/// the audio is session data and nothing else can reach it once the
/// session is gone. `SessionRecording` rows are the metadata layer views
/// read; this enum owns the files.
enum SessionRecordings {
    static var rootDirectory: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return support.appendingPathComponent("Sessions", isDirectory: true)
    }

    static func directory(for sessionID: UUID) -> URL {
        rootDirectory.appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    /// The recording's absolute URL, resolved from its metadata row (the
    /// file name/format travel with the row — no hardcoded raw.wav at the
    /// call sites). A future format change needs only this resolver.
    static func fileURL(for recording: SessionRecording) -> URL {
        directory(for: recording.sessionID)
            .appendingPathComponent(recording.fileName)
    }

    static func recordingFileExists(sessionID: UUID) -> Bool {
        let url = directory(for: sessionID).appendingPathComponent("raw.wav")
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    /// Bytes on disk of the legacy raw.wav (0 when absent).
    static func rawWAVFileSize(sessionID: UUID) -> Int64 {
        let url = directory(for: sessionID).appendingPathComponent("raw.wav")
        return ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0
    }

    /// Best-effort removal; missing directories are not an error.
    static func remove(for sessionID: UUID) {
        try? FileManager.default.removeItem(at: directory(for: sessionID))
    }

    /// Removes ONE recording's file (storage management keeps the row).
    static func removeFile(for recording: SessionRecording) {
        try? FileManager.default.removeItem(at: fileURL(for: recording))
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: rootDirectory)
    }
}

/// Reads the minimal WAV facts from raw bytes/size without loading the
/// file: for our own writer the layout is fixed (44-byte header, 16-bit
/// mono PCM), so duration follows from the byte count. Used for legacy
/// and interrupted files whose RIFF header was never patched.
enum WAVFileInspector {
    static let headerLength = 44
    /// 16 kHz × 1 channel × 2 bytes.
    static let bytesPerSecond = 32_000

    static func durationOfRawWAV(bytes: Int64) -> TimeInterval {
        guard bytes > headerLength else { return 0 }
        return Double(bytes - headerLength) / Double(bytesPerSecond)
    }
}

/// Thread-safe holder for the profile's AttachmentFileStore, so the
/// repository (main-actor) can reap files on deletes without a stored
/// reference in the protocol. Set by the composition root at profile
/// build; nil = no file store (demo/in-memory).
enum AttachmentFileStoreShared {
    nonisolated(unsafe) static var store: AttachmentFileStore?
}

@MainActor
final class TranscriptRepository: ClassroomRepositoryProtocol {
    private let container: ModelContainer
    /// SQLite file whose size `storageBytes()` reports.
    private let databaseURL: URL
    /// Cloud-sync hook: notified after every persisted mutation.
    var mutationObserver: (any TranscriptMutationObserving)?

    private var context: ModelContext { container.mainContext }

    init(container: ModelContainer, databaseURL: URL? = nil) {
        self.container = container
        if let databaseURL {
            self.databaseURL = databaseURL
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!
            self.databaseURL = support.appendingPathComponent("LiveTranslate.sqlite")
        }
    }

    // MARK: - Sessions

    func createSession(_ draft: SessionDraft) throws -> ClassroomSession {
        let session = ClassroomSession(
            title: draft.title,
            sourceLanguage: draft.sourceLanguage,
            targetLanguage: draft.targetLanguage,
            asrBackend: draft.backend.rawValue,
            modelVersion: draft.modelVersion,
            computePreference: draft.computePreference,
            translationModel: draft.translationModel,
            courseID: draft.courseID
        )
        context.insert(session)
        // Keep the course's quick-start ordering honest (most recently
        // used first on the home screen).
        if let courseID = draft.courseID,
           let course = try? course(id: courseID) {
            course.lastUsedAt = session.startTime
            course.updatedAt = .now
        }
        try context.save()
        mutationObserver?.sessionCreated(session)
        return session
    }

    func finishSession(_ session: ClassroomSession, abnormal: Bool) throws {
        session.endTime = .now
        // The coordinator writes a pause-aware duration (classroom time with
        // paused intervals excluded) before finishing; keep it. Only fall
        // back to wall-clock when the caller supplied no duration (a session
        // finished without going through the coordinator's stop path).
        if session.duration <= 0 {
            session.duration = session.endTime!.timeIntervalSince(session.startTime)
        }
        session.abnormalTermination = session.abnormalTermination || abnormal
        session.updatedAt = .now
        try context.save()
        mutationObserver?.sessionUpdated(session)
    }

    /// Renames a session through the repository so the change is saved
    /// deterministically (not via autosave) and the sync layer learns
    /// about it.
    func renameSession(_ session: ClassroomSession, to title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        session.title = trimmed
        session.updatedAt = .now
        try context.save()
        mutationObserver?.sessionUpdated(session)
    }

    // MARK: - Entries

    func addEntry(_ draft: EntryDraft, to session: ClassroomSession) throws -> TranscriptEntry {
        let entry = TranscriptEntry(
            sessionID: session.id,
            sequenceID: draft.sequenceID,
            startOffset: draft.startOffset,
            endOffset: draft.endOffset,
            originalText: draft.originalText,
            asrBackend: draft.asrBackend.rawValue,
            timeSource: draft.timeSource,
            asrLatency: draft.asrLatency,
            asrRTF: draft.asrRTF
        )
        // Assigning the relationship keeps both sides consistent; entries
        // are ordered by sequenceID at read time.
        entry.session = session
        context.insert(entry)
        session.entryCount += 1
        session.updatedAt = .now
        try context.save()
        mutationObserver?.entryCreated(entry)
        return entry
    }

    func updateTranslation(entryID: UUID, text: String, latency: TimeInterval?, status: TranslationStatus) throws {
        let descriptor = FetchDescriptor<TranscriptEntry>(predicate: #Predicate { $0.id == entryID })
        guard let entry = try context.fetch(descriptor).first else { return }
        entry.translatedText = text
        entry.translationLatency = latency
        entry.translationStatus = status.rawValue
        if let session = entry.session {
            session.updatedAt = .now
        }
        try context.save()
        mutationObserver?.entryUpdated(entry)
    }

    // MARK: - Queries

    func sessions(matching query: String) throws -> [ClassroomSession] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = try context.fetch(FetchDescriptor<ClassroomSession>(
            sortBy: [SortDescriptor(\.startTime, order: .reverse)]
        ))
        guard !trimmed.isEmpty else { return all }
        let needle = trimmed.lowercased()
        // Note text and study-review text participate in search: a session
        // matches when any of its notes or its review content contains the
        // query (the user's own words are often the fastest path back).
        let notes = try context.fetch(FetchDescriptor<SessionNote>())
        var hitSessionIDs = Set(
            notes.filter { $0.text.lowercased().contains(needle) }.map(\.sessionID)
        )
        let reviews = try context.fetch(FetchDescriptor<StudyReview>())
        for review in reviews where !review.contentJSON.isEmpty {
            if let content = StudyReviewContent.decode(review.contentJSON),
               content.searchableText.lowercased().contains(needle) {
                hitSessionIDs.insert(review.sessionID)
            }
        }
        // Attachment content participates: user titles/captions, local OCR
        // text and the persisted multimodal analysis (never a live model
        // call — search reads stored text only).
        let attachments = try context.fetch(FetchDescriptor<SessionAttachment>())
        for attachment in attachments {
            var text = attachment.title + "\n" + attachment.caption
            if !attachment.ocrText.isEmpty { text += "\n" + attachment.ocrText }
            if !attachment.analysisJSON.isEmpty,
               let analysis = AttachmentAnalysisResult.decode(attachment.analysisJSON) {
                text += "\n" + analysis.searchableText
            }
            if text.lowercased().contains(needle) {
                hitSessionIDs.insert(attachment.sessionID)
            }
        }
        // Corrections participate: the user's edited text is what they
        // search for. Build entryID → correction once.
        let corrections = try context.fetch(FetchDescriptor<TranscriptCorrection>())
        let correctionsByEntry = Dictionary(
            corrections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        return all.filter { session in
            if hitSessionIDs.contains(session.id) { return true }
            if session.title.lowercased().contains(needle) { return true }
            return session.entries.contains { entry in
                entry.effectiveRussianText(correction: correctionsByEntry[entry.id])
                    .lowercased().contains(needle)
                    || (entry.effectiveChineseText(correction: correctionsByEntry[entry.id]) ?? "")
                        .lowercased().contains(needle)
            }
        }
    }

    func entries(for session: ClassroomSession) throws -> [TranscriptEntry] {
        session.entries.sorted { $0.sequenceID < $1.sequenceID }
    }

    /// Failure states worth re-running: real failures plus entries whose
    /// translation was never attempted because the API wasn't configured
    /// yet (the class was recorded local-only and the user configured the
    /// API afterwards). Skipped is a user intent and stays excluded.
    func entriesNeedingRetry(for session: ClassroomSession) throws -> [TranscriptEntry] {
        try entries(for: session).filter { $0.status == .failed || $0.status == .notConfigured }
    }

    // MARK: - Deletion

    func deleteSession(_ session: ClassroomSession) throws {
        let sessionID = session.id
        // Notes are session-scoped with no SwiftData relationship — delete
        // them explicitly alongside the cascade-deleted entries, together
        // with the session's study review AND attachments (metadata rows
        // plus their files). Corrections follow their entries; the
        // recording row + file are session data too.
        let noteDescriptor = FetchDescriptor<SessionNote>(
            predicate: #Predicate { $0.sessionID == sessionID }
        )
        for note in try context.fetch(noteDescriptor) {
            context.delete(note)
        }
        if let review = try studyReview(forSessionID: sessionID) {
            context.delete(review)
        }
        let attachmentDescriptor = FetchDescriptor<SessionAttachment>(
            predicate: #Predicate { $0.sessionID == sessionID }
        )
        for attachment in try context.fetch(attachmentDescriptor) {
            context.delete(attachment)
        }
        let correctionDescriptor = FetchDescriptor<TranscriptCorrection>(
            predicate: #Predicate { $0.sessionID == sessionID }
        )
        for correction in try context.fetch(correctionDescriptor) {
            context.delete(correction)
        }
        if let recording = try recording(sessionID: sessionID) {
            context.delete(recording)
        }
        context.delete(session)
        try context.save()
        SessionRecordings.remove(for: sessionID)
        AttachmentFileStoreShared.store?.removeSessionFiles(for: sessionID)
        mutationObserver?.sessionDeleted(id: sessionID)
    }

    func deleteAllSessions() throws {
        let sessions = try context.fetch(FetchDescriptor<ClassroomSession>())
        let ids = sessions.map(\.id)
        try context.delete(model: ClassroomSession.self)
        try context.delete(model: SessionNote.self)
        try context.delete(model: StudyReview.self)
        try context.delete(model: SessionAttachment.self)
        try context.delete(model: TranscriptCorrection.self)
        try context.delete(model: SessionRecording.self)
        try context.save()
        SessionRecordings.removeAll()
        AttachmentFileStoreShared.store?.removeAll()
        for id in ids {
            mutationObserver?.sessionDeleted(id: id)
        }
    }

    // MARK: - Maintenance

    /// SQLite store size including WAL and SHM sidecars.
    func storageBytes() -> Int {
        let fm = FileManager.default
        let candidates = [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
        ]
        return candidates.reduce(0) { total, url in
            guard let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int else {
                return total
            }
            return total + size
        }
    }

    /// Flag every session that never got a clean end as abnormally
    /// terminated (the app was killed mid-classroom).
    func markAbnormalTerminations() throws {
        let descriptor = FetchDescriptor<ClassroomSession>(predicate: #Predicate { $0.endTime == nil })
        let unfinished = try context.fetch(descriptor)
        guard !unfinished.isEmpty else { return }
        for session in unfinished {
            session.abnormalTermination = true
            session.endTime = session.updatedAt
            session.duration = session.endTime!.timeIntervalSince(session.startTime)
        }
        try context.save()
        for session in unfinished {
            mutationObserver?.sessionUpdated(session)
        }
    }

    // MARK: - Cloud sync

    /// Writes an acknowledged serverVersion back into the local row.
    func recordServerVersion(entityType: SyncEntityType, entityID: UUID, version: Int) throws {
        switch entityType {
        case .session:
            let descriptor = FetchDescriptor<ClassroomSession>(
                predicate: #Predicate { $0.id == entityID }
            )
            guard let session = try context.fetch(descriptor).first else { return }
            session.serverVersion = max(session.serverVersion, version)
        case .entry:
            let descriptor = FetchDescriptor<TranscriptEntry>(
                predicate: #Predicate { $0.id == entityID }
            )
            guard let entry = try context.fetch(descriptor).first else { return }
            entry.serverVersion = max(entry.serverVersion, version)
        case .course:
            let descriptor = FetchDescriptor<Course>(
                predicate: #Predicate { $0.id == entityID }
            )
            guard let course = try context.fetch(descriptor).first else { return }
            course.serverVersion = max(course.serverVersion, version)
        case .note:
            let descriptor = FetchDescriptor<SessionNote>(
                predicate: #Predicate { $0.id == entityID }
            )
            guard let note = try context.fetch(descriptor).first else { return }
            note.serverVersion = max(note.serverVersion, version)
        case .studyReview:
            let descriptor = FetchDescriptor<StudyReview>(
                predicate: #Predicate { $0.id == entityID }
            )
            guard let review = try context.fetch(descriptor).first else { return }
            review.serverVersion = max(review.serverVersion, version)
        case .attachment:
            let descriptor = FetchDescriptor<SessionAttachment>(
                predicate: #Predicate { $0.id == entityID }
            )
            guard let attachment = try context.fetch(descriptor).first else { return }
            attachment.serverVersion = max(attachment.serverVersion, version)
        case .term:
            let descriptor = FetchDescriptor<GlossaryTerm>(
                predicate: #Predicate { $0.id == entityID }
            )
            guard let term = try context.fetch(descriptor).first else { return }
            term.serverVersion = max(term.serverVersion, version)
        case .studyCard:
            let descriptor = FetchDescriptor<StudyCard>(
                predicate: #Predicate { $0.id == entityID }
            )
            guard let card = try context.fetch(descriptor).first else { return }
            card.serverVersion = max(card.serverVersion, version)
        case .studyTask:
            let descriptor = FetchDescriptor<StudyTask>(
                predicate: #Predicate { $0.id == entityID }
            )
            guard let task = try context.fetch(descriptor).first else { return }
            task.serverVersion = max(task.serverVersion, version)
        case .transcriptCorrection:
            let descriptor = FetchDescriptor<TranscriptCorrection>(
                predicate: #Predicate { $0.id == entityID }
            )
            guard let correction = try context.fetch(descriptor).first else { return }
            correction.serverVersion = max(correction.serverVersion, version)
        case .bookmark, .favorite:
            break // tracked by BookmarkStore
        }
        try context.save()
    }

    /// Pull apply: upsert a session from a server record. Rows are only
    /// overwritten when the remote serverVersion is ahead.
    func applyRemoteSession(record: SyncServerRecordDTO, serverVersion: Int) throws {
        guard let recordID = record.id else { return }
        let descriptor = FetchDescriptor<ClassroomSession>(
            predicate: #Predicate { $0.id == recordID }
        )
        let existing = try context.fetch(descriptor).first
        if let existing, existing.serverVersion >= serverVersion { return }

        let session: ClassroomSession
        if let existing {
            session = existing
        } else {
            // A cloud-created row carries no local ASR metadata; the
            // backend fields are display-only and marked as imported.
            session = ClassroomSession(
                id: recordID,
                title: record.title ?? "",
                startTime: record.startedAt ?? .now,
                asrBackend: "cloud",
                courseID: record.courseId
            )
            context.insert(session)
        }
        if let title = record.title, !title.isEmpty { session.title = title }
        if let endedAt = record.endedAt { session.endTime = endedAt }
        if let duration = record.duration, duration > session.duration {
            session.duration = duration
        }
        if let status = record.sessionStatus, status != "active" {
            session.endTime = session.endTime ?? session.updatedAt
        }
        session.abnormalTermination = session.abnormalTermination || (record.abnormalTermination ?? false)
        // Course reference is full row state: a record without courseId
        // means the session is standalone server-side.
        session.courseID = record.courseId
        session.serverVersion = serverVersion
        try context.save()
    }

    /// Pull apply: upsert an entry from a server record.
    func applyRemoteEntry(record: SyncServerRecordDTO, serverVersion: Int) throws {
        guard let recordID = record.id, let sessionID = record.sessionId else { return }
        let descriptor = FetchDescriptor<TranscriptEntry>(
            predicate: #Predicate { $0.id == recordID }
        )
        let existing = try context.fetch(descriptor).first
        if let existing, existing.serverVersion >= serverVersion { return }

        let entry: TranscriptEntry
        if let existing {
            entry = existing
        } else {
            // The parent session must exist (or be created as a shell) so
            // the relationship stays intact. Cloud-imported rows carry no
            // local ASR metadata; "cloud" marks them as imported.
            let sessionDescriptor = FetchDescriptor<ClassroomSession>(
                predicate: #Predicate { $0.id == sessionID }
            )
            let session: ClassroomSession
            if let fetched = try context.fetch(sessionDescriptor).first {
                session = fetched
            } else {
                session = ClassroomSession(
                    id: sessionID, title: "", startTime: .now, asrBackend: "cloud"
                )
                context.insert(session)
            }
            entry = TranscriptEntry(
                id: recordID,
                sessionID: sessionID,
                sequenceID: record.sequenceId ?? 0,
                startOffset: record.startOffset ?? 0,
                endOffset: record.endOffset ?? 0,
                originalText: record.russianText ?? "",
                asrBackend: "cloud"
            )
            entry.session = session
            context.insert(entry)
            session.entryCount += 1
        }
        if let russian = record.russianText, !russian.isEmpty {
            entry.originalText = russian
        }
        if let chinese = record.chineseText {
            entry.translatedText = chinese.isEmpty ? nil : chinese
        }
        if let status = record.translationStatus {
            entry.translationStatus = status
        }
        if let sequence = record.sequenceId { entry.sequenceID = sequence }
        if let start = record.startOffset { entry.startOffset = start }
        if let end = record.endOffset { entry.endOffset = end }
        // Time provenance: rows applied from the server carry offsets of
        // unknown origin (another device's segmenter, a cloud import) —
        // legacy is the honest marker unless the record says otherwise.
        if let source = record.timeSource, let parsed = TranscriptTimeSource(rawValue: source) {
            entry.timeSource = parsed
        } else {
            entry.timeSource = .legacy
        }
        entry.serverVersion = serverVersion
        try context.save()
    }

    func deleteSessionByID(_ id: UUID) throws {
        let descriptor = FetchDescriptor<ClassroomSession>(
            predicate: #Predicate { $0.id == id }
        )
        guard let session = try context.fetch(descriptor).first else { return }
        let noteDescriptor = FetchDescriptor<SessionNote>(
            predicate: #Predicate { $0.sessionID == id }
        )
        for note in try context.fetch(noteDescriptor) {
            context.delete(note)
        }
        if let review = try studyReview(forSessionID: id) {
            context.delete(review)
        }
        let attachmentDescriptor = FetchDescriptor<SessionAttachment>(
            predicate: #Predicate { $0.sessionID == id }
        )
        for attachment in try context.fetch(attachmentDescriptor) {
            context.delete(attachment)
        }
        let correctionDescriptor = FetchDescriptor<TranscriptCorrection>(
            predicate: #Predicate { $0.sessionID == id }
        )
        for correction in try context.fetch(correctionDescriptor) {
            context.delete(correction)
        }
        if let recording = try recording(sessionID: id) {
            context.delete(recording)
        }
        try context.delete(session)
        try context.save()
        SessionRecordings.remove(for: id)
        AttachmentFileStoreShared.store?.removeSessionFiles(for: id)
    }

    func deleteEntryByID(_ id: UUID) throws {
        let descriptor = FetchDescriptor<TranscriptEntry>(
            predicate: #Predicate { $0.id == id }
        )
        guard let entry = try context.fetch(descriptor).first else { return }
        if let session = entry.session, session.entryCount > 0 {
            session.entryCount -= 1
        }
        // Notes AND attachments anchored to the removed entry keep their
        // content — the anchor is metadata and is simply dropped. The
        // correction overlay dies with its entry (nothing left to correct).
        let noteDescriptor = FetchDescriptor<SessionNote>(
            predicate: #Predicate { $0.anchorEntryID == id }
        )
        for note in try context.fetch(noteDescriptor) {
            note.anchorEntryID = nil
            note.updatedAt = .now
        }
        let attachmentDescriptor = FetchDescriptor<SessionAttachment>(
            predicate: #Predicate { $0.anchorEntryID == id }
        )
        for attachment in try context.fetch(attachmentDescriptor) {
            attachment.anchorEntryID = nil
            attachment.updatedAt = .now
        }
        let correctionDescriptor = FetchDescriptor<TranscriptCorrection>(
            predicate: #Predicate { $0.id == id }
        )
        for correction in try context.fetch(correctionDescriptor) {
            context.delete(correction)
        }
        try context.delete(entry)
        try context.save()
    }

    // MARK: - Guest-data migration support

    func sessionSummary(id: UUID) -> SessionSummary? {
        let descriptor = FetchDescriptor<ClassroomSession>(
            predicate: #Predicate { $0.id == id }
        )
        guard let session = try? context.fetch(descriptor).first else { return nil }
        return SessionSummary(
            id: session.id,
            title: session.title,
            startTime: session.startTime,
            entryCount: session.entryCount
        )
    }

    func entryExists(id: UUID) -> Bool {
        let descriptor = FetchDescriptor<TranscriptEntry>(
            predicate: #Predicate { $0.id == id }
        )
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }

    func courseID(sessionID: UUID) throws -> UUID? {
        let descriptor = FetchDescriptor<ClassroomSession>(
            predicate: #Predicate { $0.id == sessionID }
        )
        return try context.fetch(descriptor).first?.courseID
    }

    /// First-upload snapshot: every course, session, entry and note becomes
    /// an outbox upsert (favorites are enqueued by the sync service from
    /// BookmarkStore). Order matters: courses before sessions (so a
    /// session's course reference resolves), notes last (the server
    /// validates a note's parent session exists). Runs in batches on the
    /// main actor so the UI is never blocked for long; the outbox makes it
    /// resumable.
    func syncSnapshots(
        batchSize: Int, progress: ((Int, Int) -> Void)?
    ) -> [SyncOutboxItem] {
        var items: [SyncOutboxItem] = []
        let courses = (try? context.fetch(FetchDescriptor<Course>())) ?? []
        for course in courses {
            items.append(SyncOutboxItem(
                entityType: .course,
                entityID: course.id,
                operation: .upsert,
                baseServerVersion: course.serverVersion,
                payload: CloudSyncService.payload(for: course)
            ))
        }
        let sessions = (try? context.fetch(FetchDescriptor<ClassroomSession>())) ?? []
        for (index, session) in sessions.enumerated() {
            items.append(SyncOutboxItem(
                entityType: .session,
                entityID: session.id,
                operation: .upsert,
                baseServerVersion: session.serverVersion,
                payload: CloudSyncService.payload(for: session)
            ))
            let entries = (try? entries(for: session)) ?? []
            for entry in entries {
                var payload = CloudSyncService.payload(for: entry)
                payload.sessionId = entry.sessionID
                items.append(SyncOutboxItem(
                    entityType: .entry,
                    entityID: entry.id,
                    operation: .upsert,
                    baseServerVersion: entry.serverVersion,
                    payload: payload
                ))
            }
            // Corrections ride after their entries (the server validates
            // the parent entry exists, like notes after sessions).
            let corrections = (try? corrections(forSessionID: session.id)) ?? []
            for correction in corrections {
                var payload = CloudSyncService.payload(for: correction)
                payload.sessionId = correction.sessionID
                payload.entryId = correction.id
                items.append(SyncOutboxItem(
                    entityType: .transcriptCorrection,
                    entityID: correction.id,
                    operation: .upsert,
                    baseServerVersion: correction.serverVersion,
                    payload: payload
                ))
            }
            let notes = (try? notes(forSessionID: session.id)) ?? []
            for note in notes {
                var payload = CloudSyncService.payload(for: note)
                payload.sessionId = note.sessionID
                items.append(SyncOutboxItem(
                    entityType: .note,
                    entityID: note.id,
                    operation: .upsert,
                    baseServerVersion: note.serverVersion,
                    payload: payload
                ))
            }
            if let review = try? studyReview(forSessionID: session.id),
               !review.contentJSON.isEmpty {
                var payload = CloudSyncService.payload(for: review)
                payload.sessionId = review.sessionID
                items.append(SyncOutboxItem(
                    entityType: .studyReview,
                    entityID: review.id,
                    operation: .upsert,
                    baseServerVersion: review.serverVersion,
                    payload: payload
                ))
            }
            let attachments = (try? attachments(forSessionID: session.id)) ?? []
            for attachment in attachments {
                var payload = CloudSyncService.payload(for: attachment)
                payload.sessionId = attachment.sessionID
                items.append(SyncOutboxItem(
                    entityType: .attachment,
                    entityID: attachment.id,
                    operation: .upsert,
                    baseServerVersion: attachment.serverVersion,
                    payload: payload
                ))
            }
            if batchSize > 0, (index + 1) % batchSize == 0 {
                progress?(index + 1, sessions.count)
            }
        }
        // Learning entities are course-level (not session children), so
        // they snapshot after the session loop. pendingConfirm tasks are
        // device-local AI candidates — never uploaded.
        let terms = (try? context.fetch(FetchDescriptor<GlossaryTerm>())) ?? []
        for term in terms {
            items.append(SyncOutboxItem(
                entityType: .term,
                entityID: term.id,
                operation: .upsert,
                baseServerVersion: term.serverVersion,
                payload: CloudSyncService.payload(for: term)
            ))
        }
        let cards = (try? context.fetch(FetchDescriptor<StudyCard>())) ?? []
        for card in cards {
            items.append(SyncOutboxItem(
                entityType: .studyCard,
                entityID: card.id,
                operation: .upsert,
                baseServerVersion: card.serverVersion,
                payload: CloudSyncService.payload(for: card)
            ))
        }
        let tasks = (try? context.fetch(FetchDescriptor<StudyTask>())) ?? []
        for task in tasks where task.status != .pendingConfirm {
            items.append(SyncOutboxItem(
                entityType: .studyTask,
                entityID: task.id,
                operation: .upsert,
                baseServerVersion: task.serverVersion,
                payload: CloudSyncService.payload(for: task)
            ))
        }
        progress?(sessions.count, sessions.count)
        return items
    }

    // MARK: - Courses

    func createCourse(_ draft: CourseDraft) throws -> Course {
        let course = Course(
            name: draft.name,
            teacherName: draft.teacherName,
            location: draft.location,
            colorIndex: draft.colorIndex,
            isArchived: draft.isArchived
        )
        context.insert(course)
        try context.save()
        mutationObserver?.courseCreated(course)
        return course
    }

    func updateCourse(_ course: Course, with draft: CourseDraft) throws {
        course.name = draft.name
        course.teacherName = draft.teacherName
        course.location = draft.location
        course.colorIndex = draft.colorIndex
        course.isArchived = draft.isArchived
        course.updatedAt = .now
        try context.save()
        mutationObserver?.courseUpdated(course)
    }

    func courses() throws -> [Course] {
        let all = try context.fetch(FetchDescriptor<Course>())
        // Active courses first (most recently used), archived behind.
        return all.sorted { lhs, rhs in
            switch (lhs.isArchived, rhs.isArchived) {
            case (false, true): return true
            case (true, false): return false
            default:
                return (lhs.lastUsedAt ?? lhs.createdAt) > (rhs.lastUsedAt ?? rhs.createdAt)
            }
        }
    }

    func course(id: UUID) throws -> Course? {
        let descriptor = FetchDescriptor<Course>(predicate: #Predicate { $0.id == id })
        return try context.fetch(descriptor).first
    }

    func deleteCourse(_ course: Course) throws {
        let courseID = course.id
        // Sessions survive: they become standalone (courseID cleared). The
        // server performs the same nullification when it processes the
        // course delete; the cleared rows sync through the server-side
        // cascade, so no per-session outbox operations are needed here.
        let sessions = try context.fetch(FetchDescriptor<ClassroomSession>(
            predicate: #Predicate { $0.courseID == courseID }
        ))
        for session in sessions {
            session.courseID = nil
            session.updatedAt = .now
        }
        // Learning material survives too — terms/cards/tasks keep their
        // rows and schedule; only the course scoping reference is cleared
        // (the server-side detach does the same and logs the change).
        let terms = try context.fetch(FetchDescriptor<GlossaryTerm>(
            predicate: #Predicate { $0.courseID == courseID }
        ))
        for term in terms {
            term.courseID = nil
            term.updatedAt = .now
            mutationObserver?.termUpdated(term)
        }
        let cards = try context.fetch(FetchDescriptor<StudyCard>(
            predicate: #Predicate { $0.courseID == courseID }
        ))
        for card in cards {
            card.courseID = nil
            card.updatedAt = .now
            mutationObserver?.cardUpdated(card)
        }
        let tasks = try context.fetch(FetchDescriptor<StudyTask>(
            predicate: #Predicate { $0.courseID == courseID }
        ))
        for task in tasks {
            task.courseID = nil
            task.updatedAt = .now
            if task.status != .pendingConfirm {
                mutationObserver?.taskUpdated(task)
            }
        }
        context.delete(course)
        try context.save()
        mutationObserver?.courseDeleted(id: courseID)
    }

    func assignCourse(_ courseID: UUID?, to session: ClassroomSession) throws {
        guard session.courseID != courseID else { return }
        session.courseID = courseID
        session.updatedAt = .now
        if let courseID, let course = try? course(id: courseID) {
            course.lastUsedAt = max(course.lastUsedAt ?? .distantPast, session.startTime)
            course.updatedAt = .now
        }
        try context.save()
        mutationObserver?.sessionUpdated(session)
    }

    func applyRemoteCourse(record: SyncServerRecordDTO, serverVersion: Int) throws {
        guard let recordID = record.id else { return }
        let descriptor = FetchDescriptor<Course>(
            predicate: #Predicate { $0.id == recordID }
        )
        let existing = try context.fetch(descriptor).first
        if let existing, existing.serverVersion >= serverVersion { return }

        let course: Course
        if let existing {
            course = existing
        } else {
            course = Course(
                id: recordID,
                name: record.title ?? ""
            )
            context.insert(course)
        }
        if let name = record.title, !name.isEmpty { course.name = name }
        if let teacher = record.teacher { course.teacherName = teacher }
        if let location = record.location { course.location = location }
        if let colorIndex = record.colorIndex { course.colorIndex = colorIndex }
        if let isArchived = record.isArchived { course.isArchived = isArchived }
        course.serverVersion = serverVersion
        try context.save()
    }

    func deleteCourseByID(_ id: UUID) throws {
        // Mirror the server cascade: sessions of the deleted course become
        // standalone, learning material keeps its rows with the course
        // reference cleared. No mutation-observer notifications — this is
        // the remote-applied side of a delete.
        let sessions = try context.fetch(FetchDescriptor<ClassroomSession>(
            predicate: #Predicate { $0.courseID == id }
        ))
        for session in sessions {
            session.courseID = nil
        }
        let terms = try context.fetch(FetchDescriptor<GlossaryTerm>(
            predicate: #Predicate { $0.courseID == id }
        ))
        for term in terms { term.courseID = nil }
        let cards = try context.fetch(FetchDescriptor<StudyCard>(
            predicate: #Predicate { $0.courseID == id }
        ))
        for card in cards { card.courseID = nil }
        let tasks = try context.fetch(FetchDescriptor<StudyTask>(
            predicate: #Predicate { $0.courseID == id }
        ))
        for task in tasks { task.courseID = nil }
        let descriptor = FetchDescriptor<Course>(predicate: #Predicate { $0.id == id })
        guard let course = try context.fetch(descriptor).first else {
            try context.save()
            return
        }
        context.delete(course)
        try context.save()
    }

    // MARK: - Session notes

    func notes(forSessionID id: UUID) throws -> [SessionNote] {
        let descriptor = FetchDescriptor<SessionNote>(
            predicate: #Predicate { $0.sessionID == id },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return try context.fetch(descriptor)
    }

    func addNote(_ draft: NoteDraft, toSessionID id: UUID) throws -> SessionNote {
        // The session must exist — notes are session-scoped.
        let sessionDescriptor = FetchDescriptor<ClassroomSession>(
            predicate: #Predicate { $0.id == id }
        )
        guard try context.fetch(sessionDescriptor).first != nil else {
            throw RepositoryError.sessionMissing
        }
        let note = SessionNote(
            sessionID: id,
            anchorEntryID: draft.anchorEntryID,
            timeOffset: draft.timeOffset,
            text: draft.text
        )
        context.insert(note)
        try context.save()
        mutationObserver?.noteCreated(note)
        return note
    }

    func updateNote(_ note: SessionNote, text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, note.text != trimmed else { return }
        note.text = trimmed
        note.updatedAt = .now
        try context.save()
        mutationObserver?.noteUpdated(note)
    }

    func updateNoteAnchor(_ note: SessionNote, anchorEntryID: UUID?) throws {
        guard note.anchorEntryID != anchorEntryID else { return }
        note.anchorEntryID = anchorEntryID
        note.updatedAt = .now
        try context.save()
        mutationObserver?.noteUpdated(note)
    }

    func deleteNote(_ note: SessionNote) throws {
        let noteID = note.id
        context.delete(note)
        try context.save()
        mutationObserver?.noteDeleted(id: noteID)
    }

    func applyRemoteNote(record: SyncServerRecordDTO, serverVersion: Int) throws {
        guard let recordID = record.id, let sessionID = record.sessionId else { return }
        let descriptor = FetchDescriptor<SessionNote>(
            predicate: #Predicate { $0.id == recordID }
        )
        let existing = try context.fetch(descriptor).first
        if let existing, existing.serverVersion >= serverVersion { return }

        let note: SessionNote
        if let existing {
            note = existing
        } else {
            note = SessionNote(
                id: recordID,
                sessionID: sessionID,
                anchorEntryID: record.anchorEntryId,
                timeOffset: record.noteTimeOffset,
                text: record.noteText ?? ""
            )
            context.insert(note)
        }
        if let text = record.noteText, !text.isEmpty { note.text = text }
        // The note's classroom-relative position: adopted when the record
        // carries one (absent keeps the local value — an approximation
        // beats no position).
        if let offset = record.noteTimeOffset { note.timeOffset = offset }
        // Full row state: a record without an anchor means the note is
        // unanchored server-side.
        note.anchorEntryID = record.anchorEntryId
        note.serverVersion = serverVersion
        try context.save()
    }

    func deleteNoteByID(_ id: UUID) throws {
        let descriptor = FetchDescriptor<SessionNote>(
            predicate: #Predicate { $0.id == id }
        )
        guard let note = try context.fetch(descriptor).first else { return }
        context.delete(note)
        try context.save()
    }

    // MARK: - Study reviews

    func studyReview(forSessionID id: UUID) throws -> StudyReview? {
        let descriptor = FetchDescriptor<StudyReview>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first
    }

    func allStudyReviews() throws -> [StudyReview] {
        try context.fetch(FetchDescriptor<StudyReview>())
    }

    func ensureStudyReview(forSessionID id: UUID) throws -> StudyReview {
        if let existing = try studyReview(forSessionID: id) {
            return existing
        }
        let review = StudyReview(id: id, sessionID: id)
        context.insert(review)
        try context.save()
        return review
    }

    func beginStudyReviewGeneration(_ review: StudyReview, chunkState: StudyChunkState) throws {
        review.status = StudyReviewStatus.generating.rawValue
        review.chunkStateJSON = chunkState.encodedString() ?? ""
        review.updatedAt = .now
        try context.save()
    }

    func updateStudyReviewProgress(
        _ review: StudyReview, chunkStateJSON: String, terminal: StudyReviewStatus?
    ) throws {
        review.chunkStateJSON = chunkStateJSON
        if let terminal {
            review.status = terminal.rawValue
        }
        review.updatedAt = .now
        try context.save()
    }

    func completeStudyReviewGeneration(
        _ review: StudyReview, content: StudyReviewContent,
        model: String, sourceUpdatedAt: Date
    ) throws {
        guard let json = content.encodedString() else { return }
        review.contentJSON = json
        review.generatedJSON = json
        review.hasUserEdits = false
        review.reviewModel = model
        review.generatedAt = .now
        review.sourceUpdatedAt = sourceUpdatedAt
        review.status = StudyReviewStatus.completed.rawValue
        review.updatedAt = .now
        try context.save()
        mutationObserver?.studyReviewUpdated(review)
    }

    func failStudyReviewGeneration(_ review: StudyReview) throws {
        review.status = StudyReviewStatus.failed.rawValue
        review.updatedAt = .now
        try context.save()
        // A failed run with no content stays device-local (nothing to
        // sync); a failed regeneration over an existing result keeps the
        // old content in sync — other devices should see the same state.
        if !review.contentJSON.isEmpty {
            mutationObserver?.studyReviewUpdated(review)
        }
    }

    func markStudyReviewInterrupted(_ review: StudyReview) throws {
        guard review.status == StudyReviewStatus.generating.rawValue else { return }
        let hasProgress = StudyChunkState.decode(review.chunkStateJSON)?.hasAnyProgress ?? false
        review.status = (hasProgress
            ? StudyReviewStatus.partial
            : StudyReviewStatus.failed).rawValue
        review.updatedAt = .now
        try context.save()
    }

    func applyStudyReviewUserEdits(_ review: StudyReview, content: StudyReviewContent) throws {
        guard let json = content.encodedString() else { return }
        review.contentJSON = json
        review.hasUserEdits = json != review.generatedJSON
        review.updatedAt = .now
        try context.save()
        mutationObserver?.studyReviewUpdated(review)
    }

    func deleteStudyReview(_ review: StudyReview) throws {
        let reviewID = review.id
        context.delete(review)
        try context.save()
        mutationObserver?.studyReviewDeleted(id: reviewID)
    }

    func applyRemoteStudyReview(record: SyncServerRecordDTO, serverVersion: Int) throws {
        guard let recordID = record.id else { return }
        let descriptor = FetchDescriptor<StudyReview>(
            predicate: #Predicate { $0.id == recordID }
        )
        let existing = try context.fetch(descriptor).first
        if let existing, existing.serverVersion >= serverVersion { return }

        // Local user edits win over any remote change: keep the local
        // content but adopt the remote version so the next push rebases
        // onto it (the user's edits then propagate and win server-side).
        let remoteContent = record.reviewContent ?? ""
        if let existing {
            if existing.hasUserEdits && !remoteContent.isEmpty && remoteContent != existing.contentJSON {
                existing.serverVersion = serverVersion
                try context.save()
                return
            }
            if let status = record.reviewStatus { existing.status = status }
            if !remoteContent.isEmpty {
                existing.contentJSON = remoteContent
                let remoteGenerated = record.reviewGeneratedContent ?? ""
                existing.hasUserEdits = !remoteGenerated.isEmpty && remoteContent != remoteGenerated
            }
            if let generated = record.reviewGeneratedContent, !generated.isEmpty {
                existing.generatedJSON = generated
            }
            if let model = record.reviewModel, !model.isEmpty {
                existing.reviewModel = model
            }
            if let generatedAt = record.reviewGeneratedAt {
                existing.generatedAt = generatedAt
            }
            if let sourceAt = record.reviewSourceUpdatedAt {
                existing.sourceUpdatedAt = sourceAt
            }
            existing.serverVersion = serverVersion
            try context.save()
            return
        }

        let review = StudyReview(
            id: recordID,
            sessionID: recordID,
            status: StudyReviewStatus(rawValue: record.reviewStatus ?? "") ?? .completed,
            contentJSON: remoteContent,
            generatedJSON: record.reviewGeneratedContent ?? "",
            hasUserEdits: false,
            chunkStateJSON: "",
            reviewModel: record.reviewModel ?? "",
            generatedAt: record.reviewGeneratedAt,
            sourceUpdatedAt: record.reviewSourceUpdatedAt,
            serverVersion: serverVersion
        )
        context.insert(review)
        try context.save()
    }

    func deleteStudyReviewByID(_ id: UUID) throws {
        let descriptor = FetchDescriptor<StudyReview>(
            predicate: #Predicate { $0.id == id }
        )
        guard let review = try context.fetch(descriptor).first else { return }
        context.delete(review)
        try context.save()
    }

    // MARK: - Session attachments

    func attachments(forSessionID id: UUID) throws -> [SessionAttachment] {
        let descriptor = FetchDescriptor<SessionAttachment>(
            predicate: #Predicate { $0.sessionID == id },
            sortBy: [SortDescriptor(\.capturedAt), SortDescriptor(\.sortIndex)]
        )
        return try context.fetch(descriptor)
    }

    func attachment(id: UUID) throws -> SessionAttachment? {
        let descriptor = FetchDescriptor<SessionAttachment>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first
    }

    func allAttachments() throws -> [SessionAttachment] {
        try context.fetch(FetchDescriptor<SessionAttachment>())
    }

    func attachmentExists(sessionID: UUID, contentHash: String) throws -> Bool {
        guard !contentHash.isEmpty else { return false }
        let descriptor = FetchDescriptor<SessionAttachment>(
            predicate: #Predicate { $0.sessionID == sessionID && $0.contentHash == contentHash }
        )
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }

    func addAttachment(_ draft: AttachmentDraft, toSessionID id: UUID) throws -> SessionAttachment {
        // The session must exist — attachments are session-scoped (the
        // importer guarantees the files are already on disk).
        let sessionDescriptor = FetchDescriptor<ClassroomSession>(
            predicate: #Predicate { $0.id == id }
        )
        guard let session = try context.fetch(sessionDescriptor).first else {
            throw RepositoryError.sessionMissing
        }
        let attachment = SessionAttachment(
            sessionID: id,
            courseID: draft.courseID,
            anchorEntryID: draft.anchorEntryID,
            capturedAt: draft.capturedAt,
            title: draft.title,
            caption: draft.caption,
            kind: draft.kind,
            mimeType: draft.mimeType,
            pixelWidth: draft.pixelWidth,
            pixelHeight: draft.pixelHeight,
            fileSize: draft.fileSize,
            contentHash: draft.contentHash,
            sortIndex: draft.sortIndex
        )
        context.insert(attachment)
        session.updatedAt = .now
        try context.save()
        mutationObserver?.attachmentCreated(attachment)
        return attachment
    }

    func updateAttachmentTitle(_ attachment: SessionAttachment, title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard attachment.title != trimmed else { return }
        attachment.title = trimmed
        attachment.updatedAt = .now
        try context.save()
        mutationObserver?.attachmentUpdated(attachment)
    }

    func updateAttachmentCaption(_ attachment: SessionAttachment, caption: String) throws {
        guard attachment.caption != caption else { return }
        attachment.caption = caption
        attachment.updatedAt = .now
        try context.save()
        mutationObserver?.attachmentUpdated(attachment)
    }

    func updateAttachmentKind(_ attachment: SessionAttachment, kind: AttachmentKind) throws {
        guard attachment.kind != kind else { return }
        attachment.kind = kind
        attachment.updatedAt = .now
        try context.save()
        mutationObserver?.attachmentUpdated(attachment)
    }

    func updateAttachmentAnchor(_ attachment: SessionAttachment, anchorEntryID: UUID?) throws {
        guard attachment.anchorEntryID != anchorEntryID else { return }
        attachment.anchorEntryID = anchorEntryID
        attachment.updatedAt = .now
        try context.save()
        mutationObserver?.attachmentUpdated(attachment)
    }

    func updateAttachmentSortIndex(_ attachment: SessionAttachment, sortIndex: Int) throws {
        guard attachment.sortIndex != sortIndex else { return }
        attachment.sortIndex = sortIndex
        attachment.updatedAt = .now
        try context.save()
        mutationObserver?.attachmentUpdated(attachment)
    }

    func updateAttachmentTransform(_ attachment: SessionAttachment, transform: AttachmentTransform) throws {
        let json = transform.encodedJSON() ?? ""
        guard attachment.transformJSON != json else { return }
        attachment.transformJSON = json
        attachment.updatedAt = .now
        try context.save()
        mutationObserver?.attachmentUpdated(attachment)
    }

    func updateAttachmentOCRText(_ attachment: SessionAttachment, text: String) throws {
        guard attachment.ocrText != text else { return }
        attachment.ocrText = text
        attachment.updatedAt = .now
        try context.save()
        mutationObserver?.attachmentUpdated(attachment)
    }

    func completeAttachmentAnalysis(
        _ attachment: SessionAttachment, result: AttachmentAnalysisResult, status: AttachmentAnalysisStatus
    ) throws {
        guard let json = result.encodedJSON() else { return }
        attachment.analysisJSON = json
        attachment.analysisStatus = status
        attachment.updatedAt = .now
        // A new analysis result is new study material — an existing review
        // must show 课堂资料已更新. Bumping the session's updatedAt drives
        // the existing staleness check (no extra sync churn: the session
        // row is not re-notified).
        if let session = try? context.fetch(FetchDescriptor<ClassroomSession>(
            predicate: #Predicate { $0.id == attachment.sessionID }
        )).first {
            session.updatedAt = .now
        }
        try context.save()
        mutationObserver?.attachmentUpdated(attachment)
    }

    func updateAttachmentAnalysisProgress(
        _ attachment: SessionAttachment, status: AttachmentAnalysisStatus
    ) throws {
        guard attachment.analysisStatus != status else { return }
        attachment.analysisStatus = status
        attachment.updatedAt = .now
        try context.save()
    }

    func failAttachmentAnalysis(_ attachment: SessionAttachment) throws {
        attachment.analysisStatus = .failed
        attachment.updatedAt = .now
        try context.save()
        // A failed first run (no result) stays device-local; a failed
        // RE-analysis over an existing result keeps the old result in sync
        // so other devices see the same state.
        if !attachment.analysisJSON.isEmpty {
            mutationObserver?.attachmentUpdated(attachment)
        }
    }

    func deleteAttachment(_ attachment: SessionAttachment) throws {
        let attachmentID = attachment.id
        let sessionID = attachment.sessionID
        context.delete(attachment)
        // Removal is a study-material change too (review staleness).
        if let session = try? context.fetch(FetchDescriptor<ClassroomSession>(
            predicate: #Predicate { $0.id == sessionID }
        )).first {
            session.updatedAt = .now
        }
        try context.save()
        AttachmentFileStoreShared.store?.removeFiles(for: attachmentID, sessionID: sessionID)
        mutationObserver?.attachmentDeleted(id: attachmentID)
    }

    func applyRemoteAttachment(record: SyncServerRecordDTO, serverVersion: Int) throws {
        guard let recordID = record.id, let sessionID = record.sessionId else { return }
        let descriptor = FetchDescriptor<SessionAttachment>(
            predicate: #Predicate { $0.id == recordID }
        )
        let existing = try context.fetch(descriptor).first
        if let existing, existing.serverVersion >= serverVersion { return }

        let analysisJSON = record.attachmentAnalysis ?? ""
        let attachment: SessionAttachment
        if let existing {
            attachment = existing
            if let title = record.title, !title.isEmpty { attachment.title = title }
            attachment.caption = record.attachmentCaption ?? attachment.caption
            if let kindRaw = record.attachmentKind, let kind = AttachmentKind(rawValue: kindRaw) {
                attachment.kind = kind
            }
            if let mime = record.attachmentMime, !mime.isEmpty { attachment.mimeType = mime }
            if let width = record.attachmentWidth { attachment.pixelWidth = width }
            if let height = record.attachmentHeight { attachment.pixelHeight = height }
            // Hash/size are identity — immutable after creation.
            if let sortIndex = record.attachmentSortIndex { attachment.sortIndex = sortIndex }
            if let capturedAt = record.attachmentCapturedAt { attachment.capturedAt = capturedAt }
            attachment.transformJSON = record.attachmentTransform ?? attachment.transformJSON
            // Full row state: a record without an anchor means unanchored.
            attachment.anchorEntryID = record.anchorEntryId
            attachment.courseID = record.courseId
            if let ocr = record.attachmentOcrText, !ocr.isEmpty { attachment.ocrText = ocr }
            if let statusRaw = record.attachmentAnalysisStatus,
               let status = AttachmentAnalysisStatus(rawValue: statusRaw),
               status != .analyzing {
                attachment.analysisStatus = status
            }
            if !analysisJSON.isEmpty { attachment.analysisJSON = analysisJSON }
            attachment.serverVersion = serverVersion
        } else {
            attachment = SessionAttachment(
                id: recordID,
                sessionID: sessionID,
                courseID: record.courseId,
                anchorEntryID: record.anchorEntryId,
                capturedAt: record.attachmentCapturedAt ?? .now,
                title: record.title ?? "",
                caption: record.attachmentCaption ?? "",
                kind: AttachmentKind(rawValue: record.attachmentKind ?? "") ?? .other,
                mimeType: record.attachmentMime ?? "",
                pixelWidth: record.attachmentWidth ?? 0,
                pixelHeight: record.attachmentHeight ?? 0,
                fileSize: record.attachmentFileSize ?? 0,
                contentHash: record.attachmentHash ?? "",
                sortIndex: record.attachmentSortIndex ?? 0,
                analysisStatus: AttachmentAnalysisStatus(
                    rawValue: record.attachmentAnalysisStatus ?? ""
                ) ?? .pending,
                analysisJSON: analysisJSON,
                ocrText: record.attachmentOcrText ?? "",
                serverVersion: serverVersion
            )
            attachment.transformJSON = record.attachmentTransform ?? ""
            context.insert(attachment)
        }
        try context.save()
    }

    func deleteAttachmentByID(_ id: UUID) throws {
        let descriptor = FetchDescriptor<SessionAttachment>(
            predicate: #Predicate { $0.id == id }
        )
        guard let attachment = try context.fetch(descriptor).first else { return }
        let sessionID = attachment.sessionID
        context.delete(attachment)
        try context.save()
        AttachmentFileStoreShared.store?.removeFiles(for: id, sessionID: sessionID)
    }

    // MARK: - Learning entities (review center)

    // MARK: Terms

    func terms(courseID: UUID?) throws -> [GlossaryTerm] {
        let all = try context.fetch(FetchDescriptor<GlossaryTerm>())
        let scoped: [GlossaryTerm]
        if let courseID {
            scoped = all.filter { $0.courseID == courseID }
        } else {
            scoped = all
        }
        return scoped.sorted { $0.createdAt > $1.createdAt }
    }

    func terms(matching query: String) throws -> [GlossaryTerm] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let lowered = trimmed.lowercased()
        let all = try context.fetch(FetchDescriptor<GlossaryTerm>())
        return all.filter { term in
            term.russian.lowercased().contains(lowered)
                || term.chinese.lowercased().contains(lowered)
                || term.explanation.lowercased().contains(lowered)
                || term.userNote.lowercased().contains(lowered)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func findTerm(courseID: UUID?, russian: String) throws -> GlossaryTerm? {
        let normalized = russian
            .lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let all = try context.fetch(FetchDescriptor<GlossaryTerm>())
        return all.first { term in
            term.courseID == courseID && term.normalizedRussian == normalized
        }
    }

    func addTerm(_ draft: TermDraft) throws -> GlossaryTerm {
        let term = GlossaryTerm(
            russian: draft.russian,
            chinese: draft.chinese,
            explanation: draft.explanation,
            partOfSpeech: draft.partOfSpeech,
            userNote: draft.userNote,
            courseID: draft.courseID,
            sessionID: draft.sessionID,
            sourceEntryID: draft.sourceEntryID,
            sourceAttachmentID: draft.sourceAttachmentID,
            sourceReviewID: draft.sourceReviewID,
            sourceSessionIDs: draft.sessionID.map { [$0] } ?? [],
            isFavorite: draft.isFavorite,
            status: draft.status
        )
        context.insert(term)
        try context.save()
        mutationObserver?.termCreated(term)
        return term
    }

    func updateTerm(_ term: GlossaryTerm, with draft: TermDraft) throws {
        term.russian = draft.russian
        term.chinese = draft.chinese
        term.explanation = draft.explanation
        term.partOfSpeech = draft.partOfSpeech
        term.userNote = draft.userNote
        term.isFavorite = draft.isFavorite
        term.status = draft.status
        term.courseID = draft.courseID
        term.updatedAt = .now
        try context.save()
        mutationObserver?.termUpdated(term)
    }

    func mergeTermSources(
        _ term: GlossaryTerm, sessionID: UUID?,
        entryID: UUID?, attachmentID: UUID?
    ) throws {
        var sessions = term.sourceSessionIDs
        if let sessionID, !sessions.contains(sessionID) {
            sessions.append(sessionID)
        }
        term.sourceSessionIDsJSON = Self.encodeSourceSessions(sessions)
        if term.sessionID == nil { term.sessionID = sessionID }
        if term.sourceEntryID == nil { term.sourceEntryID = entryID }
        if term.sourceAttachmentID == nil { term.sourceAttachmentID = attachmentID }
        term.updatedAt = .now
        try context.save()
        mutationObserver?.termUpdated(term)
    }

    func updateTermFavorite(_ term: GlossaryTerm, isFavorite: Bool) throws {
        guard term.isFavorite != isFavorite else { return }
        term.isFavorite = isFavorite
        term.updatedAt = .now
        try context.save()
        mutationObserver?.termUpdated(term)
    }

    func updateTermStatus(_ term: GlossaryTerm, status: GlossaryTermStatus) throws {
        guard term.status != status else { return }
        term.status = status
        term.updatedAt = .now
        try context.save()
        mutationObserver?.termUpdated(term)
    }

    func deleteTerm(_ term: GlossaryTerm) throws {
        let termID = term.id
        context.delete(term)
        try context.save()
        mutationObserver?.termDeleted(id: termID)
    }

    func applyRemoteTerm(record: SyncServerRecordDTO, serverVersion: Int) throws {
        guard let recordID = record.id,
              let russian = record.termRussian, !russian.isEmpty else { return }
        let descriptor = FetchDescriptor<GlossaryTerm>(
            predicate: #Predicate { $0.id == recordID }
        )
        let existing = try context.fetch(descriptor).first
        if let existing, existing.serverVersion >= serverVersion { return }

        let term: GlossaryTerm
        if let existing {
            term = existing
            term.russian = russian
            if let chinese = record.termChinese { term.chinese = chinese }
            if let explanation = record.termExplanation { term.explanation = explanation }
            if let partOfSpeech = record.termPartOfSpeech { term.partOfSpeech = partOfSpeech }
            if let userNote = record.termUserNote { term.userNote = userNote }
            if let favorite = record.termFavorite { term.isFavorite = favorite }
            if let statusRaw = record.termStatus,
               let status = GlossaryTermStatus(rawValue: statusRaw) {
                term.status = status
            }
            // Full row state: absent references mean "no source" server-side.
            term.courseID = record.courseId
            term.sessionID = record.sessionId
            term.sourceEntryID = record.entryId
            term.sourceAttachmentID = record.sourceAttachmentId
            term.sourceReviewID = record.sourceReviewId
            term.sourceSessionIDsJSON = record.termSourceSessions ?? "[]"
        } else {
            term = GlossaryTerm(
                id: recordID,
                russian: russian,
                chinese: record.termChinese ?? "",
                explanation: record.termExplanation ?? "",
                partOfSpeech: record.termPartOfSpeech ?? "",
                userNote: record.termUserNote ?? "",
                courseID: record.courseId,
                sessionID: record.sessionId,
                sourceEntryID: record.entryId,
                sourceAttachmentID: record.sourceAttachmentId,
                sourceReviewID: record.sourceReviewId,
                sourceSessionIDs: Self.decodeSourceSessions(record.termSourceSessions),
                isFavorite: record.termFavorite ?? false,
                status: GlossaryTermStatus(rawValue: record.termStatus ?? "") ?? .new,
                serverVersion: serverVersion
            )
            context.insert(term)
        }
        term.serverVersion = serverVersion
        try context.save()
    }

    func deleteTermByID(_ id: UUID) throws {
        let descriptor = FetchDescriptor<GlossaryTerm>(
            predicate: #Predicate { $0.id == id }
        )
        guard let term = try context.fetch(descriptor).first else { return }
        context.delete(term)
        try context.save()
    }

    private static func encodeSourceSessions(_ ids: [UUID]) -> String {
        guard let data = try? JSONEncoder().encode(ids),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    private static func decodeSourceSessions(_ json: String?) -> [UUID] {
        guard let json, let data = json.data(using: .utf8),
              let ids = try? JSONDecoder().decode([UUID].self, from: data) else { return [] }
        return ids
    }

    // MARK: Study cards

    func cards(courseID: UUID?) throws -> [StudyCard] {
        let all = try context.fetch(FetchDescriptor<StudyCard>())
        let scoped: [StudyCard]
        if let courseID {
            scoped = all.filter { $0.courseID == courseID }
        } else {
            scoped = all
        }
        return scoped.sorted { $0.createdAt > $1.createdAt }
    }

    func dueCards(before date: Date, limit: Int) throws -> [StudyCard] {
        let all = try context.fetch(FetchDescriptor<StudyCard>())
        return all
            .filter { card in
                card.stage != .new && card.dueAt != nil && card.dueAt! <= date
            }
            .sorted { ($0.dueAt ?? .distantPast) < ($1.dueAt ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }

    func cards(matching query: String) throws -> [StudyCard] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let lowered = trimmed.lowercased()
        let all = try context.fetch(FetchDescriptor<StudyCard>())
        return all.filter { card in
            card.front.lowercased().contains(lowered)
                || card.back.lowercased().contains(lowered)
                || card.userNote.lowercased().contains(lowered)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func cards(forTermID id: UUID) throws -> [StudyCard] {
        let all = try context.fetch(FetchDescriptor<StudyCard>())
        return all
            .filter { $0.sourceTermID == id }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func addCard(_ draft: CardDraft) throws -> StudyCard {
        let card = StudyCard(
            front: draft.front,
            back: draft.back,
            type: draft.type,
            origin: draft.origin,
            userNote: draft.userNote,
            courseID: draft.courseID,
            sessionID: draft.sessionID,
            sourceEntryID: draft.sourceEntryID,
            sourceAttachmentID: draft.sourceAttachmentID,
            sourceTermID: draft.sourceTermID
        )
        context.insert(card)
        try context.save()
        mutationObserver?.cardCreated(card)
        return card
    }

    func updateCard(_ card: StudyCard, with draft: CardDraft) throws {
        card.front = draft.front
        card.back = draft.back
        card.type = draft.type
        card.userNote = draft.userNote
        card.courseID = draft.courseID
        card.origin = draft.origin
        card.updatedAt = .now
        try context.save()
        mutationObserver?.cardUpdated(card)
    }

    func reviewCard(_ card: StudyCard, grade: StudyCardGrade, at date: Date) throws {
        StudyCardScheduler.apply(grade, to: card, at: date)
        try context.save()
        mutationObserver?.cardUpdated(card)
    }

    func restoreCardSchedule(_ card: StudyCard) throws {
        card.updatedAt = .now
        try context.save()
        mutationObserver?.cardUpdated(card)
    }

    func resetCardSchedule(_ card: StudyCard) throws {
        card.stage = .new
        card.reviewCount = 0
        card.intervalHours = 0
        card.dueAt = nil
        card.lastReviewedAt = nil
        card.lastGrade = nil
        card.updatedAt = .now
        try context.save()
        mutationObserver?.cardUpdated(card)
    }

    func enrollCard(_ card: StudyCard) throws {
        StudyCardScheduler.enroll(card)
        try context.save()
        mutationObserver?.cardUpdated(card)
    }

    func deleteCard(_ card: StudyCard) throws {
        let cardID = card.id
        context.delete(card)
        try context.save()
        mutationObserver?.cardDeleted(id: cardID)
    }

    func applyRemoteStudyCard(record: SyncServerRecordDTO, serverVersion: Int) throws {
        guard let recordID = record.id,
              let front = record.cardFront, !front.isEmpty else { return }
        let descriptor = FetchDescriptor<StudyCard>(
            predicate: #Predicate { $0.id == recordID }
        )
        let existing = try context.fetch(descriptor).first
        if let existing, existing.serverVersion >= serverVersion { return }

        let card: StudyCard
        if let existing {
            card = existing
            card.front = front
            if let back = record.cardBack { card.back = back }
            if let typeRaw = record.cardType, let type = StudyCardType(rawValue: typeRaw) {
                card.type = type
            }
            if let note = record.cardUserNote { card.userNote = note }
            if let originRaw = record.cardOrigin, let origin = StudyCardOrigin(rawValue: originRaw) {
                card.origin = origin
            }
            card.courseID = record.courseId
            card.sessionID = record.sessionId
            card.sourceEntryID = record.entryId
            card.sourceAttachmentID = record.sourceAttachmentId
            card.sourceTermID = record.sourceTermId
            // Review state: the newer lastReviewedAt wins (multi-device
            // review merge — mirrors the server-side rule).
            let remoteReviewed = record.cardLastReviewedAt ?? .distantPast
            let localReviewed = card.lastReviewedAt ?? .distantPast
            if remoteReviewed >= localReviewed {
                if let stageRaw = record.cardStage, let stage = StudyCardStage(rawValue: stageRaw) {
                    card.stage = stage
                }
                if let count = record.cardReviewCount { card.reviewCount = count }
                if let interval = record.cardIntervalHours { card.intervalHours = interval }
                card.dueAt = record.cardDueAt
                card.lastReviewedAt = record.cardLastReviewedAt
                if let gradeRaw = record.cardLastGrade {
                    card.lastGrade = StudyCardGrade(rawValue: gradeRaw)
                }
            }
        } else {
            card = StudyCard(
                id: recordID,
                front: front,
                back: record.cardBack ?? "",
                type: StudyCardType(rawValue: record.cardType ?? "") ?? .qa,
                origin: StudyCardOrigin(rawValue: record.cardOrigin ?? "") ?? .manual,
                userNote: record.cardUserNote ?? "",
                courseID: record.courseId,
                sessionID: record.sessionId,
                sourceEntryID: record.entryId,
                sourceAttachmentID: record.sourceAttachmentId,
                sourceTermID: record.sourceTermId,
                stage: StudyCardStage(rawValue: record.cardStage ?? "") ?? .new,
                reviewCount: record.cardReviewCount ?? 0,
                intervalHours: record.cardIntervalHours ?? 0,
                dueAt: record.cardDueAt,
                lastReviewedAt: record.cardLastReviewedAt,
                lastGrade: StudyCardGrade(rawValue: record.cardLastGrade ?? ""),
                serverVersion: serverVersion
            )
            context.insert(card)
        }
        card.serverVersion = serverVersion
        try context.save()
    }

    func deleteCardByID(_ id: UUID) throws {
        let descriptor = FetchDescriptor<StudyCard>(
            predicate: #Predicate { $0.id == id }
        )
        guard let card = try context.fetch(descriptor).first else { return }
        context.delete(card)
        try context.save()
    }

    // MARK: Study tasks

    func tasks(courseID: UUID?, includeDone: Bool) throws -> [StudyTask] {
        let all = try context.fetch(FetchDescriptor<StudyTask>())
        var scoped = all.filter { $0.status != .pendingConfirm }
        if let courseID {
            scoped = scoped.filter { $0.courseID == courseID }
        }
        if !includeDone {
            scoped = scoped.filter { $0.status != .done && $0.status != .ignored }
        }
        // Unfinished first, by due date (undated last), then newest.
        return scoped.sorted { lhs, rhs in
            let lhsDone = lhs.status == .done || lhs.status == .ignored
            let rhsDone = rhs.status == .done || rhs.status == .ignored
            if lhsDone != rhsDone { return rhsDone }
            switch (lhs.dueAt, rhs.dueAt) {
            case let (l?, r?): return l < r
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs.createdAt > rhs.createdAt
            }
        }
    }

    func pendingConfirmTasks() throws -> [StudyTask] {
        let all = try context.fetch(FetchDescriptor<StudyTask>())
        return all
            .filter { $0.status == .pendingConfirm }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func tasks(matching query: String) throws -> [StudyTask] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let lowered = trimmed.lowercased()
        let all = try context.fetch(FetchDescriptor<StudyTask>())
        return all.filter { task in
            task.status != .pendingConfirm
                && (task.title.lowercased().contains(lowered)
                    || task.detail.lowercased().contains(lowered)
                    || task.userNote.lowercased().contains(lowered))
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func addTask(_ draft: TaskDraft) throws -> StudyTask {
        let task = StudyTask(
            title: draft.title,
            detail: draft.detail,
            priority: draft.priority,
            status: draft.status,
            origin: draft.origin,
            uncertainty: draft.uncertainty,
            userNote: draft.userNote,
            dueAt: draft.dueAt,
            courseID: draft.courseID,
            sessionID: draft.sessionID,
            sourceEntryID: draft.sourceEntryID,
            sourceAttachmentID: draft.sourceAttachmentID,
            sourceReviewID: draft.sourceReviewID
        )
        context.insert(task)
        try context.save()
        // pendingConfirm candidates are device-local until confirmed.
        if task.status != .pendingConfirm {
            mutationObserver?.taskCreated(task)
        }
        return task
    }

    func updateTask(_ task: StudyTask, with draft: TaskDraft) throws {
        task.title = draft.title
        task.detail = draft.detail
        task.priority = draft.priority
        task.uncertainty = draft.uncertainty
        task.userNote = draft.userNote
        task.dueAt = draft.dueAt
        task.courseID = draft.courseID
        task.updatedAt = .now
        try context.save()
        if task.status != .pendingConfirm {
            mutationObserver?.taskUpdated(task)
        }
    }

    func confirmTask(_ task: StudyTask) throws {
        guard task.status == .pendingConfirm else { return }
        task.status = .pending
        task.updatedAt = .now
        try context.save()
        // First push of a previously device-local candidate.
        mutationObserver?.taskCreated(task)
    }

    func setTaskStatus(_ task: StudyTask, status: StudyTaskStatus) throws {
        guard task.status != status else { return }
        task.status = status
        task.completedAt = status == .done ? .now : nil
        task.updatedAt = .now
        try context.save()
        if task.status != .pendingConfirm {
            mutationObserver?.taskUpdated(task)
        }
    }

    func deleteTask(_ task: StudyTask) throws {
        let taskID = task.id
        let wasConfirmed = task.status != .pendingConfirm
        context.delete(task)
        try context.save()
        // An unconfirmed AI candidate never reached the server — no
        // tombstone needed.
        if wasConfirmed {
            mutationObserver?.taskDeleted(id: taskID)
        }
    }

    func applyRemoteStudyTask(record: SyncServerRecordDTO, serverVersion: Int) throws {
        guard let recordID = record.id,
              let title = record.title, !title.isEmpty else { return }
        let descriptor = FetchDescriptor<StudyTask>(
            predicate: #Predicate { $0.id == recordID }
        )
        let existing = try context.fetch(descriptor).first
        if let existing, existing.serverVersion >= serverVersion { return }

        let task: StudyTask
        if let existing {
            task = existing
            task.title = title
            if let detail = record.taskDetail { task.detail = detail }
            if let priorityRaw = record.taskPriority,
               let priority = StudyTaskPriority(rawValue: priorityRaw) {
                task.priority = priority
            }
            if let originRaw = record.taskOrigin, let origin = StudyTaskOrigin(rawValue: originRaw) {
                task.origin = origin
            }
            if let uncertainty = record.taskUncertainty { task.uncertainty = uncertainty }
            if let note = record.taskUserNote { task.userNote = note }
            task.dueAt = record.taskDueAt
            task.courseID = record.courseId
            task.sessionID = record.sessionId
            task.sourceEntryID = record.entryId
            task.sourceAttachmentID = record.sourceAttachmentId
            task.sourceReviewID = record.sourceReviewId
            // Done is sticky: a stale non-done push must not reopen a
            // locally completed task (mirrors the server-side rule).
            let remoteStatus = StudyTaskStatus(rawValue: record.taskStatus ?? "") ?? .pending
            if remoteStatus == .done || task.status != .done {
                task.status = remoteStatus
                task.completedAt = remoteStatus == .done
                    ? (record.taskCompletedAt ?? task.completedAt ?? .now)
                    : nil
            }
        } else {
            task = StudyTask(
                id: recordID,
                title: title,
                detail: record.taskDetail ?? "",
                priority: StudyTaskPriority(rawValue: record.taskPriority ?? "") ?? .normal,
                status: StudyTaskStatus(rawValue: record.taskStatus ?? "") ?? .pending,
                origin: StudyTaskOrigin(rawValue: record.taskOrigin ?? "") ?? .manual,
                uncertainty: record.taskUncertainty ?? "",
                userNote: record.taskUserNote ?? "",
                dueAt: record.taskDueAt,
                completedAt: record.taskCompletedAt,
                courseID: record.courseId,
                sessionID: record.sessionId,
                sourceEntryID: record.entryId,
                sourceAttachmentID: record.sourceAttachmentId,
                sourceReviewID: record.sourceReviewId,
                serverVersion: serverVersion
            )
            context.insert(task)
        }
        task.serverVersion = serverVersion
        try context.save()
    }

    func deleteTaskByID(_ id: UUID) throws {
        let descriptor = FetchDescriptor<StudyTask>(
            predicate: #Predicate { $0.id == id }
        )
        guard let task = try context.fetch(descriptor).first else { return }
        context.delete(task)
        try context.save()
    }

    // MARK: - Session recordings (device-local)

    func recording(sessionID: UUID) throws -> SessionRecording? {
        let descriptor = FetchDescriptor<SessionRecording>(
            predicate: #Predicate { $0.sessionID == sessionID }
        )
        return try context.fetch(descriptor).first
    }

    func allRecordings() throws -> [SessionRecording] {
        try context.fetch(FetchDescriptor<SessionRecording>())
    }

    func beginRecording(sessionID: UUID) throws -> SessionRecording {
        if let existing = try recording(sessionID: sessionID) {
            // A row already exists (relaunch after an abnormal end, or a
            // stale row from a deleted file): reuse it — the writer starts
            // a fresh file, so reset the state honestly.
            existing.isDeleted = false
            existing.isComplete = false
            existing.duration = 0
            existing.fileSize = 0
            existing.waveformStatus = .notGenerated
            existing.updatedAt = .now
            try context.save()
            return existing
        }
        let recording = SessionRecording(sessionID: sessionID)
        context.insert(recording)
        try context.save()
        return recording
    }

    func finishRecording(
        _ recording: SessionRecording, duration: TimeInterval, fileSize: Int64
    ) throws {
        recording.duration = max(0, duration)
        recording.fileSize = max(0, fileSize)
        recording.isComplete = true
        recording.updatedAt = .now
        try context.save()
    }

    func updateRecordingWaveformStatus(
        _ recording: SessionRecording, status: SessionRecording.WaveformStatus
    ) throws {
        guard recording.waveformStatus != status else { return }
        recording.waveformStatus = status
        recording.updatedAt = .now
        try context.save()
    }

    @discardableResult
    func deleteRecordingFile(_ recording: SessionRecording) throws -> Int64 {
        guard !recording.isDeleted else {
            return (try? Self.recordingFileSize(recording)) ?? 0
        }
        let reclaimed = (try? Self.recordingFileSize(recording)) ?? 0
        SessionRecordings.removeFile(for: recording)
        // The row (and every transcript time offset) survives: only the
        // audio is gone.
        recording.isDeleted = true
        recording.waveformStatus = .notGenerated
        recording.updatedAt = .now
        try context.save()
        return reclaimed
    }

    /// Real bytes on disk for one recording (0 when the file is gone).
    private static func recordingFileSize(_ recording: SessionRecording) throws -> Int64 {
        let url = SessionRecordings.directory(for: recording.sessionID)
            .appendingPathComponent(recording.fileName)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? Int64) ?? 0
    }

    /// Launch-time reconciliation between rows and disk:
    /// - a raw.wav with no row (recorded by an older app version) gains a
    ///   legacy row (duration inferred from the file size; completion
    ///   unknown → false, which the player treats as "may be incomplete");
    /// - a row whose session is finished but `isComplete` false (the app
    ///   died mid-class) keeps its duration best-effort from file size;
    /// - a row whose file is gone flips `isDeleted` (never a phantom play
    ///   button).
    /// Never deletes a recording whose session is still running/unfinished.
    func reconcileRecordingState() throws {
        // Sessions still in progress keep their files and rows untouched.
        let runningDescriptor = FetchDescriptor<ClassroomSession>(
            predicate: #Predicate { $0.endTime == nil }
        )
        let runningIDs = Set(try context.fetch(runningDescriptor).map(\.id))

        let sessions = try context.fetch(FetchDescriptor<ClassroomSession>())
        var knownIDs = Set<UUID>()
        for session in sessions {
            knownIDs.insert(session.id)
            guard let recording = try recording(sessionID: session.id) else {
                // Legacy recording: file exists, row does not.
                if !runningIDs.contains(session.id),
                   SessionRecordings.recordingFileExists(sessionID: session.id) {
                    let row = SessionRecording(sessionID: session.id)
                    row.isComplete = session.abnormalTermination == false
                    let size = SessionRecordings.rawWAVFileSize(sessionID: session.id)
                    row.fileSize = size
                    row.duration = size > 0
                        ? WAVFileInspector.durationOfRawWAV(bytes: size) : 0
                    context.insert(row)
                }
                continue
            }
            if runningIDs.contains(session.id) { continue }
            let exists = SessionRecordings.recordingFileExists(sessionID: session.id)
            if exists {
                if !recording.isDeleted {
                    // Refresh size (the writer may have died before the
                    // row was updated).
                    recording.fileSize = SessionRecordings.rawWAVFileSize(sessionID: session.id)
                    if recording.duration <= 0, recording.fileSize > 0 {
                        recording.duration = WAVFileInspector
                            .durationOfRawWAV(bytes: recording.fileSize)
                    }
                    recording.updatedAt = .now
                }
            } else if !recording.isDeleted {
                // The file was removed behind our back — record the truth.
                recording.isDeleted = true
                recording.updatedAt = .now
            }
        }
        // Rows without a session are orphans (session deleted on another
        // device but the file is device-local): the audio is unreachable,
        // drop both.
        for recording in try allRecordings() where !knownIDs.contains(recording.sessionID) {
            SessionRecordings.remove(for: recording.sessionID)
            context.delete(recording)
        }
        try context.save()
    }

    // MARK: - Transcript corrections

    func corrections(forSessionID id: UUID) throws -> [TranscriptCorrection] {
        let descriptor = FetchDescriptor<TranscriptCorrection>(
            predicate: #Predicate { $0.sessionID == id }
        )
        return try context.fetch(descriptor)
    }

    func allCorrections() throws -> [TranscriptCorrection] {
        try context.fetch(FetchDescriptor<TranscriptCorrection>())
    }

    func saveCorrection(
        sessionID: UUID, entryID: UUID,
        russian: String, chinese: String?, needsRetranslation: Bool
    ) throws -> TranscriptCorrection {
        let descriptor = FetchDescriptor<TranscriptCorrection>(
            predicate: #Predicate { $0.id == entryID }
        )
        let correction: TranscriptCorrection
        if let existing = try context.fetch(descriptor).first {
            correction = existing
        } else {
            correction = TranscriptCorrection(id: entryID, sessionID: sessionID)
            context.insert(correction)
        }
        correction.russianText = russian
        correction.chineseText = chinese
        correction.needsRetranslation = needsRetranslation
        correction.modifiedAt = .now
        correction.updatedAt = .now
        // Corrections are classroom content: the session's staleness
        // marker (课堂内容已更新) must fire for study reviews.
        let sessionDescriptor = FetchDescriptor<ClassroomSession>(
            predicate: #Predicate { $0.id == sessionID }
        )
        if let session = try context.fetch(sessionDescriptor).first {
            session.updatedAt = .now
        }
        try context.save()
        mutationObserver?.correctionUpserted(correction)
        return correction
    }

    func deleteCorrection(entryID: UUID) throws {
        let descriptor = FetchDescriptor<TranscriptCorrection>(
            predicate: #Predicate { $0.id == entryID }
        )
        guard let correction = try context.fetch(descriptor).first else { return }
        let sessionID = correction.sessionID
        context.delete(correction)
        let sessionDescriptor = FetchDescriptor<ClassroomSession>(
            predicate: #Predicate { $0.id == sessionID }
        )
        if let session = try context.fetch(sessionDescriptor).first {
            session.updatedAt = .now
        }
        try context.save()
        mutationObserver?.correctionDeleted(id: entryID)
    }

    func applyRemoteCorrection(record: SyncServerRecordDTO, serverVersion: Int) throws {
        guard let recordID = record.id, let sessionID = record.sessionId else { return }
        let descriptor = FetchDescriptor<TranscriptCorrection>(
            predicate: #Predicate { $0.id == recordID }
        )
        let existing = try context.fetch(descriptor).first
        if let existing, existing.serverVersion >= serverVersion { return }

        let remoteRussian = record.correctionRussian ?? ""
        let remoteChinese = record.correctionChinese
        let remoteModified = record.correctionModifiedAt ?? .distantPast

        let correction: TranscriptCorrection
        if let existing {
            // Conflict semantics: both sides substantively edited since the
            // last common state → keep the LOCAL text (the device the user
            // is holding wins) and preserve the REMOTE as a conflict copy
            // the user can adopt deliberately. "Substantive" = the fields
            // actually differ.
            let localModified = existing.modifiedAt
            let differs = existing.russianText != remoteRussian
                || existing.chineseText != remoteChinese
            let remoteIsNewer = remoteModified > localModified
            let remoteHasContent = !remoteRussian.isEmpty || remoteChinese != nil
            let localHasContent = !existing.russianText.isEmpty || existing.chineseText != nil
            if remoteIsNewer && differs && remoteHasContent && localHasContent {
                existing.conflictJSON = CorrectionConflictCopy(
                    russianText: remoteRussian,
                    chineseText: remoteChinese,
                    modifiedAt: remoteModified
                ).encodedJSON()
                existing.serverVersion = serverVersion
                try context.save()
                return
            }
            if remoteIsNewer {
                existing.russianText = remoteRussian
                existing.chineseText = remoteChinese
                if let needs = record.correctionNeedsRetranslation {
                    existing.needsRetranslation = needs
                }
            } else if differs && !remoteIsNewer && remoteHasContent {
                // Local is newer: keep local content, but a substantive
                // remote difference still merits the conflict copy so
                // nothing is silently discarded.
                existing.conflictJSON = CorrectionConflictCopy(
                    russianText: remoteRussian,
                    chineseText: remoteChinese,
                    modifiedAt: remoteModified
                ).encodedJSON()
            }
            existing.serverVersion = serverVersion
            existing.updatedAt = .now
        } else {
            correction = TranscriptCorrection(
                id: recordID,
                sessionID: sessionID,
                russianText: remoteRussian,
                chineseText: remoteChinese,
                modifiedAt: remoteModified == .distantPast ? .now : remoteModified,
                needsRetranslation: record.correctionNeedsRetranslation ?? false,
                serverVersion: serverVersion
            )
            context.insert(correction)
        }
        try context.save()
    }

    func deleteCorrectionByID(_ id: UUID) throws {
        let descriptor = FetchDescriptor<TranscriptCorrection>(
            predicate: #Predicate { $0.id == id }
        )
        guard let correction = try context.fetch(descriptor).first else { return }
        context.delete(correction)
        try context.save()
    }
}

/// Conflict copy preserved when a remote correction loses the
/// newer-modifiedAt race but carries substantively different text. The
/// user can adopt it (or dismiss it) from the correction editor.
struct CorrectionConflictCopy: Codable, Sendable, Equatable {
    var russianText: String
    var chineseText: String?
    var modifiedAt: Date

    func encodedJSON() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ json: String?) -> CorrectionConflictCopy? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CorrectionConflictCopy.self, from: data)
    }
}
