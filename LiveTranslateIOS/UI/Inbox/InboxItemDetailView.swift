import SwiftUI
import PDFKit

/// One inbox item's organizing surface: the original content preview,
/// everything the local classifier and the AI found, and the confirm
/// flow that runs the selected actions through the EXISTING formal
/// pipelines. Uncertain fields are never hidden; manual classification
/// works with zero model configuration.
struct InboxItemDetailView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let itemID: UUID

    @State private var courses: [Course] = []
    @State private var sessions: [ClassroomSession] = []
    /// User-chosen context for the confirm round.
    @State private var courseID: UUID?
    @State private var sessionID: UUID?
    @State private var duplicateMaterials: [CourseMaterial] = []
    @State private var duplicateResolution: InboxActionExecutor.DuplicateResolution = .keepCopy
    /// Manual classification (works without any model): the picked kind
    /// becomes a manual action on confirm.
    @State private var manualKind: InboxActionKind = .saveAsMaterial
    @State private var manualMaterialKind: MaterialKind = .lecture
    @State private var isConfirming = false
    @State private var failures: [InboxActionExecutor.Failure] = []
    @State private var showScheduleSheet = false
    /// Schedule actions routed to the confirmation sheet (one item may
    /// carry several classes; all of them ledger when the sheet saves).
    @State private var scheduleActions: [InboxSuggestedAction] = []
    @State private var showDeleteConfirm = false

    private var inbox: InboxCoordinator { environment.inbox }
    private var item: SharedInboxItem? { inbox.item(id: itemID) }
    private var suggestions: InboxSuggestionPayload? {
        item.flatMap { inbox.suggestions(for: $0) }
    }

    var body: some View {
        LTPage {
            Group {
                if let item {
                    content(item)
                } else {
                    LTEmptyState(
                        symbol: "tray",
                        title: "项目不存在",
                        message: "这条分享可能已被删除"
                    )
                }
            }
        }
        .navigationTitle(item?.title.isEmpty == false ? item!.title : "收件箱项目")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("删除此项目", systemImage: "trash")
                    }
                    if item?.status.isPending == true || suggestions?.aiActions.isEmpty == false {
                        Button {
                            Task {
                                await inbox.inspect(itemID: itemID, courses: courseTuples, force: true)
                                loadDuplicates()
                            }
                        } label: {
                            Label("重新识别", systemImage: "arrow.clockwise")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(LTColors.textSecondary)
                }
                .accessibilityLabel(Text("更多操作"))
            }
        }
        .task {
            inbox.reconcile()
            courses = (try? environment.repository.courses()) ?? []
            sessions = (try? environment.repository.sessions(matching: "")) ?? []
            if let item {
                // Pre-fill the user's choices from what the classifier
                // matched (still fully changeable).
                if let local = inbox.suggestions(for: item)?.local,
                   let matched = local.matchedCourseID {
                    courseID = matched
                }
                await inbox.inspect(itemID: itemID, courses: courseTuples)
                loadDuplicates()
            }
        }
        .onAppear {
            inbox.reload()
        }
        .sheet(isPresented: $showScheduleSheet) {
            if let item {
                InboxScheduleConfirmSheet(
                    item: item,
                    candidates: scheduleActions.compactMap(\.scheduleCandidate)
                ) { scheduleIDs in
                    // Ledger every routed schedule action now that the
                    // schedules landed (the sheet is the confirm step).
                    for action in scheduleActions {
                        environment.inboxExecutor?.ledger(
                            itemID: itemID, action: action,
                            entityID: scheduleIDs.first
                        )
                    }
                    inbox.reload()
                }
                .environment(environment)
            }
        }
        .confirmationDialog(
            "删除这条分享？",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                inbox.deleteItems(ids: [itemID])
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除收件箱项目不会影响已经正式保存的资料或记录。")
        }
    }

    private var courseTuples: [(id: UUID, name: String, teacher: String)] {
        courses.map { ($0.id, $0.name, $0.teacherName) }
    }

    // MARK: - Content

    private func content(_ item: SharedInboxItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LTSpacing.l) {
                statusCard(item)
                previewCard(item)
                if let local = suggestions?.local {
                    localCard(local)
                }
                if let suggestions {
                    aiCard(suggestions, item: item)
                }
                if item.status.isPending {
                    contextCard(item)
                    manualCard(item)
                    confirmCard(item)
                } else {
                    ledgerCard(item)
                }
                if let local = suggestions?.local, let date = local.detectedDateText {
                    LabeledRow(label: "识别到的日期文本", value: date)
                        .ltCard()
                }
            }
            .padding(.horizontal, LTSpacing.screenPadding)
            .padding(.top, LTSpacing.s)
            .padding(.bottom, LTSpacing.tabBarReserve)
        }
    }

    // MARK: - Status / metadata

    private func statusCard(_ item: SharedInboxItem) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.xs) {
            HStack {
                StatusChip(text: item.status.displayName, tint: InboxScreen.statusTint(item.status))
                if !item.errorSummary.isEmpty {
                    Text(item.errorSummary)
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.warning)
                        .lineLimit(3)
                }
                Spacer()
            }
            LabeledRow(label: "接收时间", value: item.receivedAt.formatted(date: .abbreviated, time: .shortened))
            if item.payloadKind == .file {
                LabeledRow(label: "文件大小", value: Format.bytes(Int(item.fileSize)))
                LabeledRow(label: "内容校验", value: String(item.contentHash.prefix(16)) + "…")
            }
            LabeledRow(label: "来源", value: item.sourceDisplayName.isEmpty ? "系统分享" : item.sourceDisplayName)
        }
        .ltCard()
    }

    // MARK: - Preview (original content, honest per kind)

    @ViewBuilder
    private func previewCard(_ item: SharedInboxItem) -> some View {
        switch item.payloadKind {
        case .url:
            VStack(alignment: .leading, spacing: LTSpacing.s) {
                Label("链接", systemImage: "link")
                    .font(LTTypography.cardTitle)
                if !item.urlTitle.isEmpty {
                    Text(item.urlTitle).font(.subheadline.weight(.medium))
                }
                Text(item.url)
                    .font(.caption.monospaced())
                    .foregroundStyle(LTColors.accentCyan)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if !item.textContent.isEmpty {
                    Divider().overlay(LTColors.separator)
                    Text("分享时的文字")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textTertiary)
                    Text(item.textContent)
                        .font(.subheadline)
                        .foregroundStyle(LTColors.textSecondary)
                        .textSelection(.enabled)
                        .lineSpacing(4)
                }
                Button {
                    if let url = URL(string: item.url) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("打开原网页", systemImage: "safari")
                        .font(.footnote.weight(.medium))
                }
                .buttonStyle(LTSecondaryButtonStyle())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .ltCard()
        case .text:
            VStack(alignment: .leading, spacing: LTSpacing.s) {
                Label("分享文本", systemImage: "text.quote")
                    .font(LTTypography.cardTitle)
                Text(item.textContent)
                    .font(.subheadline)
                    .foregroundStyle(LTColors.textSecondary)
                    .textSelection(.enabled)
                    .lineSpacing(4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .ltCard()
        case .file:
            filePreview(item)
        }
    }

    @ViewBuilder
    private func filePreview(_ item: SharedInboxItem) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            Label(
                item.fileHints.family == .pdf ? "PDF 预览（首页）"
                : item.fileHints.family == .image ? "图片预览"
                : "文件",
                systemImage: item.fileHints.family == .image ? "photo" : "doc"
            )
            .font(LTTypography.cardTitle)
            switch item.fileHints.family {
            case .image:
                if let data = inbox.payloadData(for: item),
                   let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: LTRadius.small))
                } else {
                    Text("暂存文件不可用")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.warning)
                }
            case .pdf:
                if let url = inbox.payloadURL(for: item),
                   let document = PDFDocument(url: url),
                   let page = document.page(at: 0) {
                    let thumbnail = page.thumbnail(
                        of: CGSize(width: 480, height: 640), for: .mediaBox
                    )
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: LTRadius.small))
                    Text("共 \(document.pageCount) 页 · \(Format.bytes(Int(item.fileSize)))")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textTertiary)
                } else {
                    Text("暂存文件不可用")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.warning)
                }
            case .text, .markdown:
                if let data = inbox.payloadData(for: item),
                   let text = String(data: data, encoding: .utf8) {
                    Text(String(text.prefix(1_200)))
                        .font(.subheadline)
                        .foregroundStyle(LTColors.textSecondary)
                        .textSelection(.enabled)
                        .lineSpacing(4)
                }
            case .other:
                LabeledRow(label: "文件", value: item.title)
                LabeledRow(label: "类型", value: item.fileHints.mimeType)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ltCard()
    }

    // MARK: - Local classification

    private func localCard(_ local: InboxLocalClassification) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.xs) {
            Label("本地识别（规则）", systemImage: "gearshape.2")
                .font(LTTypography.cardTitle)
            HStack {
                StatusChip(text: local.kind.displayName, tint: LTColors.accentBlue)
                if let course = local.matchedCourseName {
                    StatusChip(text: "可能属于 \(course)", tint: LTColors.accentCyan)
                }
                Spacer()
            }
            Text(local.reason)
                .font(.footnote)
                .foregroundStyle(LTColors.textSecondary)
        }
        .ltCard()
    }

    // MARK: - AI suggestions (checkable multi-action list)

    private func aiCard(_ payload: InboxSuggestionPayload, item: SharedInboxItem) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            Label("AI 建议", systemImage: "sparkles")
                .font(LTTypography.cardTitle)
            if let error = payload.aiError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(LTColors.warning)
            }
            if let missing = payload.aiMissingInfo, !missing.isEmpty {
                Text("模型未看到的信息：\(missing)")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textTertiary)
            }
            let ledgered = Set(item.completedOperations.map(\.id))
            ForEach(payload.aiActions) { action in
                actionRow(action, item: item, ledgered: ledgered)
            }
            if payload.aiActions.isEmpty && payload.aiError == nil {
                Text("这条内容没有触发 AI 建议——可以用下面的手动归类。")
                    .font(.footnote)
                    .foregroundStyle(LTColors.textTertiary)
            }
        }
        .ltCard()
    }

    @ViewBuilder
    private func actionRow(
        _ action: InboxSuggestedAction, item: SharedInboxItem, ledgered: Set<UUID>
    ) -> some View {
        let isDone = ledgered.contains(action.id)
        VStack(alignment: .leading, spacing: LTSpacing.xxs) {
            Toggle(isOn: Binding(
                get: { isDone ? true : action.isSelected },
                set: { newValue in toggleAction(action, selected: newValue) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title)
                        .font(.subheadline.weight(.medium))
                        .strikethrough(isDone, color: LTColors.textTertiary)
                    actionDetail(action)
                }
            }
            .disabled(isDone || item.status == .processing)
            if isDone {
                Label("已完成", systemImage: "checkmark.circle.fill")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.accentGreen)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func actionDetail(_ action: InboxSuggestedAction) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            switch InboxActionKind(rawValue: action.kindRaw) {
            case .saveAsMaterial:
                Text("类型：\(MaterialKind(rawValue: action.materialKindRaw)?.displayName ?? "其他")")
            case .linkAsMaterial:
                Text("保存为链接资料（可打开原网页、搜索）")
            case .attachToSession:
                Text("将在下方「关联课堂」选择的课堂里保存为课堂图片")
            case .createExamCandidate:
                if let exam = action.examCandidate {
                    Text(Self.examLine(exam))
                }
            case .createTaskCandidate:
                if let task = action.taskCandidate {
                    Text(Self.taskLine(task))
                }
            case .importSchedule:
                if let schedule = action.scheduleCandidate {
                    Text(Self.scheduleLine(schedule))
                }
            case .saveAsNote:
                Text("文本将保存为所选课堂的笔记")
            case nil:
                EmptyView()
            }
        }
        .font(LTTypography.caption)
        .foregroundStyle(LTColors.textTertiary)
    }

    private func toggleAction(_ action: InboxSuggestedAction, selected: Bool) {
        guard var payload = suggestions,
              let index = payload.aiActions.firstIndex(where: { $0.id == action.id })
        else { return }
        payload.aiActions[index].isSelected = selected
        inbox.persistSuggestions(itemID: itemID, payload: payload)
    }

    // MARK: - User context (course / session / duplicate resolution)

    private func contextCard(_ item: SharedInboxItem) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            Label("归属（可选）", systemImage: "folder")
                .font(LTTypography.cardTitle)
            Picker("所属课程", selection: $courseID) {
                Text("未归类").tag(UUID?.none)
                ForEach(courses) { course in
                    Text(course.name).tag(UUID?.some(course.id))
                }
            }
            let needsSession = selectedActions.contains {
                InboxActionKind(rawValue: $0.kindRaw)?.requiresSession == true
            } || manualKind.requiresSession
            if needsSession {
                Picker("关联课堂", selection: $sessionID) {
                    Text("请选择课堂").tag(UUID?.none)
                    ForEach(sessions) { session in
                        Text(session.title).tag(UUID?.some(session.id))
                    }
                }
            }
            if !duplicateMaterials.isEmpty {
                Divider().overlay(LTColors.separator)
                Text("资料库中已有相同文件")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(LTColors.warning)
                ForEach(duplicateMaterials) { duplicate in
                    Text(duplicate.title)
                        .font(.footnote)
                        .foregroundStyle(LTColors.textSecondary)
                }
                Picker("处理方式", selection: $duplicateResolution) {
                    Text("仍保留一份副本").tag(InboxActionExecutor.DuplicateResolution.keepCopy)
                    Text("为已有资料建立新关联").tag(
                        InboxActionExecutor.DuplicateResolution.relinkExisting(
                            duplicateMaterials.first?.id ?? UUID()
                        )
                    )
                }
            }
        }
        .ltCard()
    }

    // MARK: - Manual classification (always available)

    private func manualCard(_ item: SharedInboxItem) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            Label("手动归类（不需要模型）", systemImage: "hand.draw")
                .font(LTTypography.cardTitle)
            Picker("归类为", selection: $manualKind) {
                manualOption(.saveAsMaterial, for: item)
                manualOption(.linkAsMaterial, for: item)
                manualOption(.attachToSession, for: item)
                manualOption(.saveAsNote, for: item)
                manualOption(.createTaskCandidate, for: item)
                manualOption(.importSchedule, for: item)
            }
            if manualKind == .saveAsMaterial || manualKind == .linkAsMaterial {
                Picker("资料类型", selection: $manualMaterialKind) {
                    ForEach(MaterialKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
            }
            Text("每次确认会执行勾选的 AI 建议加上这里选择的手动归类。手动创建考试请前往复习中心的考试候选。")
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.textTertiary)
        }
        .ltCard()
    }

    @ViewBuilder
    private func manualOption(_ kind: InboxActionKind, for item: SharedInboxItem) -> some View {
        // Options that cannot apply to this payload kind are not offered
        // (dead options are worse than hidden ones).
        let applicable: Bool
        switch kind {
        case .saveAsMaterial: applicable = item.payloadKind == .file
        case .linkAsMaterial: applicable = item.payloadKind == .url
        case .attachToSession: applicable = item.payloadKind == .file && item.fileHints.family == .image
        case .saveAsNote: applicable = item.payloadKind == .text || item.payloadKind == .url
        case .createTaskCandidate:
            applicable = true
        case .importSchedule: applicable = true
        case .createExamCandidate: applicable = false
        }
        if applicable {
            Text(kind.displayName).tag(kind)
        }
    }

    // MARK: - Confirm

    private var selectedActions: [InboxSuggestedAction] {
        (suggestions?.aiActions ?? []).filter(\.isSelected)
    }

    private func confirmCard(_ item: SharedInboxItem) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            let ledgered = Set(item.completedOperations.map(\.id))
            let runnable = selectedActions.filter { !ledgered.contains($0.id) }
            let scheduleActions = runnable.filter {
                InboxActionKind(rawValue: $0.kindRaw) == .importSchedule
            }
            let others = runnable.filter {
                InboxActionKind(rawValue: $0.kindRaw) != .importSchedule
            }
            Button {
                confirm(others: others, schedule: scheduleActions, item: item)
            } label: {
                HStack {
                    if isConfirming { ProgressView().controlSize(.small) }
                    Text(confirmLabel(others: others, scheduleCount: scheduleActions.count))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(LTPrimaryButtonStyle())
            .disabled(isConfirming || (others.isEmpty && scheduleActions.isEmpty))

            if !failures.isEmpty {
                VStack(alignment: .leading, spacing: LTSpacing.xxs) {
                    Text("失败的操作")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(LTColors.destructive)
                    ForEach(failures, id: \.operationID) { failure in
                        Text("\(failure.title)：\(failure.reason)")
                            .font(.footnote)
                            .foregroundStyle(LTColors.textSecondary)
                    }
                    // Retry only re-runs what failed (ledgered operations
                    // are skipped by the executor).
                    Button("重试失败项") {
                        Task { await confirmRunnable(others, item: item) }
                    }
                    .font(.footnote.weight(.medium))
                }
            }
        }
        .ltCard()
    }

    private func confirmLabel(
        others: [InboxSuggestedAction], scheduleCount: Int
    ) -> String {
        var parts: [String] = []
        if !others.isEmpty { parts.append("\(others.count) 项操作") }
        if scheduleCount > 0 { parts.append("课表确认") }
        if parts.isEmpty { return "确认导入" }
        return "确认导入（\(parts.joined(separator: " + "))）"
    }

    private func confirm(
        others: [InboxSuggestedAction],
        schedule: [InboxSuggestedAction],
        item: SharedInboxItem
    ) {
        failures = []
        // Schedule seeds: the selected AI schedule actions; when none are
        // selected, a manual importSchedule pick becomes the seed (it
        // already carries the AI candidate when one exists).
        var seeds = schedule
        if seeds.isEmpty, let manual = manualAction(for: item),
           manual.kindRaw == InboxActionKind.importSchedule.rawValue {
            seeds = [manual]
        }
        Task {
            await confirmRunnable(others, item: item)
            // Schedule actions route to their own confirmation sheet.
            if !seeds.isEmpty {
                scheduleActions = seeds
                showScheduleSheet = true
            }
        }
    }

    private func confirmRunnable(
        _ actions: [InboxSuggestedAction], item: SharedInboxItem
    ) async {
        guard !actions.isEmpty else { return }
        guard let executor = environment.inboxExecutor else {
            failures = [InboxActionExecutor.Failure(
                operationID: UUID(),
                title: String(localized: "共享存储", comment: "inbox detail"),
                reason: String(localized: "共享存储不可用，无法导入", comment: "inbox detail")
            )]
            return
        }
        isConfirming = true
        defer { isConfirming = false }

        // Manual classification joins the round as its own action.
        let manual = manualAction(for: item)

        // Session-required actions refuse honestly without a choice.
        let needsSession = actions.contains {
            InboxActionKind(rawValue: $0.kindRaw)?.requiresSession == true
        } || (manual?.kindRaw == InboxActionKind.attachToSession.rawValue
            || manual?.kindRaw == InboxActionKind.saveAsNote.rawValue)
        if needsSession, sessionID == nil {
            failures = [InboxActionExecutor.Failure(
                operationID: UUID(),
                title: String(localized: "课堂归属", comment: "inbox detail"),
                reason: String(localized: "请先选择关联课堂", comment: "inbox detail")
            )]
            return
        }

        let context = InboxActionExecutor.Context(
            courseID: courseID,
            sessionID: sessionID,
            duplicateResolution: duplicateResolution
        )
        let outcome = await executor.perform(
            itemID: itemID,
            context: context,
            selected: actions,
            manualAction: manual
        )
        failures = outcome.failures
        inbox.reload()
    }

    /// The manual pick as an action (a fresh id — manual picks are
    /// one-off rounds, not idempotent retries).
    private func manualAction(for item: SharedInboxItem) -> InboxSuggestedAction? {
        switch manualKind {
        case .saveAsMaterial:
            guard item.payloadKind == .file else { return nil }
            var action = InboxSuggestedAction(kind: .saveAsMaterial, title: "保存为课程资料（手动）")
            action.materialKindRaw = manualMaterialKind.rawValue
            return action
        case .linkAsMaterial:
            guard item.payloadKind == .url else { return nil }
            var action = InboxSuggestedAction(kind: .linkAsMaterial, title: "保存为链接资料（手动）")
            action.materialKindRaw = manualMaterialKind.rawValue
            return action
        case .attachToSession:
            guard item.payloadKind == .file, item.fileHints.family == .image else { return nil }
            return InboxSuggestedAction(kind: .attachToSession, title: "存为课堂图片（手动）")
        case .saveAsNote:
            guard item.payloadKind == .text || item.payloadKind == .url else { return nil }
            var action = InboxSuggestedAction(kind: .saveAsNote, title: "保存为课堂笔记（手动）")
            action.noteText = item.textContent.isEmpty ? item.urlTitle : item.textContent
            return action
        case .createExamCandidate:
            // Manual exam creation routes to the exam center's own form
            // (it needs a date the rules here cannot invent); this item
            // stays in the inbox until the user saves it there.
            return nil
        case .createTaskCandidate:
            var action = InboxSuggestedAction(kind: .createTaskCandidate, title: "创建作业候选（手动）")
            action.taskCandidate = TaskCandidateSnapshot(
                title: item.title,
                detail: item.textContent
            )
            return action
        case .importSchedule:
            var action = InboxSuggestedAction(kind: .importSchedule, title: "导入课程表（手动）")
            if let aiSchedule = selectedActions.first(where: {
                InboxActionKind(rawValue: $0.kindRaw) == .importSchedule
            })?.scheduleCandidate {
                action.scheduleCandidate = aiSchedule
            } else {
                // A blank, fully-editable row (the sheet edits every field).
                action.scheduleCandidate = ScheduleCandidateSnapshot(courseName: item.title)
            }
            return action
        }
    }

    // MARK: - Ledger (post-confirm accounting)

    private func ledgerCard(_ item: SharedInboxItem) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            Label("已完成的操作", systemImage: "checkmark.seal")
                .font(LTTypography.cardTitle)
            if item.completedOperations.isEmpty {
                Text("还没有执行任何操作")
                    .font(.footnote)
                    .foregroundStyle(LTColors.textTertiary)
            }
            ForEach(item.completedOperations) { record in
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(LTColors.accentGreen)
                    Text(record.label)
                        .font(.footnote)
                        .foregroundStyle(LTColors.textSecondary)
                    Spacer()
                    if let entityID = record.resultingEntityID,
                       let target = ledgerTarget(record, entityID: entityID) {
                        NavigationLink(value: target) {
                            Text("查看")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(LTColors.accentBlue)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if item.status == .partiallyProcessed {
                Text("部分操作未完成——可重试失败项。")
                    .font(.footnote)
                    .foregroundStyle(LTColors.warning)
            }
        }
        .ltCard()
    }

    private func ledgerTarget(
        _ record: SharedInboxOperationRecord, entityID: UUID
    ) -> InboxLedgerRoute? {
        switch record.kindRaw {
        case SharedInboxActionKindRaw.saveAsMaterial,
            SharedInboxActionKindRaw.linkAsMaterial:
            return .material(entityID)
        case SharedInboxActionKindRaw.attachToSession:
            return .session(entityID)
        case SharedInboxActionKindRaw.createExamCandidate:
            return .exam(entityID)
        case SharedInboxActionKindRaw.createTaskCandidate:
            return .task
        case SharedInboxActionKindRaw.importSchedule:
            return .timetable
        case SharedInboxActionKindRaw.saveAsNote:
            return .sessionDetailNote(entityID)
        default:
            return nil
        }
    }

    // MARK: - Duplicates

    private func loadDuplicates() {
        guard let item, item.payloadKind == .file, !item.contentHash.isEmpty else {
            duplicateMaterials = []
            return
        }
        duplicateMaterials = (try? environment.repository.materials(
            contentHash: item.contentHash
        )) ?? []
    }

    // MARK: - Candidate line formatting

    static func examLine(_ exam: ExamCandidateSnapshot) -> String {
        var parts: [String] = [exam.title]
        if !exam.dateKey.isEmpty { parts.append(exam.dateKey) }
        if !exam.timeText.isEmpty { parts.append(exam.timeText) }
        if !exam.location.isEmpty { parts.append(exam.location) }
        if exam.dateUncertain { parts.append(String(localized: "日期待确认", comment: "inbox exam line")) }
        return parts.joined(separator: " · ")
    }

    static func taskLine(_ task: TaskCandidateSnapshot) -> String {
        var parts: [String] = [task.title]
        if let due = task.dueAt {
            parts.append(due.formatted(date: .abbreviated, time: .omitted))
        }
        if !task.uncertainty.isEmpty { parts.append(task.uncertainty) }
        return parts.joined(separator: " · ")
    }

    static func scheduleLine(_ schedule: ScheduleCandidateSnapshot) -> String {
        var parts: [String] = [
            schedule.courseName,
            InboxScheduleConfirmSheet.weekdayName(schedule.weekday),
            "\(InboxScheduleConfirmSheet.formatSecs(schedule.startSecs))–\(InboxScheduleConfirmSheet.formatSecs(schedule.endSecs))",
        ]
        if !schedule.location.isEmpty { parts.append(schedule.location) }
        if schedule.timeUncertain { parts.append(String(localized: "时间待确认", comment: "inbox schedule line")) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Ledger jump targets

/// Post-confirm navigation targets (the formal entity's own screen — the
/// inbox never renders formal content itself).
enum InboxLedgerRoute: Hashable {
    case material(UUID)
    case session(UUID)
    case exam(UUID)
    case task
    case timetable
    case sessionDetailNote(UUID)

    /// The destination view for the route (attached where the detail view
    /// lives inside its NavigationStack).
    @ViewBuilder
    static func destination(for route: InboxLedgerRoute) -> some View {
        switch route {
        case .material(let id):
            MaterialReaderScreen(materialID: id)
        case .session(let id):
            SessionDetailView(sessionID: id)
        case .exam(let id):
            ExamDetailView(examID: id)
        case .task:
            ReviewCenterScreen()
        case .timetable:
            ScheduleScreen()
        case .sessionDetailNote(let id):
            SessionDetailView(sessionID: id)
        }
    }
}
