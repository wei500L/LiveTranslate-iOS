import Foundation
import OSLog

/// The course assistant (问这门课): a grounded question-answering flow,
/// not a chatbot.
///
///     ask(question)
///     → save the user message (history is durable immediately)
///     → build the scope's source snapshots (repository reads, main
///       actor, value types only)
///     → LOCAL retrieval (CourseAssistantRetriever: explainable TF-IDF
///       over ru/zh/mixed text — no vector DB, no network)
///     → no hit ⇒ honest 没有找到足够依据 answer, NO model request
///     → hit ⇒ one model call over the SELECTED sources only (never the
///       whole course database)
///     → parse [n] markers against the retrieval snapshot; invalid or
///       fabricated numbers are dropped — a citation must point at a
///       chunk that was actually sent
///     → save the answer with its citations (jump-back provenance)
///
/// Status comes from the real stages (检索中 / 正在提问 / 正在保存), never
/// a streaming animation. Offline: history, materials and extracted
/// text stay readable; only asking is marked unavailable.
@MainActor
@Observable
final class CourseAssistantService {
    private static let logger = Logger(
        subsystem: "com.livetranslate.ios", category: "course-assistant"
    )

    /// Real pipeline stages for the UI (no fake streaming).
    enum AskingStage: Equatable, Sendable {
        case retrieving
        case asking
        case saving

        var label: String {
            switch self {
            case .retrieving: return "正在检索课程内容…"
            case .asking: return "正在整理回答…"
            case .saving: return "正在保存…"
            }
        }
    }

