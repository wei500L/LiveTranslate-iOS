import Foundation
import Observation
import SwiftUI

/// 办事事项的共享 ViewModel：列表、详情、草稿编辑、本地规则/AI 候选、
/// 提醒与日历编排。View 不直接操作 SwiftData —— 全部写入经 repository。
@MainActor
@Observable
final class ErrandViewModel {
    // MARK: - State

    private(set) var cases: [ErrandCase] = []
    private(set) var drafts: [ErrandCase] = []
    private(set) var isLoaded = false

    /// 详情正在查看的事项（nil = 列表态）。
    private(set) var detailCase: ErrandCase?
    private(set) var detailItems: [ErrandCaseItem] = []

    /// AI/规则候选（草稿编辑态 —— 未确认，绝不入库为正式行）。
    struct PendingCandidate: Identifiable, Equatable {
        var id: String
        var kind: ErrandCaseItemKind
        var title: String
        var detail: String
        var date: ErrandDateParser.Candidate?
        var reason: String
        var sourceTurnID: UUID?
        var feeText: String?
    }

    private(set) var candidates: [PendingCandidate] = []
    /// AI 整理进行中（防重复提交）。
    private(set) var isOrganizing = false
    /// 最近一次 AI 整理的错误（nil = 无；CancellationError 不进入）。
    private(set) var organizeError: String?
    /// 最近一次整理的来源回合（候选确认后建本地来源链接用）。
    private(set) var organizeTurnIDs: [UUID] = []

    /// 提醒授权的真实状态（不是猜测）。
    private(set) var notificationsDenied = false

    private weak var environmentBox: AppEnvironment?
    private var environment: AppEnvironment? { environmentBox }

    // MARK: - Attach & reload

    func attach(_ environment: AppEnvironment) {
        environmentBox = environment
    }

    func reload() {
        guard let repository = environment?.repository else { return }
        cases = (try? repository.errandCases(includeArchived: false)) ?? []
        drafts = repository.errandCaseDrafts
        isLoaded = true
    }

    /// 首页卡片数据：需要行动的正式事项（今日/近期预约、逾期截止、到
    /// 达跟进时间、置顶、等待超期）。归档与无动作事项绝不进首页。
    struct HomeHighlight: Equatable {
        var errandCase: ErrandCase
        var reason: String
        var isOverdue: Bool
    }

    func homeHighlights(now: Date = .now) -> [HomeHighlight] {
        guard let repository = environment?.repository else { return [] }
        var result: [HomeHighlight] = []
        for errandCase in cases {
            if errandCase.pinned {
                result.append(HomeHighlight(
                    errandCase: errandCase, reason: "置顶", isOverdue: false
                ))
                continue
            }
            let items = (try? repository.errandCaseItems(caseID: errandCase.id)) ?? []
            let dated = items.filter {
                ($0.kind == .appointment || $0.kind == .deadline || $0.kind == .followUp)
                    && $0.dueAt != nil && $0.status == .pending
            }
            if let next = dated.compactMap(\.dueAt).min() {
                let isOverdue = next < now
                let kind = dated.first { $0.dueAt == next }?.kind ?? .appointment
                result.append(HomeHighlight(
                    errandCase: errandCase,
                    reason: isOverdue
                        ? "\(kind.displayName)已逾期"
                        : "\(kind.displayName) \(Self.shortDate(next))",
                    isOverdue: isOverdue
                ))
                continue
            }
            // waiting 状态超过预计日期。
            if errandCase.status == .waitingForResult,
               let expected = errandCase.expectedResultAt, expected < now {
                result.append(HomeHighlight(
                    errandCase: errandCase, reason: "等待结果已超期", isOverdue: true
                ))
            }
        }
        return result
    }

    /// "今天"聚合：只聚合同一个 case item（点击回到同一事项；完成聚合
    /// 项即完成原 item 并幂等取消通知；不复制为 StudyTask）。
    struct TodayEntry: Identifiable, Equatable {
        var id: UUID { itemID }
        var itemID: UUID
        var caseID: UUID
        var caseTitle: String
        var itemTitle: String
        var kind: ErrandCaseItemKind
        var dueAt: Date
    }

