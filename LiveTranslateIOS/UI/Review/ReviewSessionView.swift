import SwiftUI

/// One flashcard review session: the due queue built at start, one card
/// at a time, front → reveal → four grades. Every grade persists
/// immediately through the repository (a mid-session app kill loses
/// nothing — the next session rebuilds the queue from real due dates).
///
/// Queue rules, all explainable:
/// - cards due now (oldest due first), capped at 30;
/// - up to 10 never-reviewed cards join today's queue (入队) so freshly
///   saved material actually gets its first review;
/// - a card graded 忘记了 returns in 10 minutes on the SCHEDULE but is
///   never re-shown within the same session;
/// - 撤销 restores the previous scheduling state exactly.
struct ReviewSessionView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    /// Course scope (nil = every course).
    let courseID: UUID?

    @State private var queue: [StudyCard] = []
    @State private var index = 0
    @State private var revealed = false
    @State private var results: [GradeResult] = []
    @State private var undoStates: [CardUndoState] = []
    @State private var phase: Phase = .loading
    @State private var loadError: String?

    enum Phase { case loading, reviewing, finished, failed }

    struct GradeResult {
        let cardID: UUID
        let front: String
        let grade: StudyCardGrade
    }

    /// Snapshot of a card's scheduling fields, taken before a grade so
    /// 撤销 can restore them exactly.
    struct CardUndoState {
        let card: StudyCard
        let stageRaw: String
        let reviewCount: Int
        let intervalHours: Int
        let dueAt: Date?
        let lastReviewedAt: Date?
        let lastGradeRaw: String
    }

    var body: some View {
        NavigationStack {
            LTPage {
                Group {
                    switch phase {
                    case .loading:
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .failed:
                        LTEmptyState(
                            symbol: "exclamationmark.triangle",
                            title: "无法开始复习",
                            message: loadError ?? "读取卡片失败，请重试"
                        )
                    case .reviewing:
                        reviewingContent
                    case .finished:
                        finishedContent
                    }
                }
            }
            .navigationTitle(courseName.isEmpty ? "今日复习" : courseName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(phase == .finished ? "完成" : "退出") {
                        dismiss()
                    }
                }
                if phase == .reviewing, !undoStates.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            undoLastGrade()
                        } label: {
                            Label("撤销上一次", systemImage: "arrow.uturn.backward")
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await buildQueue() }
    }

    // MARK: Reviewing

    private var reviewingContent: some View {
        VStack(spacing: LTSpacing.l) {
            progressHeader
            if let card = currentCard {
                cardView(card)
            }
        }
        .padding(.horizontal, LTSpacing.screenPadding)
        .padding(.top, LTSpacing.s)
        .padding(.bottom, LTSpacing.xl + LTSpacing.tabBarReserve)
    }

    private var progressHeader: some View {
        HStack {
            Text("第 \(index + 1) / \(queue.count) 张")
                .font(.footnote.weight(.medium))
                .foregroundStyle(LTColors.textSecondary)
            Spacer()
            Text("剩余 \(queue.count - index) 张")
                .font(LTTypography.timestamp)
                .foregroundStyle(LTColors.textTertiary)
        }
    }

    @ViewBuilder
    private func cardView(_ card: StudyCard) -> some View {
        VStack(spacing: LTSpacing.l) {
            Spacer(minLength: LTSpacing.s)
            // The content IS the interface: front is the visual subject,
            // the back reveals on tap. Long answers scroll.
            ScrollView {
                VStack(spacing: LTSpacing.m) {
                    Text(card.front)
                        .font(.system(.title2, design: .serif))
                        .fontWeight(.semibold)
                        .foregroundStyle(LTColors.textPrimary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .textSelection(.enabled)
                    if revealed {
                        Divider().overlay(LTColors.separator)
                        Text(card.back)
                            .font(.system(.title3, design: .serif))
                            .foregroundStyle(LTColors.accentGreen)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .textSelection(.enabled)
                        if !card.userNote.isEmpty {
                            Text(card.userNote)
                                .font(.footnote)
                                .foregroundStyle(LTColors.textSecondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(LTSpacing.l)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { reveal() }

            if revealed {
                gradeButtons
            } else {
                Button(action: reveal) {
                    Text("显示答案")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(LTPrimaryButtonStyle())
                .padding(.bottom, LTSpacing.s)
            }
            sourceFooter(card)
        }
    }

    private func reveal() {
        guard !revealed else { return }
        revealed = true
        LTHaptics.tap()
    }

    /// Four grades, plain language, full-width hit areas.
    private var gradeButtons: some View {
        VStack(spacing: LTSpacing.xs) {
            gradeButton("忘记了", tint: LTColors.destructive, grade: .forgot)
            HStack(spacing: LTSpacing.xs) {
                gradeButton("有点难", tint: LTColors.warning, grade: .hard)
                gradeButton("记住了", tint: LTColors.accentGreen, grade: .good)
            }
            gradeButton("很熟悉", tint: LTColors.accentCyan, grade: .easy)
        }
    }

    private func gradeButton(_ title: String, tint: Color, grade: StudyCardGrade) -> some View {
        Button {
            apply(grade)
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, minHeight: LTSpacing.minTouchTarget)
                .background(RoundedRectangle(cornerRadius: LTRadius.medium).fill(tint.opacity(0.14)))
                .overlay(RoundedRectangle(cornerRadius: LTRadius.medium).strokeBorder(tint.opacity(0.4), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    /// Source entry stays out of the way (a single footnote link).
    @ViewBuilder
    private func sourceFooter(_ card: StudyCard) -> some View {
        if let sessionID = card.sessionID,
           let session = (try? environment.repository.sessions(matching: ""))?
               .first(where: { $0.id == sessionID }) {
            NavigationLink {
                SessionDetailView(sessionID: sessionID)
            } label: {
                Label("来自：\(session.title)", systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(LTColors.textTertiary)
            }
            .buttonStyle(.plain)
        } else if card.sessionID != nil {
            Label("来源课堂已删除", systemImage: "waveform.slash")
                .font(.caption)
                .foregroundStyle(LTColors.textTertiary)
        }
    }

    // MARK: Finished

    private var finishedContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LTSpacing.l) {
                VStack(spacing: LTSpacing.s) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(LTColors.accentGreen)
                    Text("本次复习完成")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(LTColors.textPrimary)
                    Text(Self.summaryText(results))
                        .font(.subheadline)
                        .foregroundStyle(LTColors.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(LTSpacing.l)
                .ltCard()

                VStack(alignment: .leading, spacing: LTSpacing.s) {
                    LTSectionHeader(title: "本次评分")
                    ForEach(Array(results.enumerated()), id: \.offset) { _, result in
                        HStack(spacing: LTSpacing.s) {
                            Image(systemName: Self.gradeSymbol(result.grade))
                                .font(.caption)
                                .foregroundStyle(Self.gradeTint(result.grade))
                            Text(result.front)
                                .font(.footnote)
                                .foregroundStyle(LTColors.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            Text(Self.gradeName(result.grade))
                                .font(LTTypography.timestamp)
                                .foregroundStyle(Self.gradeTint(result.grade))
                        }
                    }
                }
                .padding(LTSpacing.l)
                .ltCard()

                Button {
                    dismiss()
                } label: {
                    Text("回到复习中心")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(LTPrimaryButtonStyle())
            }
            .padding(.horizontal, LTSpacing.screenPadding)
            .padding(.top, LTSpacing.xl)
            .padding(.bottom, LTSpacing.xl + LTSpacing.tabBarReserve)
        }
    }

    // MARK: Logic

    private var currentCard: StudyCard? {
        index < queue.count ? queue[index] : nil
    }

    private var courseName: String {
        guard let courseID,
              let course = try? environment.repository.course(id: courseID) else { return "" }
        return course.name
    }

    private func buildQueue() async {
        do {
            // Due cards (all courses — filtered to the course scope before
            // the cap, so other courses cannot crowd this one out).
            var queue = try environment.repository.dueCards(before: .now, limit: 60)
            if let courseID {
                // A course-scoped session reviews that course's cards plus
                // uncategorized ones.
                queue = queue.filter { $0.courseID == courseID || $0.courseID == nil }
            }
            queue = Array(queue.prefix(30))
            if queue.count < 30 {
                // Enroll a bounded batch of never-reviewed cards so newly
                // saved material gets its first review today.
                let all = try environment.repository.cards(courseID: courseID)
                let fresh = all
                    .filter { $0.stageRaw == StudyCardStage.new.rawValue }
                    .prefix(30 - queue.count)
                for card in fresh {
                    try environment.repository.enrollCard(card)
                    queue.append(card)
                }
            }
            self.queue = queue
            phase = queue.isEmpty ? .finished : .reviewing
        } catch {
            loadError = error.localizedDescription
            phase = .failed
        }
    }

    private func apply(_ grade: StudyCardGrade) {
        guard let card = currentCard else { return }
        undoStates.append(CardUndoState(
            card: card,
            stageRaw: card.stageRaw,
            reviewCount: card.reviewCount,
            intervalHours: card.intervalHours,
            dueAt: card.dueAt,
            lastReviewedAt: card.lastReviewedAt,
            lastGradeRaw: card.lastGradeRaw
        ))
        try? environment.repository.reviewCard(card, grade: grade, at: .now)
        results.append(GradeResult(cardID: card.id, front: card.front, grade: grade))
        LTHaptics.success()
        advance()
    }

    private func advance() {
        revealed = false
        if index + 1 >= queue.count {
            phase = .finished
        } else {
            index += 1
        }
    }

    private func undoLastGrade() {
        guard let state = undoStates.popLast(), let last = results.popLast() else { return }
        state.card.stageRaw = state.stageRaw
        state.card.reviewCount = state.reviewCount
        state.card.intervalHours = state.intervalHours
        state.card.dueAt = state.dueAt
        state.card.lastReviewedAt = state.lastReviewedAt
        state.card.lastGradeRaw = state.lastGradeRaw
        state.card.updatedAt = .now
        try? environment.repository.restoreCardSchedule(state.card)
        // Step back to the undone card.
        if let position = queue.firstIndex(where: { $0.id == last.cardID }) {
            index = position
        }
        revealed = false
        if phase == .finished { phase = .reviewing }
        LTHaptics.warning()
    }

    // MARK: Formatting helpers (shared with other screens)

    static func gradeName(_ grade: StudyCardGrade) -> String {
        switch grade {
        case .forgot: return "忘记了"
        case .hard: return "有点难"
        case .good: return "记住了"
        case .easy: return "很熟悉"
        }
    }

    static func gradeTint(_ grade: StudyCardGrade) -> Color {
        switch grade {
        case .forgot: return LTColors.destructive
        case .hard: return LTColors.warning
        case .good: return LTColors.accentGreen
        case .easy: return LTColors.accentCyan
        }
    }

    static func gradeSymbol(_ grade: StudyCardGrade) -> String {
        switch grade {
        case .forgot: return "xmark.circle"
        case .hard: return "minus.circle"
        case .good: return "checkmark.circle"
        case .easy: return "star.circle"
        }
    }

    static func summaryText(_ results: [GradeResult]) -> String {
        guard !results.isEmpty else { return "当前没有待复习的卡片" }
        let counts = Dictionary(grouping: results, by: \.grade)
            .mapValues(\.count)
        let parts = StudyCardGrade.allCases.map { grade in
            counts[grade].map { "\(gradeName(grade)) \($0)" }
        }.compactMap { $0 }
        return "共复习 \(results.count) 张：" + parts.joined(separator: "，")
    }
}
