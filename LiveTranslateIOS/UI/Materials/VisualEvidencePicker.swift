import SwiftUI

/// Multi-select evidence picker for visual Q&A: classroom images (per
/// session) and course materials (image materials as one row, PDFs as
/// selectable pages). The selection is capped at
/// `VisualAskImagePipeline.maxEvidenceCount` — the counter shows the
/// real budget; going over is refused visibly, not silently.
struct VisualEvidencePickerSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    /// Course scope for both lists (nil = everything).
    let courseID: UUID?
    /// Preselects this session's attachments section (reader/session
    /// entry points); nil = list the course's sessions.
    var focusSessionID: UUID? = nil
    /// Preselects this material's pages (reader entry).
    var focusMaterialID: UUID? = nil
    /// Already-selected evidence (counts toward the cap).
    let existing: [VisualEvidence]
    let onDone: ([VisualEvidence]) -> Void

    @State private var selected: [VisualEvidence] = []
    @State private var sessions: [ClassroomSession] = []
    @State private var attachmentsBySession: [UUID: [SessionAttachment]] = [:]
    @State private var materials: [CourseMaterial] = []
    @State private var loaded = false

    private var capacity: Int {
        VisualAskImagePipeline.maxEvidenceCount - existing.count
    }

    var body: some View {
        NavigationStack {
            LTPage {
                if !loaded {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    list
                }
            }
            .navigationTitle("选择图片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成（\(selected.count)）") {
                        onDone(existing + selected)
                        dismiss()
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
        .presentationDetents([.large])
        .task { load() }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LTSpacing.l) {
                Label(
                    "一次最多 \(VisualAskImagePipeline.maxEvidenceCount) 张图片或页面\(capacity < VisualAskImagePipeline.maxEvidenceCount ? "，还可再选 \(max(capacity, 0)) 张" : "")",
                    systemImage: "photo.stack"
                )
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.textSecondary)

                if !sessions.isEmpty {
                    LTSectionHeader(title: "课堂图片")
                    ForEach(sessions) { session in
                        sessionSection(session)
                    }
                }
                if !materials.isEmpty {
                    LTSectionHeader(title: "课程资料")
                    ForEach(materials) { material in
                        materialSection(material)
                    }
                }
                if sessions.isEmpty && materials.isEmpty {
                    LTEmptyState(
                        symbol: "photo.on.rectangle",
                        title: "没有可提问的图片",
                        message: "先在课堂里拍摄板书，或把 PDF/图片导入课程资料库"
                    )
                }
            }
            .padding(.horizontal, LTSpacing.screenPadding)
            .padding(.bottom, LTSpacing.tabBarReserve)
        }
    }

    // MARK: - Classroom images

    @ViewBuilder
    private func sessionSection(_ session: ClassroomSession) -> some View {
        let attachments = attachmentsBySession[session.id] ?? []
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            Text(session.title)
                .font(LTTypography.cardTitle)
                .foregroundStyle(LTColors.textPrimary)
            if attachments.isEmpty {
                Text("这堂课没有图片")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textTertiary)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 88), spacing: LTSpacing.s)],
                    spacing: LTSpacing.s
                ) {
                    ForEach(attachments, id: \.id) { attachment in
                        let evidence = VisualAskEvidenceLoader.attachmentEvidence(attachment)
                        Button {
                            toggle(evidence)
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                VisualEvidenceThumbnail(evidence: evidence)
                                    .frame(height: 88)
                                    .clipShape(RoundedRectangle(cornerRadius: LTRadius.small))
                                selectionMark(for: evidence)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!isSelected(evidence) && capacity - selected.count <= 0)
                        .accessibilityLabel(Text("选择 \(evidence.title)"))
                    }
                }
            }
        }
        .ltCard()
    }

    // MARK: - Materials

    @ViewBuilder
    private func materialSection(_ material: CourseMaterial) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            HStack(spacing: LTSpacing.s) {
                LTIconBadge(
                    symbol: material.format.symbol,
                    tint: material.ownsFile ? LTColors.accentBlue : LTColors.accentCyan,
                    size: 34
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(material.title.isEmpty ? material.originalFileName : material.title)
                        .font(LTTypography.button)
                        .foregroundStyle(LTColors.textPrimary)
                        .lineLimit(1)
                    Text(material.format == .pdf ? "PDF · \(material.pageCount) 页" : "图片资料")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textTertiary)
                }
                Spacer()
            }
            switch material.format {
            case .image:
                let evidence = VisualAskEvidenceLoader.materialImageEvidence(material)
                Button {
                    toggle(evidence)
                } label: {
                    HStack {
                        VisualEvidenceThumbnail(evidence: evidence)
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: LTRadius.small))
                        Spacer()
                        selectionMark(for: evidence)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!isSelected(evidence) && capacity - selected.count <= 0)
            case .pdf:
                // Page chips are always selectable (LazyVGrid stays
                // bounded); very long PDFs cap at 40 with the honest
                // in-reader alternative.
                let shownPages = min(material.pageCount, 40)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 64), spacing: LTSpacing.xs)],
                    spacing: LTSpacing.xs
                ) {
                    ForEach(1...max(shownPages, 1), id: \.self) { page in
                        let evidence = VisualAskEvidenceLoader.materialPageEvidence(material, pageNumber: page)
                        Button {
                            toggle(evidence)
                        } label: {
                            Text("第 \(page) 页")
                                .font(LTTypography.button)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, LTSpacing.xs)
                                .background(
                                    isSelected(evidence)
                                        ? LTColors.accentGreen.opacity(0.25)
                                        : LTColors.surfacePrimary.opacity(0.7)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: LTRadius.small))
                                .overlay(
                                    RoundedRectangle(cornerRadius: LTRadius.small)
                                        .strokeBorder(
                                            isSelected(evidence) ? LTColors.accentGreen : LTColors.border,
                                            lineWidth: 1
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(!isSelected(evidence) && capacity - selected.count <= 0)
                    }
                }
                if material.pageCount > 40 {
                    Text("这份资料页数较多，只列出前 40 页；翻到目标页后用阅读器里的「询问此页」。")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textTertiary)
                }
            case .text, .markdown, .other:
                Text("文字资料无需选图，直接在课程助手里提问即可。")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textTertiary)
            }
        }
        .ltCard()
    }

    // MARK: - Selection

    private func selectionMark(for evidence: VisualEvidence) -> some View {
        ZStack {
            if isSelected(evidence) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(LTColors.accentGreen)
            } else {
                Circle()
                    .strokeBorder(LTColors.textTertiary.opacity(0.6), lineWidth: 1)
                    .frame(width: 18, height: 18)
            }
        }
        .padding(6)
    }

    private func isSelected(_ evidence: VisualEvidence) -> Bool {
        selected.contains { $0.kindRaw == evidence.kindRaw && $0.sourceID == evidence.sourceID && $0.pageNumber == evidence.pageNumber }
            || existing.contains { $0.kindRaw == evidence.kindRaw && $0.sourceID == evidence.sourceID && $0.pageNumber == evidence.pageNumber }
    }

    private func toggle(_ evidence: VisualEvidence) {
        if let index = selected.firstIndex(where: {
            $0.kindRaw == evidence.kindRaw && $0.sourceID == evidence.sourceID && $0.pageNumber == evidence.pageNumber
        }) {
            selected.remove(at: index)
            return
        }
        guard selected.count < capacity else { return }
        selected.append(evidence)
    }

    // MARK: - Loading

    private func load() {
        let repository = environment.repository
        // Sessions: the focused one, else the course's sessions.
        let allSessions = (try? repository.sessions(matching: "")) ?? []
        if let focusSessionID {
            sessions = allSessions.filter { $0.id == focusSessionID }
        } else if let courseID {
            sessions = allSessions.filter { $0.courseID == courseID }
        } else {
            sessions = allSessions
        }
        // Most recent sessions first, capped — the picker stays fast on
        // long histories.
        sessions.sort { $0.startTime > $1.startTime }
        var bySession: [UUID: [SessionAttachment]] = [:]
        for session in sessions.prefix(12) {
            bySession[session.id] = ((try? repository.attachments(forSessionID: session.id)) ?? [])
                .sorted { $0.capturedAt < $1.capturedAt }
        }
        attachmentsBySession = bySession
        sessions = sessions.filter { !(bySession[$0.id] ?? []).isEmpty }

        if let focusMaterialID {
            materials = [((try? repository.material(id: focusMaterialID)) ?? nil)].compactMap { $0 }
        } else {
            materials = ((try? repository.materials(courseID: courseID)) ?? [])
                .filter { $0.format == .image || $0.format == .pdf }
                .sorted { $0.lastOpenedAt ?? $0.createdAt > $1.lastOpenedAt ?? $1.createdAt }
        }
        loaded = true
    }
}