    func todayEntries(on date: Date, calendar: Calendar = .current) -> [TodayEntry] {
        guard let repository = environment?.repository else { return [] }
        var result: [TodayEntry] = []
        for errandCase in cases where !errandCase.status.isTerminal {
            let items = (try? repository.errandCaseItems(caseID: errandCase.id)) ?? []
            for item in items
            where item.status == .pending && item.dueAt != nil && item.kind.carriesTime {
                guard let dueAt = item.dueAt,
                      calendar.isDate(dueAt, inSameDayAs: date) else { continue }
                result.append(TodayEntry(
                    itemID: item.id,
                    caseID: errandCase.id,
                    caseTitle: errandCase.title,
                    itemTitle: item.title,
                    kind: item.kind,
                    dueAt: dueAt
                ))
            }
        }
        return result.sorted { $0.dueAt < $1.dueAt }
    }

    // MARK: - Draft lifecycle

    /// 新建草稿（空白手动创建 —— 无 AI、无网络同样可用）。
    @discardableResult
    func startDraft(scene: InterpreterScene, title: String = "") -> ErrandCase? {
        guard let repository = environment?.repository else { return nil }
        let draft = try? repository.startErrandCaseDraft(scene: scene, title: title)
        reload()
        return draft
    }

    /// 从一个已保存对话创建草稿并建立本地来源链接（不复制对话、不修改
    /// 原对话；幂等）。
    @discardableResult
    func startDraft(
        fromConversation conversationID: UUID,
        scene: InterpreterScene
    ) -> ErrandCase? {
        guard let repository = environment?.repository else { return nil }
        guard let draft = try? repository.startErrandCaseDraft(scene: scene, title: "")
        else { return nil }
        _ = try? repository.addErrandLocalSource(
            to: draft,
            ErrandLocalSource(kind: .conversation, conversationID: conversationID)
        )
        reload()
        return draft
    }

    /// 保存草稿为正式事项（用户已确认将同步的字段；状态由用户选择，
    /// 默认 preparing —— 有确认预约时可选 scheduled）。
    func saveDraft(_ draft: ErrandCase, status: ErrandCaseStatus? = nil) {
        guard let repository = environment?.repository else { return }
        let resolved: ErrandCaseStatus
        if let status {
            resolved = status
        } else {
            // Default by content: a confirmed appointment item → scheduled;
            // otherwise preparing (识别到日期绝不自动进入 scheduled ——
            // 只有用户确认的预约项才计入)。
            let items = (try? repository.errandCaseItems(caseID: draft.id)) ?? []
            let hasConfirmedAppointment = items.contains {
                $0.kind == .appointment && $0.status != .unconfirmed
                    && $0.dueAt != nil && !$0.dateUncertain
            }
            resolved = hasConfirmedAppointment ? .scheduled : .preparing
        }
        do {
            try repository.saveErrandCaseDraft(draft, status: resolved)
            // 保存后为已确认时间的清单项挂提醒（默认提前 1 小时 —— 用户
            // 可在详情里改）。
            Task { await self.armDefaults(for: draft) }
        } catch {
            // 状态机违规等 —— 列表如实刷新。
        }
        reload()
    }

    private func armDefaults(for draft: ErrandCase) async {
        guard let repository = environment?.repository,
              let errandReminders = environment?.errandReminders,
              let saved = repository.errandCase(id: draft.id)
        else { return }
        let items = (try? repository.errandCaseItems(caseID: draft.id)) ?? []
        for item in items where item.kind.carriesTime && item.dueAt != nil
            && !item.dateUncertain && item.status != .unconfirmed {
            let kind: ErrandReminderScheduler.Kind
            switch item.kind {
            case .appointment: kind = .appointment
            case .deadline: kind = .deadline
            case .followUp: kind = .followUp
            default: continue
            }
            let ok = await errandReminders.enable(
                item: item, caseTitle: saved.title, kind: kind, lead: .hour
            )
            notificationsDenied = notificationsDenied || !ok
        }
    }

    func discardDraft(_ draft: ErrandCase) {
        guard let repository = environment?.repository else { return }
        try? repository.discardErrandCaseDraft(draft)
        candidates = []
        organizeTurnIDs = []
        reload()
    }

    /// 草稿被杀 App 后可恢复：有内容的草稿保留；空草稿在丢弃/退出编辑
    /// 时清理（discard 由用户显式触发；保存路径的空草稿自动清理）。
    func cleanupEmptyDrafts() {
        guard let repository = environment?.repository else { return }
        for draft in repository.errandCaseDrafts {
            let items = (try? repository.errandCaseItems(caseID: draft.id)) ?? []
            let sources = draft.localSources ?? []
            let hasContent = !draft.purpose.isEmpty || !draft.userNote.isEmpty
                || !draft.location.isEmpty || !draft.contact.isEmpty
                || draft.expectedResultAt != nil || !sources.isEmpty
            if items.isEmpty && !hasContent {
                try? repository.discardErrandCaseDraft(draft)
            }
        }
        reload()
    }

