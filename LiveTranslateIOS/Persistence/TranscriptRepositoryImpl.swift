import Foundation
import SwiftData

/// SwiftData-backed implementation of `ClassroomRepositoryProtocol`.
///
/// All access is MainActor-isolated: SwiftData models are not Sendable, so
/// every read and write happens on the main actor, matching how the UI
/// consumes them.
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
            translationModel: draft.translationModel
        )
        context.insert(session)
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
        return all.filter { session in
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
        context.delete(session)
        try context.save()
        mutationObserver?.sessionDeleted(id: sessionID)
    }

    func deleteAllSessions() throws {
        let sessions = try context.fetch(FetchDescriptor<ClassroomSession>())
        let ids = sessions.map(\.id)
        try context.delete(model: ClassroomSession.self)
        try context.save()
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
                asrBackend: "cloud"
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
        try context.delete(session)
        try context.save()
    }

    func deleteEntryByID(_ id: UUID) throws {
        let descriptor = FetchDescriptor<TranscriptEntry>(
            predicate: #Predicate { $0.id == id }
        )
        guard let entry = try context.fetch(descriptor).first else { return }
        if let session = entry.session, session.entryCount > 0 {
            session.entryCount -= 1
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

    /// First-upload snapshot: every session and entry becomes an outbox
    /// upsert (favorites are enqueued by the sync service from
    /// BookmarkStore). Runs in batches on the main actor so the UI is
    /// never blocked for long; the outbox makes it resumable.
    func syncSnapshots(
        batchSize: Int, progress: ((Int, Int) -> Void)?
    ) -> [SyncOutboxItem] {
        var items: [SyncOutboxItem] = []
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
            if batchSize > 0, (index + 1) % batchSize == 0 {
                progress?(index + 1, sessions.count)
            }
        }
        progress?(sessions.count, sessions.count)
        return items
    }
}
