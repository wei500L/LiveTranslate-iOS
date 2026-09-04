import SwiftUI
import UIKit

/// The reading-style card for a visual Q&A answer: the main answer,
/// steps, formulas (LaTeX kept verbatim, copyable), visible text,
/// uncertainties, suggested follow-ups, evidence chips (jumpable) and
/// retrieval citations — plus the learning-loop actions (note / term /
/// card / task / 复习整理 / copy / share). Long Chinese/Russian text
/// stays selectable. Every action writes through the repository — no
/// toast-only buttons.
struct VisualAnswerCard: View {
    @Environment(AppEnvironment.self) private var environment
    let message: CourseAssistantMessage
    let answer: VisualAnswer
    let evidence: [VisualEvidence]
    let citations: [AssistantMessageCitation]
    /// Suggested-action taps prefill the input (never auto-send).
    var onFollowUp: (String) -> Void = { _ in }

    @State private var termDraftBox: TermDraftBox?
    @State private var cardDraftBox: CardDraftBox?
    @State private var taskDraftBox: TaskDraftBox?
    @State private var shareItem: SharedFile?
    @State private var confirmCaptionAttachmentID: UUID?
    @State private var confirmFormulaAttachmentID: UUID?
    @State private var savedNote = false
    @State private var savedDigestNote = false
    @State private var savedAnnotation = false

    struct TermDraftBox: Identifiable {
        let id = UUID()
        let draft: TermDraft
    }

    struct CardDraftBox: Identifiable {
        let id = UUID()
        let draft: CardDraft
    }

    struct TaskDraftBox: Identifiable {
        let id = UUID()
        let draft: TaskDraft
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            if !answer.isPlainText || !answer.answer.isEmpty {
                Text(answer.answer)
                    .font(Font.subheadline)
                    .foregroundStyle(LTColors.textPrimary)
                    .textSelection(.enabled)
                    .lineSpacing(4)
            }

