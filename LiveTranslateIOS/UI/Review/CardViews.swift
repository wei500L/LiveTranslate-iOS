import SwiftUI

// MARK: - Card list

/// The 卡片 section of the review center. New cards sit outside the
/// schedule until their first review session enrolls them (入队).
struct CardListView: View {
    @Environment(AppEnvironment.self) private var environment
    @Binding var courses: [Course]
    @Binding var selectedCourseID: UUID?
    /// Launches the flashcard session (owned by the review center).
    var onStartReview: (UUID?) -> Void

    @State private var cards: [StudyCard] = []
    @State private var searchText = ""
    @State private var dueOnly = false
    @State private var editingCard: StudyCard?
    @State private var showingNewCard = false
    @State private var showingAIGeneration = false
    @State private var isLoaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: LTSpacing.m) {
            filterRow
            if isLoaded && filtered.isEmpty {
                LTEmptyState(
                    symbol: "rectangle.on.rectangle",
                    title: cards.isEmpty ? "还没有学习卡片" : "没有匹配的卡片",
                    message: cards.isEmpty
                        ? "从术语、课堂重点、板书公式或笔记里制作卡片"
                        : "换个筛选条件或搜索词试试"
                )
            } else if isLoaded {
                VStack(spacing: LTSpacing.xs) {
                    ForEach(filtered) { card in
                        NavigationLink {
                            CardDetailView(card: card, courses: courses)
                        } label: {
                            CardRowView(card: card)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button { editingCard = card } label: { Label("编辑", systemImage: "pencil") }
                            Button(role: .destructive) {
                                try? environment.repository.deleteCard(card)
                                reload()
                            } label: { Label("删除卡片", systemImage: "trash") }
                        }
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, LTSpacing.xl)
            }
        }
        .searchable(text: $searchText, prompt: "搜索卡片")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { showingNewCard = true } label: { Label("手动创建", systemImage: "square.and.pencil") }
                    Button { showingAIGeneration = true } label: { Label("AI 辅助生成", systemImage: "sparkles") }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .onAppear { reload() }
        .onChange(of: selectedCourseID) { reload() }
        .onChange(of: searchText) { reload() }
        .sheet(item: $editingCard) { card in
            CardSaveSheet(draft: CardDraft(
                front: card.front,
                back: card.back,
                type: card.type,
                userNote: card.userNote,
                courseID: card.courseID,
                origin: card.origin
            )) { _ in reload() }
        }
        .sheet(isPresented: $showingNewCard) {
            CardSaveSheet(draft: CardDraft(front: "", back: "", courseID: selectedCourseID)) { _ in reload() }
        }
        .sheet(isPresented: $showingAIGeneration) {
            AICardGenerationView(preselectedCourseID: selectedCourseID, courses: courses)
        }
    }

    private var filtered: [StudyCard] {
        cards.filter { card in
            !dueOnly || card.isDueNow
        }
    }

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: LTSpacing.s) {
                Menu {
                    Button("全部课程") { selectedCourseID = nil }
                    ForEach(courses) { course in
                        Button(course.name) { selectedCourseID = course.id }
                    }
                } label: {
                    chip(
                        label: selectedCourseID == nil
                            ? "全部课程"
                            : courses.first(where: { $0.id == selectedCourseID })?.name ?? "课程",
                        selected: selectedCourseID != nil
                    )
                }
                Button {
                    dueOnly.toggle()
                    reload()
                } label: {
                    chip(label: "只看待复习", symbol: "clock", selected: dueOnly)
                }
                if !dueOnly {
                    Button {
                        onStartReview(selectedCourseID)
                    } label: {
                        chip(label: "开始复习", symbol: "play.fill", selected: true)
                    }
                }
            }
        }
    }

    private func chip(label: String, symbol: String? = nil, selected: Bool) -> some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).font(.caption2)
            }
            Text(label).font(.footnote.weight(.medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule().fill(selected ? LTColors.accentGreen.opacity(0.18) : LTColors.surfacePrimary.opacity(0.7))
        )
        .overlay(
            Capsule().strokeBorder(selected ? LTColors.accentGreen.opacity(0.5) : LTColors.border, lineWidth: 0.5)
        )
        .foregroundStyle(selected ? LTColors.accentGreen : LTColors.textSecondary)
    }

    private func reload() {
        if searchText.isEmpty {
            cards = (try? environment.repository.cards(courseID: selectedCourseID)) ?? []
        } else {
            cards = (try? environment.repository.cards(matching: searchText)) ?? []
            if let selectedCourseID {
                cards = cards.filter { $0.courseID == selectedCourseID }
            }
        }
        isLoaded = true
    }
}

