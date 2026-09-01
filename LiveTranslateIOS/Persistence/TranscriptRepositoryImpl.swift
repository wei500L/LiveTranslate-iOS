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
        return session
    }

    func finishSession(_ session: ClassroomSession, abnormal: Bool) throws {
        session.endTime = .now
        session.duration = session.endTime!.timeIntervalSince(session.startTime)
        session.abnormalTermination = session.abnormalTermination || abnormal
        session.updatedAt = .now
        try context.save()
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

    func entriesNeedingRetry(for session: ClassroomSession) throws -> [TranscriptEntry] {
        try entries(for: session).filter { $0.status == .failed }
    }

    // MARK: - Deletion

    func deleteSession(_ session: ClassroomSession) throws {
        context.delete(session)
        try context.save()
    }

    func deleteAllSessions() throws {
        try context.delete(model: ClassroomSession.self)
        try context.save()
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
    }
}
