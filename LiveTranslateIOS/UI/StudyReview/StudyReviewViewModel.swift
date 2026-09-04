import SwiftUI
import Observation

/// View model for the study-review page: loads the classroom, its review
/// and entries; drives the generator; applies every edit through the
/// repository (so user changes persist and sync). Views stay reading-only
/// presenters.
@MainActor
@Observable
final class StudyReviewViewModel {
    private var environment: AppEnvironment?
    private(set) var session: ClassroomSession?
    private(set) var review: StudyReview?
    private(set) var entries: [TranscriptEntry] = []
    private(set) var attachments: [SessionAttachment] = []
    /// Entry id → correction (effective-text previews and save flows).
    private(set) var correctionsByEntryID: [UUID: TranscriptCorrection] = [:]
    var isLoaded = false

    // MARK: - Lifecycle

    func attach(_ environment: AppEnvironment) {
        self.environment = environment
    }

    func load(sessionID: UUID) {
        guard let environment else { return }
        let all = (try? environment.repository.sessions(matching: "")) ?? []
        guard let session = all.first(where: { $0.id == sessionID }) else {
            self.session = nil
            review = nil
            entries = []
            attachments = []
            correctionsByEntryID = [:]
            isLoaded = true
            return
        }
        self.session = session
        entries = (try? environment.repository.entries(for: session)) ?? []
        attachments = (try? environment.repository.attachments(forSessionID: sessionID)) ?? []
        let corrections = (try? environment.repository.corrections(forSessionID: sessionID)) ?? []
        correctionsByEntryID = Dictionary(
            corrections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        review = try? environment.repository.studyReview(forSessionID: sessionID)
        reconcileOrphanedGeneration()
        isLoaded = true
    }

    func reload() {
        guard let id = session?.id else { return }
        load(sessionID: id)
    }

    /// An app kill mid-generation leaves a `generating` row with no active
    /// task — convert it into a resumable state instead of a forever
    /// spinner.
    private func reconcileOrphanedGeneration() {
        guard let environment, let review,
              review.status == StudyReviewStatus.generating.rawValue,
              !environment.studyReviewGenerator.isActive(review.id) else { return }
        try? environment.repository.markStudyReviewInterrupted(review)
        self.review = try? environment.repository.studyReview(forSessionID: review.id)
    }

    // MARK: - Derived state

    var content: StudyReviewContent? {
        guard let review, !review.contentJSON.isEmpty else { return nil }
        return StudyReviewContent.decode(review.contentJSON)
    }

    var status: StudyReviewStatus? {
        review.flatMap { StudyReviewStatus(rawValue: $0.status) }
    }

    /// Live pipeline progress (from the environment-owned generator).
    var progress: StudyReviewGenerator.Progress? {
        guard let id = session?.id else { return nil }
        return environment?.studyReviewGenerator.progress(for: id)
    }

    var isServiceConfigured: Bool {
        environment?.studyReviewService.isConfiguredNow ?? false
    }

    /// True when the classroom changed after the last generation (late
    /// translations, new notes) — prompts 重新整理, never auto-regenerates.
    var isStale: Bool {
        guard let session, let review, let sourceUpdatedAt = review.sourceUpdatedAt else {
            return false
        }
        return session.updatedAt > sourceUpdatedAt
    }

    var hasUserEdits: Bool {
        review?.hasUserEdits ?? false
    }

    var generatedAt: Date? {
        review?.generatedAt
    }

    var reviewModel: String {
        review?.reviewModel ?? ""
    }

    var entryCount: Int {
        entries.count
    }

    /// Any AI field present — gates the section rendering.
    var hasReadableContent: Bool {
        guard let content else { return false }
        return !content.topic.isEmpty || !content.summary.isEmpty || !content.outline.isEmpty
            || !content.keyPoints.isEmpty || !content.terms.isEmpty
            || !content.assignments.isEmpty || !content.uncertainties.isEmpty
    }

    // MARK: - Citations

    private var entriesByID: [UUID: TranscriptEntry] {
        Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func entry(for id: UUID) -> TranscriptEntry? {
        entriesByID[id]
    }

    /// Timestamp label for a citation button; "原文已不存在" when the cited
    /// line is gone (kept visible — the review text itself survives).
    func citationLabel(_ entryID: UUID) -> String {
        guard let entry = entriesByID[entryID] else { return "原文已不存在" }
        return TranscriptExporter.mmss(entry.startOffset)
    }

    /// Label for an image citation chip ("图片已不存在" when the image was
    /// deleted — the review text itself survives).
    func attachmentLabel(_ attachmentID: UUID) -> String {
        guard let attachment = attachments.first(where: { $0.id == attachmentID }) else {
            return String(localized: "图片已不存在")
        }
        return attachment.kind.displayName
    }

    /// One-line preview of a cited line (outline citations). Effective
    /// text: the correction when present, else the model output.
    func entryPreview(_ entryID: UUID) -> String? {
        guard let entry = entriesByID[entryID] else { return "原文已不存在" }
        let correction = correctionsByEntryID[entryID]
        let chinese = entry.effectiveChineseText(correction: correction) ?? ""
        let russian = entry.effectiveRussianText(correction: correction)
        return chinese.isEmpty ? String(russian.prefix(60)) : String(chinese.prefix(60))
    }

    // MARK: - Generation

    func generate(resume: Bool) {
        guard let environment, let session else { return }
        let context = classContext()
        let notes = noteTexts()
        let currentEntries = entries
        let materials = attachmentMaterials()
        environment.studyReviewGenerator.generate(
            session: session,
            context: context,
            notes: notes,
            entries: currentEntries,
            attachments: materials,
            resume: resume
        )
    }

    /// Analyzed attachments become prompt material (板书与图片分析);
    /// unanalyzed ones are skipped (the UI surfaces them separately —
    /// images missing analysis never silently degrade the review).
    private func attachmentMaterials() -> [StudyReviewPrompt.AttachmentMaterial] {
        guard let environment, let session else { return [] }
        let analyzed = (try? environment.repository.attachments(forSessionID: session.id)) ?? []
            .filter { $0.analysisStatus == .completed || $0.analysisStatus == .partial }
        return analyzed.enumerated().prefix(12).map { index, attachment in
            let result = AttachmentAnalysisResult.decode(attachment.analysisJSON)
            var digestParts: [String] = []
            if let visible = result?.visibleText, !visible.isEmpty {
                digestParts.append(visible.prefix(4).joined(separator: " / "))
            }
            if let formulas = result?.formulas, !formulas.isEmpty {
                digestParts.append("公式：\(formulas.prefix(3).joined(separator: "；"))")
            }
            if let code = result?.codeBlocks, !code.isEmpty {
                digestParts.append("代码：\(code.prefix(1).joined(separator: "\n").prefix(300))")
            }
            if let points = result?.keyPoints, !points.isEmpty {
                digestParts.append("要点：\(points.prefix(4).joined(separator: "；"))")
            }
            return StudyReviewPrompt.AttachmentMaterial(
                id: attachment.id,
                number: index + 1,
                kindName: attachment.kind.displayName,
                title: attachment.title,
                caption: attachment.caption,
                digest: digestParts.joined(separator: "\n")
            )
        }
    }

    /// Attachments present but not yet analyzed (drives the review UI's
    /// hint to analyze them first).
    var unanalyzedAttachmentCount: Int {
        attachments.filter {
            $0.analysisStatus == .pending || $0.analysisStatus == .failed
        }.count
    }

    var analyzedAttachmentCount: Int {
        attachments.filter {
            $0.analysisStatus == .completed || $0.analysisStatus == .partial
        }.count
    }

    func cancel() {
        guard let id = session?.id else { return }
        environment?.studyReviewGenerator.cancel(id)
    }

    private func classContext() -> StudyReviewPrompt.ClassContext {
        var context = StudyReviewPrompt.ClassContext()
        context.sessionTitle = session?.title ?? ""
        if let courseID = session?.courseID,
           let course = try? environment?.repository.course(id: courseID) {
            context.courseName = course.name
            context.teacherName = course.teacherName
        }
        return context
    }

    private func noteTexts() -> [String] {
        guard let session else { return [] }
        let notes = (try? environment?.repository.notes(forSessionID: session.id)) ?? []
        var texts = notes.map(\.text)
        // Linked course materials ride as EXTRA study material (额外素
        // 材): their digests and page-level text inform the review as
        // reference context — the same standing as the notes, never
        // cited as transcript lines.
        let linkedMaterials = ((try? environment?.repository.materials(courseID: nil)) ?? [])
            .filter { $0.sessionID == session.id }
        for material in linkedMaterials.prefix(3) {
            let title = material.title.isEmpty ? material.originalFileName : material.title
            if let digest = material.digest, !digest.searchableText.isEmpty {
                texts.append("【课程资料 · \(title) 导读】\(digest.searchableText.prefix(1_500))")
            } else {
                let pages = (try? environment?.repository.materialPages(
                    materialID: material.id
                )) ?? []
                let pageText = pages
                    .compactMap { page -> String? in
                        let text = page.effectiveText
                        return text.isEmpty ? nil : "第\(page.pageNumber)页：\(text)"
                    }
                    .prefix(6)
                    .joined(separator: "\n")
                if !pageText.isEmpty {
                    texts.append("【课程资料 · \(title)】\(pageText.prefix(1_500))")
                }
            }
        }
        return texts
    }

    // MARK: - Edits (all persist through the repository)

    /// Applies a mutation to the current content and saves it as the
    /// user's copy.
    private func updateContent(_ mutate: (inout StudyReviewContent) -> Void) {
        guard let environment, let review, var content = content else { return }
        mutate(&content)
        try? environment.repository.applyStudyReviewUserEdits(review, content: content)
        reload()
    }

    func editKeyPoint(_ point: StudyReviewContent.KeyPoint, text: String) {
        updateContent { content in
            if let index = content.keyPoints.firstIndex(where: { $0.id == point.id }) {
                content.keyPoints[index].text = text
            }
        }
    }

    func deleteKeyPoint(_ point: StudyReviewContent.KeyPoint) {
        updateContent { content in
            content.keyPoints.removeAll { $0.id == point.id }
        }
    }

    func editTerm(_ term: StudyReviewContent.TermItem, mergedText: String) {
        updateContent { content in
            if let index = content.terms.firstIndex(where: { $0.id == term.id }) {
                // Merged text: russian / chinese / explanation lines.
                let lines = mergedText
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map(String.init)
                if lines.count >= 2 {
                    content.terms[index].russian = lines[0]
                    content.terms[index].chinese = lines[1]
                }
                if lines.count >= 3 {
                    content.terms[index].explanation = lines[2...].joined(separator: "\n")
                }
            }
        }
    }

    func deleteTerm(_ term: StudyReviewContent.TermItem) {
        updateContent { content in
            content.terms.removeAll { $0.id == term.id }
        }
    }

    func editAssignment(_ assignment: StudyReviewContent.AssignmentItem, text: String) {
        updateContent { content in
            if let index = content.assignments.firstIndex(where: { $0.id == assignment.id }) {
                content.assignments[index].text = text
            }
        }
    }

    func deleteAssignment(_ assignment: StudyReviewContent.AssignmentItem) {
        updateContent { content in
            content.assignments.removeAll { $0.id == assignment.id }
        }
    }

    func editUncertainty(_ item: StudyReviewContent.UncertaintyItem, text: String) {
        updateContent { content in
            if let index = content.uncertainties.firstIndex(where: { $0.id == item.id }) {
                content.uncertainties[index].text = text
            }
        }
    }

    func deleteUncertainty(_ item: StudyReviewContent.UncertaintyItem) {
        updateContent { content in
            content.uncertainties.removeAll { $0.id == item.id }
        }
    }

    func editOutlineNode(_ node: StudyReviewContent.OutlineNode, mergedText: String) {
        updateContent { content in
            if let index = findOutlineNode(&content.outline, id: node.id) {
                let lines = mergedText
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map(String.init)
                content.outline[index].title = lines.first ?? node.title
                if lines.count > 1 {
                    content.outline[index].detail = lines.dropFirst()
                        .joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
    }

    func deleteOutlineNode(_ node: StudyReviewContent.OutlineNode) {
        updateContent { content in
            removeOutlineNode(&content.outline, id: node.id)
        }
    }

    func addUserAddition(_ text: String) {
        updateContent { content in
            content.userNotes.append(.init(text: text))
        }
    }

    func editUserAddition(_ addition: StudyReviewContent.UserAddition, text: String) {
        updateContent { content in
            if let index = content.userNotes.firstIndex(where: { $0.id == addition.id }) {
                content.userNotes[index].text = text
            }
        }
    }

    func deleteUserAddition(_ addition: StudyReviewContent.UserAddition) {
        updateContent { content in
            content.userNotes.removeAll { $0.id == addition.id }
        }
    }

    private func findOutlineNode(
        _ nodes: inout [StudyReviewContent.OutlineNode], id: UUID
    ) -> Int? {
        if let index = nodes.firstIndex(where: { $0.id == id }) {
            return index
        }
        for index in nodes.indices {
            if findOutlineNode(&nodes[index].children, id: id) != nil {
                return index
            }
        }
        return nil
    }

    private func removeOutlineNode(
        _ nodes: inout [StudyReviewContent.OutlineNode], id: UUID
    ) {
        nodes.removeAll { $0.id == id }
        for index in nodes.indices {
            removeOutlineNode(&nodes[index].children, id: id)
        }
    }

    // MARK: - Delete / export

    func deleteReview() {
        guard let environment, let review else { return }
        try? environment.repository.deleteStudyReview(review)
        reload()
    }

    /// Standalone review export (Markdown with the review only).
    func exportReviewURL() async -> URL? {
        guard let session, let environment, let content else { return nil }
        let data = SessionExport.payload(
            session: session,
            entries: [],
            notes: [],
            scope: .reviewOnly,
            review: content,
            fallbackBackend: environment.settings.preferredBackend
        )
        return await SessionExport.writeSnapshot(data: data, format: .markdown)
    }
}
