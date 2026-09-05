import Foundation
import OSLog

/// The course assistant (问这门课): a grounded question-answering flow,
/// not a chatbot — and its visual extension (图片问答). Three question
/// shapes ride ONE thread system:
///
///     text ask    — the original retrieval-grounded flow
///     visual ask  — question + evidence images (attachments / material
///                   pages / crop selections), optionally combined with
///                   retrieved course text: ONE multimodal request
///     follow-ups  — reuse the thread; only bounded history and the
///                   turn's own evidence ride the request
///
///     ask(question, evidence, options)
///     → save the user message with its evidence references (durable
///       immediately)
///     → prepare bounded upright JPEGs from the evidence (crop, HEIC→
///       JPEG, budget-enforced — request lifecycle only)
///     → build the scope's source snapshots (repository reads, main
///       actor, value types only; bounded by the user's context toggles)
///     → LOCAL retrieval (CourseAssistantRetriever: explainable TF-IDF
///       over ru/zh/mixed text — no vector DB, no network)
///     → no image AND no hit ⇒ honest 没有找到足够依据 answer, NO model
///       request; image present but no hit ⇒ pure visual answer
///     → ONE model call over the SELECTED sources and evidence only
///     → validate [n] markers against the retrieval snapshot and 图片
///       citations against the evidence list; fabricated numbers are
///       dropped — a citation must point at something actually sent
///     → save the answer with its citations + evidence snapshot +
///       structured payload (jump-back provenance)
///
/// Status comes from the real stages (准备图片 / 检索中 / 正在提问 / 正在
/// 保存), never a streaming animation. Offline: history, materials and
/// extracted text stay readable; only asking is marked unavailable.
@MainActor
@Observable
final class CourseAssistantService {
    private static let logger = Logger(
        subsystem: "com.livetranslate.ios", category: "course-assistant"
    )

    /// Real pipeline stages for the UI (no fake streaming).
    enum AskingStage: Equatable, Sendable {
        case preparingImages
        case retrieving
        case asking
        case saving

        var label: String {
            switch self {
            case .preparingImages: return "正在准备图片…"
            case .retrieving: return "正在检索课程内容…"
            case .asking: return "正在整理回答…"
            case .saving: return "正在保存…"
            }
        }
    }

