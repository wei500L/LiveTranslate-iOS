import Foundation

/// 确认与正式入库 — executes the user's CONFIRMED inbox actions through
/// the EXISTING formal pipelines (material import, attachment import,
/// exam/task candidate creation, schedule creation, session notes).
/// Never a second entity system: every action ends in the same
/// repository/material/attachment services the in-app flows use.
///
/// Idempotency & partial success (the operation-ledger rules):
/// - every action carries a stable operation id; a completed operation
///   is recorded in the item's ledger the MOMENT it succeeds (before the
///   next action starts);
/// - re-running an item skips already-ledgered operations — a crash or
///   retry never duplicates a formal entity;
/// - one action's failure never rolls back the successes;
/// - completed = every selected action in the ledger;
///   partiallyProcessed = some in, some failed (failures listed);
///   failed = nothing landed.
@MainActor
final class InboxActionExecutor {
    struct Context {
        /// User-confirmed course association (nil = 未归类, allowed).
        var courseID: UUID?
        /// Required by attachToSession / saveAsNote (valid 归属).
        var sessionID: UUID?
        /// Duplicate-file resolution for saveAsMaterial.
        var duplicateResolution: DuplicateResolution = .keepCopy
    }

    enum DuplicateResolution: Hashable {
        /// Import as a fresh independent copy (保留副本).
        case keepCopy
        /// Update the EXISTING same-bytes material's links instead of
        /// copying again (为已有资料建立新关联).
        case relinkExisting(UUID)
    }

    struct Failure: Equatable {
        var operationID: UUID
        var title: String
        var reason: String
    }

    struct Outcome {
        var item: SharedInboxItem
        var failures: [Failure]
    }

    private let repository: any ClassroomRepositoryProtocol
    private let materialImporter: MaterialImportService
    private let attachmentImporter: AttachmentImportService
    private let store: SharedInboxStore

    init(
        repository: any ClassroomRepositoryProtocol,
        materialImporter: MaterialImportService,
        attachmentImporter: AttachmentImportService,
        store: SharedInboxStore
    ) {
        self.repository = repository
        self.materialImporter = materialImporter
        self.attachmentImporter = attachmentImporter
        self.store = store
    }

    // MARK: - Execution

    /// Executes the item's SELECTED, not-yet-completed actions in order.
    /// The item status/ledger is updated on the store after EVERY action
    /// (crash-safe); the returned outcome lists per-action failures.
    func perform(
        itemID: UUID,
        context: Context,
        selected: [InboxSuggestedAction],
        manualAction: InboxSuggestedAction? = nil
    ) async -> Outcome {
        // manualAction (手动归类, no AI involved) joins the round.
        var actions = selected.filter { $0.isSelected }
        if let manualAction {
            actions.append(manualAction)
        }
        // Re-load the freshest ledger under the store.
        guard let fresh = store.loadManifest().items.first(where: { $0.id == itemID }) else {
            return Outcome(item: .init(scopeKey: "", payloadKind: .text, title: ""), failures: [])
        }
        let ledgered = Set(fresh.completedOperations.map(\.id))

        store.updateItem(id: itemID) { item in
            item.status = .processing
            item.errorSummary = ""
        }

        var failures: [Failure] = []
        var completed = 0
        // Schedule imports route to their own confirmation sheet (semester
        // range + course assignment) — never executed inline; the sheet
        // ledgers the operation after its schedules land.
        var routedToScheduleForm = false
        for action in actions where !ledgered.contains(action.id) {
            if InboxActionKind(rawValue: action.kindRaw) == .importSchedule {
                routedToScheduleForm = true
                continue
            }
            do {
                let entityID = try await execute(action: action, item: fresh, context: context)
                // Ledger FIRST — the moment the formal entity exists.
                store.updateItem(id: itemID) { item in
                    item.completedOperations.append(SharedInboxOperationRecord(
                        id: action.id,
                        kindRaw: action.kindRaw,
                        finishedAt: .now,
                        resultingEntityID: entityID,
                        label: action.title
                    ))
                }
                completed += 1
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription
                    ?? String(localized: "操作失败", comment: "inbox execute")
                failures.append(Failure(
                    operationID: action.id, title: action.title, reason: reason
                ))
            }
        }

        // Terminal state: honest accounting of what landed. completed
        // requires every selected action in the ledger — a schedule
        // action awaiting its form keeps the item at needsConfirmation
        // (the form's ledger() flips it to completed when it saves).
        let updated = store.updateItem(id: itemID) { item in
            if failures.isEmpty {
                if completed > 0 || !item.completedOperations.isEmpty {
                    item.status = routedToScheduleForm ? .needsConfirmation : .completed
                } else {
                    item.status = .needsConfirmation
                }
            } else if completed > 0 || !item.completedOperations.isEmpty {
                item.status = .partiallyProcessed
                item.errorSummary = failures.map(\.reason).joined(separator: "；")
            } else {
                item.status = .failed
                item.errorSummary = failures.map(\.reason).joined(separator: "；")
            }
        }
        return Outcome(item: updated ?? fresh, failures: failures)
    }

