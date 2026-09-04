import SwiftUI

/// 考试列表 — the 计划 segment of the review center. Candidates awaiting
/// confirmation on top (AI extracted, device-local), then real exams
/// grouped by soonest date. Every row leads to the real detail page.
struct ExamListScreen: View {
    @Environment(AppEnvironment.self) private var environment
    let courses: [Course]

    @State private var exams: [Exam] = []
    @State private var candidates: [Exam] = []
    @State private var showingNewExam = false
    @State private var showingCandidateReview = false
    @State private var isLoaded = false

    private var liveExams: [Exam] {
        exams.filter { $0.status == .scheduled }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LTSpacing.m) {
            if !candidates.isEmpty {
                candidateBanner
            }
            if isLoaded && liveExams.isEmpty && candidates.isEmpty {
                LTEmptyState(
                    symbol: "graduationcap",
                    title: "还没有安排考试",
                    message: "从课程或课程表添加考试，或从课堂图片识别考试通知"
                )
            } else if isLoaded {
                examList
                if !finishedExams.isEmpty {
                    finishedSection
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, LTSpacing.xl)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        showingNewExam = true
                    } label: {
                        Label("手动创建考试", systemImage: "plus")
                    }
                    if isRecognitionConfigured {
                        Button {
                            showingCandidateReview = true
                        } label: {
                            Label("从图片或课堂识别考试", systemImage: "text.viewfinder")
                        }
                    }
                    Section {
                        if environment.examReminders.studyReminderEnabled {
                            Button(role: .destructive) {
                                environment.examReminders.disableStudyReminder()
                            } label: {
                                Label("关闭每日学习提醒", systemImage: "bell.slash")
                            }
                        } else {
                            Button {
                                Task {
                                    _ = await environment.examReminders.enableStudyReminder(minuteOfDay: 19 * 60)
                                }
                            } label: {
                                Label("开启每日学习提醒（19:00）", systemImage: "bell")
                            }
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(Text("添加考试"))
            }
        }
        .sheet(isPresented: $showingNewExam) {
            NavigationStack {
                ExamFormScreen(preselectedCourseID: nil, editing: nil)
                    .environment(environment)
            }
        }
        .sheet(isPresented: $showingCandidateReview) {
            NavigationStack {
                ExamCandidateReviewScreen()
                    .environment(environment)
            }
        }
        .onAppear { reload() }
    }

    /// Any recognition path available (image OR text sources — the
    /// candidate flow covers both).
    private var isRecognitionConfigured: Bool {
        environment.attachmentAnalysisService.isConfiguredNow
            || environment.studyReviewService.isConfiguredNow
    }

    /// The 待确认 banner: AI candidates never become real exams, plan
    /// targets or notifications until confirmed here.
    private var candidateBanner: some View {
        Button {
            showingCandidateReview = true
        } label: {
            HStack(spacing: LTSpacing.s) {
                Image(systemName: "sparkles")
                    .font(.subheadline)
                    .foregroundStyle(LTColors.accentGreen)
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidates.count == 1
                        ? "有 1 条考试候选待确认"
                        : "有 \(candidates.count) 条考试候选待确认")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(LTColors.textPrimary)
                    Text("AI 从图片或资料中识别，确认后才会创建提醒和计划")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(LTColors.textTertiary)
            }
            .padding(LTSpacing.m)
            .ltCard()
        }
        .buttonStyle(.plain)
    }

    private var examList: some View {
        VStack(spacing: LTSpacing.xs) {
            ForEach(liveExams) { exam in
                NavigationLink {
                    ExamDetailView(examID: exam.id)
                        .environment(environment)
                } label: {
                    ExamRowView(exam: exam, courseName: courseName(exam))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var finishedExams: [Exam] {
        exams.filter { $0.status == .done || $0.status == .cancelled }
    }

    private var finishedSection: some View {
        VStack(alignment: .leading, spacing: LTSpacing.xs) {
            LTSectionHeader(title: "已结束")
            VStack(spacing: LTSpacing.xs) {
                ForEach(finishedExams) { exam in
                    NavigationLink {
                        ExamDetailView(examID: exam.id)
                            .environment(environment)
                    } label: {
                        ExamRowView(exam: exam, courseName: courseName(exam))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func courseName(_ exam: Exam) -> String? {
        exam.courseID.flatMap { id in courses.first { $0.id == id }?.name }
    }

    private func reload() {
        exams = (try? environment.repository.exams(courseID: nil, includeCandidates: false)) ?? []
        candidates = (try? environment.repository.pendingExamCandidates()) ?? []
        isLoaded = true
    }
}

/// One exam row: type symbol + title, date/时间, countdown in words (no
/// per-second countdowns), course + location as the secondary line.
struct ExamRowView: View {
    let exam: Exam
    let courseName: String?

    var body: some View {
        HStack(spacing: LTSpacing.m) {
            LTIconBadge(symbol: exam.kind.symbol, tint: tint, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: LTSpacing.xs) {
                    Text(exam.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LTColors.textPrimary)
                        .lineLimit(1)
                    if exam.status == .done {
                        StatusChip(text: "已完成", tint: LTColors.textTertiary)
                    } else if exam.status == .cancelled {
                        StatusChip(text: "已取消", tint: LTColors.textTertiary)
                    }
                }
                Text(subtitle)
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(countdownLabel)
                .font(LTTypography.timestamp)
                .foregroundStyle(countdownTint)
        }
        .padding(LTSpacing.m)
        .ltCard()
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch exam.status {
        case .scheduled: return LTColors.accentGreen
        case .pending: return LTColors.accentCyan
        case .done, .cancelled: return LTColors.textTertiary
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let courseName { parts.append(courseName) }
        if let date = exam.examDate {
            parts.append(date.formatted(date: .abbreviated, time: .omitted))
            if exam.hasTime {
                parts.append(String(format: "%02d:%02d", exam.startSecs / 3600, (exam.startSecs % 3600) / 60))
            }
        }
        if !exam.location.isEmpty { parts.append(exam.location) }
        return parts.joined(separator: " · ")
    }

    /// Countdown in days (words, not a ticking clock — days is the
    /// honest resolution until the exam day).
    private var countdownLabel: String {
        guard let days = exam.daysUntilExam, exam.status == .scheduled else {
            return exam.status.displayName
        }
        switch days {
        case let d where d < 0: return "已结束"
        case 0: return "今天"
        case 1: return "明天"
        case 2...7: return "\(days) 天后"
        default: return "\(days) 天"
        }
    }

    private var countdownTint: Color {
        guard let days = exam.daysUntilExam, exam.status == .scheduled else {
            return LTColors.textTertiary
        }
        if days < 0 { return LTColors.textTertiary }
        if days <= 3 { return LTColors.warning }
        return LTColors.textSecondary
    }
}