    // MARK: - Detail

    func openDetail(_ errandCase: ErrandCase) {
        detailCase = errandCase
        reloadDetailItems()
    }

    /// 详情视图按 id 打开（事项可能已被删除 —— detailCase 为 nil 时
    /// 视图显示诚实的"事项已不存在"状态）。
    func openDetailById(_ id: UUID) {
        detailCase = environment?.repository.errandCase(id: id)
        reloadDetailItems()
    }

    func closeDetail() {
        detailCase = nil
        detailItems = []
    }

    func reloadDetailItems() {
        guard let errandCase = detailCase,
              let repository = environment?.repository else { return }
        detailItems = (try? repository.errandCaseItems(caseID: errandCase.id)) ?? []
    }

    // MARK: - Items（详情交互）

    func addItem(
        to errandCase: ErrandCase,
        title: String, kind: ErrandCaseItemKind, detail: String = ""
    ) {
        guard let repository = environment?.repository else { return }
        _ = try? repository.addErrandCaseItem(ErrandItemDraft(
            caseID: errandCase.id, title: title, kind: kind, detail: detail
        ))
        reloadDetailItems()
    }

    func setItemStatus(_ item: ErrandCaseItem, to status: ErrandCaseItemStatus) {
        guard let repository = environment?.repository else { return }
        try? repository.setErrandCaseItemStatus(item, to: status)
        // 完成/跳过对应步骤时取消提醒（幂等）。
        if status == .done || status == .skipped {
            environment?.errandReminders.disable(itemID: item.id)
        }
        reloadDetailItems()
    }

    /// 确认一个候选行（AI/规则 → 正式清单项，可带确认时间）。候选行是
    /// .unconfirmed 的设备本地行 —— 确认后才进入同步。
    func confirmItem(_ item: ErrandCaseItem, dueAt: Date?) {
        guard let repository = environment?.repository else { return }
        try? repository.setErrandCaseItemDate(
            item, dueAt: dueAt, dateText: nil, isRelative: nil, uncertain: dueAt == nil ? nil : false
        )
        try? repository.confirmErrandCaseItem(item)
        reloadDetailItems()
    }

    func deleteItem(_ item: ErrandCaseItem) {
        guard let repository = environment?.repository else { return }
        environment?.errandReminders.disable(itemID: item.id)
        environment?.errandCalendar.removeMirroredAppointment(itemID: item.id)
        try? repository.deleteErrandCaseItem(item)
        reloadDetailItems()
    }

    // MARK: - 本地规则候选（无 AI 路径）

    /// 用本地确定性规则从对话生成候选（可解释理由；用户逐项勾选）。
    func extractLocalCandidates(
        fromConversation conversationID: UUID
    ) {
        guard let repository = environment?.repository else { return }
        guard let conversation = repository.interpreterConversation(id: conversationID)
        else { return }
        let turns = (try? repository.interpreterTurns(conversationID: conversationID)) ?? []
        let projections = turns.map { turn in
            (id: turn.id, text: turn.sourceText, isCounterpart: turn.speaker == .counterpart)
        }
        applyExtracted(ErrandDraftExtractor.candidates(fromTurns: projections))
        organizeTurnIDs = turns.map(\.id)
    }

    /// 从文件分析结果生成候选。
    func extractLocalCandidates(
        fromDocumentAnalysis documentID: UUID
    ) {
        guard let repository = environment?.repository,
              let document = repository.interpreterDocument(id: documentID),
              let analysis = document.analysis
        else { return }
        applyExtracted(ErrandDraftExtractor.candidates(fromAnalysis: analysis))
    }

    private func applyExtracted(_ extracted: [ErrandDraftExtractor.Candidate]) {
        candidates = extracted.map { candidate in
            PendingCandidate(
                id: "\(candidate.kind.rawValue)|\(candidate.title)",
                kind: candidate.kind,
                title: candidate.title,
                detail: candidate.detail,
                date: candidate.date,
                reason: candidate.reason,
                sourceTurnID: candidate.sourceTurnID,
                feeText: candidate.feeText
            )
        }
    }

    // MARK: - AI 整理

