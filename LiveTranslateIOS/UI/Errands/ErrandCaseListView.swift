import SwiftUI

/// 办事事项列表（从首页/搜索/Intent push 进入 —— 不新增底部 Tab）。
/// 显示正式事项与进行中的草稿；归档项默认隐藏但可达。
struct ErrandCaseListView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var viewModel = ErrandViewModel()
    @State private var pushingDetail: ErrandCase?
    @State private var showingEditor = false
    @State private var showingArchived = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LTPage {
                ScrollView {
                    VStack(spacing: LTSpacing.l) {
                        if !viewModel.drafts.isEmpty {
                            draftsSection
                        }
                        if viewModel.cases.isEmpty && viewModel.drafts.isEmpty {
                            LTEmptyState(
                                symbol: "checklist",
                                title: "还没有办事事项",
                                message: "从随身翻译的对话或文件整理一件事，或手动新建。无网络也能完整使用。"
                            )
                        }
                        caseList(viewModel.cases)
                        if showingArchived {
                            archivedSection
                        }
                    }
                    .padding(.horizontal, LTSpacing.screenPadding)
                    .padding(.top, LTSpacing.s)
                    .padding(.bottom, LTSpacing.xl)
                }
            }
            .navigationTitle("办事事项")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingEditor = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(LTColors.accentGreen)
                    }
                    .accessibilityLabel(Text("新建办事事项"))
                }
            }
            .navigationDestination(item: Binding(
                get: { pushingDetail.map { ErrandCaseRoute(caseID: $0.id) } },
                set: { pushingDetail = $0?.caseID.flatMap(environment.repository.errandCase(id:)) }
            )) { route in
                ErrandCaseDetailView(caseID: route.caseID)
                    .environment(environment)
            }
            .sheet(isPresented: $showingEditor) {
                ErrandCaseEditorView(sourceConversationID: nil)
                    .environment(environment)
            }
            .task {
                viewModel.attach(environment)
                viewModel.reload()
                await environment.refreshErrandReminders()
            }
            .onAppear {
                viewModel.reload()
                consumeRoutes()
            }
        }
    }

    private struct ErrandCaseRoute: Identifiable {
        var caseID: UUID
        var id: UUID { caseID }
    }

    private func consumeRoutes() {
        // 系统路由（Intent/Spotlight 的 errandCaseList 打开这里）。
        if environment.flow.pendingErrandCaseList {
            environment.flow.consumeErrandCaseListRoute()
        }
        // 通知路由的指定事项。
        if let caseID = environment.flow.pendingErrandCaseID {
            environment.flow.consumeErrandCaseReminder()
            if let target = environment.repository.errandCase(id: caseID) {
                pushingDetail = target
            } else {
                environment.reportMissingTarget("这个办事事项已不存在")
            }
        }
    }

    // MARK: - Sections

    private var draftsSection: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            LTSectionHeader(title: "草稿（仅本机，不同步）")
            ForEach(viewModel.drafts) { draft in
                Button {
                    pushingDetail = draft
                } label: {
                    ErrandCaseRow(
                        errandCase: draft,
                        statusText: "草稿",
                        reason: "未保存 —— 保存后才进入云同步",
                        tint: LTColors.warning,
                        isDraft: true
                    )
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("未保存的草稿，点按继续整理"))
            }
        }
    }

    @ViewBuilder
    private func caseList(_ cases: [ErrandCase]) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            LTSectionHeader(title: "进行中")
            ForEach(cases) { errandCase in
                formalRow(errandCase)
            }
            archivedToggle
        }
    }

    private func formalRow(_ errandCase: ErrandCase) -> some View {
        Button {
            pushingDetail = errandCase
        } label: {
            ErrandCaseRow(
                errandCase: errandCase,
                statusText: errandCase.status.displayName,
                reason: rowReason(errandCase),
                tint: tint(errandCase),
                isDraft: false
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("点按查看材料清单与进度"))
    }

    /// 显示已归档入口（计数在构建器块外求值 —— ViewBuilder 的 if 块里
    /// 不能放 let 声明）。
    @ViewBuilder
    private var archivedToggle: some View {
        let archivedCount = archivedCases().count
        if !showingArchived && archivedCount > 0 {
            Button {
                showingArchived = true
            } label: {
                Label(
                    archivedToggleLabel(archivedCount),
                    systemImage: "archivebox"
                )
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.textSecondary)
            }
        }
    }

    private func archivedToggleLabel(_ count: Int) -> String {
        "显示已归档（\(count)）"
    }

    private var archivedSection: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            LTSectionHeader(title: "已归档")
            ForEach(archivedCases()) { errandCase in
                Button {
                    pushingDetail = errandCase
                } label: {
                    ErrandCaseRow(
                        errandCase: errandCase,
                        statusText: errandCase.status.displayName,
                        reason: rowReason(errandCase),
                        tint: LTColors.textTertiary,
                        isDraft: false
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func archivedCases() -> [ErrandCase] {
        ((try? environment.repository.errandCases(includeArchived: true)) ?? [])
            .filter { $0.status == .archived }
    }

    private func rowReason(_ errandCase: ErrandCase) -> String {
        let items = (try? environment.repository.errandCaseItems(caseID: errandCase.id)) ?? []
        let pending = items.filter { $0.status == .pending }.count
        let dated = items
            .filter { $0.kind.carriesTime && $0.dueAt != nil && $0.status == .pending }
            .compactMap(\.dueAt).min()
        if let dated {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "M月d日"
            return "最近时间 \(formatter.string(from: dated)) · 待办 \(pending)"
        }
        return pending > 0 ? "待办 \(pending) 项" : errandCase.status.displayName
    }

    private func tint(_ errandCase: ErrandCase) -> Color {
        switch errandCase.status {
        case .scheduled: return LTColors.accentCyan
        case .waitingForResult: return LTColors.warning
        case .needsFollowUp: return LTColors.warning
        case .completed: return LTColors.accentGreen
        default: return LTColors.accentBlue
        }
    }
}

// MARK: - Row

/// 一行事项卡片：类型图标、颜色与 VoiceOver 文案区分（不只靠颜色）。
private struct ErrandCaseRow: View {
    let errandCase: ErrandCase
    let statusText: String
    let reason: String
    let tint: Color
    let isDraft: Bool

    var body: some View {
        HStack(spacing: LTSpacing.m) {
            LTIconBadge(symbol: errandCase.scene.symbol, tint: tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(errandCase.title)
                    .font(LTTypography.cardTitle)
                    .foregroundStyle(LTColors.textPrimary)
                    .lineLimit(2)
                Text(reason)
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(statusText)
                .font(.caption.weight(.medium))
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(tint.opacity(0.14)))
        }
        .ltCard(padding: LTSpacing.l)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(errandCase.title)，\(statusText)，\(reason)"))
    }
}
