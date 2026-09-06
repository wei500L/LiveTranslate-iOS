import SwiftUI

/// 办事事项草稿编辑器：手动创建（无 AI、无网络可用）、从对话/文件整
/// 理候选、AI 结构化整理（可选）。保存前明确显示同步边界。
struct ErrandCaseEditorView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    /// 从随身翻译带来的来源对话（nil = 空白创建）。
    var sourceConversationID: UUID?
    /// 从文件助手带来的来源文件（文件分析结果 → 候选；本地来源链接）。
    var sourceDocumentID: UUID?

    init(
        sourceConversationID: UUID? = nil,
        sourceDocumentID: UUID? = nil
    ) {
        self.sourceConversationID = sourceConversationID
        self.sourceDocumentID = sourceDocumentID
    }

    @State private var viewModel = ErrandViewModel()
    @State private var draft: ErrandCase?
    @State private var title = ""
    @State private var purpose = ""
    @State private var note = ""
    @State private var location = ""
    @State private var contact = ""
    @State private var scene: InterpreterScene = .general
    @State private var userContext = ""
    @State private var showingAIHint = false
    @State private var showSaveConfirm = false
    /// AI 发送预览确认（AI 请求先经过发送预览 —— 用户核对后才发出）。
    @State private var showAIPreviewConfirm = false

    var body: some View {
        NavigationStack {
            LTPage {
                ScrollView {
                    VStack(alignment: .leading, spacing: LTSpacing.l) {
                        basicSection
                        if let sourceConversationID {
                            sourceSection(sourceConversationID)
                        }
                        contextSection
                        aiSection
                        syncBoundaryNotice
                    }
                    .padding(.horizontal, LTSpacing.screenPadding)
                    .padding(.top, LTSpacing.s)
                    .padding(.bottom, LTSpacing.xl)
                }
            }
            // 草稿编辑页携带敏感背景 —— 录屏/镜像时遮挡。
            .screenCaptureMask()
            .navigationTitle("新办事事项")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { cancel() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { showSaveConfirm = true }
                        .font(.body.weight(.semibold))
                }
            }
            .confirmationDialog(
                "保存这个办事事项？",
                isPresented: $showSaveConfirm,
                titleVisibility: .visible
            ) {
                Button("保存并同步") { save() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("保存后这些字段会同步到你的账号：标题、场景、目的、备注、地点、联系方式、清单与已确认的时间。本地来源链接（文件名/页码/引文）、提醒与日历设置仅保存在本机。")
            }
            .confirmationDialog(
                "发送给 AI 整理？",
                isPresented: $showAIPreviewConfirm,
                titleVisibility: .visible
            ) {
                Button("发送并整理") {
                    Task {
                        await viewModel.organizeWithAI(
                            conversationID: sourceConversationID,
                            documentIDs: sourceDocumentID.map { [$0] } ?? [],
                            userContext: userContext,
                            scene: scene
                        )
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text(viewModel.organizeDisclosureSummary ?? "将发送所选对话与文件摘录")
            }
            .alert(
                "没有可发送的内容",
                isPresented: $showingAIHint
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text("请先在随身翻译里产生对话，或选择一份已完成提取的文件，或填写办事背景。")
            }
            .task {
                viewModel.attach(environment)
                viewModel.reload()
                if draft == nil {
                    createDraft()
                }
            }
        }
    }

    private func createDraft() {
        var resolvedScene = scene
        if let sourceConversationID,
           let conversation = environment.repository.interpreterConversation(id: sourceConversationID) {
            resolvedScene = conversation.scene
        }
        scene = resolvedScene
        draft = viewModel.startDraft(scene: resolvedScene)
        if title.isEmpty {
            title = draft?.title ?? ""
        }
        // 从对话创建：默认只建立本地来源链接（不复制对话、不修改原对话；
        // 重复加入幂等）。
        if let sourceConversationID, let draft {
            _ = try? environment.repository.addErrandLocalSource(
                to: draft,
                ErrandLocalSource(kind: .conversation, conversationID: sourceConversationID)
            )
            // 本地规则候选（确定性、可解释 —— 无 AI 也能整理）。
            viewModel.extractLocalCandidates(fromConversation: sourceConversationID)
        }
        // 从文件创建：文件分析已确认的结构化结果直读为候选（重复加入
        // 幂等；删除文件不删事项）。
        if let sourceDocumentID, let draft {
            if let document = environment.repository.interpreterDocument(id: sourceDocumentID) {
                _ = try? environment.repository.addErrandLocalSource(
                    to: draft,
                    ErrandLocalSource(
                        kind: .document,
                        documentID: document.id,
                        documentName: document.originalFileName
                    )
                )
                viewModel.extractLocalCandidates(fromDocumentAnalysis: document.id)
            }
        }
    }

    // MARK: - Sections

    private var basicSection: some View {
        VStack(alignment: .leading, spacing: LTSpacing.m) {
            LabeledContent {
                TextField("事项标题", text: $title)
                    .multilineTextAlignment(.trailing)
            } label: {
                Text("标题")
            }
            Picker("场景", selection: $scene) {
                ForEach(InterpreterScene.allCases) { scene in
                    Text(scene.displayName).tag(scene)
                }
            }
            LabeledContent {
                TextField("去哪里办（可留空）", text: $location)
                    .multilineTextAlignment(.trailing)
            } label: {
                Text("地点")
            }
            LabeledContent {
                TextField("电话/邮箱（可留空）", text: $contact)
                    .multilineTextAlignment(.trailing)
            } label: {
                Text("联系方式")
            }
        }
        .ltCard(padding: LTSpacing.l)
    }

    @ViewBuilder
    private func sourceSection(_ conversationID: UUID) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.xs) {
            Label("来源（仅本机链接）", systemImage: "link")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(LTColors.textSecondary)
            Text("对话与文件不会被复制或上传；删除事项不影响原件。清单建好后可在详情里继续加入来源。")
                .font(.caption2)
                .foregroundStyle(LTColors.textTertiary)
        }
        .ltCard(padding: LTSpacing.m)
    }

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: LTSpacing.m) {
            LabeledContent {
                TextField("一句话目的（如：办宿舍入住登记）", text: $purpose, axis: .vertical)
                    .lineLimit(1...3)
                    .multilineTextAlignment(.trailing)
            } label: {
                Text("目的")
            }
            LabeledContent {
                TextField("备注", text: $note, axis: .vertical)
                    .lineLimit(1...4)
                    .multilineTextAlignment(.trailing)
            } label: {
                Text("备注")
            }
            TextField("办事背景（给 AI 整理用，可留空）", text: $userContext, axis: .vertical)
                .lineLimit(2...4)
        }
        .ltCard(padding: LTSpacing.l)
    }

    private var aiSection: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            HStack {
                Label("整理候选", systemImage: "wand.and.stars")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(LTColors.textSecondary)
                Spacer()
                // 本地规则（永远可用 —— 无网络、无模型）。
                if let sourceConversationID {
                    Button("本地规则") {
                        viewModel.extractLocalCandidates(fromConversation: sourceConversationID)
                    }
                    .font(.footnote.weight(.medium))
                    .buttonStyle(.bordered)
                    .tint(LTColors.accentBlue)
                }
                Button {
                    // 先构建发送预览（不请求模型）—— 用户核对摘要后才
                    // 真正发出。
                    let hasContent = viewModel.previewOrganize(
                        conversationID: sourceConversationID,
                        documentIDs: sourceDocumentID.map { [$0] } ?? [],
                        userContext: userContext,
                        scene: scene
                    )
                    if hasContent {
                        showAIPreviewConfirm = true
                    } else {
                        showingAIHint = true
                    }
                } label: {
                    if viewModel.isOrganizing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("AI 整理")
                    }
                }
                .font(.footnote.weight(.medium))
                .buttonStyle(.bordered)
                .tint(LTColors.accentCyan)
                .disabled(!viewModel.isAIConfigured || viewModel.isOrganizing)
            }
            if !viewModel.isAIConfigured {
                // 模型未配置：禁用 AI 并给设置入口，但不禁用手动能力。
                HStack {
                    Text("AI 未配置 —— 手动创建与本地规则不受影响")
                        .font(.caption2)
                        .foregroundStyle(LTColors.textTertiary)
                    Spacer()
                    NavigationLink {
                        SettingsScreen()
                    } label: {
                        Text("去设置")
                            .font(.caption2.weight(.medium))
                    }
                }
            }
            if let error = viewModel.organizeError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(LTColors.warning)
            }
            if viewModel.candidates.isEmpty {
                Text("保存后可以在详情里逐项添加材料、动作、问题与时间。")
                    .font(.caption2)
                    .foregroundStyle(LTColors.textTertiary)
            } else {
                Text("候选 \(viewModel.candidates.count) 条 —— 保存后在详情里逐项核对加入")
                    .font(.caption2)
                    .foregroundStyle(LTColors.warning)
                ForEach(viewModel.candidates.prefix(8)) { candidate in
                    HStack(alignment: .top, spacing: LTSpacing.s) {
                        Image(systemName: candidate.kind.symbol)
                            .font(.caption)
                            .foregroundStyle(LTColors.warning)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.title)
                                .font(.caption)
                                .foregroundStyle(LTColors.textPrimary)
                                .lineLimit(2)
                            Text(candidate.reason)
                                .font(.caption2)
                                .foregroundStyle(LTColors.textTertiary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .ltCard(padding: LTSpacing.m)
    }

    private var syncBoundaryNotice: some View {
        Label(
            "草稿仅保存在本机；保存后才同步（字段见保存确认）。本地来源与提醒永不上传。",
            systemImage: "lock.shield"
        )
        .font(.caption2)
        .foregroundStyle(LTColors.textTertiary)
    }

    // MARK: - Actions

    private func save() {
        guard let draft else { return }
        if !title.trimmingCharacters(in: .whitespaces).isEmpty {
            try? environment.repository.updateErrandCaseMeta(
                draft, title: title, purpose: purpose,
                userNote: note, timezoneID: TimeZone.current.identifier,
                location: location, contact: contact,
                expectedResultAt: nil, pinned: nil, scene: scene
            )
        }
        // 候选物化为 .unconfirmed 行（设备本地 —— 正式事项里也绝不上
        // 船，直到用户逐项确认；杀 App 后草稿与候选均可恢复）。
        for candidate in viewModel.candidates {
            _ = try? environment.repository.addErrandCaseItem(ErrandItemDraft(
                caseID: draft.id,
                title: candidate.title,
                kind: candidate.kind,
                status: .unconfirmed,
                detail: candidate.detail,
                dateText: candidate.date?.rawText ?? "",
                dateIsRelative: candidate.date?.isRelative ?? false,
                dateUncertain: candidate.date?.uncertain ?? false,
                origin: .ai,
                confirmed: false,
                feeText: candidate.feeText ?? ""
            ))
        }
        viewModel.saveDraft(draft)
        dismiss()
    }

    private func cancel() {
        // 有用户输入的草稿按询问保存处理：这里走确认弹窗（简化为保留
        // 草稿 —— 列表里可见"草稿"区，用户可继续编辑或丢弃）。
        if let draft {
            let items = (try? environment.repository.errandCaseItems(caseID: draft.id)) ?? []
            let hasContent = !purpose.isEmpty || !note.isEmpty || !location.isEmpty
                || !contact.isEmpty || !(draft.localSources ?? []).isEmpty
            if items.isEmpty && !hasContent {
                // 空草稿退出时清理。
                viewModel.discardDraft(draft)
            }
        }
        dismiss()
    }
}