    /// AI 是否可用（未配置时 UI 禁用"AI 整理"并给设置入口，但不禁用
    /// 手动能力）。
    var isAIConfigured: Bool {
        environment?.studyServiceBoxForInterpreter?.get()?.isConfiguredNow ?? false
    }

    /// 最近一次 AI 请求的发送预览摘要（发送前给用户核对 —— AI 请求先
    /// 经过发送预览与敏感遮盖）。
    private(set) var organizeDisclosureSummary: String?

    /// 收集一次整理的预算内输入（对话回合 + 文件 chunk + 用户背景）。
    private func gatherInput(
        conversationID: UUID?,
        documentIDs: [UUID],
        userContext: String,
        scene: InterpreterScene
    ) -> ErrandAIService.Input? {
        guard let repository = environment?.repository else { return nil }
        var turnProjections: [(id: UUID, text: String, isCounterpart: Bool)] = []
        if let conversationID,
           repository.interpreterConversation(id: conversationID) != nil {
            let turns = (try? repository.interpreterTurns(conversationID: conversationID)) ?? []
            turnProjections = turns.map { turn in
                (id: turn.id, text: turn.sourceText, isCounterpart: turn.speaker == .counterpart)
            }
        }
        // 文件来源：所选文档的 chunk（复用 InterpreterDocumentChunker
        // 的既有链路 —— 用户已允许模型使用的就绪文档）。
        var sources: [InterpreterDocumentChunker.RequestSource] = []
        for documentID in documentIDs {
            guard let document = repository.interpreterDocument(id: documentID),
                  document.allowsModelUse,
                  document.status == .ready || document.status == .partiallyExtracted,
                  let extraction = InterpreterDocumentStoreShared.store?
                      .readExtraction(documentID: document.id)
            else { continue }
            var chunks: [InterpreterDocumentChunker.Chunk] = []
            for page in extraction.pages {
                chunks.append(contentsOf: InterpreterDocumentChunker.chunks(
                    documentID: document.id,
                    documentName: (document.originalFileName as NSString).deletingPathExtension,
                    pageNumber: page.pageNumber,
                    text: page.effectiveText
                ))
            }
            let selected = InterpreterDocumentChunker.selectChunks(
                InterpreterDocumentChunker.SelectionRequest(
                    chunks: chunks, selectedPages: [], question: "办事材料整理"
                )
            )
            sources.append(
                contentsOf: InterpreterDocumentChunker.requestSources(for: selected)
            )
        }
        let built = ErrandAIService.buildInput(
            turns: turnProjections,
            sources: sources,
            userContext: userContext,
            scene: scene
        )
        return built.input
    }

    /// 构建发送预览摘要（不请求模型）。返回 false = 没有可发送内容。
    @discardableResult
    func previewOrganize(
        conversationID: UUID?,
        documentIDs: [UUID],
        userContext: String,
        scene: InterpreterScene
    ) -> Bool {
        guard let input = gatherInput(
            conversationID: conversationID,
            documentIDs: documentIDs,
            userContext: userContext,
            scene: scene
        ) else { return false }
        guard !input.turnLines.isEmpty || !input.sourceLines.isEmpty || !input.userContext.isEmpty
        else {
            organizeDisclosureSummary = nil
            return false
        }
        let disclosure = AIRequestDisclosure(
            feature: .errandOrganizing,
            host: nil,
            textCategory: .mixed,
            characterCount: (input.turnLines + input.sourceLines).map(\.count).reduce(0, +)
                + input.userContext.count,
            imageCount: 0,
            masked: true,
            userTriggered: true
        )
        organizeDisclosureSummary = disclosure.previewSummary
            + " · 对话 \(input.turnLines.count) 行、文件 \(input.sourceLines.count) 段"
        return true
    }

    /// 用 AI 整理当前对话 + 可选文件来源。防重复提交；CancellationError
    /// 不标记失败；迟到回调经 case-scope 守卫。
    func organizeWithAI(
        conversationID: UUID?,
        documentIDs: [UUID],
        userContext: String,
        scene: InterpreterScene
    ) async {
        guard !isOrganizing else { return }
        guard let repository = environment?.repository else { return }
        isOrganizing = true
        organizeError = nil
        // 迟到回调守卫：捕获事项草稿 id（结果只写回仍然存在的草稿）。
        let targetDraftID = detailCase?.id ?? drafts.first?.id

        do {
            guard let input = gatherInput(
                conversationID: conversationID,
                documentIDs: documentIDs,
                userContext: userContext,
                scene: scene
            ) else {
                isOrganizing = false
                return
            }
            organizeTurnIDs = input.turnIDs
            guard let service = environment?.studyServiceBoxForInterpreter?.get()
            else {
                isOrganizing = false
                return
            }
            let aiService = ErrandAIService(model: service)
            let suggestion = try await aiService.organize(input)

            // Case-scope 守卫：草稿仍在（未被丢弃/删除）才写回。
            if let targetDraftID, repository.errandCase(id: targetDraftID) == nil {
                isOrganizing = false
                return
            }
            applySuggestion(suggestion, turnIDs: input.turnIDs)
        } catch is CancellationError {
            // 取消不标失败。
        } catch {
            organizeError = "AI 整理未完成 —— 草稿与来源已保留，可重试或手动添加"
        }
        isOrganizing = false
    }

