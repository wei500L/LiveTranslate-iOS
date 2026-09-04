import SwiftUI

/// Global search tab: one field searching classroom titles plus Chinese and
/// Russian transcript text through the existing repository query, with a
/// per-session match snippet. Debounced, since entry-text search is the
/// expensive path.
struct SearchScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var query = ""
    @State private var appliedQuery = ""
    @State private var results: [SessionHit] = []
    @State private var isLoaded = false
    @State private var isSearching = false
    @State private var debounceTask: Task<Void, Never>?
    @State private var termHits: [GlossaryTerm] = []
    @State private var cardHits: [StudyCard] = []
    @State private var taskHits: [StudyTask] = []
    /// Material hits (title/file name/digest + page-level text).
    @State private var materialHits: [MaterialHit] = []
    /// Assistant-history hits (question/answer text).
    @State private var assistantHits: [(message: CourseAssistantMessage, thread: CourseAssistantThread)] = []
    /// Exam-center hits (exam title/scope/note, topic titles, plan-item
    /// titles/notes, activity notes).
    @State private var examHits: [Exam] = []
    @State private var examTopicHits: [(topic: ExamTopic, examID: UUID)] = []
    @State private var planItemHits: [StudyPlanItem] = []
    @State private var activityHits: [StudyActivity] = []
    @State private var viewingTerm: GlossaryTerm?
    @State private var viewingTask: StudyTask?
    @State private var viewingCard: StudyCard?
    /// Entry id → correction (effective-text snippets in results).
    @State private var correctionsByEntryID: [UUID: TranscriptCorrection] = [:]

    /// One matched session with its best snippet.
    struct SessionHit: Identifiable {
        enum MatchKind {
            case review, note, attachment, transcript, title
        }

        let session: ClassroomSession
        let snippet: String
        let matchKind: MatchKind

        var id: UUID { session.id }
    }

    /// One matched course material with its best snippet (page-level
    /// text, digest or metadata).
    struct MaterialHit: Identifiable {
        let material: CourseMaterial
        let snippet: String
        /// Matched page (nil = digest/metadata match).
        let pageNumber: Int?

        var id: UUID { material.id }
    }

    var body: some View {
        NavigationStack {
            LTPage {
                ScrollView {
                    VStack(alignment: .leading, spacing: LTSpacing.l) {
                        searchField
                        if !appliedQuery.isEmpty && isLoaded {
                            resultHeader
                            learningResultList
                            resultList
                        } else if isLoaded {
                            LTEmptyState(
                                symbol: "magnifyingglass",
                                title: "搜索全部课堂",
                                message: "支持课堂名称、笔记、学习整理、术语、卡片、任务、考试、学习计划、课程资料页文字、问答历史、中文翻译与俄语原文"
                            )
                        }
                    }
                    .padding(.horizontal, LTSpacing.screenPadding)
                    .padding(.top, LTSpacing.s)
                    .padding(.bottom, LTSpacing.xl)
                }
            }
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            isLoaded = true
        }
        .onChange(of: query) { _, newValue in
            searchDidChange(newValue)
        }
        .sheet(item: $viewingTerm) { term in
            NavigationStack {
                TermDetailView(term: term, courses: [])
            }
        }
        .sheet(item: $viewingTask) { task in
            NavigationStack {
                TaskDetailView(task: task, courses: [])
            }
        }
        .sheet(item: $viewingCard) { card in
            NavigationStack {
                CardDetailView(card: card, courses: [])
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: LTSpacing.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(LTColors.textTertiary)
            TextField("课堂名称 / 笔记 / 中文翻译 / 俄语原文", text: $query)
                .font(.subheadline)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if isSearching {
                ProgressView()
                    .controlSize(.small)
            } else if !query.isEmpty {
                Button {
                    query = ""
                    appliedQuery = ""
                    results = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(LTColors.textTertiary)
                }
                .accessibilityLabel(Text("清除搜索"))
            }
        }
        .padding(LTSpacing.m)
        .background(RoundedRectangle(cornerRadius: LTRadius.medium).fill(LTColors.surfacePrimary))
        .overlay(RoundedRectangle(cornerRadius: LTRadius.medium).strokeBorder(LTColors.border, lineWidth: 0.5))
    }

    private var resultHeader: some View {
        let learningCount = termHits.count + cardHits.count + taskHits.count
            + materialHits.count + assistantHits.count
            + examHits.count + examTopicHits.count + planItemHits.count
            + activityHits.count
        let sessionPart = results.isEmpty ? "没有匹配的课堂" : "共 \(results.count) 堂课匹配"
        let learningPart = learningCount > 0 ? " · 学习资料 \(learningCount) 条" : ""
        return Text(sessionPart + learningPart)
            .font(LTTypography.caption)
            .foregroundStyle(LTColors.textTertiary)
    }

    /// Learning-material results: terms, cards, tasks (each with its kind
    /// chip and a real destination).
    @ViewBuilder
    private var learningResultList: some View {
        if !termHits.isEmpty || !cardHits.isEmpty || !taskHits.isEmpty
            || !materialHits.isEmpty || !assistantHits.isEmpty
            || !examHits.isEmpty || !examTopicHits.isEmpty || !planItemHits.isEmpty
            || !activityHits.isEmpty {
            VStack(alignment: .leading, spacing: LTSpacing.s) {
                LTSectionHeader(title: "学习资料")
                VStack(spacing: LTSpacing.xs) {
                    ForEach(materialHits) { hit in
                        NavigationLink {
                            MaterialReaderScreen(materialID: hit.material.id)
                                .environment(environment)
                        } label: {
                            learningRow(
                                symbol: hit.material.format.symbol,
                                tint: LTColors.accentBlue,
                                title: hit.material.title.isEmpty
                                    ? hit.material.originalFileName : hit.material.title,
                                subtitle: hit.snippet,
                                chip: "课程资料"
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(termHits.prefix(5)) { term in
                        Button {
                            viewingTerm = term
                        } label: {
                            learningRow(symbol: "character.book.closed", tint: LTColors.accentGreen, title: term.russian, subtitle: term.chinese, chip: "术语")
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(cardHits.prefix(5)) { card in
                        Button {
                            viewingCard = card
                        } label: {
                            learningRow(symbol: "rectangle.on.rectangle", tint: LTColors.accentCyan, title: card.front, subtitle: card.back, chip: "学习卡片")
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(taskHits.prefix(5)) { task in
                        Button {
                            viewingTask = task
                        } label: {
                            learningRow(symbol: "checklist", tint: LTColors.warning, title: task.title, subtitle: task.detail, chip: "作业任务")
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(assistantHits.prefix(3), id: \.message.id) { hit in
                        NavigationLink {
                            CourseAssistantScreen(
                                courseID: hit.thread.courseID,
                                initialThreadID: hit.thread.id
                            )
                            .environment(environment)
                        } label: {
                            learningRow(
                                symbol: hit.message.assistantMode == .visual
                                    ? "text.viewfinder" : "bubble.left.and.text.bubble.right",
                                tint: hit.message.assistantMode == .visual
                                    ? LTColors.accentCyan : LTColors.accentGreen,
                                title: hit.thread.title,
                                subtitle: hit.message.text,
                                chip: hit.message.assistantMode == .visual
                                    ? "视觉问答 · \(assistantVisualSourceLabel(hit.message))" : "问答"
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(examHits.prefix(4)) { exam in
                        NavigationLink {
                            ExamDetailView(examID: exam.id)
                                .environment(environment)
                        } label: {
                            learningRow(
                                symbol: exam.kind.symbol,
                                tint: LTColors.accentGreen,
                                title: exam.title,
                                subtitle: examSubtitle(exam),
                                chip: "考试 · \(exam.kind.displayName)"
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(examTopicHits.prefix(4), id: \.topic.id) { hit in
                        NavigationLink {
                            ExamDetailView(examID: hit.examID)
                                .environment(environment)
                        } label: {
                            learningRow(
                                symbol: "lightbulb",
                                tint: LTColors.accentCyan,
                                title: hit.topic.title,
                                subtitle: hit.topic.status.displayName,
                                chip: "考试主题"
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(planItemHits.prefix(4)) { item in
                        NavigationLink {
                            StudyPlanDetailView(planID: item.planID)
                                .environment(environment)
                        } label: {
                            learningRow(
                                symbol: item.kind.symbol,
                                tint: LTColors.warning,
                                title: item.title,
                                subtitle: item.itemDate?.formatted(
                                    date: .abbreviated, time: .omitted
                                ) ?? item.status.displayName,
                                chip: "学习计划"
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(activityHits.prefix(3)) { activity in
                        learningRow(
                            symbol: "timer",
                            tint: LTColors.accentCyan,
                            title: "学习记录 · \(activity.note)",
                            subtitle: activity.startedAt.formatted(
                                date: .abbreviated, time: .shortened
                            ),
                            chip: "学习活动"
                        )
                    }
                }
            }
        }
    }

    /// The visual hit's source kind (课堂图片 / 资料图片 / PDF 页) — the
    /// first image evidence of the turn.
    private func assistantVisualSourceLabel(_ message: CourseAssistantMessage) -> String {
        let first = message.visualEvidence.first { $0.kind.isImageKind }
        return first?.kind.displayName ?? "图片"
    }

    private func learningRow(
        symbol: String, tint: Color, title: String, subtitle: String, chip: String
    ) -> some View {
        HStack(spacing: LTSpacing.s) {
            Image(systemName: symbol)
                .font(.subheadline)
                .foregroundStyle(tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(LTColors.textPrimary)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(LTColors.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            StatusChip(text: chip, tint: tint)
        }
        .padding(LTSpacing.m)
        .ltCard()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var resultList: some View {
        if results.isEmpty {
            LTEmptyState(
                symbol: "questionmark.circle",
                title: "换个关键词试试",
                message: "搜索会覆盖课堂名称、笔记、术语、卡片、任务与全部双语文本"
            )
        } else {
            VStack(spacing: LTSpacing.s) {
                ForEach(results) { hit in
                    NavigationLink {
                        SessionDetailView(
                            sessionID: hit.session.id,
                            openReviewOnLoad: hit.matchKind == .review,
                            openAttachmentsOnLoad: hit.matchKind == .attachment
                        )
                    } label: {
                        searchResultRow(hit)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func searchResultRow(_ hit: SessionHit) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: LTSpacing.s) {
                LTIconBadge(
                    symbol: LTIconography.symbol(for: hit.session.title),
                    tint: LTIconography.tint(for: hit.session.title),
                    size: 34
                )
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: LTSpacing.xs) {
                        Text(hit.session.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(LTColors.textPrimary)
                            .lineLimit(1)
                        if hit.matchKind == .note {
                            Label("笔记", systemImage: "pencil.line")
                                .font(LTTypography.timestamp)
                                .foregroundStyle(LTColors.warning.opacity(0.9))
                        }
                        if hit.matchKind == .review {
                            Label("学习整理", systemImage: "sparkles")
                                .font(LTTypography.timestamp)
                                .foregroundStyle(LTColors.accentGreen.opacity(0.9))
                        }
                        if hit.matchKind == .attachment {
                            Label("课堂图片", systemImage: "photo")
                                .font(LTTypography.timestamp)
                                .foregroundStyle(LTColors.accentCyan.opacity(0.9))
                        }
                    }
                    Text("\(Format.date(hit.session.startTime)) · \(Format.clock(hit.session.duration))")
                        .font(LTTypography.timestamp)
                        .foregroundStyle(LTColors.textTertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(LTColors.textTertiary)
            }
            Text(hit.snippet)
                .font(.footnote)
                .foregroundStyle(LTColors.textSecondary)
                .lineLimit(2)
                .padding(.leading, 46)
        }
        .ltCard()
        .accessibilityElement(children: .combine)
    }

    // MARK: - Search logic

    private func searchDidChange(_ newValue: String) {
        debounceTask?.cancel()
        let trimmed = newValue.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            appliedQuery = ""
            results = []
            termHits = []
            cardHits = []
            taskHits = []
            materialHits = []
            assistantHits = []
            examHits = []
            examTopicHits = []
            planItemHits = []
            activityHits = []
            return
        }
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await runSearch(trimmed)
        }
    }

    private func runSearch(_ query: String) async {
        isSearching = true
        defer { isSearching = false }
        // Corrections participate in matching (the user's edited text is
        // what they search for). Session-level matching itself is
        // correction-aware inside the repository.
        correctionsByEntryID = Dictionary(
            ((try? environment.repository.allCorrections()) ?? [])
                .map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        // The repository query already searches titles, both texts and
        // note text.
        let sessions = (try? environment.repository.sessions(matching: query)) ?? []
        results = sessions.map { session in
            let match = bestMatch(for: session, query: query)
            return SessionHit(session: session, snippet: match.snippet, matchKind: match.kind)
        }
        // Learning material: terms (russian/chinese/note), cards
        // (front/back/note), confirmed tasks (title/detail/note).
        termHits = (try? environment.repository.terms(matching: query)) ?? []
        cardHits = (try? environment.repository.cards(matching: query)) ?? []
        taskHits = (try? environment.repository.tasks(matching: query)) ?? []
        // Course materials: page-level text (extracted + OCR) first, then
        // the repository's metadata/digest match.
        materialHits = materialMatches(query)
        // Assistant history (question and answer text).
        assistantHits = (try? environment.repository.assistantMessages(matching: query)) ?? []
        // Exam center: exams (title/scope/note), topics (title/detail),
        // plan items (title/note). Search-note hits ride the activity
        // rows the same way — their note field participates via the
        // repository's matching query.
        examHits = (try? environment.repository.exams(matching: query)) ?? []
        examTopicHits = topicMatches(query)
        planItemHits = (try? environment.repository.studyPlanItems(matching: query)) ?? []
        activityHits = (try? environment.repository.studyActivities(matching: query)) ?? []
        appliedQuery = query
    }

    /// Topic search needs the parent exam id for the jump — a small
    /// in-memory join over the exams the repository returned.
    private func topicMatches(_ query: String) -> [(topic: ExamTopic, examID: UUID)] {
        let exams = (try? environment.repository.exams(courseID: nil, includeCandidates: false)) ?? []
        var hits: [(ExamTopic, UUID)] = []
        let lowered = query.lowercased()
        for exam in exams {
            let topics = (try? environment.repository.examTopics(examID: exam.id)) ?? []
            for topic in topics
            where topic.title.lowercased().contains(lowered)
                || topic.detail.lowercased().contains(lowered) {
                hits.append((topic, exam.id))
            }
        }
        return Array(hits.prefix(6))
    }

    private func examSubtitle(_ exam: Exam) -> String {
        if !exam.scopeText.isEmpty { return exam.scopeText }
        if let date = exam.examDate {
            return date.formatted(date: .abbreviated, time: .omitted)
        }
        return ""
    }

    /// Material matching: page text, digest, title/file name and the
    /// user's page notes — each hit carries a jump target.
    private func materialMatches(_ query: String) -> [MaterialHit] {
        var hits: [MaterialHit] = []
        let pageMatches = (try? environment.repository.materialPages(matching: query)) ?? []
        for (page, material) in pageMatches {
            let snippet = firstMatchingLine(
                [page.extractedText, page.ocrText], query: query
            ) ?? page.effectiveText
            hits.append(MaterialHit(
                material: material,
                snippet: "第 \(page.pageNumber) 页 · \(snippet)",
                pageNumber: page.pageNumber
            ))
        }
        let metadataMatches = (try? environment.repository.materials(matching: query)) ?? []
        for material in metadataMatches where !hits.contains(where: { $0.material.id == material.id }) {
            let digestSnippet = material.digest.map {
                firstMatchingLine([$0.searchableText], query: query)
            } ?? nil
            hits.append(MaterialHit(
                material: material,
                snippet: digestSnippet ?? material.title,
                pageNumber: nil
            ))
        }
        return Array(hits.prefix(8))
    }

    private func firstMatchingLine(_ texts: [String], query: String) -> String? {
        for text in texts {
            for line in text.components(separatedBy: "\n") {
                if line.localizedCaseInsensitiveContains(query) {
                    return line
                }
            }
        }
        return nil
    }

    /// First matching line of one attachment's stored text (title/caption,
    /// OCR, analysis), nil when the image did not match.
    private func attachmentMatch(
        _ attachment: SessionAttachment, query: String
    ) -> String? {
        var candidates: [String] = [attachment.title, attachment.caption]
        if !attachment.ocrText.isEmpty { candidates.append(attachment.ocrText) }
        if let analysis = AttachmentAnalysisResult.decode(attachment.analysisJSON) {
            if let t = analysis.title { candidates.append(t) }
            candidates.append(contentsOf: analysis.visibleText ?? [])
            candidates.append(contentsOf: analysis.formulas ?? [])
            candidates.append(contentsOf: analysis.codeBlocks ?? [])
            candidates.append(contentsOf: analysis.keyPoints ?? [])
            if let e = analysis.explanation { candidates.append(e) }
        }
        return candidates.first {
            !$0.isEmpty && $0.localizedCaseInsensitiveContains(query)
        }
    }

    /// Where a session matched: the study review wins the snippet (the
    /// most distilled form of the classroom), then note text, then the
    /// first matching transcript entry, then the title.
    private func bestMatch(
        for session: ClassroomSession, query: String
    ) -> (snippet: String, kind: SessionHit.MatchKind) {
        if let review = try? environment.repository.studyReview(forSessionID: session.id),
           !review.contentJSON.isEmpty,
           let content = StudyReviewContent.decode(review.contentJSON) {
            if let hit = [content.topic, content.summary]
                .first(where: { $0.localizedCaseInsensitiveContains(query) }) {
                return (hit, .review)
            }
            let itemHit = (content.keyPoints.map(\.text)
                + content.assignments.map(\.text)
                + content.uncertainties.map(\.text))
                .first { $0.localizedCaseInsensitiveContains(query) }
            if let itemHit {
                return (itemHit, .review)
            }
        }
        // Persisted attachment content: titles/captions, local OCR text
        // and the stored analysis — never a live model call.
        let attachments = (try? environment.repository.attachments(forSessionID: session.id)) ?? []
        for attachment in attachments {
            if let hit = attachmentMatch(attachment, query: query) {
                let label = attachment.kind.displayName
                return ("\(label)：\(hit)", .attachment)
            }
        }
        let notes = (try? environment.repository.notes(forSessionID: session.id)) ?? []
        if let note = notes.first(where: { $0.text.localizedCaseInsensitiveContains(query) }) {
            return ("✎ \(note.text)", .note)
        }
        let entries = (try? environment.repository.entries(for: session)) ?? []
        if let hit = entries.first({
            $0.originalText.localizedCaseInsensitiveContains(query)
                || ($0.translatedText ?? "").localizedCaseInsensitiveContains(query)
                || (correctionsByEntryID[$0.id]?.russianText ?? "")
                    .localizedCaseInsensitiveContains(query)
                || (correctionsByEntryID[$0.id]?.chineseText ?? "")
                    .localizedCaseInsensitiveContains(query)
        }) {
            // Effective text (correction first, model fallback).
            let correction = correctionsByEntryID[hit.id]
            let effectiveRussian = hit.effectiveRussianText(correction: correction)
            let effectiveChinese = hit.effectiveChineseText(correction: correction) ?? ""
            let translated = effectiveChinese.isEmpty ? "" : "\(effectiveChinese) · "
            return ("\(translated)\(effectiveRussian)", .transcript)
        }
        return (session.title, .title)
    }
}
