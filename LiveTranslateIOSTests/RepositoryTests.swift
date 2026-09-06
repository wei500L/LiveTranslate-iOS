import XCTest
import SwiftData
@testable import LiveTranslateIOS

@MainActor
final class RepositoryTests: XCTestCase {
    private var container: ModelContainer!
    private var repository: TranscriptRepository!

    override func setUp() async throws {
        let schema = Schema([
            ClassroomSession.self, TranscriptEntry.self,
            Course.self, SessionNote.self, StudyReview.self, SessionAttachment.self,
            GlossaryTerm.self, StudyCard.self, StudyTask.self,
            SessionRecording.self, TranscriptCorrection.self,
            CourseSchedule.self, ScheduleException.self,
            InterpreterConversation.self, InterpreterTurn.self,
            ErrandCase.self, ErrandCaseItem.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
        repository = TranscriptRepository(
            container: container,
            databaseURL: URL(fileURLWithPath: "/dev/null/nonexistent.sqlite")
        )
    }

    private func makeDraft(title: String = "Лекция") -> SessionDraft {
        SessionDraft(
            title: title,
            backend: .sherpaONNXInt8,
            modelVersion: "c0acd38",
            computePreference: "int8-2threads",
            translationModel: "deepseek-chat"
        )
    }

    func testCreateAndFinishSession() throws {
        let session = try repository.createSession(makeDraft())
        XCTAssertNil(session.endTime)
        XCTAssertEqual(session.asrBackend, ASRBackendKind.sherpaONNXInt8.rawValue)
        XCTAssertEqual(session.sourceLanguage, "ru")
        XCTAssertEqual(session.targetLanguage, "zh-CN")

        try repository.finishSession(session, abnormal: false)
        XCTAssertNotNil(session.endTime)
        XCTAssertGreaterThan(session.duration, -1)
        XCTAssertFalse(session.abnormalTermination)
    }

    func testAddEntryUpdatesSessionCount() throws {
        let session = try repository.createSession(makeDraft())
        let entry = try repository.addEntry(
            EntryDraft(
                sequenceID: 0,
                startOffset: 1.0,
                endOffset: 3.5,
                originalText: "Тест",
                asrBackend: .sherpaONNXInt8,
                asrLatency: 0.4,
                asrRTF: 0.16
            ),
            to: session
        )
        XCTAssertEqual(entry.status, .pending)
        XCTAssertEqual(session.entryCount, 1)
        XCTAssertEqual(entry.session?.id, session.id)
        let entries = try repository.entries(for: session)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.originalText, "Тест")
    }

    func testEntriesSortedBySequenceID() throws {
        let session = try repository.createSession(makeDraft())
        // Insert deliberately out of order.
        for sequence in [2, 0, 1] {
            _ = try repository.addEntry(
                EntryDraft(
                    sequenceID: sequence,
                    startOffset: TimeInterval(sequence),
                    endOffset: TimeInterval(sequence) + 1,
                    originalText: "utterance \(sequence)",
                    asrBackend: .coreMLFP16,
                    asrLatency: 0.1,
                    asrRTF: 0.05
                ),
                to: session
            )
        }
        let entries = try repository.entries(for: session)
        XCTAssertEqual(entries.map(\.sequenceID), [0, 1, 2])
    }

    func testUpdateTranslation() throws {
        let session = try repository.createSession(makeDraft())
        let entry = try repository.addEntry(
            EntryDraft(
                sequenceID: 0, startOffset: 0, endOffset: 1,
                originalText: "привет",
                asrBackend: .coreMLFP16, asrLatency: 0, asrRTF: 0
            ),
            to: session
        )
        try repository.updateTranslation(
            entryID: entry.id, text: "你好", latency: 1.2, status: .completed
        )
        let entries = try repository.entries(for: session)
        XCTAssertEqual(entries.first?.translatedText, "你好")
        XCTAssertEqual(entries.first?.translationLatency, 1.2)
        XCTAssertEqual(entries.first?.status, .completed)
        // No matching entry is not an error.
        try repository.updateTranslation(
            entryID: UUID(), text: "x", latency: nil, status: .completed
        )
    }

    func testSearchByTitleAndContent() throws {
        let math = try repository.createSession(makeDraft(title: "Алгебра"))
        let history = try repository.createSession(makeDraft(title: "История"))
        _ = try repository.addEntry(
            EntryDraft(
                sequenceID: 0, startOffset: 0, endOffset: 1,
                originalText: "теорема Пифагора",
                asrBackend: .coreMLFP16, asrLatency: 0, asrRTF: 0
            ),
            to: history
        )

        XCTAssertEqual(try repository.sessions(matching: "").count, 2)
        let byTitle = try repository.sessions(matching: "алгебр")
        XCTAssertEqual(byTitle.count, 1)
        XCTAssertEqual(byTitle.first?.id, math.id)

        let byOriginal = try repository.sessions(matching: "Пифагора")
        XCTAssertEqual(byOriginal.count, 1)
        XCTAssertEqual(byOriginal.first?.id, history.id)

        _ = try repository.addEntry(
            EntryDraft(
                sequenceID: 1, startOffset: 1, endOffset: 2,
                originalText: "второй фрагмент",
                asrBackend: .coreMLFP16, asrLatency: 0, asrRTF: 0
            ),
            to: history
        )
        try repository.updateTranslation(
            entryID: (try repository.entries(for: history).first!.id),
            text: "毕达哥拉斯定理", latency: nil, status: .completed
        )
        let byTranslation = try repository.sessions(matching: "毕达哥拉斯")
        XCTAssertEqual(byTranslation.count, 1)
        XCTAssertEqual(byTranslation.first?.id, history.id)

        XCTAssertTrue(try repository.sessions(matching: "量子物理课").isEmpty)
    }

    func testSessionsSortedNewestFirst() throws {
        let older = try repository.createSession(makeDraft(title: "old"))
        older.startTime = Date(timeIntervalSinceNow: -3600)
        _ = try repository.createSession(makeDraft(title: "new"))
        let sessions = try repository.sessions(matching: "")
        XCTAssertEqual(sessions.count, 2)
        XCTAssertGreaterThanOrEqual(sessions[0].startTime, sessions[1].startTime)
    }

    func testEntriesNeedingRetry() throws {
        let session = try repository.createSession(makeDraft())
        var ids: [UUID] = []
        for sequence in 0..<4 {
            let entry = try repository.addEntry(
                EntryDraft(
                    sequenceID: sequence, startOffset: 0, endOffset: 1,
                    originalText: "text \(sequence)",
                    asrBackend: .coreMLFP16, asrLatency: 0, asrRTF: 0
                ),
                to: session
            )
            ids.append(entry.id)
        }
        try repository.updateTranslation(entryID: ids[0], text: "ok", latency: nil, status: .completed)
        try repository.updateTranslation(entryID: ids[1], text: "", latency: nil, status: .failed)
        // ids[2] stays pending.
        // Not-configured entries are retryable: the class can be recorded
        // local-only and the translation API configured afterwards.
        try repository.updateTranslation(entryID: ids[3], text: "", latency: nil, status: .notConfigured)
        let retry = try repository.entriesNeedingRetry(for: session)
        XCTAssertEqual(retry.map(\.sequenceID), [1, 3])
    }

    func testDeleteSessionCascades() throws {
        let session = try repository.createSession(makeDraft())
        _ = try repository.addEntry(
            EntryDraft(
                sequenceID: 0, startOffset: 0, endOffset: 1,
                originalText: "x",
                asrBackend: .coreMLFP16, asrLatency: 0, asrRTF: 0
            ),
            to: session
        )
        try repository.deleteSession(session)
        XCTAssertTrue(try repository.sessions(matching: "").isEmpty)
        let entryCount = try container.mainContext.fetchCount(FetchDescriptor<TranscriptEntry>())
        XCTAssertEqual(entryCount, 0)
    }

    func testDeleteAllSessions() throws {
        for index in 0..<3 {
            _ = try repository.createSession(makeDraft(title: "s\(index)"))
        }
        try repository.deleteAllSessions()
        XCTAssertTrue(try repository.sessions(matching: "").isEmpty)
    }

    func testMarkAbnormalTerminations() throws {
        let clean = try repository.createSession(makeDraft(title: "clean"))
        try repository.finishSession(clean, abnormal: false)

        let killed = try repository.createSession(makeDraft(title: "killed"))
        // No finishSession: simulates app termination mid-classroom.

        try repository.markAbnormalTerminations()

        XCTAssertFalse(clean.abnormalTermination)
        XCTAssertNotNil(clean.endTime)
        XCTAssertTrue(killed.abnormalTermination)
        XCTAssertNotNil(killed.endTime)
    }

    func testStorageBytesReportsZeroForMissingFile() {
        // In-memory store: no SQLite file exists at the injected URL.
        XCTAssertEqual(repository.storageBytes(), 0)
    }
}