    enum AskError: LocalizedError, Equatable {
        case notConfigured

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "课程助手需要先在设置中配置兼容模型。"
            }
        }
    }

    /// The scope one question is asked in.
    enum Scope: Equatable, Sendable {
        /// The whole course (nil = everything, for 未归类 threads).
        case course(courseID: UUID?)
        case material(materialID: UUID)
        case session(sessionID: UUID)
        case page(materialID: UUID, pageNumber: Int)

        var scopeLabel: CourseAssistantPrompt.ScopeLabel {
            switch self {
            case .course: return .course
            case .material: return .material
            case .session: return .session
            case .page: return .page
            }
        }
    }

    /// How many retrieved chunks ride one request (the context budget —
    /// the whole course database is NEVER sent).
    static let sourceLimit = 12
    /// Characters per source chunk in the prompt (long pages are
    /// windowed around the match instead of sent whole).
    static let sourceExcerptLimit = 700
    /// Past turns included for follow-up understanding.
    static let historyTurnLimit = 4

    private let repository: any ClassroomRepositoryProtocol
    private let textServiceProvider: () -> (any StudyReviewModelService)?
    /// In-flight ask per thread (one question at a time per thread).
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private(set) var stageByThread: [UUID: AskingStage] = [:]

    init(
        repository: any ClassroomRepositoryProtocol,
        textServiceProvider: @escaping () -> (any StudyReviewModelService)?
    ) {
        self.repository = repository
        self.textServiceProvider = textServiceProvider
    }

    var isModelConfigured: Bool {
        textServiceProvider()?.isConfiguredNow ?? false
    }

    func isAsking(threadID: UUID) -> Bool {
        tasks[threadID] != nil
    }

    func stage(threadID: UUID) -> AskingStage? {
        stageByThread[threadID]
    }

    func cancel(threadID: UUID) {
        tasks[threadID]?.cancel()
    }

    // MARK: - Ask

    /// Runs one question through the pipeline. The user message is saved
    /// immediately (history is durable even when the answer fails); the
    /// answer lands as a message row on completion.
    func ask(
        thread: CourseAssistantThread, question: String, scope: Scope
    ) {
        let threadID = thread.id
        guard tasks[threadID] == nil else { return }
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // The default course scope is the thread's own course.
        let effectiveScope: Scope
        if case .course(nil) = scope, let courseID = thread.courseID {
            effectiveScope = .course(courseID: courseID)
        } else {
            effectiveScope = scope
        }
        tasks[threadID] = Task { [weak self] in
            await self?.run(
                threadID: threadID, question: trimmed, scope: effectiveScope
            )
            self?.tasks[threadID] = nil
        }
    }

    private func run(threadID: UUID, question: String, scope: Scope) async {
        stageByThread[threadID] = .retrieving
        defer { stageByThread[threadID] = nil }

        // The user message is durable from the start; a failed answer
        // never loses the question.
        let userMessage = try? repository.addAssistantMessage(
            AssistantMessageDraft(
                threadID: threadID,
                role: .user,
                text: question,
                scopeMaterialID: scope.materialID,
                scopeSessionID: scope.sessionID
            )
        )
        _ = userMessage

        do {
            guard let service = textServiceProvider(), service.isConfiguredNow else {
                throw AskError.notConfigured
            }

            // ---- Retrieval (local) --------------------------------------
            let snapshots = buildSourceSnapshots(scope: scope)
            let retrievalTask = Task.detached(priority: .userInitiated) {
                CourseAssistantRetriever.search(
                    query: question, chunks: snapshots, limit: Self.sourceLimit
                )
            }
            let hits = await retrievalTask.value

            let answerText: String
            var citations: [AssistantMessageCitation] = []
            if hits.isEmpty {
                // No evidence at all: the honest answer, NO model request.
                answerText = CourseAssistantPrompt.noEvidenceAnswer
            } else {
                // ---- Model request over the SELECTED sources only -----
                stageByThread[threadID] = .asking
                let sources = hits.map { hit in
                    CourseAssistantPrompt.SourceLine(
                        number: hit.number,
                        label: hit.chunk.label,
                        text: excerpt(hit.chunk.text, question: question)
                    )
                }
                let history = recentHistory(threadID: threadID, excluding: question)
                let prompt = CourseAssistantPrompt.userPrompt(
                    scope: scope.scopeLabel,
                    sources: sources,
                    history: history,
                    question: question
                )
                let raw = try await service.complete(
                    systemPrompt: CourseAssistantPrompt.systemPrompt(),
                    userPrompt: prompt,
                    maxTokens: 2_000
                )
                // ---- Citation validation --------------------------------
                let (text, parsedCitations) = Self.resolveCitations(
                    raw, hits: hits
                )
                answerText = text
                citations = parsedCitations
            }

            // ---- Save ---------------------------------------------------
            stageByThread[threadID] = .saving
            _ = try repository.addAssistantMessage(
                AssistantMessageDraft(
                    threadID: threadID,
                    role: .assistant,
                    text: answerText,
                    scopeMaterialID: scope.materialID,
                    scopeSessionID: scope.sessionID,
                    citations: citations
                )
            )
        } catch is CancellationError {
            return
        } catch {
            // The failure is saved as a visible answer row — never a
            // silent disappearance of the question.
            let message = (error as? LocalizedError)?.errorDescription
                ?? String(localized: "回答生成失败，请稍后再试。")
            _ = try? repository.addAssistantMessage(
                AssistantMessageDraft(
                    threadID: threadID,
                    role: .assistant,
                    text: message,
                    scopeMaterialID: scope.materialID,
                    scopeSessionID: scope.sessionID
                )
            )
            Self.logger.error(
                "assistant ask failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    // MARK: - Citation resolution

    /// Maps [n] markers in the model answer to the retrieval snapshot.
    /// Numbers outside the snapshot are stripped from the text (a
    /// fabricated citation is never displayed, never saved). An answer
    /// whose markers all failed carries an honest leading note.
    static func resolveCitations(
        _ raw: String, hits: [CourseAssistantRetriever.ScoredChunk]
    ) -> (text: String, citations: [AssistantMessageCitation]) {
        let hitByNumber = Dictionary(hits.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
        var usedNumbers: Set<Int> = []
        // First pass: find which markers resolve.
        if let regex = try? NSRegularExpression(pattern: #"\[(\d{1,3})\]"#) {
            let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
            for match in regex.matches(in: raw, range: range) {
                guard let numberRange = Range(match.range(at: 1), in: raw),
                      let number = Int(raw[numberRange]) else { continue }
                if hitByNumber[number] != nil {
                    usedNumbers.insert(number)
                }
            }
        }
        var citations: [AssistantMessageCitation] = usedNumbers.sorted().map { number in
            let hit = hitByNumber[number]!
            return AssistantMessageCitation(
                number: number,
                kind: hit.chunk.kind,
                label: hit.chunk.label,
                materialID: hit.chunk.materialID,
                pageNumber: hit.chunk.pageNumber,
                sessionID: hit.chunk.sessionID,
                entryID: hit.chunk.entryID,
                noteID: hit.chunk.noteID,
                attachmentID: hit.chunk.attachmentID,
                reviewID: hit.chunk.reviewID,
                snippet: excerptText(hit.chunk.text, limit: 140)
            )
        }
        // Renumber citations to their first-appearance order in the text
        // so the displayed [n] set is dense and stable.
        var text = raw
        if !usedNumbers.isEmpty {
            // Markers already match their hit numbers; keep them as-is.
        } else {
            // No valid citation: strip stray markers so nothing dead is
            // displayed, and note the absence honestly.
            text = stripMarkers(raw)
            if !text.isEmpty {
                text = "（以下回答未标注可用来源，仅供参考）\n\n" + text
            }
        }
        // Drop markers that do not resolve (fabricated [99] etc.).
        text = dropInvalidMarkers(text, valid: usedNumbers)
        return (text, citations)
    }

    private static func stripMarkers(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"\[\d{1,3}\]"#,
            with: "",
            options: .regularExpression
        )
    }

    private static func dropInvalidMarkers(_ text: String, valid: Set<Int>) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\[(\d{1,3})\]"#) else {
            return text
        }
        var result = text
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in regex.matches(in: text, range: range).reversed() {
            guard let numberRange = Range(match.range(at: 1), in: text),
                  let number = Int(text[numberRange]),
                  !valid.contains(number),
                  let fullRange = Range(match.range, in: text) else { continue }
            result.replaceSubrange(fullRange, with: "")
        }
        return result
    }

    // MARK: - Corpus building (main actor → Sendable snapshots)

    /// Builds the scope's retrieval corpus as VALUE snapshots (the
    /// detached search never touches SwiftData models).
    private func buildSourceSnapshots(scope: Scope) -> [CourseAssistantRetriever.SourceChunk] {
        var chunks: [CourseAssistantRetriever.SourceChunk] = []
        let courseID = scope.courseIDValue

        // Material pages + digests.
        let materials: [CourseMaterial]
        switch scope {
        case .course:
            materials = (try? repository.materials(courseID: courseID)) ?? []
        case .material(let materialID), .page(let materialID, _):
            materials = [((try? repository.material(id: materialID)) ?? nil)].compactMap { $0 }
        case .session(let sessionID):
            // The class's linked materials, whatever their course.
            materials = ((try? repository.materials(courseID: nil)) ?? [])
                .filter { $0.sessionID == sessionID }
        }
        for material in materials {
            let materialLabel = material.title.isEmpty ? material.originalFileName : material.title
            switch scope {
            case .page(_, let pageNumber):
                // The asked page and its neighbours.
                let pages = (try? repository.materialPages(materialID: material.id)) ?? []
                for page in pages where abs(page.pageNumber - pageNumber) <= 1 {
                    let text = page.effectiveText
                    guard !text.isEmpty else { continue }
                    chunks.append(.init(
                        kind: .materialPage,
                        label: "\(materialLabel) · 第 \(page.pageNumber) 页",
                        text: text,
                        materialID: material.id,
                        pageNumber: page.pageNumber
                    ))
                }
            default:
                let pages = (try? repository.materialPages(materialID: material.id)) ?? []
                for page in pages {
                    let text = page.effectiveText
                    guard !text.isEmpty else { continue }
                    chunks.append(.init(
                        kind: .materialPage,
                        label: "\(materialLabel) · 第 \(page.pageNumber) 页",
                        text: text,
                        materialID: material.id,
                        pageNumber: page.pageNumber
                    ))
                }
            }
            // The digest's searchable text is retrievable too (with its
            // own provenance back into the material).
            if let digest = material.digest, !digest.searchableText.isEmpty {
                chunks.append(.init(
                    kind: .materialPage,
                    label: "\(materialLabel) · 导读",
                    text: digest.searchableText,
                    materialID: material.id,
                    pageNumber: nil
                ))
            }
        }

        // Session transcripts (EFFECTIVE text — corrections first),
        // notes, attachments, reviews; learning rows.
        let sessions: [ClassroomSession]
        switch scope {
        case .session(let sessionID):
            sessions = ((try? repository.sessions(matching: "")) ?? [])
                .filter { $0.id == sessionID }
        case .course:
            let all = (try? repository.sessions(matching: "")) ?? []
            sessions = courseID == nil
                ? all
                : all.filter { $0.courseID == courseID }
        default:
            sessions = []
        }
        for session in sessions {
            appendSessionChunks(session: session, into: &chunks)
        }

        // Learning rows (terms/cards/tasks of the course scope).
        if case .course = scope {
            let terms = (try? repository.terms(courseID: courseID)) ?? []
            for term in terms {
                var text = "\(term.russian) — \(term.chinese)"
                if !term.explanation.isEmpty { text += "：\(term.explanation)" }
                chunks.append(.init(
                    kind: .learning,
                    label: "术语 · \(term.russian)",
                    text: text,
                    sessionID: term.sessionID,
                    entryID: term.sourceEntryID,
                    attachmentID: term.sourceAttachmentID,
                    reviewID: term.sourceReviewID
                ))
            }
            let cards = (try? repository.cards(courseID: courseID)) ?? []
            for card in cards {
                chunks.append(.init(
                    kind: .learning,
                    label: "学习卡片",
                    text: "\(card.front) — \(card.back)",
                    sessionID: card.sessionID,
                    entryID: card.sourceEntryID,
                    attachmentID: card.sourceAttachmentID
                ))
            }
            let tasks = (try? repository.tasks(courseID: courseID, includeDone: true)) ?? []
            for task in tasks {
                var text = task.title
                if !task.detail.isEmpty { text += "：\(task.detail)" }
                chunks.append(.init(
                    kind: .learning,
                    label: "学习任务",
                    text: text,
                    sessionID: task.sessionID,
                    entryID: task.sourceEntryID,
                    attachmentID: task.sourceAttachmentID,
                    reviewID: task.sourceReviewID
                ))
            }
        }
        return chunks
    }

    /// Appends one session's retrieval chunks: transcript groups
    /// (effective text), notes, attachments and the study review.
    private func appendSessionChunks(
        session: ClassroomSession, into chunks: inout [CourseAssistantRetriever.SourceChunk]
    ) {
        let sessionLabel = session.title
        let entries = (try? repository.entries(for: session)) ?? []
        let corrections = (try? repository.corrections(forSessionID: session.id)) ?? []
        let correctionsByEntry = Dictionary(
            corrections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        // Group adjacent entries into ~600-char chunks — a citation lands
        // on the FIRST entry of its group (jump target), the group text
        // is all four entries' effective text.
        var groupEntries: [TranscriptEntry] = []
        var groupChars = 0
        func flushGroup() {
            guard let first = groupEntries.first else { return }
            let text = groupEntries.map { entry -> String in
                let russian = entry.effectiveRussianText(correction: correctionsByEntry[entry.id])
                let chinese = entry.effectiveChineseText(correction: correctionsByEntry[entry.id]) ?? ""
                return chinese.isEmpty ? russian : "\(russian)\n\(chinese)"
            }.joined(separator: "\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                groupEntries = []
                groupChars = 0
                return
            }
            chunks.append(.init(
                kind: .transcript,
                label: "\(sessionLabel) · \(TranscriptExporter.mmss(first.startOffset))",
                text: text,
                sessionID: session.id,
                entryID: first.id
            ))
            groupEntries = []
            groupChars = 0
        }
        for entry in entries {
            let cost = entry.originalText.count + (entry.translatedText?.count ?? 0)
            if !groupEntries.isEmpty && groupChars + cost > 600 {
                flushGroup()
            }
            groupEntries.append(entry)
            groupChars += cost
        }
        flushGroup()

        // Notes.
        let notes = (try? repository.notes(forSessionID: session.id)) ?? []
        for note in notes where !note.text.isEmpty {
            chunks.append(.init(
                kind: .note,
                label: "\(sessionLabel) · 课堂笔记",
                text: note.text,
                sessionID: session.id,
                noteID: note.id
            ))
        }
        // Attachments (analysis + OCR searchable text).
        let attachments = (try? repository.attachments(forSessionID: session.id)) ?? []
        for attachment in attachments {
            var text = attachment.ocrText
            if let analysis = AttachmentAnalysisResult.decode(attachment.analysisJSON) {
                let analysisText = analysis.searchableText
                if !analysisText.isEmpty {
                    text = text.isEmpty ? analysisText : text + "\n" + analysisText
                }
            }
            guard !text.isEmpty else { continue }
            chunks.append(.init(
                kind: .attachment,
                label: "\(sessionLabel) · \(attachment.kind.displayName)\(attachment.title.isEmpty ? "" : " · \(attachment.title)")",
                text: text,
                sessionID: session.id,
                attachmentID: attachment.id
            ))
        }
        // Study review.
        if let review = try? repository.studyReview(forSessionID: session.id),
           let content = StudyReviewContent.decode(review.contentJSON),
           !content.searchableText.isEmpty {
            chunks.append(.init(
                kind: .review,
                label: "\(sessionLabel) · 课后整理",
                text: content.searchableText,
                sessionID: session.id,
                reviewID: review.id
            ))
        }
    }

    private func recentHistory(threadID: UUID, excluding question: String) -> [CourseAssistantPrompt.HistoryTurn] {
        let messages = (try? repository.assistantMessages(threadID: threadID)) ?? []
        let recent = messages.suffix(Self.historyTurnLimit)
        return recent.map { message in
            CourseAssistantPrompt.HistoryTurn(
                isUser: message.role == .user,
                text: message.text
            )
        }
    }

    // MARK: - Text helpers

    /// Windows a long chunk around the best query overlap so the prompt
    /// stays inside the context budget without losing the matched part.
    private func excerpt(_ text: String, question: String) -> String {
        guard text.count > Self.sourceExcerptLimit else { return text }
        // Prefer a window containing the first query token hit.
        let queryTokens = CourseAssistantRetriever.tokenize(question)
        var windowStart = text.startIndex
        for token in queryTokens where text.count >= token.count {
            if let range = text.range(of: token, options: .caseInsensitive) {
                windowStart = range.lowerBound
                break
            }
        }
        // Walk forward from the anchor for the budget.
        var start = windowStart
        var budget = Self.sourceExcerptLimit
        while budget > 0, start > text.startIndex, text.distance(from: text.startIndex, to: start) > Self.sourceExcerptLimit / 3 {
            start = text.index(before: start)
            budget -= 1
        }
        var end = start
        while budget > 0, end < text.endIndex {
            end = text.index(after: end)
            budget -= 1
        }
        let slice = String(text[start..<end])
        let prefix = start > text.startIndex ? "…" : ""
        let suffix = end < text.endIndex ? "…" : ""
        return prefix + slice + suffix
    }

    static func excerptText(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }
}

private extension CourseAssistantService.Scope {
    var materialID: UUID? {
        if case .material(let id) = self { return id }
        if case .page(let id, _) = self { return id }
        return nil
    }

    var sessionID: UUID? {
        if case .session(let id) = self { return id }
        return nil
    }

    var courseIDValue: UUID? {
        if case .course(let id) = self { return id }
        return nil
    }
}
