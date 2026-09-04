import SwiftUI
import PhotosUI

/// AI 考试候选确认 — the assisted entry flow. Sources: a photo (教师通知
///截图 / 黑板照片), a course material's text, a session transcript or a
/// visual-QA answer. The parser only PROPOSES; every candidate is edited
/// and confirmed here BEFORE anything is created (device-local
/// `.pending` rows on 保存候选, promoted by 确认). No notification, no
/// plan, no sync before confirmation.
struct ExamCandidateReviewScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var candidates: [Exam] = []
    @State private var isParsing = false
    @State private var parseError: String?
    @State private var photoItem: PhotosPickerItem?
    @State private var selectedMaterialID: UUID?
    @State private var selectedSessionID: UUID?
    @State private var editingCandidate: Exam?
    @State private var isLoaded = false

    private var materials: [CourseMaterial] {
        (try? environment.repository.materials(courseID: nil)) ?? []
    }

    private var sessions: [ClassroomSession] {
        ((try? environment.repository.sessions(matching: "")) ?? [])
            .sorted { $0.startTime > $1.startTime }
    }

    var body: some View {
        LTPage {
            ScrollView {
                VStack(alignment: .leading, spacing: LTSpacing.l) {
                    sourceCard
                    if isParsing {
                        HStack(spacing: LTSpacing.s) {
                            ProgressView()
                            Text("正在识别考试信息…")
                                .font(.footnote)
                                .foregroundStyle(LTColors.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, LTSpacing.l)
                    }
                    if let parseError {
                        Label(parseError, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(LTColors.warning)
                            .padding(LTSpacing.m)
                            .ltCard()
                    }
                    candidateSection
                }
                .padding(.horizontal, LTSpacing.screenPadding)
                .padding(.top, LTSpacing.s)
                .padding(.bottom, LTSpacing.xl)
            }
        }
        .navigationTitle("识别考试")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") { dismiss() }
            }
        }
        .sheet(item: $editingCandidate) { candidate in
            NavigationStack {
                ExamFormScreen(
                    preselectedCourseID: nil,
                    editing: candidate
                )
                .environment(environment)
            }
        }
        .onAppear { reload() }
    }

    // MARK: - Sources

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            LTSectionHeader(title: "从哪里识别")
            VStack(spacing: LTSpacing.xs) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    sourceRow("camera.viewfinder", "教师通知截图 / 黑板照片", LTColors.accentCyan)
                }
                .buttonStyle(.plain)
                Menu {
                    ForEach(materials) { material in
                        Button(material.title.isEmpty ? material.originalFileName : material.title) {
                            parseMaterial(material)
                        }
                    }
                } label: {
                    sourceRow("doc.text.viewfinder", "课程资料（PDF 通知）", LTColors.accentBlue)
                }
                Menu {
                    ForEach(sessions.prefix(8)) { session in
                        Button(session.title) {
                            parseSession(session)
                        }
                    }
                } label: {
                    sourceRow("waveform", "课堂转录 / 笔记", LTColors.accentGreen)
                }
            }
            if !environment.attachmentAnalysisService.isConfiguredNow
                && !environment.studyReviewService.isConfiguredNow {
                Text("模型服务尚未配置。手动创建考试不受影响。")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.warning)
            }
        }
        .ltCard()
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await parsePhoto(item) }
        }
    }

    // nonisolated: the PhotosPicker label closure is nonisolated; this
    // row touches no instance state (parameters + static design tokens).
    nonisolated private func sourceRow(_ symbol: String, _ title: String, _ tint: Color) -> some View {
        HStack(spacing: LTSpacing.s) {
            Image(systemName: symbol)
                .font(.subheadline)
                .foregroundStyle(tint)
                .frame(width: 28)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(LTColors.textPrimary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(LTColors.textTertiary)
        }
        .padding(LTSpacing.s)
        .background(RoundedRectangle(cornerRadius: LTRadius.small).fill(LTColors.surfacePrimary.opacity(0.6)))
    }

    // MARK: - Candidates

    @ViewBuilder
    private var candidateSection: some View {
        if isLoaded {
            if candidates.isEmpty {
                LTEmptyState(
                    symbol: "text.viewfinder",
                    title: "还没有考试候选",
                    message: "识别结果会先保存在这里，确认后才会成为正式考试"
                )
            } else {
                VStack(alignment: .leading, spacing: LTSpacing.s) {
                    LTSectionHeader(title: "待确认（保存在本机）")
                    Text("候选不会创建提醒或学习计划，也不会同步到云端。")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textTertiary)
                    VStack(spacing: LTSpacing.xs) {
                        ForEach(candidates) { candidate in
                            candidateRow(candidate)
                        }
                    }
                }
            }
        }
    }

    private func candidateRow(_ candidate: Exam) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            HStack(spacing: LTSpacing.s) {
                LTIconBadge(symbol: candidate.kind.symbol, tint: LTColors.accentCyan, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(LTColors.textPrimary)
                    Text(candidateSubtitle(candidate))
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textSecondary)
                }
                Spacer()
            }
            if let source = candidate.source {
                Label("识别自\(source.kindDisplayName)：\(source.originalText)", systemImage: "quote.opening")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textTertiary)
                if !source.uncertainties.isEmpty {
                    Label(source.uncertainties.joined(separator: " · "), systemImage: "exclamationmark.triangle")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.warning)
                }
            }
            HStack(spacing: LTSpacing.s) {
                Button {
                    confirm(candidate)
                } label: {
                    Label("确认为考试", systemImage: "checkmark")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(LTPrimaryButtonStyle())
                Button {
                    editingCandidate = candidate
                } label: {
                    Text("编辑")
                        .font(.footnote.weight(.medium))
                        .frame(minWidth: 64, minHeight: 36)
                }
                .buttonStyle(LTSecondaryButtonStyle())
                Button(role: .destructive) {
                    try? environment.repository.deleteExam(candidate)
                    reload()
                } label: {
                    Image(systemName: "trash")
                        .font(.footnote)
                        .foregroundStyle(LTColors.destructive)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("忽略候选"))
            }
        }
        .padding(LTSpacing.m)
        .ltCard()
    }

    private func candidateSubtitle(_ candidate: Exam) -> String {
        var parts: [String] = []
        if let date = candidate.examDate {
            parts.append(date.formatted(date: .abbreviated, time: .omitted))
            if candidate.hasTime {
                parts.append(String(format: "%02d:%02d", candidate.startSecs / 3600, (candidate.startSecs % 3600) / 60))
            }
        } else {
            parts.append("日期未识别")
        }
        if !candidate.location.isEmpty { parts.append(candidate.location) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Parsing

    private var parser: ExamCandidateParser {
        ExamCandidateParser(
            imageService: environment.attachmentAnalysisService.isConfiguredNow
                ? environment.attachmentAnalysisService : nil,
            textService: environment.studyReviewService.isConfiguredNow
                ? environment.studyReviewService : nil
        )
    }

    private func parsePhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        isParsing = true
        parseError = nil
        defer { isParsing = false; photoItem = nil }
        do {
            let parsed = try await parser.parseImage(
                imageData: data, imageMIME: "image/jpeg",
                sourceKind: .attachment, sourceID: nil, sourceTimestamp: .now
            )
            applyParsed(parsed)
        } catch {
            parseError = error.localizedDescription
        }
    }

    private func parseMaterial(_ material: CourseMaterial) {
        // Text sources: the material's extracted text (page text layer
        // first, OCR as fallback).
        let pages = (try? environment.repository.materialPages(materialID: material.id)) ?? []
        let text = pages.map(\.effectiveText).joined(separator: "\n")
        guard !text.isEmpty else {
            parseError = "这份资料还没有可识别的文本内容"
            return
        }
        parseText(text, kind: .material, sourceID: material.id)
    }

    private func parseSession(_ session: ClassroomSession) {
        let entries = (try? environment.repository.entries(for: session)) ?? []
        let notes = (try? environment.repository.notes(forSessionID: session.id)) ?? []
        var text = entries.map(\.originalText).joined(separator: "\n")
        if !notes.isEmpty {
            text += "\n" + notes.map(\.text).joined(separator: "\n")
        }
        guard !text.isEmpty else {
            parseError = "这堂课还没有转录或笔记内容"
            return
        }
        parseText(text, kind: .transcript, sourceID: session.id)
    }

    private func parseText(_ text: String, kind: ExamSource.SourceKind, sourceID: UUID?) {
        isParsing = true
        parseError = nil
        Task {
            defer { isParsing = false }
            do {
                let parsed = try await parser.parseText(
                    text, sourceKind: kind, sourceID: sourceID,
                    sourceTimestamp: .now
                )
                applyParsed(parsed)
            } catch {
                parseError = error.localizedDescription
            }
        }
    }

    /// Persists parsed candidates as DEVICE-LOCAL rows (status .pending,
    /// origin .ai). Nothing syncs, nothing is scheduled.
    private func applyParsed(_ parsed: ExamCandidateParser.Parsed) {
        guard !parsed.candidates.isEmpty else {
            parseError = parsed.missingInfo ?? "没有识别到考试安排"
            return
        }
        for candidate in parsed.candidates where candidate.isViable {
            let startSecs = Self.parseTimeToSecs(candidate.timeText) ?? -1
            var scope = candidate.scopeText
            if !candidate.requirements.isEmpty {
                scope = scope.isEmpty
                    ? candidate.requirements
                    : scope + "\n教师要求：" + candidate.requirements
            }
            _ = try? environment.repository.addExam(ExamDraft(
                title: candidate.title,
                kind: candidate.kind,
                examDateKey: candidate.dateKey.isEmpty ? Self.todayKey() : candidate.dateKey,
                startSecs: startSecs,
                location: candidate.location,
                scopeText: scope,
                status: .pending,
                origin: .ai,
                source: candidate.source
            ))
        }
        reload()
    }

    private static func parseTimeToSecs(_ text: String) -> Int? {
        guard !text.isEmpty else { return nil }
        let parts = text.replacingOccurrences(of: "：", with: ":").split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return hour * 3600 + minute * 60
    }

    private static func todayKey() -> String {
        Exam.dateKey(.now)
    }

    // MARK: - Actions

    private func confirm(_ candidate: Exam) {
        try? environment.repository.confirmExam(candidate)
        reload()
    }

    private func reload() {
        candidates = (try? environment.repository.pendingExamCandidates()) ?? []
        isLoaded = true
    }
}