    // MARK: - Per-kind execution (existing formal pipelines only)

    /// Ledgers an action completed OUTSIDE `perform` — the schedule
    /// import, whose own confirmation sheet (semester range, course
    /// assignment) persists the schedules and reports back. Re-evaluates
    /// the terminal status against the user's current selection.
    func ledger(itemID: UUID, action: InboxSuggestedAction, entityID: UUID?) {
        store.updateItem(id: itemID) { item in
            guard !item.completedOperations.contains(where: { $0.id == action.id }) else { return }
            item.completedOperations.append(SharedInboxOperationRecord(
                id: action.id,
                kindRaw: action.kindRaw,
                finishedAt: .now,
                resultingEntityID: entityID,
                label: action.title
            ))
            // completed = every selected action now in the ledger.
            let selected = Set(item.selectedOperationIDs)
            let done = Set(item.completedOperations.map(\.id))
            if selected.subtracting(done).isEmpty, !selected.isEmpty {
                item.status = .completed
                item.errorSummary = ""
            }
        }
    }

    private func execute(
        action: InboxSuggestedAction,
        item: SharedInboxItem,
        context: Context
    ) async throws -> UUID? {
        switch InboxActionKind(rawValue: action.kindRaw) {
        case .saveAsMaterial:
            return try await importAsMaterial(action: action, item: item, context: context)
        case .linkAsMaterial:
            return try importAsLinkMaterial(action: action, item: item, context: context)
        case .attachToSession:
            return try await importAsAttachment(item: item, context: context)
        case .createExamCandidate:
            return try createExamCandidate(action: action, item: item, context: context)
        case .createTaskCandidate:
            return try createTaskCandidate(action: action, context: context)
        case .importSchedule:
            // Schedule import needs its own confirmation form (semester
            // range, course assignment) — routed by the detail view; the
            // operation is ledgered there after the schedules land.
            throw ExecutorError.needsScheduleForm
        case .saveAsNote:
            return try saveAsNote(action: action, context: context)
        case nil:
            throw ExecutorError.unknownAction
        }
    }

