import SwiftUI

/// 考试范围与知识主题管理 — manual topic creation + AI topic suggestion
/// (from the exam's scope text / the course's material digests, via the
/// text model). AI suggestions require explicit confirmation (每条建议
/// 都要点确认才进入范围); the source rides along in TopicSource.
struct ExamTopicsEditor: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let examID: UUID

    @State private var topics: [ExamTopic] = []
    @State private var newTitle = ""
    @State private var newImportance: ExamTopicImportance = .normal
    @State private var suggestions: [String] = []
    @State private var isSuggesting = false
    @State private var suggestError: String?

    var body: some View {
        LTPage {
            ScrollView {
                VStack(alignment: .leading, spacing: LTSpacing.l) {
                    addCard
                    if !suggestions.isEmpty {
                        suggestionCard
                    }
                    topicList
                }
                .padding(.horizontal, LTSpacing.screenPadding)
                .padding(.top, LTSpacing.s)
                .padding(.bottom, LTSpacing.xl)
            }
        }
        .navigationTitle("考试范围与主题")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
        .onAppear { reload() }
    }

    private var exam: Exam? {
        try? environment.repository.exam(id: examID)
    }

    // MARK: - Manual add

    private var addCard: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            LTSectionHeader(title: "添加主题")
            HStack(spacing: LTSpacing.s) {
                TextField("如：傅里叶变换", text: $newTitle)
                    .font(.subheadline)
                    .textFieldStyle(.roundedBorder)
                    .environment(\.colorScheme, .dark)
                Picker("重要程度", selection: $newImportance) {
                    ForEach(ExamTopicImportance.allCases) { importance in
                        Text(importance.displayName).tag(importance)
                    }
                }
                .labelsHidden()
                Button {
                    addTopic()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(LTColors.accentGreen)
                }
                .buttonStyle(.plain)
                .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityLabel(Text("添加主题"))
            }
            Button {
                Task { await suggestTopics() }
            } label: {
                Label(
                    isSuggesting ? "正在整理建议…" : "从考试范围和资料建议主题",
                    systemImage: "sparkles"
                )
                .font(.footnote.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(
                environment.studyReviewService.isConfiguredNow
                    ? LTColors.accentCyan : LTColors.textTertiary
            )
            .disabled(isSuggesting || !environment.studyReviewService.isConfiguredNow)
        }
        .ltCard()
    }

    // MARK: - AI suggestions (confirm one by one)

    private var suggestionCard: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            LTSectionHeader(title: "AI 建议（需逐条确认）")
            if let suggestError {
                Text(suggestError)
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.warning)
            }
            VStack(spacing: LTSpacing.xs) {
                ForEach(suggestions, id: \.self) { suggestion in
                    HStack(spacing: LTSpacing.s) {
                        Text(suggestion)
                            .font(.subheadline)
                            .foregroundStyle(LTColors.textPrimary)
                            .lineLimit(2)
                        Spacer()
                        Button {
                            acceptSuggestion(suggestion)
                        } label: {
                            Image(systemName: "plus.circle")
                                .foregroundStyle(LTColors.accentGreen)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("采纳该建议"))
                        Button {
                            suggestions.removeAll { $0 == suggestion }
                        } label: {
                            Image(systemName: "xmark.circle")
                                .foregroundStyle(LTColors.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("忽略该建议"))
                    }
                    .padding(LTSpacing.s)
                    .background(RoundedRectangle(cornerRadius: LTRadius.small).fill(LTColors.surfacePrimary.opacity(0.6)))
                }
            }
        }
        .ltCard()
    }

    private var topicList: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            LTSectionHeader(title: "当前主题（\(topics.count)）")
            if topics.isEmpty {
                Text("还没有主题。学习计划会围绕这些主题安排。")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textTertiary)
            } else {
                VStack(spacing: LTSpacing.xs) {
                    ForEach(topics) { topic in
                        row(topic)
                    }
                }
            }
        }
        .ltCard()
    }

    private func row(_ topic: ExamTopic) -> some View {
        HStack(spacing: LTSpacing.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(topic.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(LTColors.textPrimary)
                Text("\(topic.importance.displayName) · \(topic.status.displayName)")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textTertiary)
            }
            Spacer()
            Menu {
                ForEach(ExamTopicImportance.allCases) { importance in
                    Button(importance.displayName) {
                        try? environment.repository.updateExamTopic(
                            topic,
                            with: ExamTopicDraft(
                                examID: topic.examID,
                                title: topic.title,
                                detail: topic.detail,
                                importance: importance,
                                selfRating: topic.selfRating,
                                status: topic.status,
                                source: topic.source,
                                userEdited: true
                            )
                        )
                        reload()
                    }
                }
            } label: {
                StatusChip(text: topic.importance.displayName, tint: LTColors.textSecondary)
            }
            Button(role: .destructive) {
                try? environment.repository.deleteExamTopic(topic)
                reload()
            } label: {
                Image(systemName: "trash")
                    .font(.footnote)
                    .foregroundStyle(LTColors.destructive)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("删除主题"))
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func addTopic() {
        guard let exam else { return }
        let title = newTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        _ = try? environment.repository.addExamTopic(ExamTopicDraft(
            examID: exam.id,
            title: title,
            importance: newImportance,
            source: TopicSource(kind: .user, sourceID: nil, originalText: title),
            userEdited: true
        ))
        newTitle = ""
        reload()
    }

    private func acceptSuggestion(_ suggestion: String) {
        guard let exam else { return }
        _ = try? environment.repository.addExamTopic(ExamTopicDraft(
            examID: exam.id,
            title: suggestion,
            source: TopicSource(kind: .scope, sourceID: nil, originalText: suggestion),
            userEdited: true
        ))
        suggestions.removeAll { $0 == suggestion }
        reload()
    }

    /// AI topic suggestion: the exam's scope + the course's material
    /// digests go in; a plain topic-name list comes out. Confirm-first —
    /// nothing is written until the user taps ＋.
    private func suggestTopics() async {
        guard let exam else { return }
        isSuggesting = true
        suggestError = nil
        defer { isSuggesting = false }
        do {
            var context = "考试：\(exam.title)\n"
            if !exam.scopeText.isEmpty { context += "考试范围：\(exam.scopeText)\n" }
            if let courseID = exam.courseID {
                let materials = (try? environment.repository.materials(courseID: courseID)) ?? []
                for material in materials.prefix(3) {
                    if let digest = material.digest {
                        // The digest's outline titles are the material's
                        // real chapter/topic structure.
                        let outlineTitles = (digest.outline ?? []).map(\.title)
                            .filter { !$0.isEmpty }.prefix(10).joined(separator: "；")
                        let concepts = (digest.keyConcepts ?? []).prefix(8)
                            .compactMap(\.text).joined(separator: "；")
                        var parts: [String] = []
                        if !outlineTitles.isEmpty { parts.append(outlineTitles) }
                        if !concepts.isEmpty { parts.append(concepts) }
                        if !parts.isEmpty {
                            context += "资料《\(material.title)》要点：\(parts.joined(separator: "；"))\n"
                        }
                    }
                }
            }
            let systemPrompt = """
            你是一名备考助手。用户会给你一场考试的范围和相关课程资料要点。\
            请列出这场考试最值得复习的知识主题（8 个以内），每个主题 12 字以内的中文名称。\
            只输出 JSON：{"topics":["主题1","主题2"]}，不要输出其他文本。\
            不要编造范围里没有的主题。
            """
            let text = try await environment.studyReviewService.complete(
                systemPrompt: systemPrompt,
                userPrompt: context,
                maxTokens: 600
            )
            guard let payload = AttachmentAnalysisParser.jsonPayload(from: text),
                  let data = payload.data(using: .utf8),
                  let wire = try? JSONDecoder().decode(WireTopics.self, from: data)
            else {
                suggestError = "无法解析模型输出"
                return
            }
            let existing = Set(topics.map(\.title))
            suggestions = wire.topics.filter { !existing.contains($0) }
            if suggestions.isEmpty {
                suggestError = "没有新的主题建议"
            }
        } catch {
            suggestError = error.localizedDescription
        }
    }

    private struct WireTopics: Decodable {
        var topics: [String]
    }

    private func reload() {
        topics = (try? environment.repository.examTopics(examID: examID)) ?? []
    }
}
