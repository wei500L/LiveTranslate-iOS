import Foundation
import SwiftData

/// Errand-case (办事事项) repository methods — the case/item family of
/// `ClassroomRepositoryProtocol`. Implemented as an extension on the
/// concrete class so it shares the model context and the
/// mutationObserver chain (the interpreter-family convention).
///
/// Draft semantics (multi-draft, stricter than the interpreter's
/// single-draft): DRAFT cases and their items NEVER notify the sync
/// observer — unconfirmed work is device-local until the user saves.
/// `saveErrandCaseDraft` promotes the case (and its confirmed items)
/// onto the wire in one go. Unconfirmed AI-candidate items stay
/// device-local even inside a formal case until the user confirms them
/// one by one (the StudyTask pendingConfirm convention).
extension TranscriptRepository {

    // MARK: - Draft lifecycle

    /// All draft cases (multiple concurrent drafts are allowed — the
    /// user can prepare several errands at once; drafts never sync).
    var errandCaseDrafts: [ErrandCase] {
        let descriptor = FetchDescriptor<ErrandCase>()
        let rows = (try? context.fetch(descriptor)) ?? []
        return rows.filter { $0.status == .draft }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Creates a fresh draft (device-local; never notifies sync).
    func startErrandCaseDraft(
        scene: InterpreterScene, title: String
    ) throws -> ErrandCase {
        let draft = ErrandCase(
            title: title.isEmpty
                ? Self.defaultErrandCaseTitle(scene: scene, date: .now)
                : title,
            sceneRaw: scene.rawValue
        )
        context.insert(draft)
        try context.save()
        // Draft rows never notify sync.
        return draft
    }

    /// 默认标题：场景显示名 · M月d日（绝不用 AI 生成标题作为保存前提）。
    static func defaultErrandCaseTitle(scene: InterpreterScene, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return "\(scene.displayName)事项 · \(formatter.string(from: date))"
    }

    /// Promotes a draft into a formal, syncing case. The user has just
    /// confirmed which fields ride the wire; the case AND its confirmed
    /// items go out together. Empty drafts (no items, no user content)
    /// are deleted instead of promoted (no history garbage).
    func saveErrandCaseDraft(
        _ errandCase: ErrandCase, status: ErrandCaseStatus
    ) throws {
        guard errandCase.status == .draft else { return }
        let items = try errandCaseItems(caseID: errandCase.id)
        let hasUserContent = !errandCase.purpose.isEmpty
            || !errandCase.userNote.isEmpty || !errandCase.location.isEmpty
            || !errandCase.contact.isEmpty || errandCase.expectedResultAt != nil
            || !(errandCase.localSources ?? []).isEmpty
        let confirmedItems = items.filter { $0.status != .unconfirmed }
        guard !confirmedItems.isEmpty || hasUserContent else {
            // 空草稿自动清理：不创建历史垃圾，也不上云。
            try discardErrandCaseDraft(errandCase)
            return
        }
        guard ErrandCaseStatus.draft.canTransition(to: status) else {
            throw ErrandTransitionError.invalidTransition
        }
        errandCase.status = status
        errandCase.updatedAt = .now
        try context.save()
        // The case AND its confirmed items ride the wire for the first
        // time (unconfirmed candidates stay device-local).
        mutationObserver?.errandCaseSaved(errandCase)
        for item in confirmedItems {
            mutationObserver?.errandCaseItemCreated(item)
        }
    }

    /// Discards a draft and its items outright (no wire traffic).
    func discardErrandCaseDraft(_ errandCase: ErrandCase) throws {
        guard errandCase.status == .draft else { return }
        try deleteErrandCaseRows(errandCase)
        // Draft deletes produce no wire traffic (nothing was uploaded).
    }

    // MARK: - Queries

    func errandCase(id: UUID) -> ErrandCase? {
        let descriptor = FetchDescriptor<ErrandCase>(
            predicate: #Predicate { $0.id == id }
        )
        return (try? context.fetch(descriptor))?.first
    }

    func errandCaseItems(caseID: UUID) throws -> [ErrandCaseItem] {
        let descriptor = FetchDescriptor<ErrandCaseItem>(
            predicate: #Predicate { $0.caseID == caseID }
        )
        return try context.fetch(descriptor).sorted { $0.sequence < $1.sequence }
    }

    /// Formal (non-draft) cases, newest first. Archived cases only when
    /// asked (the list hides them by default; history stays reachable).
    func errandCases(includeArchived: Bool = false) throws -> [ErrandCase] {
        let descriptor = FetchDescriptor<ErrandCase>()
        return try context.fetch(descriptor)
            .filter { $0.status != .draft && (includeArchived || $0.status != .archived) }
            .sorted { ($0.pinned, $0.updatedAt) > ($1.pinned, $1.updatedAt) }
    }

    /// One case's item by id.
    func errandCaseItem(id: UUID) -> ErrandCaseItem? {
        let descriptor = FetchDescriptor<ErrandCaseItem>(
            predicate: #Predicate { $0.id == id }
        )
        return (try? context.fetch(descriptor))?.first
    }

    /// Formal cases whose title / user note / confirmed checklist text
    /// matches the query (global search). Drafts, local-source file
    /// names and date raw text are deliberately NOT searched (searching
    /// a file name would leak the device-local source vocabulary).
    func errandCases(matching query: String) throws -> [ErrandCase] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let lowered = trimmed.lowercased()
        return ((try? errandCases(includeArchived: true)) ?? []).filter { errandCase in
            if errandCase.title.lowercased().contains(lowered) { return true }
            if errandCase.purpose.lowercased().contains(lowered) { return true }
            if errandCase.userNote.lowercased().contains(lowered) { return true }
            let items = (try? errandCaseItems(caseID: errandCase.id)) ?? []
            return items.contains { item in
                item.status != .unconfirmed
                    && (item.title.lowercased().contains(lowered)
                        || item.detail.lowercased().contains(lowered))
            }
        }
    }

