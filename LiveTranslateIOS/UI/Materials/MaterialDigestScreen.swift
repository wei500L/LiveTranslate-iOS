import SwiftUI
import Observation

/// The material digest (导读): overview, outline, concepts, Russian
/// terms, formulas, examples, assignments — every item carries page
/// references that jump back into the reader. Saving a term to the
/// glossary, creating a card, or confirming an assignment all go through
/// the EXISTING repository flows (dedup + confirmation included).
struct MaterialDigestScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = MaterialDigestViewModel()
    @State private var savedTermIDs: Set<UUID> = []
    @State private var savedCardKeys: Set<String> = []
    @State private var createdTaskKeys: Set<String> = []

    let materialID: UUID

    var body: some View {
        LTPage {
            Group {
                if viewModel.isLoaded, viewModel.material == nil {
                    LTEmptyState(
                        symbol: "questionmark.folder",
                        title: "资料不存在",
                        message: "这份资料可能已被删除"
                    )
                } else if viewModel.isLoaded {
                    digestContent
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("资料导读")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("完成") { dismiss() }
            }
        }
        .task {
            viewModel.attach(environment)
            viewModel.load(materialID: materialID)
        }
    }

    @ViewBuilder
    private var digestContent: some View {
        ScrollView {
            VStack(spacing: LTSpacing.l) {
                if viewModel.isGenerating {
                    generatingCard
                } else if let digest = viewModel.material?.digest {
                    digestSections(digest)
                } else {
                    emptyCard
                }
            }
            .padding(.horizontal, LTSpacing.screenPadding)
            .padding(.bottom, LTSpacing.tabBarReserve)
        }
    }

    /// Real-stage progress (准备 / 分段提取 / 识别扫描页 / 汇总 / 保存) —
    /// never a streaming animation.
    private var generatingCard: some View {
        VStack(spacing: LTSpacing.s) {
            ProgressView()
            Text(viewModel.progressLabel)
                .font(Font.subheadline)
                .foregroundStyle(LTColors.textSecondary)
            Button("取消") {
                viewModel.cancel(environment: environment)
            }
            .buttonStyle(LTSecondaryButtonStyle())
        }
        .ltCard()
    }

    private var emptyCard: some View {
        VStack(spacing: LTSpacing.s) {
            LTIconBadge(symbol: "sparkles", tint: LTColors.accentGreen, size: 44)
            Text("还没有导读")
                .font(LTTypography.cardTitle)
                .foregroundStyle(LTColors.textPrimary)
            switch viewModel.material?.digestStatus {
            case .partial:
                Text("上次整理没有完成，可以继续。")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textTertiary)
                Button("继续整理") {
                    viewModel.generate(environment: environment, resume: true)
                }
                .buttonStyle(LTPrimaryButtonStyle())
            case .failed:
                Text("上次整理失败，可以重试。")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textTertiary)
                generateButton
            default:
                Text(environment.isTranslationConfigured
                    ? "生成资料概述、目录、术语、公式与重点页码，全部带页码引用。"
                    : "生成导读需要先在设置中配置兼容模型。")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textTertiary)
                    .multilineTextAlignment(.center)
                generateButton
            }
        }
        .ltCard()
    }

    private var generateButton: some View {
        Group {
            if environment.isTranslationConfigured {
                Button("生成导读") {
                    viewModel.generate(environment: environment, resume: false)
                }
                .buttonStyle(LTPrimaryButtonStyle())
            }
        }
    }

    @ViewBuilder
    private func digestSections(_ digest: MaterialDigestResult) -> some View {
        if let overview = digest.overview, !overview.isEmpty {
            section("资料概述") {
                Text(overview)
                    .font(Font.subheadline)
                    .foregroundStyle(LTColors.textSecondary)
                    .lineSpacing(4)
                    .textSelection(.enabled)
            }
        }
        if let outline = digest.outline, !outline.isEmpty {
            section("目录结构") {
                VStack(alignment: .leading, spacing: LTSpacing.xs) {
                    ForEach(outline) { node in
                        VStack(alignment: .leading, spacing: LTSpacing.xxs) {
                            HStack(spacing: LTSpacing.xs) {
                                Text(node.title)
                                    .font(LTTypography.cardTitle)
                                    .foregroundStyle(LTColors.textPrimary)
                                pageRefs(node.pageRefs)
                            }
                            if !node.detail.isEmpty {
                                Text(node.detail)
                                    .font(LTTypography.caption)
                                    .foregroundStyle(LTColors.textTertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        if let concepts = digest.keyConcepts, !concepts.isEmpty {
            section("重要概念") {
                refItems(concepts)
            }
        }
        if let terms = digest.terms, !terms.isEmpty {
            section("俄语术语") {
                VStack(spacing: LTSpacing.s) {
                    ForEach(terms) { term in
                        VStack(alignment: .leading, spacing: LTSpacing.xxs) {
                            HStack(spacing: LTSpacing.xs) {
                                Text(term.russian)
                                    .font(LTTypography.cardTitle)
                                    .foregroundStyle(LTColors.textPrimary)
                                Text(term.chinese)
                                    .font(Font.subheadline)
                                    .foregroundStyle(LTColors.accentCyan)
                                Spacer()
                                Button(savedTermIDs.contains(term.id) ? "已保存" : "存入术语库") {
                                    saveTerm(term)
                                }
                                .font(LTTypography.button)
                                .buttonStyle(LTSecondaryButtonStyle(tint: LTColors.accentCyan))
                                .disabled(savedTermIDs.contains(term.id))
                            }
                            if !term.explanation.isEmpty {
                                Text(term.explanation)
                                    .font(LTTypography.caption)
                                    .foregroundStyle(LTColors.textTertiary)
                            }
                            pageRefs(term.pageRefs)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        if let formulas = digest.formulas, !formulas.isEmpty {
            section("公式与符号") {
                VStack(spacing: LTSpacing.s) {
                    ForEach(formulas) { formula in
                        VStack(alignment: .leading, spacing: LTSpacing.xxs) {
                            HStack(spacing: LTSpacing.xs) {
                                Text(formula.text)
                                    .font(.system(size: 15, design: .monospaced))
                                    .foregroundStyle(LTColors.textPrimary)
                                    .lineLimit(3)
                                Spacer()
                                Button(savedCardKeys.contains("f-\(formula.id)") ? "已制卡" : "制为卡片") {
                                    createFormulaCard(formula)
                                }
                                .font(LTTypography.button)
                                .buttonStyle(LTSecondaryButtonStyle(tint: LTColors.accentCyan))
                                .disabled(savedCardKeys.contains("f-\(formula.id)"))
                            }
                            if !formula.detail.isEmpty {
                                Text(formula.detail)
                                    .font(LTTypography.caption)
                                    .foregroundStyle(LTColors.textTertiary)
                            }
                            pageRefs(formula.pageRefs)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        if let examples = digest.examples, !examples.isEmpty {
            section("例题与步骤") {
                refItems(examples)
            }
        }
        if let assignments = digest.assignments, !assignments.isEmpty {
            section("作业与截止") {
                VStack(spacing: LTSpacing.s) {
                    ForEach(assignments) { assignment in
                        VStack(alignment: .leading, spacing: LTSpacing.xxs) {
                            HStack(spacing: LTSpacing.xs) {
                                Text(assignment.text)
                                    .font(Font.subheadline)
                                    .foregroundStyle(LTColors.textPrimary)
                                Spacer()
                                Button(createdTaskKeys.contains("a-\(assignment.id)") ? "已加入待确认" : "加入任务") {
                                    createTask(assignment)
                                }
                                .font(LTTypography.button)
                                .buttonStyle(LTSecondaryButtonStyle(tint: LTColors.warning))
                                .disabled(createdTaskKeys.contains("a-\(assignment.id)"))
                            }
                            if !assignment.detail.isEmpty {
                                Text(assignment.detail)
                                    .font(LTTypography.caption)
                                    .foregroundStyle(LTColors.textTertiary)
                            }
                            pageRefs(assignment.pageRefs)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("资料里识别出的作业先进入「待确认」，在复习中心确认后才成为正式任务。")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textTertiary)
                }
            }
        }
        if let prerequisites = digest.prerequisites, !prerequisites.isEmpty {
            section("阅读前需掌握") {
                VStack(alignment: .leading, spacing: LTSpacing.xxs) {
                    ForEach(prerequisites, id: \.self) { prerequisite in
                        Text("· \(prerequisite)")
                            .font(Font.subheadline)
                            .foregroundStyle(LTColors.textSecondary)
                    }
                }
            }
        }
        if let pages = digest.recommendedPages, !pages.isEmpty {
            section("建议重点阅读") {
                pageRefs(pages, prominent: true)
            }
        }
        if let uncertainties = digest.uncertainties, !uncertainties.isEmpty {
            section("不确定的内容") {
                VStack(alignment: .leading, spacing: LTSpacing.xxs) {
                    ForEach(uncertainties, id: \.self) { uncertainty in
                        Text("· \(uncertainty)")
                            .font(LTTypography.caption)
                            .foregroundStyle(LTColors.textTertiary)
                    }
                }
            }
        }
        // Regeneration (manual only — a stale digest never re-runs by
        // itself; the reader's card shows the 资料内容已更新 hint).
        if viewModel.isDigestStale {
            section(nil) {
                VStack(spacing: LTSpacing.xs) {
                    Text("资料内容已更新，可重新整理")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.warning)
                    if environment.isTranslationConfigured {
                        Button("重新生成导读") {
                            viewModel.generate(environment: environment, resume: false)
                        }
                        .buttonStyle(LTSecondaryButtonStyle())
                    }
                }
            }
        }
    }

    private func section(_ title: String?, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            if let title {
                LTSectionHeader(title: title)
            }
            content()
        }
        .ltCard()
    }

    private func refItems(_ items: [MaterialDigestResult.RefItem]) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: LTSpacing.xxs) {
                    Text(item.text)
                        .font(Font.subheadline)
                        .foregroundStyle(LTColors.textPrimary)
                    if !item.detail.isEmpty {
                        Text(item.detail)
                            .font(LTTypography.caption)
                            .foregroundStyle(LTColors.textTertiary)
                    }
                    pageRefs(item.pageRefs)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Page reference chips — taps jump to the real page in the reader.
    private func pageRefs(_ pages: [Int], prominent: Bool = false) -> some View {
        Group {
            if !pages.isEmpty {
                HStack(spacing: LTSpacing.xxs) {
                    ForEach(pages, id: \.self) { page in
                        Button {
                            viewModel.openReaderPage(page)
                        } label: {
                            Text("第 \(page) 页")
                                .font(LTTypography.caption)
                                .padding(.horizontal, LTSpacing.s)
                                .padding(.vertical, 2)
                                .background(
                                    (prominent ? LTColors.accentGreen : LTColors.accentBlue)
                                        .opacity(0.18)
                                )
                                .clipShape(Capsule())
                        }
                        .foregroundStyle(
                            prominent ? LTColors.accentGreen : LTColors.accentCyan
                        )
                        .accessibilityLabel(Text("跳到第 \(page) 页"))
                    }
                }
            }
        }
    }

    // MARK: - Learning-loop actions (existing repository flows)

    /// 存入术语库 — dedup against the course's existing terms (the
    /// repository's findTerm path) happens in the save sheet's save
    /// action; here we go straight through addTerm with dedup check.
    private func saveTerm(_ term: MaterialDigestResult.TermEntry) {
        guard let material = viewModel.material else { return }
        let courseID = material.courseID
        // Dedup within the course first (same normalized russian) —
        // existing term wins, we just record the new source.
        if let existing = try? environment.repository.findTerm(
            courseID: courseID, russian: term.russian
        ) {
            try? environment.repository.mergeTermSources(
                existing, sessionID: nil, entryID: nil, attachmentID: nil
            )
            savedTermIDs.insert(term.id)
            return
        }
        _ = try? environment.repository.addTerm(TermDraft(
            russian: term.russian,
            chinese: term.chinese,
            explanation: term.explanation,
            courseID: courseID,
            sourceMaterialID: material.id,
            sourceMaterialPage: term.pageRefs.first ?? 0
        ))
        savedTermIDs.insert(term.id)
    }

    private func createFormulaCard(_ formula: MaterialDigestResult.RefItem) {
        guard let material = viewModel.material else { return }
        _ = try? environment.repository.addCard(CardDraft(
            front: formula.text,
            back: formula.detail.isEmpty ? formula.text : formula.detail,
            type: .formula,
            origin: .ai,
            courseID: material.courseID,
            sourceMaterialID: material.id,
            sourceMaterialPage: formula.pageRefs.first ?? 0
        ))
        savedCardKeys.insert("f-\(formula.id)")
    }

    /// 加入任务 — enters pendingConfirm (an AI candidate the user
    /// confirms in the review center), never a direct task.
    private func createTask(_ assignment: MaterialDigestResult.RefItem) {
        guard let material = viewModel.material else { return }
        _ = try? environment.repository.addTask(TaskDraft(
            title: assignment.text,
            detail: assignment.detail,
            origin: .ai,
            status: .pendingConfirm,
            courseID: material.courseID,
            sourceMaterialID: material.id,
            sourceMaterialPage: assignment.pageRefs.first ?? 0
        ))
        createdTaskKeys.insert("a-\(assignment.id)")
    }
}

// MARK: - View model

@MainActor
@Observable
final class MaterialDigestViewModel {
    private(set) var material: CourseMaterial?
    private(set) var isLoaded = false
    /// Reader jump target (consumed by the presenting screen).
    var pendingReaderPage: Int?
    private weak var environmentBox: AppEnvironment?
    private var materialID: UUID?

    func attach(_ environment: AppEnvironment) {
        environmentBox = environment
    }

    func load(materialID: UUID) {
        self.materialID = materialID
        reload()
        isLoaded = true
    }

    func reload() {
        guard let materialID else { return }
        material = environmentBox.flatMap {
            try? $0.repository.material(id: materialID)
        } ?? nil
    }

    var isGenerating: Bool {
        guard let material else { return false }
        return environmentBox?.materialDigestGenerator.isActive(material.id) ?? false
    }

    var progressLabel: String {
        guard let material else { return "" }
        return environmentBox?.materialDigestGenerator.progress(for: material.id)?.label
            ?? "正在整理资料内容…"
    }

    var isDigestStale: Bool {
        guard let material else { return false }
        return environmentBox?.materialDigestGenerator.isDigestStale(material) ?? false
    }

    func generate(environment: AppEnvironment, resume: Bool) {
        guard let material else { return }
        environment.materialDigestGenerator.generate(material: material, resume: resume)
    }

    func cancel(environment: AppEnvironment) {
        guard let material else { return }
        environment.materialDigestGenerator.cancel(material.id)
    }

    func openReaderPage(_ page: Int) {
        pendingReaderPage = page
    }
}
