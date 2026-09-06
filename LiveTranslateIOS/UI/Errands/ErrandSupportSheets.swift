import SwiftUI
import UIKit

// 办事事项详情的支撑 sheet：手动添加清单项、记录办理结果、日历选
// 择、导出。全部遵守隐私边界（导出走 TemporaryExportStore；复制走
// ClipboardService；敏感文本 sensitive 策略）。

// MARK: - 手动添加清单项

struct ErrandItemAddSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let errandCase: ErrandCase
    var initialKind: ErrandCaseItemKind = .requiredDocument

    @State private var title = ""
    @State private var detail = ""
    @State private var kind: ErrandCaseItemKind
    @FocusState private var titleFocused: Bool

    init(errandCase: ErrandCase, initialKind: ErrandCaseItemKind = .requiredDocument) {
        self.errandCase = errandCase
        self.initialKind = initialKind
        _kind = State(initialValue: initialKind)
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
                    Section("内容") {
                        TextField("标题（如：护照原件）", text: $title)
                            .focused($titleFocused)
                            .onSubmit { add() }
                        if kind == .requiredDocument {
                            TextField("说明（原件 / 复印件 / 翻译件 / 公证件…）", text: $detail)
                        }
                        if kind.carriesTime {
                            Label("时间稍后在详情里确认（识别不会自动成预约）", systemImage: "clock")
                                .font(.caption2)
                                .foregroundStyle(LTColors.textTertiary)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("添加清单项")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("添加", action: add)
                        .font(.body.weight(.semibold))
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { titleFocused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func add() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? environment.repository.addErrandCaseItem(ErrandItemDraft(
            caseID: errandCase.id,
            title: trimmed,
            kind: kind,
            detail: detail.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        dismiss()
    }
}

// MARK: - 记录办理结果

/// 结束现场沟通后的显式操作：等待结果 / 需要补交 / 设置跟进。进入
/// waitingForResult 可保存预计结果日期；进入 needsFollowUp 需要至少
/// 一个未完成跟进项或用户确认无日期跟进 —— 不只改颜色。
struct ErrandResultSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let errandCase: ErrandCase

    @State private var outcome: Outcome = .waiting
    @State private var expectedDate = Date.now.addingTimeInterval(7 * 24 * 3600)
    @State private var hasExpectedDate = true
    @State private var followUpNote = ""
    @State private var validationMessage: String?

    enum Outcome: String, CaseIterable, Identifiable {
        case waiting = "等待结果"
        case needsFollowUp = "需要补交/跟进"
        case completed = "已完成"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            LTPage {
                Form {
                    Section("办理结果") {
                        Picker("结果", selection: $outcome) {
                            ForEach(Outcome.allCases) { outcome in
                                Text(outcome.rawValue).tag(outcome)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                    if outcome == .waiting {
                        Section("预计结果时间") {
                            Toggle("设置预计日期", isOn: $hasExpectedDate)
                            if hasExpectedDate {
                                DatePicker("预计", selection: $expectedDate, displayedComponents: [.date])
                                    .environment(\.locale, Locale(identifier: "zh_CN"))
                            }
                        }
                    }
                    if outcome == .needsFollowUp {
                        Section("跟进") {
                            TextField("要跟进什么（如：周五去补交护照复印件）", text: $followUpNote, axis: .vertical)
                                .lineLimit(2...4)
                        }
                    }
                    if let validationMessage {
                        Section {
                            Label(validationMessage, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(LTColors.warning)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("记录办理结果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存", action: save)
                        .font(.body.weight(.semibold))
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        let repository = environment.repository
        switch outcome {
        case .waiting:
            try? repository.updateErrandCaseMeta(
                errandCase,
                expectedResultAt: hasExpectedDate ? expectedDate : nil,
                pinned: nil
            )
            try? repository.setErrandCaseStatus(errandCase, to: .waitingForResult)
        case .needsFollowUp:
            // needsFollowUp 至少需要一个未完成跟进项，或用户显式确认无
            // 日期跟进 —— 否则拒绝（不只改颜色）。
            let items = (try? repository.errandCaseItems(caseID: errandCase.id)) ?? []
            let hasOpenFollowUp = items.contains {
                ($0.kind == .followUp || $0.kind == .action) && $0.status == .pending
            }
            let note = followUpNote.trimmingCharacters(in: .whitespacesAndNewlines)
            if !hasOpenFollowUp && note.isEmpty {
                validationMessage = "请先写要跟进的内容，或在清单里留一个未完成的跟进项"
                return
            }
            if !note.isEmpty {
                _ = try? repository.addErrandCaseItem(ErrandItemDraft(
                    caseID: errandCase.id,
                    title: note,
                    kind: .followUp
                ))
            }
            try? repository.setErrandCaseStatus(errandCase, to: .needsFollowUp)
        case .completed:
            // 完成事项：取消未需要的提醒；不自动删除对话/文件/本地来源；
            // 历史保留。
            environment.errandReminders.cancelCase(caseID: errandCase.id)
            try? repository.setErrandCaseStatus(errandCase, to: .completed)
        }
        dismiss()
    }
}

// MARK: - 日历选择（可选写入 —— 只有用户点"加入日历"才执行）

struct ErrandCalendarPickerSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let item: ErrandCaseItem
    let errandCase: ErrandCase

    @State private var calendars: [ErrandCalendarInfo] = []
    @State private var writeFailed = false
    @State private var isWriting = false

    var body: some View {
        NavigationStack {
            LTPage {
                ScrollView {
                    VStack(alignment: .leading, spacing: LTSpacing.l) {
                        VStack(alignment: .leading, spacing: LTSpacing.xs) {
                            Label("把已确认的预约加入日历", systemImage: "calendar.badge.plus")
                                .font(.body.weight(.semibold))
                            Text("事件只写入你选择的日历；App 不会读取你的日历。映射仅保存在本设备，不会同步。")
                                .font(.caption2)
                                .foregroundStyle(LTColors.textTertiary)
                        }
                        if calendars.isEmpty {
                            LTEmptyState(
                                symbol: "calendar",
                                title: writeFailed ? "无法写入日历" : "正在读取可写日历…",
                                message: writeFailed
                                    ? "日历权限被拒绝或没有可写的日历。事项本身不受影响。"
                                    : "需要你在系统弹窗中允许写入日历。"
                            )
                        }
                        ForEach(calendars) { calendar in
                            Button {
                                Task { await mirror(to: calendar) }
                            } label: {
                                HStack {
                                    Image(systemName: "calendar")
                                        .foregroundStyle(LTColors.accentBlue)
                                    Text(calendar.title)
                                        .font(.body)
                                        .foregroundStyle(LTColors.textPrimary)
                                    Spacer()
                                    if isWriting {
                                        ProgressView()
                                    }
                                }
                                .ltCard(padding: LTSpacing.m)
                            }
                            .buttonStyle(.plain)
                            .disabled(isWriting)
                        }
                    }
                    .padding(.horizontal, LTSpacing.screenPadding)
                    .padding(.top, LTSpacing.s)
                }
            }
            .navigationTitle("加入日历")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            calendars = await environment.errandCalendar.writableCalendars()
            writeFailed = calendars.isEmpty
        }
    }

    private func mirror(to calendar: ErrandCalendarInfo) async {
        isWriting = true
        // 写入失败如实返回 false —— 绝不显示成功。
        let ok = await environment.errandCalendar.mirror(
            item: item,
            caseTitle: errandCase.title,
            location: errandCase.location,
            note: errandCase.purpose.isEmpty ? errandCase.title : errandCase.purpose,
            calendar: calendar
        )
        isWriting = false
        if ok {
            dismiss()
        } else {
            writeFailed = true
            calendars = []
        }
    }
}

// MARK: - 导出

struct ErrandExportSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let errandCase: ErrandCase
    let items: [ErrandCaseItem]

    @State private var format: ErrandExporter.Options.Format = .markdown
    @State private var includeExcerpts = false
    @State private var excerptTurns: [ErrandExporter.TurnExcerpt] = []
    @State private var exportedURL: URL?
    @State private var showShare = false

    /// 本地来源中的对话（导出摘录的候选 —— 逐条选择 + 预览）。
    @State private var conversationTurns: [(id: UUID, text: String, isCounterpart: Bool)] = []

    var body: some View {
        NavigationStack {
            LTPage {
                ScrollView {
                    VStack(alignment: .leading, spacing: LTSpacing.l) {
                        VStack(alignment: .leading, spacing: LTSpacing.xs) {
                            Label("导出办事记录", systemImage: "square.and.arrow.up")
                                .font(.body.weight(.semibold))
                            Text("默认包含标题、状态、清单与确认的时间；不包含本地来源文件、对话全文与任何技术信息。")
                                .font(.caption2)
                                .foregroundStyle(LTColors.textTertiary)
                        }
                        Picker("格式", selection: $format) {
                            ForEach(ErrandExporter.Options.Format.allCases, id: \.rawValue) { format in
                                Text(format.rawValue).tag(format)
                            }
                        }
                        .pickerStyle(.segmented)
                        if !conversationTurns.isEmpty {
                            Toggle("附对话摘录（逐条选择）", isOn: $includeExcerpts)
                                .tint(LTColors.accentBlue)
                            if includeExcerpts {
                                ForEach(conversationTurns, id: \.id) { turn in
                                    excerptRow(turn)
                                }
                                Text("摘录将经过敏感遮盖后展示预览；不含遮盖标记的行按原文导出。")
                                    .font(.caption2)
                                    .foregroundStyle(LTColors.textTertiary)
                            }
                        }
                        Button {
                            export()
                        } label: {
                            Label("生成并分享", systemImage: "square.and.arrow.up")
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(LTColors.accentGreen)
                    }
                    .padding(.horizontal, LTSpacing.screenPadding)
                    .padding(.top, LTSpacing.s)
                    .padding(.bottom, LTSpacing.xl)
                }
            }
            .navigationTitle("导出")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
            .sheet(isPresented: $showShare) {
                if let exportedURL {
                    // 现有系统分享桥（Export/ShareSheet.swift）。
                    ShareSheet(items: [exportedURL])
                }
            }
        }
        .presentationDetents([.large])
        .onAppear(perform: loadConversationTurns)
    }

    private func excerptRow(_ turn: (id: UUID, text: String, isCounterpart: Bool)) -> some View {
        let selected = excerptTurns.contains { $0.id == turn.id }
        return Button {
            if selected {
                excerptTurns.removeAll { $0.id == turn.id }
            } else {
                // 摘录预览走敏感遮盖（第十七轮遮盖器）。
                let (masked, _) = InterpreterSensitiveMasker.masked(turn.text)
                excerptTurns.append(ErrandExporter.TurnExcerpt(
                    id: turn.id, text: masked, isCounterpart: turn.isCounterpart
                ))
            }
        } label: {
            HStack(alignment: .top, spacing: LTSpacing.s) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? LTColors.accentGreen : LTColors.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(turn.isCounterpart ? "对方" : "我")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LTColors.textSecondary)
                    Text(excerptTurns.first { $0.id == turn.id }?.text ?? turn.text)
                        .font(.caption2)
                        .foregroundStyle(LTColors.textPrimary)
                        .lineLimit(3)
                }
                Spacer()
            }
            .ltCard(padding: LTSpacing.m)
        }
        .buttonStyle(.plain)
    }

    private func loadConversationTurns() {
        let sources = errandCase.localSources ?? []
        guard let conversationSource = sources.first(where: { $0.kind == .conversation }),
              let conversationID = conversationSource.conversationID
        else { return }
        let turns = (try? environment.repository.interpreterTurns(conversationID: conversationID)) ?? []
        conversationTurns = turns.suffix(20).map { turn in
            (id: turn.id, text: turn.sourceText, isCounterpart: turn.speaker == .counterpart)
        }
    }

    private func export() {
        let options = ErrandExporter.Options(
            includeConversationExcerpts: includeExcerpts,
            format: format
        )
        let snapshot = ErrandExporter.snapshot(errandCase)
        let itemSnapshots = items.map(ErrandExporter.snapshot)
        let content: String
        switch format {
        case .markdown:
            content = ErrandExporter.markdown(
                errandCase: snapshot, items: itemSnapshots, options: options, excerpts: excerptTurns
            )
        case .plainText:
            content = ErrandExporter.plainText(
                errandCase: snapshot, items: itemSnapshots, options: options, excerpts: excerptTurns
            )
        }
        let ext = format == .markdown ? "md" : "txt"
        let fileName = ErrandExporter.safeFileName(title: errandCase.title, ext: ext)
        if let url = try? ErrandExporter.writeTemporaryFile(content: content, fileName: fileName) {
            exportedURL = url
            showShare = true
        }
    }
}