    // MARK: - Case updates (formal rows notify sync; drafts stay local)

    /// Field updates with nil = keep. purpose/userNote are full desired
    /// state ('' clears — the context-note convention).
    func updateErrandCaseMeta(
        _ errandCase: ErrandCase,
        title: String? = nil,
        purpose: String? = nil,
        userNote: String? = nil,
        timezoneID: String? = nil,
        location: String? = nil,
        contact: String? = nil,
        expectedResultAt: Date? = nil,
        pinned: Bool? = nil,
        scene: InterpreterScene? = nil
    ) throws {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errandCase.title = title
        }
        if let purpose { errandCase.purpose = purpose }
        if let userNote { errandCase.userNote = userNote }
        if let timezoneID { errandCase.timezoneID = timezoneID }
        if let location { errandCase.location = location }
        if let contact { errandCase.contact = contact }
        if let expectedResultAt { errandCase.expectedResultAt = expectedResultAt }
        if let pinned { errandCase.pinned = pinned }
        if let scene { errandCase.sceneRaw = scene.rawValue }
        try saveErrandCase(errandCase)
    }

    /// 状态转换（受约束 —— canTransition 双重执行；不合法转换抛错）。
    func setErrandCaseStatus(
        _ errandCase: ErrandCase, to next: ErrandCaseStatus
    ) throws {
        guard errandCase.status.canTransition(to: next) else {
            throw ErrandTransitionError.invalidTransition
        }
        errandCase.status = next
        try saveErrandCase(errandCase)
    }

    private func saveErrandCase(_ errandCase: ErrandCase) throws {
        errandCase.updatedAt = .now
        try context.save()
        if errandCase.status.isFormal {
            mutationObserver?.errandCaseUpdated(errandCase)
        }
    }

    /// Deletes a case and its item rows. Caller-side system surfaces
    /// (notifications, calendar mirrors, Spotlight) are cleaned by the
    /// mutation fanout; the wire delete is a single case op (the server
    /// cascades tombstones to items).
    func deleteErrandCase(_ errandCase: ErrandCase) throws {
        let id = errandCase.id
        let wasFormal = errandCase.status.isFormal
        try deleteErrandCaseRows(errandCase)
        if wasFormal {
            mutationObserver?.errandCaseDeleted(id: id)
        }
    }

    /// Row deletion shared by discard/delete/pull paths — never notifies.
    private func deleteErrandCaseRows(_ errandCase: ErrandCase) throws {
        let items = (try? errandCaseItems(caseID: errandCase.id)) ?? []
        for item in items {
            context.delete(item)
        }
        context.delete(errandCase)
        try context.save()
    }

    // MARK: - Items

    /// Appends a checklist item. `status: .unconfirmed` rows are AI/rule
    /// candidates — they stay device-local even in a formal case until
    /// the user confirms them (no sync notification).
    @discardableResult
    func addErrandCaseItem(_ draft: ErrandItemDraft) throws -> ErrandCaseItem {
        let sequence = ((try? errandCaseItems(caseID: draft.caseID)) ?? [])
            .map(\.sequence).max().map { $0 + 1 } ?? 0
        let item = ErrandCaseItem(
            caseID: draft.caseID,
            title: draft.title,
            kindRaw: draft.kind.rawValue,
            statusRaw: draft.status.rawValue,
            sequence: sequence,
            detail: draft.detail,
            dueAt: draft.dueAt,
            dateText: draft.dateText,
            dateIsRelative: draft.dateIsRelative,
            dateUncertain: draft.dateUncertain,
            originRaw: draft.origin.rawValue,
            confirmed: draft.confirmed,
            feeText: draft.feeText,
            feeAmount: draft.feeAmount,
            feeCurrency: draft.feeCurrency,
            modifiedAt: draft.modifiedAt
        )
        context.insert(item)
        try context.save()
        notifyIfSyncable(item) {
            mutationObserver?.errandCaseItemCreated(item)
        }
        return item
    }

    /// Text edits stamp modifiedAt (the same-version merge tiebreak).
    func updateErrandCaseItem(
        _ item: ErrandCaseItem,
        title: String? = nil,
        detail: String? = nil,
        kind: ErrandCaseItemKind? = nil,
        feeText: String? = nil,
        feeAmount: Double? = nil,
        feeCurrency: String? = nil
    ) throws {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            item.title = title
        }
        if let detail { item.detail = detail }
        if let kind { item.kindRaw = kind.rawValue }
        if let feeText { item.feeText = feeText }
        if let feeAmount { item.feeAmount = feeAmount }
        if let feeCurrency { item.feeCurrency = feeCurrency }
        item.modifiedAt = .now
        try saveErrandCaseItem(item)
    }

    /// Status flips. done stamps completedAt; a reopen (done → pending)
    /// stamps modifiedAt so the server-side terminal-stickiness sees a
    /// genuinely newer edit.
    func setErrandCaseItemStatus(
        _ item: ErrandCaseItem, to next: ErrandCaseItemStatus
    ) throws {
        let wasTerminal = item.status == .done || item.status == .skipped
        item.status = next
        if next == .done, item.completedAt == nil {
            item.completedAt = .now
        }
        if wasTerminal && (next == .pending || next == .unconfirmed) {
            item.modifiedAt = .now
        }
        try saveErrandCaseItem(item)
    }

    /// Confirms an AI/rule candidate (the per-item 确认 action): the row
    /// becomes a real, syncing checklist item. Idempotent.
    func confirmErrandCaseItem(_ item: ErrandCaseItem) throws {
        let wasCandidate = item.status == .unconfirmed || !item.confirmed
        item.confirmed = true
        if item.status == .unconfirmed {
            item.status = .pending
        }
        item.modifiedAt = .now
        try saveErrandCaseItem(item)
        _ = wasCandidate // (the observer fired above when applicable)
    }

    /// Sets the user-CONFIRMED time (nil = no confirmed time). The date
    /// wording and conversion flags ride alongside for honest display.
    func setErrandCaseItemDate(
        _ item: ErrandCaseItem,
        dueAt: Date?,
        dateText: String? = nil,
        isRelative: Bool? = nil,
        uncertain: Bool? = nil
    ) throws {
        item.dueAt = dueAt
        if let dateText { item.dateText = dateText }
        if let isRelative { item.dateIsRelative = isRelative }
        if let uncertain { item.dateUncertain = uncertain }
        item.modifiedAt = .now
        try saveErrandCaseItem(item)
    }

    /// Sort order inside the case (reordering is a plain user edit).
    func setErrandCaseItemSequence(_ item: ErrandCaseItem, sequence: Int) throws {
        item.sequence = sequence
        item.modifiedAt = .now
        try saveErrandCaseItem(item)
    }

    func deleteErrandCaseItem(_ item: ErrandCaseItem) throws {
        let syncable = isItemSyncable(item)
        let id = item.id
        context.delete(item)
        try context.save()
        if syncable {
            mutationObserver?.errandCaseItemDeleted(id: id)
        }
    }

    private func saveErrandCaseItem(_ item: ErrandCaseItem) throws {
        item.updatedAt = .now
        try context.save()
        notifyIfSyncable(item) {
            mutationObserver?.errandCaseItemUpdated(item)
        }
    }

    /// An item rides the wire only when its parent case is formal AND the
    /// item itself is a confirmed row (never a candidate).
    private func isItemSyncable(_ item: ErrandCaseItem) -> Bool {
        item.status != .unconfirmed
            && (errandCase(id: item.caseID)?.status.isFormal ?? false)
    }

    private func notifyIfSyncable(_ item: ErrandCaseItem, _ notify: () -> Void) {
        if isItemSyncable(item) { notify() }
    }

    // MARK: - Local sources (device-local; only the flag ever syncs)

    /// Adds a local source link. Idempotent per dedup key — adding the
    /// same conversation/document twice is a no-op returning false. The
    /// content-free hasLocalSources flag rides the next case update.
    @discardableResult
    func addErrandLocalSource(
        to errandCase: ErrandCase, _ source: ErrandLocalSource
    ) throws -> Bool {
        var sources = errandCase.localSources ?? []
        guard !sources.contains(where: { $0.dedupKey == source.dedupKey }) else {
            return false
        }
        sources.append(source)
        errandCase.storeLocalSources(sources)
        errandCase.hasLocalSources = true
        try saveErrandCase(errandCase)
        return true
    }

    /// Removes one local source link. Removing the last one does NOT
    /// clear hasLocalSources (another device may still hold sources —
    /// the flag is a "some device has sources" fact, not "this device").
    func removeErrandLocalSource(
        from errandCase: ErrandCase, id: UUID
    ) throws {
        var sources = errandCase.localSources ?? []
        let before = sources.count
        sources.removeAll { $0.id == id }
        guard sources.count != before else { return }
        errandCase.storeLocalSources(sources)
        try saveErrandCase(errandCase)
    }

    // MARK: - Remote apply (pull)

    func applyRemoteErrandCase(
        record: SyncServerRecordDTO, serverVersion: Int
    ) throws {
        guard let recordID = record.id else { return }
        let descriptor = FetchDescriptor<ErrandCase>(
            predicate: #Predicate { $0.id == recordID }
        )
        let existing = try context.fetch(descriptor).first
        if let existing, existing.serverVersion >= serverVersion { return }

        let errandCase: ErrandCase
        if let existing {
            errandCase = existing
        } else {
            errandCase = ErrandCase(
                id: recordID, title: "", sceneRaw: InterpreterScene.general.rawValue
            )
            context.insert(errandCase)
        }
        if let title = record.title, !title.isEmpty { errandCase.title = title }
        if let scene = record.errandScene,
           let parsed = InterpreterScene(rawValue: scene) {
            errandCase.sceneRaw = parsed.rawValue
        }
        if let status = record.errandStatus,
           let parsed = ErrandCaseStatus(rawValue: status) {
            errandCase.statusRaw = parsed.rawValue
        }
        if let purpose = record.errandPurpose { errandCase.purpose = purpose }
        if let note = record.errandNote { errandCase.userNote = note }
        if let timezone = record.errandTimezone { errandCase.timezoneID = timezone }
        if let location = record.errandLocation { errandCase.location = location }
        if let contact = record.errandContact { errandCase.contact = contact }
        if let expected = record.errandExpectedResultAt {
            errandCase.expectedResultAt = expected
        }
        if let pinned = record.errandPinned { errandCase.pinned = pinned }
        if let hasLocal = record.errandHasLocalSources {
            // OR 语义：该标志是"某些设备持有本地来源"的事实 —— 本机已有
            // 来源（true）时，远端 false 不把它抹掉（否则下一次本机 push
            // 会让其他设备失去"来源资料仅保存在原设备"的诚实提示）。
            errandCase.hasLocalSources = errandCase.hasLocalSources || hasLocal
        }
        // 本机 localSourcesJSON 不被远端覆盖（wire 上没有这个字段 ——
        // 其他设备的来源链接永远到不了这里）。
        errandCase.serverVersion = serverVersion
        errandCase.updatedAt = .now
        try context.save()
    }

    func applyRemoteErrandCaseItem(
        record: SyncServerRecordDTO, serverVersion: Int
    ) throws {
        guard let recordID = record.id, let caseID = record.caseId else { return }
        // Item rows may arrive before their case (the wire convention)
        // — ensure the parent exists as a shell.
        if errandCase(id: caseID) == nil {
            let shell = ErrandCase(
                id: caseID, title: "", sceneRaw: InterpreterScene.general.rawValue
            )
            context.insert(shell)
        }
        let descriptor = FetchDescriptor<ErrandCaseItem>(
            predicate: #Predicate { $0.id == recordID }
        )
        let existing = try context.fetch(descriptor).first
        if let existing, existing.serverVersion >= serverVersion { return }

        let item: ErrandCaseItem
        if let existing {
            item = existing
        } else {
            item = ErrandCaseItem(
                id: recordID, caseID: caseID, title: "",
                kindRaw: ErrandCaseItemKind.action.rawValue
            )
            context.insert(item)
        }
        item.caseID = caseID
        if let title = record.title, !title.isEmpty { item.title = title }
        if let kind = record.errandItemKind,
           let parsed = ErrandCaseItemKind(rawValue: kind) {
            item.kindRaw = parsed.rawValue
        }
        if let status = record.errandItemStatus,
           let parsed = ErrandCaseItemStatus(rawValue: status) {
            item.statusRaw = parsed.rawValue
        }
        if let sequence = record.errandItemSequence { item.sequence = sequence }
        if let detail = record.errandItemDetail { item.detail = detail }
        item.dueAt = record.errandItemDueAt
        if let dateText = record.errandItemDateText { item.dateText = dateText }
        if let isRelative = record.errandItemDateIsRelative {
            item.dateIsRelative = isRelative
        }
        if let uncertain = record.errandItemDateUncertain {
            item.dateUncertain = uncertain
        }
        if let origin = record.errandItemOrigin,
           let parsed = ErrandCaseItemOrigin(rawValue: origin) {
            item.originRaw = parsed.rawValue
        }
        // Confirmed is sticky: a remote row the user confirmed on another
        // device never un-confirms here.
        item.confirmed = item.confirmed || (record.errandItemConfirmed ?? false)
        if let feeText = record.errandItemFeeText { item.feeText = feeText }
        item.feeAmount = record.errandItemFeeAmount
        if let feeCurrency = record.errandItemFeeCurrency {
            item.feeCurrency = feeCurrency
        }
        item.modifiedAt = record.errandItemModifiedAt
        item.completedAt = record.errandItemCompletedAt
        item.serverVersion = serverVersion
        item.updatedAt = .now
        try context.save()
    }

    func deleteErrandCaseByID(_ id: UUID) throws {
        guard let errandCase = errandCase(id: id) else { return }
        // 幂等：直接删除（本地不存墓碑，delete-wins 在 push 冲突分支执行）。
        try deleteErrandCaseRows(errandCase)
    }

    func deleteErrandCaseItemByID(_ id: UUID) throws {
        guard let item = errandCaseItem(id: id) else { return }
        try deleteErrandCaseItem(item)
    }
}

/// 状态机违规（受约束转换被拒绝时抛出）。
enum ErrandTransitionError: Error {
    case invalidTransition
}
