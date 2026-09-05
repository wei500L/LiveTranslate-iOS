import SwiftUI

/// AI card generation flow: pick a classroom → tick the material to send
/// (review key points / terms / uncertainties / image formulas — only
/// what the user selected leaves the device) → generate → PREVIEW where
/// every card can be edited, deleted or deduplicated → save the checked
/// ones. Nothing is persisted before the final 保存.
struct AICardGenerationView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    /// Preselected course (from the review center's course filter).
    let preselectedCourseID: UUID?
    let courses: [Course]
    /// Preselected session (invoked from a classroom context); nil = the
    /// user picks one here.
    var preselectedSessionID: UUID? = nil

    enum Phase {
        case pickSession
        case pickMaterial
        case generating
        case preview
        case failed(String)
    }

    @State private var phase: Phase = .pickSession
    @State private var sessions: [ClassroomSession] = []
    @State private var selectedSessionID: UUID?
    @State private var items: [LearningCardGenerator.InputItem] = []
    @State private var selected: Set<UUID> = []
    @State private var generated: [LearningCardGenerator.GeneratedCard] = []
    @State private var keptCards: Set<UUID> = []
    @State private var editingCard: LearningCardGenerator.GeneratedCard?

    var body: some View {
        NavigationStack {
            LTPage {
                Group {
                    switch phase {
                    case .pickSession: sessionPicker
                    case .pickMaterial: materialPicker
                    case .generating:
                        VStack(spacing: LTSpacing.m) {
                            ProgressView()
                            Text("正在根据选中的内容生成卡片…")
                                .font(.footnote)
                                .foregroundStyle(LTColors.textSecondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .preview: preview
                    case .failed(let message):
                        LTEmptyState(
                            symbol: "exclamationmark.triangle",
                            title: "生成失败",
                            message: message
                        )
                    }
                }
            }
            .navigationTitle("AI 制作卡片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if case .pickMaterial = phase {
                        Button("生成") {
                            Task { await generate() }
                        }
                        .disabled(selected.isEmpty)
                    }
                    if case .preview = phase {
                        Button("保存 \(keptCards.count) 张") { save() }
                            .disabled(keptCards.isEmpty)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            sessions = (try? environment.repository.sessions(matching: "")) ?? []
            if let preselectedSessionID {
                selectedSessionID = preselectedSessionID
                loadMaterial()
                phase = .pickMaterial
            }
        }
        .sheet(item: $editingCard) { card in
            CardEditSheet(card: card) { updated in
                if let index = generated.firstIndex(where: { $0.id == card.id }) {
                    generated[index] = updated
                }
            }
        }
    }

    // MARK: Session picker

    private var sessionPicker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LTSpacing.s) {
                Text("选择一节课堂，从它的整理内容里挑选制卡素材")
                    .font(.footnote)
                    .foregroundStyle(LTColors.textSecondary)
                if sessions.isEmpty {
                    LTEmptyState(
                        symbol: "waveform",
                        title: "没有课堂记录",
                        message: "先上一节课，或从已有课堂的整理开始"
                    )
                }
                ForEach(sessions) { session in
                    Button {
                        selectedSessionID = session.id
                        loadMaterial()
                        phase = .pickMaterial
                    } label: {
                        HStack(spacing: LTSpacing.s) {
                            LTIconBadge(
                                symbol: LTIconography.symbol(for: session.title),
                                tint: LTIconography.tint(for: session.title),
                                size: 32
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.title)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(LTColors.textPrimary)
                                    .lineLimit(1)
                                Text(session.startTime.formatted(date: .abbreviated, time: .omitted))
                                    .font(LTTypography.timestamp)
                                    .foregroundStyle(LTColors.textTertiary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(LTColors.textTertiary)
                        }
                        .padding(LTSpacing.m)
                        .ltCard()
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, LTSpacing.screenPadding)
            .padding(.top, LTSpacing.s)
            .padding(.bottom, LTSpacing.xl)
        }
    }

    // MARK: Material picker

    private var materialPicker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LTSpacing.m) {
                Text("选择要发送的内容（只发送勾选的条目）")
                    .font(.footnote)
                    .foregroundStyle(LTColors.textSecondary)
                if items.isEmpty {
                    LTEmptyState(
                        symbol: "sparkles",
                        title: "这节课没有可用的整理内容",
                        message: "先生成 AI 学习整理，或从术语、笔记直接制卡"
                    )
                } else {
                    VStack(spacing: LTSpacing.xs) {
                        ForEach(items) { item in
                            Button {
                                if selected.contains(item.id) {
                                    selected.remove(item.id)
                                } else {
                                    selected.insert(item.id)
                                }
                            } label: {
                                HStack(alignment: .top, spacing: LTSpacing.s) {
                                    Image(systemName: selected.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                        .font(.subheadline)
                                        .foregroundStyle(selected.contains(item.id) ? LTColors.accentGreen : LTColors.textTertiary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        StatusChip(text: item.label, tint: LTColors.accentCyan)
                                        Text(item.text)
                                            .font(.subheadline)
                                            .foregroundStyle(LTColors.textPrimary)
                                            .lineLimit(3)
                                            .multilineTextAlignment(.leading)
                                    }
                                    Spacer()
                                }
                                .padding(LTSpacing.m)
                                .ltCard()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, LTSpacing.screenPadding)
            .padding(.top, LTSpacing.s)
            .padding(.bottom, LTSpacing.xl)
        }
    }

    // MARK: Preview

    private var preview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LTSpacing.m) {
                HStack {
                    Text("生成了 \(generated.count) 张，已选 \(keptCards.count) 张")
                        .font(.footnote)
                        .foregroundStyle(LTColors.textSecondary)
                    Spacer()
                    if duplicateFronts > 0 {
                        Button("去重") {
                            deduplicate()
                        }
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(LTColors.accentBlue)
                    }
                }
                VStack(spacing: LTSpacing.xs) {
                    ForEach($generated) { $card in
                        previewCard($card)
                    }
                }
                Text("保存后可以在「卡片」里编辑或删除；不满意就取消，不会留下任何内容。")
                    .font(.caption)
                    .foregroundStyle(LTColors.textTertiary)
            }
            .padding(.horizontal, LTSpacing.screenPadding)
            .padding(.top, LTSpacing.s)
            .padding(.bottom, LTSpacing.xl)
        }
    }

    private func previewCard(_ card: Binding<LearningCardGenerator.GeneratedCard>) -> some View {
        let kept = keptCards.contains(card.wrappedValue.id)
        return VStack(alignment: .leading, spacing: LTSpacing.s) {
            HStack {
                StatusChip(text: card.wrappedValue.type.displayName, tint: LTColors.accentCyan)
                Spacer()
                Button {
                    editingCard = card.wrappedValue
                } label: {
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundStyle(LTColors.accentBlue)
                }
                .accessibilityLabel("编辑这张卡片")
                Button {
                    withAnimation {
                        generated.removeAll { $0.id == card.wrappedValue.id }
                        keptCards.remove(card.wrappedValue.id)
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(LTColors.destructive)
                }
                .accessibilityLabel("删除这张卡片")
            }
            Button {
                if keptCards.contains(card.wrappedValue.id) {
                    keptCards.remove(card.wrappedValue.id)
                } else {
                    keptCards.insert(card.wrappedValue.id)
                }
            } label: {
                HStack(alignment: .top, spacing: LTSpacing.s) {
                    Image(systemName: kept ? "checkmark.circle.fill" : "circle")
                        .font(.subheadline)
                        .foregroundStyle(kept ? LTColors.accentGreen : LTColors.textTertiary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(card.wrappedValue.front)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(LTColors.textPrimary)
                            .multilineTextAlignment(.leading)
                        Text(card.wrappedValue.back)
                            .font(.footnote)
                            .foregroundStyle(LTColors.textSecondary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)
        }
        .padding(LTSpacing.m)
        .ltCard()
    }

    // MARK: Logic

    /// Number of cards sharing a normalized front with an earlier card.
    private var duplicateFronts: Int {
        var seen = Set<String>()
        var duplicates = 0
        for card in generated {
            let key = card.front.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if seen.contains(key) {
                duplicates += 1
            } else {
                seen.insert(key)
            }
        }
        return duplicates
    }

    private func deduplicate() {
        var seen = Set<String>()
        generated = generated.filter { card in
            let key = card.front.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if seen.contains(key) {
                keptCards.remove(card.id)
                return false
            }
            seen.insert(key)
            return true
        }
    }

    private func loadMaterial() {
        guard let sessionID = selectedSessionID else { return }
        var collected: [LearningCardGenerator.InputItem] = []
        let source = LearningSourceRef(
            courseID: preselectedCourseID,
            sessionID: sessionID
        )
        if let review = try? environment.repository.studyReview(forSessionID: sessionID),
           let content = StudyReviewContent.decode(review.contentJSON) {
            for keyPoint in content.keyPoints {
                collected.append(.init(
                    text: keyPoint.text, label: "重点", source: source
                ))
            }
            for term in content.terms {
                let text = "«\(term.russian)» — \(term.chinese)\(term.explanation.isEmpty ? "" : "：\(term.explanation)")"
                collected.append(.init(text: text, label: "术语", source: source))
            }
            for uncertainty in content.uncertainties {
                collected.append(.init(text: uncertainty.text, label: "待确认", source: source))
            }
        }
        // Image formulas/key points (multimodal analysis results).
        let attachments = (try? environment.repository.attachments(forSessionID: sessionID)) ?? []
        for attachment in attachments {
            guard let analysis = AttachmentAnalysisResult.decode(attachment.analysisJSON) else { continue }
            for formula in analysis.formulas ?? [] {
                collected.append(.init(
                    text: formula, label: "板书公式",
                    source: LearningSourceRef(
                        courseID: preselectedCourseID,
                        sessionID: sessionID,
                        attachmentID: attachment.id
                    )
                ))
            }
            for point in analysis.keyPoints ?? [] {
                collected.append(.init(
                    text: point, label: "图片要点",
                    source: LearningSourceRef(
                        courseID: preselectedCourseID,
                        sessionID: sessionID,
                        attachmentID: attachment.id
                    )
                ))
            }
        }
        items = Array(collected.prefix(LearningCardGenerator.Limits.maxInputItems))
        selected = Set(items.map(\.id))
    }

    private func generate() async {
        phase = .generating
        let chosen = items.filter { selected.contains($0.id) }
        do {
            let service = environment.studyReviewService
            let systemPrompt = LearningCardGenerator.systemPrompt()
            let userPrompt = LearningCardGenerator.userPrompt(items: chosen)
            let response = try await AICallScope.with(
                AICallContext(feature: .learningCard, textCategory: .mixed)
            ) {
                try await service.complete(
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    maxTokens: 3000
                )
            }
            guard let cards = LearningCardGenerator.parse(response), !cards.isEmpty else {
                phase = .failed("模型没有返回可用的卡片，请换一批素材重试。")
                return
            }
            generated = cards
            keptCards = Set(cards.map(\.id))
            phase = .preview
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func save() {
        let chosen = items.filter { selected.contains($0.id) }
        for card in generated where keptCards.contains(card.id) {
            let source = card.sourceIndex >= 1 && card.sourceIndex <= chosen.count
                ? chosen[card.sourceIndex - 1].source
                : chosen.first?.source
            let draft = CardDraft(
                front: card.front,
                back: card.back,
                type: card.type,
                courseID: source?.courseID ?? preselectedCourseID,
                sessionID: source?.sessionID,
                sourceEntryID: source?.entryID,
                sourceAttachmentID: source?.attachmentID,
                origin: .ai
            )
            _ = try? environment.repository.addCard(draft)
        }
        LTHaptics.success()
        dismiss()
    }
}

/// In-place edit of one generated card (preview stage).
private struct CardEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let card: LearningCardGenerator.GeneratedCard
    var onSave: (LearningCardGenerator.GeneratedCard) -> Void

    @State private var front: String = ""
    @State private var back: String = ""

    init(
        card: LearningCardGenerator.GeneratedCard,
        onSave: @escaping (LearningCardGenerator.GeneratedCard) -> Void
    ) {
        self.card = card
        self.onSave = onSave
        _front = State(initialValue: card.front)
        _back = State(initialValue: card.back)
    }

    var body: some View {
        NavigationStack {
            LTPage {
                Form {
                    Section("正面") {
                        TextField("正面", text: $front, axis: .vertical)
                            .lineLimit(1...4)
                    }
                    Section("背面") {
                        TextField("背面", text: $back, axis: .vertical)
                            .lineLimit(1...8)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("编辑卡片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        var updated = card
                        updated.front = front.trimmingCharacters(in: .whitespacesAndNewlines)
                        updated.back = back.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(updated)
                        dismiss()
                    }
                    .disabled(
                        front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || back.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
