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
/// session is gone (there is no playback path).
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

    /// Best-effort removal; missing directories are not an error.
    static func remove(for sessionID: UUID) {
        try? FileManager.default.removeItem(at: directory(for: sessionID))
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: rootDirectory)
    }
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
        return all.filter { session in
            if hitSessionIDs.contains(session.id) { return true }
            if session.title.lowercased().contains(needle) { return true }
            return session.entries.contains { entry in
                entry.originalText.lowercased().contains(needle)
                    || (entry.translatedText?.lowercased().contains(needle) ?? false)
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
        // with the session's study review. Raw recordings (保存原始录音)
        // are session data too.
        let noteDescriptor = FetchDescriptor<SessionNote>(
            predicate: #Predicate { $0.sessionID == sessionID }
        )
        for note in try context.fetch(noteDescriptor) {
            context.delete(note)
        }
        if let review = try studyReview(forSessionID: sessionID) {
            context.delete(review)
        }
        context.delete(session)
        try context.save()
        SessionRecordings.remove(for: sessionID)
        mutationObserver?.sessionDeleted(id: sessionID)
    }

    func deleteAllSessions() throws {
        let sessions = try context.fetch(FetchDescriptor<ClassroomSession>())
        let ids = sessions.map(\.id)
        try context.delete(model: ClassroomSession.self)
        try context.delete(model: SessionNote.self)
        try context.delete(model: StudyReview.self)
        try context.save()
        SessionRecordings.removeAll()
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
        try context.delete(session)
        try context.save()
        SessionRecordings.remove(for: id)
    }

    func deleteEntryByID(_ id: UUID) throws {
        let descriptor = FetchDescriptor<TranscriptEntry>(
            predicate: #Predicate { $0.id == id }
        )
        guard let entry = try context.fetch(descriptor).first else { return }
        if let session = entry.session, session.entryCount > 0 {
            session.entryCount -= 1
        }
        // Notes anchored to the removed entry keep their text — the anchor
        // is metadata and is simply dropped.
        let noteDescriptor = FetchDescriptor<SessionNote>(
            predicate: #Predicate { $0.anchorEntryID == id }
        )
        for note in try context.fetch(noteDescriptor) {
            note.anchorEntryID = nil
            note.updatedAt = .now
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
            if batchSize > 0, (index + 1) % batchSize == 0 {
                progress?(index + 1, sessions.count)
            }
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
        // standalone. No mutation-observer notifications — this is the
        // remote-applied side of a delete.
        let sessions = try context.fetch(FetchDescriptor<ClassroomSession>(
            predicate: #Predicate { $0.courseID == id }
        ))
        for session in sessions {
            session.courseID = nil
        }
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
                text: record.noteText ?? ""
            )
            context.insert(note)
        }
        if let text = record.noteText, !text.isEmpty { note.text = text }
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
                let remoteGenerated = record.reviewGenerated ?? ""
                existing.hasUserEdits = !remoteGenerated.isEmpty && remoteContent != remoteGenerated
            }
            if let generated = record.reviewGenerated, !generated.isEmpty {
                existing.generatedJSON = generated
            }
            if let model = record.reviewModel, !model.isEmpty {
                existing.reviewModel = model
            }
            if let generatedAt = record.reviewGeneratedAt {
                existing.generatedAt = generatedAt
            }
            if let sourceAt = record.reviewSourceAt {
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
            generatedJSON: record.reviewGenerated ?? "",
            hasUserEdits: false,
            chunkStateJSON: "",
            reviewModel: record.reviewModel ?? "",
            generatedAt: record.reviewGeneratedAt,
            sourceUpdatedAt: record.reviewSourceAt,
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
}