    private func applySuggestion(
        _ suggestion: ErrandAIService.Suggestion,
        turnIDs: [UUID]
    ) {
        var mapped: [PendingCandidate] = []
        func append(
            _ titles: [String], kind: ErrandCaseItemKind,
            dates: [ErrandDateParser.Candidate] = [], fee: Bool = false
        ) {
            for (index, title) in titles.enumerated() {
                let date = index < dates.count ? dates[index] : nil
                mapped.append(PendingCandidate(
                    id: "\(kind.rawValue)|\(title)|\(mapped.count)",
                    kind: kind,
                    title: title,
                    detail: "",
                    date: date,
                    reason: "AI 建议（来源：本次对话/文件 —— 请逐项核对）",
                    sourceTurnID: nil,
                    feeText: fee ? title : nil
                ))
            }
        }
        append(suggestion.requiredDocuments, kind: .requiredDocument)
        append(suggestion.actions, kind: .action)
        append(suggestion.questionsToAsk, kind: .question)
        append(suggestion.appointmentCandidates.map(\.rawText).map { "预约：\($0)" },
               kind: .appointment, dates: suggestion.appointmentCandidates)
        append(suggestion.deadlineCandidates.map(\.rawText).map { "截止：\($0)" },
               kind: .deadline, dates: suggestion.deadlineCandidates)
        append(suggestion.followUpCandidates.map(\.rawText).map { "跟进：\($0)" },
               kind: .followUp, dates: suggestion.followUpCandidates)
        append(suggestion.fees, kind: .payment, fee: true)
        // 不确定项绝不静默丢弃 —— 显示为待核对的说明。
        for uncertainty in suggestion.uncertainties {
            mapped.append(PendingCandidate(
                id: "uncertainty|\(uncertainty)|\(mapped.count)",
                kind: .action,
                title: "核对：\(uncertainty)",
                detail: "",
                date: nil,
                reason: "AI 整理的不确定项（冲突/模糊信息）",
                sourceTurnID: nil,
                feeText: nil
            ))
        }
        candidates = mapped
        organizeTurnIDs = turnIDs
    }

    // MARK: - 状态转换

    func setCaseStatus(_ errandCase: ErrandCase, to status: ErrandCaseStatus) {
        guard let repository = environment?.repository else { return }
        do {
            try repository.setErrandCaseStatus(errandCase, to: status)
            if status.isTerminal {
                environment?.errandReminders.cancelCase(caseID: errandCase.id)
            }
        } catch {
            // 状态机拒绝 —— UI 已按 canTransition 禁用非法项。
        }
        reload()
        if detailCase?.id == errandCase.id {
            reloadDetailItems()
        }
    }

    /// 记录办理结果（等待结果 + 可选预计日期）。
    func recordWaitingForResult(_ errandCase: ErrandCase, expectedAt: Date?) {
        guard let repository = environment?.repository else { return }
        try? repository.updateErrandCaseMeta(
            errandCase, expectedResultAt: expectedAt, pinned: nil
        )
        setCaseStatus(errandCase, to: .waitingForResult)
    }

    func deleteCase(_ errandCase: ErrandCase, alsoDeleteCalendarEvents: Bool) {
        guard let repository = environment?.repository else { return }
        // 先取消本机提醒与日历映射，再走正式删除链。
        environment?.errandReminders.cancelCase(caseID: errandCase.id)
        if alsoDeleteCalendarEvents {
            let items = (try? repository.errandCaseItems(caseID: errandCase.id)) ?? []
            for item in items {
                environment?.errandCalendar.removeMirroredAppointment(itemID: item.id)
            }
        }
        try? repository.deleteErrandCase(errandCase)
        closeDetail()
        reload()
    }

    // MARK: - Helpers

    static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }
}