    /// 课程资料 — the existing MaterialImportService pipeline (streaming
    /// copy into MaterialFileStore, row LAST, extraction kickoff). The
    /// inbox payload URL is a plain local file (no sandbox scope needed).
    private func importAsMaterial(
        action: InboxSuggestedAction,
        item: SharedInboxItem,
        context: Context
    ) async throws -> UUID? {
        guard item.payloadKind == .file,
              let payloadURL = store.payloadURL(for: item) else {
            throw ExecutorError.missingPayload
        }
        let metadata = MaterialImportService.Metadata(
            title: item.title,
            kind: MaterialKind(rawValue: action.materialKindRaw) ?? .other,
            courseID: context.courseID,
            sessionID: context.sessionID,
            occurrenceKey: nil
        )
        // Duplicate handling is user-confirmed BEFORE this call: relink
        // updates the existing material (no second copy of a large PDF);
        // keepCopy imports a fresh independent material.
        if case .relinkExisting(let existingID) = context.duplicateResolution {
            guard let existing = try repository.material(id: existingID) else {
                throw ExecutorError.missingPayload
            }
            let draft = MaterialDraft(
                title: existing.title.isEmpty ? item.title : existing.title,
                originalFileName: existing.originalFileName,
                mimeType: existing.mimeType,
                kind: MaterialKind(rawValue: action.materialKindRaw) ?? existing.kind,
                format: existing.format,
                fileSize: existing.fileSize,
                contentHash: existing.contentHash,
                pageCount: existing.pageCount,
                courseID: context.courseID ?? existing.courseID,
                sessionID: context.sessionID ?? existing.sessionID,
                occurrenceKey: existing.occurrenceKey,
                sourceAttachmentID: existing.sourceAttachmentID,
                sourceURL: existing.sourceURL,
                sharedText: existing.sharedText,
                extractionStatus: existing.extractionStatus
            )
            try repository.updateMaterial(existing, with: draft)
            return existing.id
        }
        let material = try await materialImporter.importFile(
            at: payloadURL, metadata: metadata,
            keepDuplicateCopy: true // the user already resolved duplicates
        )
        return material.id
    }

    /// 链接资料 — a material with format .link (no file; the URL is the
    /// content). Same repository path as every material.
    private func importAsLinkMaterial(
        action: InboxSuggestedAction, item: SharedInboxItem, context: Context
    ) throws -> UUID? {
        guard item.payloadKind == .url, let url = URL(string: item.url) else {
            throw ExecutorError.missingPayload
        }
        let draft = MaterialDraft(
            title: item.title.isEmpty ? (item.urlTitle.isEmpty ? url.host ?? url.absoluteString : item.urlTitle) : item.title,
            originalFileName: "",
            mimeType: "text/uri-list",
            kind: MaterialKind(rawValue: action.materialKindRaw) ?? .reading,
            format: .link,
            fileSize: 0,
            contentHash: "",
            pageCount: 0,
            courseID: context.courseID,
            sessionID: nil,
            occurrenceKey: nil,
            sourceAttachmentID: nil,
            sourceURL: item.url,
            sharedText: item.textContent,
            extractionStatus: .unsupported
        )
        let material = try repository.addMaterial(draft)
        return material.id
    }

    /// 课堂图片 — the existing AttachmentImportService pipeline into the
    /// user-selected session.
    private func importAsAttachment(
        item: SharedInboxItem, context: Context
    ) async throws -> UUID? {
        guard let sessionID = context.sessionID else {
            throw ExecutorError.sessionRequired
        }
        guard item.payloadKind == .file,
              let payloadURL = store.payloadURL(for: item),
              let data = try? Data(contentsOf: payloadURL) else {
            throw ExecutorError.missingPayload
        }
        let payload = AttachmentImagePayload(
            data: data,
            capturedAt: item.receivedAt,
            suggestedTitle: item.title,
            suggestedKind: .blackboard
        )
        let outcome = await attachmentImporter.importImages(
            [payload], sessionID: sessionID,
            defaultKind: .blackboard, anchorEntryID: nil
        )
        guard let first = outcome.imported.first else {
            throw ExecutorError.attachmentImportFailed(
                outcome.duplicates.isEmpty
                    ? (outcome.failures.first ?? String(localized: "导入失败", comment: "inbox"))
                    : String(localized: "该课堂已存在相同图片", comment: "inbox")
            )
        }
        return first
    }

