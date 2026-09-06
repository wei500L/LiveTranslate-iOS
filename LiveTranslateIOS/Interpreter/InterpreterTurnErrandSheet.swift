import SwiftUI

/// 记入事项确认 sheet（第二十轮）：把对方 turn 的现场要求记入当前办
/// 事项。简短确认，不进入完整事项编辑器 —— 正式写入走既有
/// ErrandCaseItem Repository（addErrandCaseItem），成功后上下文条与
/// 未完成计数立即刷新。
///
/// 诚实原则：
/// - 标题用当前中文翻译预填，用户可编辑；
/// - 日期候选来自 ErrandDateParser 对来源文本的确定性解析 —— 仍必须
///   经过现有日期确认流程（记入时不自动设提醒，用户在事项详情里
///   确认时间）；
/// - 费用只用来源中明确出现的文本，不换算、不猜币种；
/// - 同一类型重复保存相同内容时提示现有项，不静默重复创建。
struct InterpreterTurnErrandSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let viewModel: InterpreterViewModel
    let turn: InterpreterTurn
    let onSaved: () -> Void

    @State private var title = ""
    @State private var kind: ErrandCaseItemKind = .action
    @State private var detail = ""
    @State private var feeText = ""
    @State private var message: String?
    /// 未从 ErrandCase 进入时的选择（正式事项 / 新草稿）。
    @State private var selectedCaseID: UUID?
    @State private var showNewCase = false

    init(viewModel: InterpreterViewModel, turn: InterpreterTurn, onSaved: @escaping () -> Void) {
        self.viewModel = viewModel
        self.turn = turn
        self.onSaved = onSaved
        // 用中文翻译预填标题（无翻译时回退俄语原文 —— 诚实保留）。
        let source = turn.direction == .ru2zh
            ? (turn.chineseText.isEmpty ? turn.sourceText : turn.chineseText)
            : turn.chineseText
        _title = State(initialValue: source)
    }

    private var currentCaseID: UUID? { viewModel.errandCaseID }

    /// 来源文本（日期/费用候选的解析来源：中文翻译 + 俄语原文）。
    private var sourceText: String {
        turn.direction == .ru2zh
            ? turn.chineseText.isEmpty ? turn.sourceText : turn.chineseText
            : turn.chineseText
    }

    /// 确定性日期候选（预填展示用；正式确认仍走事项详情的日期确认
    /// 流程）。
    private var dateCandidates: [ErrandDateParser.Candidate] {
        ErrandDateParser.candidates(in: sourceText)
    }

    var body: some View {
        NavigationStack {
            LTPage {
                Form {
                    Section("类型") {
                        Picker("类型", selection: $kind) {
                            ForEach(ErrandCaseItemKind.allCases) { kind in
                                Label(kind.displayName, systemImage: kind.symbol)
                                    .tag(kind)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                    Section("内容（预填自翻译，可编辑）") {
                        TextField("标题", text: $title, axis: .vertical)
                            .lineLimit(2...4)
                        TextField("说明（可选）", text: $detail)
                    }
                    if kind == .payment {
                        Section("费用（只使用来源中明确出现的文本）") {
                            TextField("费用原文（如：3500 卢布）", text: $feeText)
                                .autocorrectionDisabled()
                            Text("费用只记录来源中明确出现的文字，不换算、不猜测币种。")
                                .font(LTTypography.caption)
                                .foregroundStyle(LTColors.textTertiary)
                        }
                    }
                    if kind.carriesTime {
                        Section("日期") {
                            if dateCandidates.isEmpty {
                                Label("来源中没有可识别的日期", systemImage: "calendar")
                                    .font(LTTypography.caption)
                                    .foregroundStyle(LTColors.textTertiary)
                            } else {
                                ForEach(dateCandidates) { candidate in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(candidate.rawText)
                                            .font(LTTypography.body)
                                        Text(candidate.reason)
                                            .font(LTTypography.caption)
                                            .foregroundStyle(LTColors.textTertiary)
                                    }
                                }
                                Label(
                                    "记入后请在事项详情中确认时间（不确定的日期绝不自动设提醒）",
                                    systemImage: "clock"
                                )
                                .font(LTTypography.caption)
                                .foregroundStyle(LTColors.textTertiary)
                            }
                        }
                    }
                    caseSection
                    if let message {
                        Section {
                            Text(message)
                                .font(LTTypography.interpreterStatus)
                                .foregroundStyle(LTColors.warning)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("记入事项")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("记入", action: save)
                        .font(.body.weight(.semibold))
                        .disabled(trimmedTitle.isEmpty)
                }
            }
        }
        .presentationDetents([.large])
        .screenCaptureMask()
    }

    /// 未从 ErrandCase 进入时的选择（现有事项 / 新草稿）。
    @ViewBuilder
    private var caseSection: some View {
        if currentCaseID == nil {
            Section("记到哪里") {
                if let cases = try? environment.repository.errandCases() {
                    ForEach(cases) { errandCase in
                        Button {
                            selectedCaseID = errandCase.id
                            showNewCase = false
                        } label: {
                            HStack {
                                Text(errandCase.title)
                                    .foregroundStyle(LTColors.textPrimary)
                                Spacer()
                                if selectedCaseID == errandCase.id && !showNewCase {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(LTColors.accentBlue)
                                }
                            }
                        }
                    }
                }
                Button {
                    showNewCase = true
                    selectedCaseID = nil
                } label: {
                    HStack {
                        Label("新建草稿事项", systemImage: "plus")
                            .foregroundStyle(LTColors.accentBlue)
                        Spacer()
                        if showNewCase {
                            Image(systemName: "checkmark")
                                .foregroundStyle(LTColors.accentBlue)
                        }
                    }
                }
            }
        }
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 保存（走既有 Repository —— 不在 Interpreter 里重做事项管理）

    private func save() {
        let trimmed = trimmedTitle
        guard !trimmed.isEmpty else { return }
        let repository = environment.repository
        // 目标事项：当前关联 > 用户选择；两者皆无时必须显式新建草稿。
        let caseID: UUID
        if let currentCaseID {
            guard repository.errandCase(id: currentCaseID) != nil else {
                message = "该事项已不存在（可能已在本机或其他设备删除）"
                return
            }
            caseID = currentCaseID
        } else if let selectedCaseID {
            guard repository.errandCase(id: selectedCaseID) != nil else {
                message = "该事项已不存在（可能已在本机或其他设备删除）"
                return
            }
            caseID = selectedCaseID
        } else if showNewCase {
            // 新草稿：复用第十八轮草稿创建（设备本地，不通知同步）。
            do {
                let draft = try repository.startErrandCaseDraft(
                    scene: viewModel.scene, title: trimmed
                )
                caseID = draft.id
            } catch {
                message = "创建草稿失败：\(error.localizedDescription)"
                return
            }
        } else {
            message = "请选择一个事项或新建草稿"
            return
        }
        // 同一类型重复保存相同内容 → 提示现有项，不静默重复创建。
        let existing = (try? repository.errandCaseItems(caseID: caseID)) ?? []
        let normalized = trimmed
        if let duplicate = existing.first(where: {
            $0.kind == kind && $0.title.trimmingCharacters(in: .whitespacesAndNewlines) == normalized
        }) {
            message = "已存在相同内容：\(duplicate.title)"
            return
        }
        var draft = ErrandItemDraft(
            caseID: caseID, title: trimmed, kind: kind, detail: detail
        )
        if kind == .payment, !feeText.isEmpty {
            draft.feeText = feeText
        }
        do {
            let item = try repository.addErrandCaseItem(draft)
            // 时间语义类型带上来源中的日期原文（正式确认仍走事项详情 ——
            // 这里只带文本，不设提醒）。
            if kind.carriesTime, let candidate = dateCandidates.first {
                try? repository.setErrandCaseItemDate(
                    item, dueAt: nil, dateText: candidate.rawText,
                    isRelative: candidate.isRelative, uncertain: candidate.uncertain
                )
            }
            viewModel.refreshCounterContext()
            onSaved()
            dismiss()
        } catch {
            message = "保存失败：\(error.localizedDescription)"
        }
    }
}