            if let steps = answer.steps, !steps.isEmpty {
                section("推导步骤") {
                    VStack(alignment: .leading, spacing: LTSpacing.xs) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: LTSpacing.xs) {
                                Text("\(index + 1).")
                                    .font(LTTypography.caption)
                                    .foregroundStyle(LTColors.textTertiary)
                                Text(step)
                                    .font(Font.subheadline)
                                    .foregroundStyle(LTColors.textSecondary)
                                    .textSelection(.enabled)
                                    .lineSpacing(3)
                            }
                        }
                    }
                }
            }

            if let formulas = answer.formulas, !formulas.isEmpty {
                section("公式") {
                    VStack(alignment: .leading, spacing: LTSpacing.xs) {
                        ForEach(Array(formulas.enumerated()), id: \.offset) { _, formula in
                            HStack(alignment: .top, spacing: LTSpacing.xs) {
                                Text(formula)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundStyle(LTColors.textSecondary)
                                    .textSelection(.enabled)
                                Spacer(minLength: LTSpacing.xs)
                                Button {
                                    UIPasteboard.general.string = formula
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: 11))
                                        .foregroundStyle(LTColors.textTertiary)
                                }
                                .accessibilityLabel(Text("复制公式"))
                            }
                        }
                    }
                }
            }

            if let visible = answer.visibleText, !visible.isEmpty {
                section("图片中的文字") {
                    VStack(alignment: .leading, spacing: LTSpacing.xs) {
                        ForEach(visible, id: \.self) { line in
                            Text(line)
                                .font(Font.subheadline)
                                .foregroundStyle(LTColors.textSecondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            if let uncertainties = answer.uncertainties, !uncertainties.isEmpty {
                section("不确定的内容") {
                    VStack(alignment: .leading, spacing: LTSpacing.xxs) {
                        ForEach(uncertainties, id: \.self) { item in
                            Label(item, systemImage: "exclamationmark.triangle")
                                .font(LTTypography.caption)
                                .foregroundStyle(LTColors.warning)
                        }
                    }
                }
            }

            if let actions = answer.suggestedActions, !actions.isEmpty {
                section("可以继续") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: LTSpacing.xs) {
                            ForEach(actions, id: \.self) { action in
                                Button(action) {
                                    onFollowUp(action)
                                }
                                .font(LTTypography.button)
                                .padding(.horizontal, LTSpacing.m)
                                .padding(.vertical, LTSpacing.xxs)
                                .background(LTColors.accentGreen.opacity(0.12))
                                .clipShape(Capsule())
                            }
                        }
                    }
                }
            }

            if !evidence.isEmpty {
                section("图片来源") {
                    VStack(alignment: .leading, spacing: LTSpacing.xxs) {
                        ForEach(Array(evidence.enumerated()), id: \.element.id) { index, item in
                            if item.kind.isImageKind {
                                VisualEvidenceChip(evidence: item, order: index, compact: true)
                            }
                        }
                    }
                }
            }

            if !citations.isEmpty {
                section("文字来源") {
                    VStack(alignment: .leading, spacing: LTSpacing.xxs) {
                        ForEach(citations) { citation in
                            citationLink(citation)
                        }
                    }
                }
            }

            if !message.answerModel.isEmpty {
                Text("回答模型：\(message.answerModel)")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textTertiary)
            }

            actionBar
        }
        .padding(LTSpacing.m)
        .background(LTColors.surfacePrimary.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: LTRadius.medium))
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $termDraftBox) { box in
            TermSaveSheet(draft: box.draft)
        }
        .sheet(item: $cardDraftBox) { box in
            CardSaveSheet(draft: box.draft)
        }
        .sheet(item: $taskDraftBox) { box in
            TaskSaveSheet(draft: box.draft, editingTask: nil)
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .confirmationDialog(
            "将这条回答设为图片说明？",
            isPresented: Binding(
                get: { confirmCaptionAttachmentID != nil },
                set: { if !$0 { confirmCaptionAttachmentID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("设为图片说明") {
                if let id = confirmCaptionAttachmentID { applyCaption(to: id) }
                confirmCaptionAttachmentID = nil
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会覆盖该图片当前的说明文字（可在编辑信息里修改）。")
        }
        .confirmationDialog(
            "把回答里的公式加入图片分析结果？",
            isPresented: Binding(
                get: { confirmFormulaAttachmentID != nil },
                set: { if !$0 { confirmFormulaAttachmentID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("加入公式") {
                if let id = confirmFormulaAttachmentID { appendFormulas(to: id) }
                confirmFormulaAttachmentID = nil
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会追加到该图片已有分析结果的公式列表，不影响 OCR 和说明。")
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.xxs) {
            Text(title)
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.textTertiary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Actions

    private var actionBar: some View {
        HStack(spacing: LTSpacing.s) {
            Button {
                UIPasteboard.general.string = answer.searchableText
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
            .buttonStyle(LTSecondaryButtonStyle())

            Button {
                shareAnswer()
            } label: {
                Label("分享", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(LTSecondaryButtonStyle())

            Menu {
                if message.scopeSessionID != nil {
                    Button {
                        saveSessionNote()
                    } label: {
                        Label(
                            savedNote ? "已保存为课堂笔记" : "保存为课堂笔记",
                            systemImage: "note.text"
                        )
                    }
                    .disabled(savedNote)
                    Button {
                        appendToStudyReview()
                    } label: {
                        Label(
                            savedDigestNote ? "已加入学习整理" : "加入本课学习整理",
                            systemImage: "square.stack.3d.up"
                        )
                    }
                    .disabled(savedDigestNote)
                }
                if annotationTarget != nil {
                    Button {
                        saveMaterialNote()
                    } label: {
                        Label(
                            savedAnnotation ? "已保存为资料页笔记" : "保存为资料页笔记",
                            systemImage: "note.text.badge.plus"
                        )
                    }
                    .disabled(savedAnnotation)
                }
                Button {
                    termDraftBox = TermDraftBox(draft: termDraft)
                } label: {
                    Label("保存为术语", systemImage: "character.book.closed")
                }
                Button {
                    cardDraftBox = CardDraftBox(draft: cardDraft)
                } label: {
                    Label("做成复习卡", systemImage: "rectangle.stack")
                }
                Button {
                    taskDraftBox = TaskDraftBox(draft: taskDraft)
                } label: {
                    Label("创建任务", systemImage: "checklist")
                }
                if let attachment = primaryAttachment {
                    Button {
                        confirmCaptionAttachmentID = attachment.id
                    } label: {
                        Label("将回答设为图片说明", systemImage: "text.bubble")
                    }
                    if let formulas = answer.formulas, !formulas.isEmpty {
                        Button {
                            confirmFormulaAttachmentID = attachment.id
                        } label: {
                            Label("将公式加入图片分析", systemImage: "function")
                        }
                    }
                }
            } label: {
                Label("保存到学习", systemImage: "graduationcap")
            }
        }
        .font(LTTypography.button)
    }

    // MARK: - Action implementations (all through the repository)

    /// The evidence's first attachment (drives 设为图片说明 / 公式加入).
    @MainActor
    private var primaryAttachment: SessionAttachment? {
        for item in evidence where item.kind.isImageKind {
            if let attachment = VisualAskEvidenceLoader.attachmentFor(item, repository: environment.repository) {
                return attachment
            }
        }
        return nil
    }

    /// Annotation target: a material page evidence, else the scoped
    /// material's first page.
    @MainActor
    private var annotationTarget: (materialID: UUID, pageNumber: Int)? {
        for item in evidence {
            if item.kind == .materialPage, let materialID = item.materialID, let page = item.pageNumber {
                return (materialID, page)
            }
        }
        if let materialID = message.scopeMaterialID,
           let material = ((try? environment.repository.material(id: materialID)) ?? nil),
           material.pageCount > 0 {
            return (materialID, 1)
        }
        return nil
    }
    private func saveSessionNote() {
        guard let sessionID = message.scopeSessionID else { return }
        let text = noteText()
        _ = try? environment.repository.addNote(
            NoteDraft(text: text, anchorEntryID: nil, timeOffset: nil),
            toSessionID: sessionID
        )
        savedNote = true
    }

    private func appendToStudyReview() {
        guard let sessionID = message.scopeSessionID,
              let review = try? environment.repository.studyReview(forSessionID: sessionID),
              var content = StudyReviewContent.decode(review.contentJSON) else { return }
        content.userNotes.append(StudyReviewContent.UserAddition(text: noteText()))
        try? environment.repository.applyStudyReviewUserEdits(review, content: content)
        savedDigestNote = true
    }

    private func saveMaterialNote() {
        guard let target = annotationTarget else { return }
        _ = try? environment.repository.addMaterialAnnotation(
            MaterialAnnotationDraft(
                materialID: target.materialID,
                pageNumber: target.pageNumber,
                kind: .note,
                text: noteText()
            )
        )
        savedAnnotation = true
    }

    private func noteText() -> String {
        var text = answer.answer
        if let steps = answer.steps, !steps.isEmpty {
            text += "\n\n" + steps.enumerated()
                .map { "\($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
        }
        if let formulas = answer.formulas, !formulas.isEmpty {
            text += "\n\n公式：" + formulas.joined(separator: "；")
        }
        return text
    }

    @MainActor
    private var termDraft: TermDraft {
        TermDraft(
            russian: "",
            chinese: "",
            explanation: String(answer.answer.prefix(600)),
            courseID: message.threadCourseID(environment: environment),
            sessionID: message.scopeSessionID,
            sourceAttachmentID: evidence.first { $0.kind == .sessionAttachment }?.sourceID,
            sourceMaterialID: message.scopeMaterialID,
            sourceMaterialPage: message.scopePageNumber ?? 0
        )
    }

    @MainActor
    private var cardDraft: CardDraft {
        CardDraft(
            front: cardFront,
            back: String(answer.answer.prefix(800)),
            type: (answer.formulas?.isEmpty == false) ? .formula : .qa,
            courseID: message.threadCourseID(environment: environment),
            sessionID: message.scopeSessionID,
            sourceAttachmentID: evidence.first { $0.kind == .sessionAttachment }?.sourceID,
            sourceMaterialID: message.scopeMaterialID,
            sourceMaterialPage: message.scopePageNumber ?? 0,
            origin: .ai
        )
    }

    @MainActor
    private var cardFront: String {
        if let question = evidenceQuestion {
            return String(question.prefix(120))
        }
        return "图片问答"
    }

    /// The user question of this answer turn (the previous user message
    /// in the thread).
    @MainActor
    private var evidenceQuestion: String? {
        let messages = (try? environment.repository.assistantMessages(threadID: message.threadID)) ?? []
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return nil }
        let previous = messages[..<index].last { $0.role == .user }
        return previous?.text
    }

    @MainActor
    private var taskDraft: TaskDraft {
        let suggested = answer.suggestedActions?.first
        let title = suggested.map { String($0.prefix(80)) }
            ?? cardFront
        return TaskDraft(
            title: title,
            detail: String(answer.answer.prefix(400)),
            status: .pendingConfirm,
            origin: .ai,
            uncertainty: "来自图片问答的回答，确认后生效",
            courseID: message.threadCourseID(environment: environment),
            sessionID: message.scopeSessionID,
            sourceAttachmentID: evidence.first { $0.kind == .sessionAttachment }?.sourceID,
            sourceMaterialID: message.scopeMaterialID,
            sourceMaterialPage: message.scopePageNumber ?? 0
        )
    }

    private func applyCaption(to attachmentID: UUID) {
        guard let attachment = ((try? environment.repository.attachment(id: attachmentID)) ?? nil) else { return }
        try? environment.repository.updateAttachmentCaption(
            attachment, caption: String(answer.answer.prefix(2_000))
        )
    }

    private func appendFormulas(to attachmentID: UUID) {
        guard let attachment = ((try? environment.repository.attachment(id: attachmentID)) ?? nil),
              var result = AttachmentAnalysisResult.decode(attachment.analysisJSON) else { return }
        let existing = result.formulas ?? []
        let additions = (answer.formulas ?? []).filter { !existing.contains($0) }
        guard !additions.isEmpty else { return }
        result.formulas = existing + additions
        try? environment.repository.completeAttachmentAnalysis(
            attachment, result: result, status: attachment.analysisStatus == .failed ? .partial : attachment.analysisStatus
        )
    }

    private func shareAnswer() {
        var text = answer.searchableText
        if !citations.isEmpty {
            text += "\n\n来源：" + citations.map(\.label).joined(separator: "；")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("图片问答回答.md")
        try? text.data(using: .utf8)?.write(to: url)
        shareItem = SharedFile(url: url)
    }

    // MARK: - Citations

    @ViewBuilder
    private func citationLink(_ citation: AssistantMessageCitation) -> some View {
        Group {
            if citation.kind == .materialPage, let materialID = citation.materialID {
                NavigationLink {
                    MaterialReaderScreen(materialID: materialID)
                        .environment(environment)
                } label: {
                    citationLabel(citation)
                }
                .buttonStyle(.plain)
            } else if let sessionID = citation.sessionID {
                NavigationLink {
                    SessionDetailView(sessionID: sessionID)
                        .environment(environment)
                } label: {
                    citationLabel(citation)
                }
                .buttonStyle(.plain)
            } else {
                citationLabel(citation)
            }
        }
    }

    private func citationLabel(_ citation: AssistantMessageCitation) -> some View {
        HStack(alignment: .top, spacing: LTSpacing.xs) {
            Image(systemName: "link")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(LTColors.accentCyan)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(citation.label)
                    .font(LTTypography.button)
                    .foregroundStyle(LTColors.accentCyan)
                if !citation.snippet.isEmpty {
                    Text(citation.snippet)
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textTertiary)
                        .lineLimit(2)
                }
            }
        }
        .accessibilityLabel(Text("来源：\(citation.label)"))
    }
}

// MARK: - Message helpers

extension CourseAssistantMessage {
    /// The owning thread's course (source attribution for learning rows).
    @MainActor
    func threadCourseID(environment: AppEnvironment) -> UUID? {
        let threads = (try? environment.repository.assistantThreads(courseID: nil)) ?? []
        return threads.first { $0.id == threadID }?.courseID
    }

    /// Scope page number (from the evidence snapshot — the page the
    /// question was about).
    var scopePageNumber: Int? {
        visualEvidence.first { $0.pageNumber != nil }?.pageNumber
    }
}