    /// 考试候选 — the existing device-local candidate flow (status
    /// .pending, origin .ai): no reminder, no plan, no sync push until
    /// the user confirms it in the exam center.
    private func createExamCandidate(
        action: InboxSuggestedAction, item: SharedInboxItem, context: Context
    ) throws -> UUID? {
        guard let snapshot = action.examCandidate else {
            throw ExecutorError.unknownAction
        }
        let startSecs = Self.parseTimeToSecs(snapshot.timeText)
        let draft = ExamDraft(
            title: snapshot.title,
            courseID: context.courseID,
            kind: ExamKind(rawValue: snapshot.kindRaw) ?? .custom,
            examDateKey: snapshot.dateKey.isEmpty
                ? Exam.dateKey(item.receivedAt) // honest fallback: today, flagged uncertain below
                : snapshot.dateKey,
            startSecs: startSecs,
            endSecs: -1,
            location: snapshot.location,
            scopeText: snapshot.scopeText,
            note: snapshot.requirements,
            status: .pending,
            origin: .ai,
            source: ExamSource(
                kind: .inbox,
                sourceID: item.id,
                originalText: snapshot.relativeWording.isEmpty ? snapshot.title : snapshot.relativeWording,
                uncertainties: Self.examUncertainties(snapshot)
            )
        )
        let exam = try repository.addExam(draft)
        return exam.id
    }

    /// 作业候选 — the existing StudyTask pendingConfirm flow (device-local
    /// until confirmed).
    private func createTaskCandidate(
        action: InboxSuggestedAction, context: Context
    ) throws -> UUID? {
        guard let snapshot = action.taskCandidate else {
            throw ExecutorError.unknownAction
        }
        let draft = TaskDraft(
            title: snapshot.title,
            detail: snapshot.detail,
            priority: StudyTaskPriority(rawValue: snapshot.priorityRaw) ?? .normal,
            status: .pendingConfirm,
            origin: .ai,
            uncertainty: snapshot.uncertainty,
            dueAt: snapshot.dueAt,
            courseID: context.courseID,
            sessionID: context.sessionID
        )
        let task = try repository.addTask(draft)
        return task.id
    }

    /// 课堂笔记 — the existing SessionNote flow into the user-selected
    /// session.
    private func saveAsNote(
        action: InboxSuggestedAction, context: Context
    ) throws -> UUID? {
        guard let sessionID = context.sessionID else {
            throw ExecutorError.sessionRequired
        }
        let text = action.noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ExecutorError.emptyNote }
        let note = try repository.addNote(
            NoteDraft(text: text), toSessionID: sessionID
        )
        return note.id
    }

    // MARK: - Helpers

    private static func parseTimeToSecs(_ text: String) -> Int {
        guard let secs = ScheduleImageParser.parseTime(text) else { return -1 }
        return secs
    }

    private static func examUncertainties(_ snapshot: ExamCandidateSnapshot) -> [String] {
        var flags: [String] = []
        if snapshot.dateUncertain { flags.append(String(localized: "日期不确定", comment: "inbox exam")) }
        if snapshot.timeUncertain { flags.append(String(localized: "时间不确定", comment: "inbox exam")) }
        if snapshot.kindUncertain { flags.append(String(localized: "考试类型不确定", comment: "inbox exam")) }
        if snapshot.locationUncertain { flags.append(String(localized: "地点不确定", comment: "inbox exam")) }
        return flags
    }

    enum ExecutorError: LocalizedError {
        case missingPayload
        case sessionRequired
        case unknownAction
        case needsScheduleForm
        case emptyNote
        case attachmentImportFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingPayload:
                return String(localized: "暂存文件不存在", comment: "inbox execute")
            case .sessionRequired:
                return String(localized: "请先选择课堂", comment: "inbox execute")
            case .unknownAction:
                return String(localized: "未知的操作类型", comment: "inbox execute")
            case .needsScheduleForm:
                return String(localized: "课表导入需要确认学期信息", comment: "inbox execute")
            case .emptyNote:
                return String(localized: "笔记内容为空", comment: "inbox execute")
            case .attachmentImportFailed(let reason):
                return reason
            }
        }
    }
}
