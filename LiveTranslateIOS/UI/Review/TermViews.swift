import SwiftUI
import AVFoundation

// MARK: - Term book (list)

/// The 术语 section of the review center: course filter, live search,
/// favorite filter, and the term rows. Navigation to TermDetailView.
struct TermBookView: View {
    @Environment(AppEnvironment.self) private var environment
    @Binding var courses: [Course]
    @Binding var selectedCourseID: UUID?

    @State private var terms: [GlossaryTerm] = []
    @State private var searchText = ""
    @State private var favoritesOnly = false
    @State private var statusFilter: GlossaryTermStatus?
    @State private var editingTerm: GlossaryTerm?
    @State private var showingNewTerm = false
    @State private var isLoaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: LTSpacing.m) {
            filterRow
            if isLoaded && filtered.isEmpty {
                LTEmptyState(
                    symbol: "character.book.closed",
                    title: terms.isEmpty ? "术语本还是空的" : "没有匹配的术语",
                    message: terms.isEmpty
                        ? "在 AI 学习整理、转录段落或图片分析里保存术语，也可以手动添加"
                        : "换个筛选条件或搜索词试试"
                )
            } else if isLoaded {
                VStack(spacing: LTSpacing.xs) {
                    ForEach(filtered) { term in
                        NavigationLink {
                            TermDetailView(term: term, courses: courses)
                        } label: {
                            TermRowView(term: term)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                editingTerm = term
                            } label: {
                                Label("编辑", systemImage: "pencil")
                            }
                            Button {
                                try? environment.repository.updateTermFavorite(
                                    term, isFavorite: !term.isFavorite
                                )
                                reload()
                            } label: {
                                Label(
                                    term.isFavorite ? "取消收藏" : "收藏",
                                    systemImage: term.isFavorite ? "star.slash" : "star"
                                )
                            }
                            Button(role: .destructive) {
                                try? environment.repository.deleteTerm(term)
                                reload()
                            } label: {
                                Label("删除术语", systemImage: "trash")
                            }
                        }
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, LTSpacing.xl)
            }
        }
        .searchable(text: $searchText, prompt: "搜索俄语或中文")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingNewTerm = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("手动添加术语")
            }
        }
        .onAppear { reload() }
        .onChange(of: selectedCourseID) { reload() }
        .onChange(of: searchText) { reload() }
        .sheet(item: $editingTerm) { term in
            TermSaveSheet(draft: TermDraft(
                russian: term.russian,
                chinese: term.chinese,
                explanation: term.explanation,
                partOfSpeech: term.partOfSpeech,
                userNote: term.userNote,
                courseID: term.courseID,
                isFavorite: term.isFavorite,
                status: term.status
            )) { _ in reload() }
        }
        .sheet(isPresented: $showingNewTerm) {
            TermSaveSheet(draft: TermDraft(
                russian: "",
                courseID: selectedCourseID
            )) { _ in reload() }
        }
    }

    private var filtered: [GlossaryTerm] {
        terms.filter { term in
            (!favoritesOnly || term.isFavorite)
                && (statusFilter == nil || term.status == statusFilter)
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
                    FilterChip(
                        label: selectedCourseID == nil
                            ? "全部课程"
                            : courses.first(where: { $0.id == selectedCourseID })?.name ?? "课程",
                        isSelected: selectedCourseID != nil
                    )
                }
                Button {
                    favoritesOnly.toggle()
                    reload()
                } label: {
                    FilterChip(label: "收藏", symbol: "star.fill", isSelected: favoritesOnly)
                }
                Menu {
                    Button("全部状态") { statusFilter = nil; reload() }
                    ForEach([GlossaryTermStatus.new, .learning, .familiar, .mastered], id: \.self) { status in
                        Button(Self.statusName(status)) { statusFilter = status; reload() }
                    }
                } label: {
                    FilterChip(
                        label: statusFilter.map(Self.statusName) ?? "状态",
                        isSelected: statusFilter != nil
                    )
                }
            }
        }
    }

    static func statusName(_ status: GlossaryTermStatus) -> String {
        switch status {
        case .new: return "新词"
        case .learning: return "在学习"
        case .familiar: return "较熟悉"
        case .mastered: return "已掌握"
        }
    }

    static func statusTint(_ status: GlossaryTermStatus) -> Color {
        switch status {
        case .new: return LTColors.accentBlue
        case .learning: return LTColors.accentCyan
        case .familiar: return LTColors.accentGreen
        case .mastered: return LTColors.warning
        }
    }

    private func reload() {
        if searchText.isEmpty {
            terms = (try? environment.repository.terms(courseID: selectedCourseID)) ?? []
        } else {
            terms = (try? environment.repository.terms(matching: searchText)) ?? []
            if let selectedCourseID {
                terms = terms.filter { $0.courseID == selectedCourseID }
            }
        }
        isLoaded = true
    }
}