struct CardRowView: View {
    let card: StudyCard

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: LTSpacing.xs) {
                StatusChip(text: card.type.displayName, tint: LTColors.accentCyan)
                if card.origin == .ai {
                    StatusChip(text: "AI", tint: LTColors.accentBlue)
                }
                Spacer()
                scheduleChip
            }
            Text(card.front)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LTColors.textPrimary)
                .lineLimit(2)
            Text(card.back)
                .font(.footnote)
                .foregroundStyle(LTColors.textSecondary)
                .lineLimit(2)
        }
        .padding(LTSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ltCard()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var scheduleChip: some View {
        switch card.stage {
        case .new:
            Text("未开始")
                .font(LTTypography.timestamp)
                .foregroundStyle(LTColors.textTertiary)
        case .learning, .young, .mature:
            if let due = card.dueAt {
                Text(due <= .now ? "待复习" : "下次 \(due.formatted(.relative(presentation: .named)))")
                    .font(LTTypography.timestamp)
                    .foregroundStyle(due <= .now ? LTColors.warning : LTColors.textTertiary)
            }
        }
    }
}

// MARK: - Card detail

/// One card: content, schedule (real numbers), source links, edit /
/// reset-progress / delete. A content edit never silently resets the
/// schedule — the reset is always an explicit, separate action.
struct CardDetailView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let card: StudyCard
    let courses: [Course]

    @State private var editing = false
    @State private var showDeleteConfirm = false
    @State private var showResetConfirm = false
    @State private var dueAt: Date?
    @State private var stage: StudyCardStage = .new
    @State private var reviewCount = 0
    @State private var lastReviewedAt: Date?

    var body: some View {
        LTPage {
            ScrollView {
                VStack(alignment: .leading, spacing: LTSpacing.l) {
                    contentCard
                    scheduleCard
                    sourceCard
                }
                .padding(.horizontal, LTSpacing.screenPadding)
                .padding(.top, LTSpacing.s)
                .padding(.bottom, LTSpacing.xl)
            }
        }
        .navigationTitle("学习卡片")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { editing = true } label: { Label("编辑", systemImage: "pencil") }
                    Button { showResetConfirm = true } label: {
                        Label("重置学习进度", systemImage: "arrow.counterclockwise")
                    }
                    Button(role: .destructive) { showDeleteConfirm = true } label: {
                        Label("删除卡片", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onAppear {
            dueAt = card.dueAt
            stage = card.stage
            reviewCount = card.reviewCount
            lastReviewedAt = card.lastReviewedAt
        }
        .sheet(isPresented: $editing) {
            CardSaveSheet(draft: CardDraft(
                front: card.front,
                back: card.back,
                type: card.type,
                userNote: card.userNote,
                courseID: card.courseID,
                origin: card.origin
            )) { _ in
                dueAt = card.dueAt
                stage = card.stage
            }
        }
        .confirmationDialog("重置这张卡片的学习进度？", isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button("重置进度", role: .destructive) {
                try? environment.repository.resetCardSchedule(card)
                dueAt = card.dueAt
                stage = card.stage
                reviewCount = card.reviewCount
                lastReviewedAt = card.lastReviewedAt
            }
        } message: {
            Text("复习次数与间隔将清零，内容保持不变。")
        }
        .confirmationDialog("删除这张卡片？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除卡片", role: .destructive) {
                try? environment.repository.deleteCard(card)
                dismiss()
            }
        } message: {
            Text("无法撤销。")
        }
    }

    private var contentCard: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            Text("正面")
                .font(.caption.weight(.semibold))
                .foregroundStyle(LTColors.textTertiary)
            Text(card.front)
                .font(.title3.weight(.medium))
                .foregroundStyle(LTColors.textPrimary)
                .textSelection(.enabled)
            Divider().overlay(LTColors.separator)
            Text("背面")
                .font(.caption.weight(.semibold))
                .foregroundStyle(LTColors.textTertiary)
            Text(card.back)
                .font(.title3.weight(.medium))
                .foregroundStyle(LTColors.accentGreen)
                .textSelection(.enabled)
            if !card.userNote.isEmpty {
                Text(card.userNote)
                    .font(.footnote)
                    .foregroundStyle(LTColors.textSecondary)
                    .textSelection(.enabled)
            }
            HStack(spacing: LTSpacing.s) {
                StatusChip(text: card.type.displayName, tint: LTColors.accentCyan)
                if let courseID = card.courseID,
                   let course = courses.first(where: { $0.id == courseID }) {
                    StatusChip(text: course.name, tint: LTColors.accentBlue)
                }
            }
        }
        .padding(LTSpacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ltCard()
    }

    private var scheduleCard: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            LTSectionHeader(title: "学习进度")
            HStack(spacing: LTSpacing.xl) {
                scheduleStat("阶段", stageName)
                scheduleStat("复习次数", "\(reviewCount)")
                scheduleStat(
                    "最近复习",
                    lastReviewedAt.map { $0.formatted(date: .omitted, time: .shortened) } ?? "—"
                )
            }
            if let dueAt {
                Text(
                    dueAt <= .now
                        ? "这张卡片现在待复习"
                        : "下次复习：\(dueAt.formatted(date: .abbreviated, time: .shortened))"
                )
                    .font(.footnote)
                    .foregroundStyle(dueAt <= .now ? LTColors.warning : LTColors.textSecondary)
            } else {
                Text("尚未加入复习队列——下次开始复习时会自动加入")
                    .font(.footnote)
                    .foregroundStyle(LTColors.textTertiary)
            }
        }
        .padding(LTSpacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ltCard()
    }

    private var stageName: String {
        switch stage {
        case .new: return "未开始"
        case .learning: return "学习中"
        case .young: return "巩固"
        case .mature: return "长期"
        }
    }

    private func scheduleStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(LTColors.textTertiary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LTColors.textPrimary)
        }
    }

    @ViewBuilder
    private var sourceCard: some View {
        if card.sessionID != nil || card.sourceAttachmentID != nil {
            VStack(alignment: .leading, spacing: LTSpacing.s) {
                LTSectionHeader(title: "来源")
                sourceRows
            }
            .padding(LTSpacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .ltCard()
        }
    }

    @ViewBuilder
    private var sourceRows: some View {
        VStack(spacing: LTSpacing.xs) {
            if let sessionID = card.sessionID {
                sourceLink(id: sessionID, kind: .session)
            }
            if let attachmentID = card.sourceAttachmentID {
                sourceLink(id: attachmentID, kind: .attachment)
            }
        }
    }

    private enum SourceKind { case session, attachment }

    @ViewBuilder
    private func sourceLink(id: UUID, kind: SourceKind) -> some View {
        // Resolve the source; a deleted one renders as 来源已不存在 (the
        // card itself always survives).
        if kind == .session,
           let session = try? environment.repository.sessions(matching: "").first(where: { $0.id == id }) {
            NavigationLink {
                SessionDetailView(sessionID: id)
            } label: {
                sourceRowLabel(symbol: "waveform", title: session.title, exists: true)
            }
            .buttonStyle(.plain)
        } else if kind == .attachment,
                  let attachment = try? environment.repository.attachment(id: id) {
            NavigationLink {
                SessionDetailView(sessionID: attachment.sessionID, openAttachmentsOnLoad: true)
            } label: {
                sourceRowLabel(symbol: "photo", title: attachment.title.isEmpty ? "课堂图片" : attachment.title, exists: true)
            }
            .buttonStyle(.plain)
        } else {
            sourceRowLabel(
                symbol: kind == .session ? "waveform" : "photo",
                title: "来源已不存在",
                exists: false
            )
        }
    }

    private func sourceRowLabel(symbol: String, title: String, exists: Bool) -> some View {
        HStack(spacing: LTSpacing.s) {
            Image(systemName: symbol)
                .font(.subheadline)
                .foregroundStyle(exists ? LTColors.accentBlue : LTColors.textTertiary)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(exists ? LTColors.textPrimary : LTColors.textTertiary)
                .lineLimit(1)
            Spacer()
            if exists {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(LTColors.textTertiary)
            }
        }
        .padding(LTSpacing.s)
        .background(RoundedRectangle(cornerRadius: LTRadius.small).fill(LTColors.surfacePrimary.opacity(0.6)))
    }
}