    enum AskError: LocalizedError, Equatable {
        case notConfigured
        case imageModelNotConfigured

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "课程助手需要先在设置中配置兼容模型。"
            case .imageModelNotConfigured:
                return "图片问答需要先在设置中配置图片理解模型。"
            }
        }
    }

    /// What context a visual question may pull in besides the images
    /// themselves. The user chooses per question (the composer's toggles);
    /// nothing beyond these bounds is ever sent.
    struct VisualAskOptions: Sendable, Equatable {
        /// 课堂转录（讲解）上下文。
        var includeTranscript: Bool = true
        /// 本堂课笔记。
        var includeNotes: Bool = true
        /// 课程资料检索（资料页、导读、学习行）。
        var includeRetrieval: Bool = true

        static let all = VisualAskOptions()
        static let imagesOnly = VisualAskOptions(
            includeTranscript: false, includeNotes: false, includeRetrieval: false
        )
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
    // nonisolated: immutable Ints read from the detached retrieval task.
    nonisolated static let sourceLimit = 12
    /// Characters per source chunk in the prompt (long pages are
    /// windowed around the match instead of sent whole).
    nonisolated static let sourceExcerptLimit = 700
    /// Past turns included for follow-up understanding.
    static let historyTurnLimit = 4

    private let repository: any ClassroomRepositoryProtocol
    private let textServiceProvider: () -> (any StudyReviewModelService)?
    /// The unified multimodal service (visual Q&A rides the SAME image
    /// model config as attachment analysis — one key, one transport).
    private let imageServiceProvider: () -> (any AttachmentAnalysisModelService)?
    /// In-flight ask per thread (one question at a time per thread).
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private(set) var stageByThread: [UUID: AskingStage] = [:]

    init(
        repository: any ClassroomRepositoryProtocol,
        textServiceProvider: @escaping () -> (any StudyReviewModelService)?,
        imageServiceProvider: @escaping () -> (any AttachmentAnalysisModelService)? = { nil }
    ) {
        self.repository = repository
        self.textServiceProvider = textServiceProvider
        self.imageServiceProvider = imageServiceProvider
    }

    var isModelConfigured: Bool {
        textServiceProvider()?.isConfiguredNow ?? false
    }

    /// Whether visual Q&A can run (the image-understanding model is
    /// configured). Views may still show history and OCR when false.
    var isImageModelConfigured: Bool {
        imageServiceProvider()?.isConfiguredNow ?? false
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
        ask(thread: thread, question: question, scope: scope, evidence: [])
    }

    /// Text + image grounded ask. `evidence` carries image references
    /// (attachments / material pages / selections) and text context;
    /// `options` bound what else rides the request. With images present
    /// the request goes to the unified multimodal service; without
    /// images this is the original retrieval-grounded text ask.
    func ask(
        thread: CourseAssistantThread,
        question: String,
        scope: Scope,
        evidence: [VisualEvidence],
        options: VisualAskOptions = .all
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
                threadID: threadID, question: trimmed, scope: effectiveScope,
                evidence: evidence, options: options
            )
            self?.tasks[threadID] = nil
        }
    }

    private func run(
        threadID: UUID,
        question: String,
        scope: Scope,
        evidence: [VisualEvidence],
        options: VisualAskOptions
    ) async {
        let imageEvidence = evidence.filter { $0.kind.isImageKind }
        let isVisual = !imageEvidence.isEmpty
        stageByThread[threadID] = isVisual ? .preparingImages : .retrieving
        defer { stageByThread[threadID] = nil }

        // The user message is durable from the start; a failed answer
        // never loses the question (or its evidence references).
        _ = try? repository.addAssistantMessage(AssistantMessageDraft(
            threadID: threadID,
            role: .user,
            text: question,
            scopeMaterialID: scope.materialID,
            scopeSessionID: scope.sessionID,
            mode: isVisual ? .visual : .text,
            evidence: isVisual ? evidence : []
        ))

        do {
            // ---- Image preparation (visual asks only) ------------------
            var preparedImages: [VisualAskImagePipeline.PreparedImage] = []
            var imageContext: [VisualAskPrompt.ImageContextLine] = []
            var contextEvidence: [VisualEvidence] = []
            if isVisual {
                guard let imageService = imageServiceProvider(),
                      imageService.isConfiguredNow else {
                    throw AskError.imageModelNotConfigured
                }
                stageByThread[threadID] = .preparingImages
                let sources = imageEvidence.compactMap {
                    VisualAskEvidenceLoader.imageSource(for: $0, repository: repository)
                }
                guard !sources.isEmpty else {
                    throw VisualAskImagePipeline.PrepareError.emptyImage
                }
                // Bounded re-encode off the main actor; the request bytes
                // exist for the request lifecycle only.
                preparedImages = try await Task.detached(priority: .userInitiated) {
                    try VisualAskImagePipeline.prepare(sources)
                }.value
                imageContext = VisualAskEvidenceLoader.imageContextLines(
                    for: evidence, repository: repository
                )
                contextEvidence = textContextEvidence(for: evidence)
            } else {
                guard let service = textServiceProvider(), service.isConfiguredNow else {
                    throw AskError.notConfigured
                }
            }

            // ---- Retrieval (local) --------------------------------------
            var hits: [CourseAssistantRetriever.ScoredChunk] = []
            if options.includeRetrieval {
                stageByThread[threadID] = .retrieving
                let snapshots = buildSourceSnapshots(scope: scope, options: options)
                let retrievalTask = Task.detached(priority: .userInitiated) {
                    CourseAssistantRetriever.search(
                        query: question, chunks: snapshots, limit: Self.sourceLimit
                    )
                }
                hits = await retrievalTask.value
            }

            // Neither images nor retrievable text: the honest answer, NO
            // model request.
            if preparedImages.isEmpty && hits.isEmpty {
                stageByThread[threadID] = .saving
                _ = try repository.addAssistantMessage(AssistantMessageDraft(
                    threadID: threadID,
                    role: .assistant,
                    text: CourseAssistantPrompt.noEvidenceAnswer,
                    scopeMaterialID: scope.materialID,
                    scopeSessionID: scope.sessionID
                ))
                return
            }

            // ---- Model request over the SELECTED material only ----------
            stageByThread[threadID] = .asking
            let history = recentHistory(threadID: threadID, excluding: question)
            let answerText: String
            var citations: [AssistantMessageCitation] = []
            var visualAnswer: VisualAnswer?
            var answerModel: String?
            if isVisual {
                let sources = hits.map { hit in
                    VisualAskPrompt.SourceLine(
                        number: hit.number,
                        label: hit.chunk.label,
                        text: excerpt(hit.chunk.text, question: question)
                    )
                }
                let prompt = VisualAskPrompt.userPrompt(
                    question: question,
                    imageCount: preparedImages.count,
                    imageContext: imageContext,
                    sources: sources,
                    history: history
                )
                guard let imageService = imageServiceProvider() else {
                    throw AskError.imageModelNotConfigured
                }
                let raw = try await imageService.complete(
                    systemPrompt: VisualAskPrompt.systemPrompt(),
                    userPrompt: prompt,
                    images: preparedImages.map(\.payload),
                    maxTokens: 2_400
                )
                // [n] markers validate against the retrieval snapshot;
                // 图片 citations validate against the evidence list.
                let cleaned: String
                if hits.isEmpty {
                    cleaned = Self.stripAllMarkers(raw)
                } else {
                    let resolved = Self.resolveCitations(raw, hits: hits)
                    cleaned = resolved.text
                    citations = resolved.citations
                }
                var parsed = VisualAnswerParser.parse(
                    text: cleaned, evidenceCount: imageEvidence.count
                )
                if (parsed.citations ?? []).isEmpty && citations.isEmpty {
                    parsed.answer = "（此回答未能生成可验证出处）\n\n" + parsed.answer
                }
                visualAnswer = parsed
                answerText = parsed.answer
                answerModel = imageService.modelName
            } else {
                let sources = hits.map { hit in
                    CourseAssistantPrompt.SourceLine(
                        number: hit.number,
                        label: hit.chunk.label,
                        text: excerpt(hit.chunk.text, question: question)
                    )
                }
                let prompt = CourseAssistantPrompt.userPrompt(
                    scope: scope.scopeLabel,
                    sources: sources,
                    history: history,
                    question: question
                )
                guard let service = textServiceProvider() else {
                    throw AskError.notConfigured
                }
                let raw = try await service.complete(
                    systemPrompt: CourseAssistantPrompt.systemPrompt(),
                    userPrompt: prompt,
                    maxTokens: 2_000
                )
                let (text, parsedCitations) = Self.resolveCitations(raw, hits: hits)
                answerText = text
                citations = parsedCitations
            }

            // ---- Save ---------------------------------------------------
            stageByThread[threadID] = .saving
            _ = try repository.addAssistantMessage(AssistantMessageDraft(
                threadID: threadID,
                role: .assistant,
                text: answerText,
                scopeMaterialID: scope.materialID,
                scopeSessionID: scope.sessionID,
                citations: citations,
                mode: isVisual ? .visual : .text,
                evidence: isVisual ? imageEvidence + contextEvidence : [],
                answer: visualAnswer,
                answerModel: answerModel
            ))
        } catch is CancellationError {
            return
        } catch {
            // The failure is saved as a visible answer row — never a
            // silent disappearance of the question.
            let message = (error as? LocalizedError)?.errorDescription
                ?? String(localized: "回答生成失败，请稍后再试。")
            _ = try? repository.addAssistantMessage(AssistantMessageDraft(
                threadID: threadID,
                role: .assistant,
                text: message,
                scopeMaterialID: scope.materialID,
                scopeSessionID: scope.sessionID
            ))
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

    /// Strips every [n] marker (visual asks with no retrieval snapshot:
    /// fabricated numbers are removed instead of validated).
    static func stripAllMarkers(_ text: String) -> String {
        stripMarkers(text)
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
    /// detached search never touches SwiftData models). `options` bounds
    /// what a visual question may pull in (transcript / notes toggles).
    private func buildSourceSnapshots(
        scope: Scope, options: VisualAskOptions = .all
    ) -> [CourseAssistantRetriever.SourceChunk] {
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
            // A link material's content is its URL + the text shared
            // alongside it — retrievable as one chunk (never the page
            // itself: the app does not fetch web pages).
            if material.isLink {
                let linkText = [material.sourceURL, material.sharedText]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                if !linkText.isEmpty {
                    chunks.append(.init(
                        kind: .materialPage,
                        label: "\(materialLabel) · 链接",
                        text: linkText,
                        materialID: material.id,
                        pageNumber: nil
                    ))
                }
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
            appendSessionChunks(
                session: session,
                includeTranscript: options.includeTranscript,
                includeNotes: options.includeNotes,
                into: &chunks
            )
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
        session: ClassroomSession,
        includeTranscript: Bool = true,
        includeNotes: Bool = true,
        into chunks: inout [CourseAssistantRetriever.SourceChunk]
    ) {
        let sessionLabel = session.title
        if includeTranscript {
            let entries = (try? repository.entries(for: session)) ?? []
            let corrections = (try? repository.corrections(forSessionID: session.id)) ?? []
            let correctionsByEntry = Dictionary(
                corrections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
            )
            // Effective text is resolved UP FRONT into plain strings: the
            // correction model objects then never cross into any closure
            // (Swift 6's exclusive-access and sending checks are happiest
            // with precomputed Sendable values).
            let effectiveEntries: [(entry: TranscriptEntry, text: String, cost: Int)] = entries.map { entry in
                let correction = correctionsByEntry[entry.id]
                let russian = entry.effectiveRussianText(correction: correction)
                let chinese = entry.effectiveChineseText(correction: correction) ?? ""
                let text = chinese.isEmpty ? russian : "\(russian)\n\(chinese)"
                return (entry, text, russian.count + chinese.count)
            }
            // Group adjacent entries into ~600-char chunks — a citation lands
            // on the FIRST entry of its group (jump target), the group text
            // is all four entries' effective text.
            var groupEntries: [(entry: TranscriptEntry, text: String)] = []
            var groupChars = 0
            func flushGroup() {
                guard let first = groupEntries.first else { return }
                let text = groupEntries.map(\.text).joined(separator: "\n")
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    groupEntries = []
                    groupChars = 0
                    return
                }
                chunks.append(.init(
                    kind: .transcript,
                    label: "\(sessionLabel) · \(TranscriptExporter.mmss(first.entry.startOffset))",
                    text: text,
                    sessionID: session.id,
                    entryID: first.entry.id
                ))
                groupEntries = []
                groupChars = 0
            }
            for effective in effectiveEntries {
                if !groupEntries.isEmpty && groupChars + effective.cost > 600 {
                    flushGroup()
                }
                groupEntries.append((effective.entry, effective.text))
                groupChars += effective.cost
            }
            flushGroup()
        }

        // Notes.
        if includeNotes {
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

    /// Snapshots the text-context evidence (existing OCR / structured
    /// analysis of the turn's image evidence) as recoverable evidence
    /// rows — the answer's 图片 chips and the learning loop can cite
    /// the LOCAL text layers, not just the images.
    private func textContextEvidence(for evidence: [VisualEvidence]) -> [VisualEvidence] {
        var rows: [VisualEvidence] = []
        for item in evidence where item.kind.isImageKind {
            guard let attachment = VisualAskEvidenceLoader.attachmentFor(
                item, repository: repository
            ) else { continue }
            if !attachment.ocrText.isEmpty {
                rows.append(VisualEvidence(
                    kind: .ocr,
                    sourceID: attachment.id,
                    sessionID: attachment.sessionID,
                    courseID: attachment.courseID,
                    title: "图片文字 · \(item.title)",
                    snippet: String(attachment.ocrText.prefix(160))
                ))
            }
            if let analysis = AttachmentAnalysisResult.decode(attachment.analysisJSON),
               !analysis.searchableText.isEmpty {
                rows.append(VisualEvidence(
                    kind: .analysis,
                    sourceID: attachment.id,
                    sessionID: attachment.sessionID,
                    courseID: attachment.courseID,
                    title: "图片分析 · \(item.title)",
                    snippet: String(analysis.searchableText.prefix(160))
                ))
            }
        }
        return rows
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