private struct FilterChip: View {
    let label: String
    var symbol: String? = nil
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.caption2)
            }
            Text(label)
                .font(.footnote.weight(.medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule().fill(
                isSelected
                    ? LTColors.accentGreen.opacity(0.18)
                    : LTColors.surfacePrimary.opacity(0.7)
            )
        )
        .overlay(
            Capsule().strokeBorder(
                isSelected ? LTColors.accentGreen.opacity(0.5) : LTColors.border,
                lineWidth: 0.5
            )
        )
        .foregroundStyle(isSelected ? LTColors.accentGreen : LTColors.textSecondary)
    }
}

struct TermRowView: View {
    let term: GlossaryTerm

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: LTSpacing.xs) {
                Text(term.russian)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LTColors.textPrimary)
                    .lineLimit(1)
                if !term.partOfSpeech.isEmpty {
                    Text(term.partOfSpeech)
                        .font(.caption2)
                        .foregroundStyle(LTColors.textTertiary)
                }
                if term.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(LTColors.warning)
                }
                Spacer()
                StatusChip(
                    text: TermBookView.statusName(term.status),
                    tint: TermBookView.statusTint(term.status)
                )
            }
            if !term.chinese.isEmpty {
                Text(term.chinese)
                    .font(.subheadline)
                    .foregroundStyle(LTColors.textSecondary)
                    .lineLimit(1)
            }
            if !term.explanation.isEmpty {
                Text(term.explanation)
                    .font(.footnote)
                    .foregroundStyle(LTColors.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(LTSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ltCard()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Term detail

/// One term: content, sources (jump back to the classroom), related cards,
/// favorite / status, edit, delete, 俄语朗读 (system TTS, lightweight).
struct TermDetailView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let term: GlossaryTerm
    let courses: [Course]

    @State private var sourceSessions: [(id: UUID, title: String)] = []
    @State private var relatedCards: [StudyCard] = []
    @State private var editing = false
    @State private var makingCard = false
    @State private var showDeleteConfirm = false
    @State private var currentStatus: GlossaryTermStatus = .new

    var body: some View {
        LTPage {
            ScrollView {
                VStack(alignment: .leading, spacing: LTSpacing.l) {
                    headerCard
                    if !sourceSessions.isEmpty {
                        sourcesCard
                    }
                    cardsCard
                }
                .padding(.horizontal, LTSpacing.screenPadding)
                .padding(.top, LTSpacing.s)
                .padding(.bottom, LTSpacing.xl)
            }
        }
        .navigationTitle("术语")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { editing = true } label: { Label("编辑", systemImage: "pencil") }
                    Button { makingCard = true } label: { Label("制作学习卡片", systemImage: "rectangle.on.rectangle") }
                    Menu {
                        ForEach([GlossaryTermStatus.new, .learning, .familiar, .mastered], id: \.self) { status in
                            Button(TermBookView.statusName(status)) {
                                try? environment.repository.updateTermStatus(term, status: status)
                                currentStatus = status
                            }
                        }
                    } label: { Label("学习状态", systemImage: "chart.line.uptrend.xyaxis") }
                    Button(role: .destructive) { showDeleteConfirm = true } label: {
                        Label("删除术语", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onAppear { reload() }
        .sheet(isPresented: $editing) {
            TermSaveSheet(draft: TermDraft(
                russian: term.russian,
                chinese: term.chinese,
                explanation: term.explanation,
                partOfSpeech: term.partOfSpeech,
                userNote: term.userNote,
                courseID: term.courseID,
                isFavorite: term.isFavorite,
                status: currentStatus
            )) { _ in reload() }
        }
        .sheet(isPresented: $makingCard) {
            CardSaveSheet(draft: CardDraft(
                front: term.russian,
                back: term.chinese.isEmpty ? term.explanation : term.chinese,
                type: .ru2zh,
                courseID: term.courseID,
                sessionID: term.sessionID,
                sourceTermID: term.id
            )) { _ in reload() }
        }
        .confirmationDialog("删除这个术语？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除术语", role: .destructive) {
                try? environment.repository.deleteTerm(term)
                dismiss()
            }
        } message: {
            Text("相关卡片会保留，不受影响。")
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(term.russian)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(LTColors.textPrimary)
                    .textSelection(.enabled)
                Spacer()
                Button {
                    Task { await TermSpeech.speak(term.russian) }
                } label: {
                    Image(systemName: "speaker.wave.2")
                        .font(.subheadline)
                        .foregroundStyle(LTColors.accentBlue)
                }
                .accessibilityLabel("朗读俄语")
                Button {
                    try? environment.repository.updateTermFavorite(term, isFavorite: !term.isFavorite)
                } label: {
                    Image(systemName: term.isFavorite ? "star.fill" : "star")
                        .font(.subheadline)
                        .foregroundStyle(term.isFavorite ? LTColors.warning : LTColors.textTertiary)
                }
                .accessibilityLabel(term.isFavorite ? "取消收藏" : "收藏")
            }
            if !term.chinese.isEmpty {
                Text(term.chinese)
                    .font(.title3)
                    .foregroundStyle(LTColors.accentGreen)
                    .textSelection(.enabled)
            }
            if !term.explanation.isEmpty {
                Text(term.explanation)
                    .font(.subheadline)
                    .foregroundStyle(LTColors.textSecondary)
                    .textSelection(.enabled)
            }
            if !term.userNote.isEmpty {
                HStack(alignment: .top, spacing: LTSpacing.xs) {
                    Image(systemName: "lightbulb")
                        .font(.caption)
                        .foregroundStyle(LTColors.warning)
                    Text(term.userNote)
                        .font(.footnote)
                        .foregroundStyle(LTColors.textSecondary)
                        .textSelection(.enabled)
                }
            }
            HStack(spacing: LTSpacing.s) {
                StatusChip(
                    text: TermBookView.statusName(currentStatus),
                    tint: TermBookView.statusTint(currentStatus)
                )
                if let courseID = term.courseID,
                   let course = courses.first(where: { $0.id == courseID }) {
                    StatusChip(text: course.name, tint: LTColors.accentBlue)
                }
                if !term.partOfSpeech.isEmpty {
                    StatusChip(text: term.partOfSpeech, tint: LTColors.textSecondary)
                }
            }
        }
        .padding(LTSpacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ltCard()
    }

    private var sourcesCard: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            LTSectionHeader(title: "出现过的课堂")
            VStack(spacing: LTSpacing.xs) {
                ForEach(sourceSessions, id: \.id) { source in
                    NavigationLink {
                        SessionDetailView(sessionID: source.id)
                    } label: {
                        HStack(spacing: LTSpacing.s) {
                            LTIconBadge(
                                symbol: LTIconography.symbol(for: source.title),
                                tint: LTIconography.tint(for: source.title),
                                size: 30
                            )
                            Text(source.title)
                                .font(.subheadline)
                                .foregroundStyle(LTColors.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(LTColors.textTertiary)
                        }
                        .padding(LTSpacing.s)
                        .background(
                            RoundedRectangle(cornerRadius: LTRadius.small)
                                .fill(LTColors.surfacePrimary.opacity(0.6))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var cardsCard: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            LTSectionHeader(title: "相关卡片", actionTitle: relatedCards.isEmpty ? "制卡" : nil) {
                makingCard = true
            }
            if relatedCards.isEmpty {
                Text("还没有从这个术语制作的卡片")
                    .font(.footnote)
                    .foregroundStyle(LTColors.textTertiary)
            } else {
                VStack(spacing: LTSpacing.xs) {
                    ForEach(relatedCards) { card in
                        HStack(spacing: LTSpacing.s) {
                            StatusChip(text: card.type.displayName, tint: LTColors.accentCyan)
                            Text(card.front)
                                .font(.subheadline)
                                .foregroundStyle(LTColors.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            if card.dueAt == nil {
                                Text("未开始复习")
                                    .font(LTTypography.timestamp)
                                    .foregroundStyle(LTColors.textTertiary)
                            } else if let due = card.dueAt, due <= .now {
                                Text("待复习")
                                    .font(LTTypography.timestamp)
                                    .foregroundStyle(LTColors.warning)
                            }
                        }
                        .padding(LTSpacing.s)
                        .background(
                            RoundedRectangle(cornerRadius: LTRadius.small)
                                .fill(LTColors.surfacePrimary.opacity(0.6))
                        )
                    }
                }
            }
        }
    }

    private func reload() {
        currentStatus = term.status
        relatedCards = (try? environment.repository.cards(forTermID: term.id)) ?? []
        let sessions = (try? environment.repository.sessions(matching: "")) ?? []
        let byID = Dictionary(sessions.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<UUID>()
        sourceSessions = term.sourceSessionIDs.compactMap { id in
            guard !seen.contains(id) else { return nil }
            seen.insert(id)
            guard let title = byID[id] else { return nil }
            return (id, title)
        }
    }
}

// MARK: - Lightweight Russian TTS

/// System speech synthesis, ru-RU voice when available. A light aid on
/// the term detail page — deliberately NOT a player or course feature.
@MainActor
enum TermSpeech {
    private static let synthesizer = AVSpeechSynthesizer()

    static func speak(_ text: String) async {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "ru-RU")
        utterance.rate = 0.45
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance)
    }
}
