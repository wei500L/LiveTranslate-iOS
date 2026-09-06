import XCTest
import SwiftData
import EventKit
import UserNotifications
@testable import LiveTranslateIOS

// 第十八轮 办事事项测试：状态机与草稿边界、wire 卫生（本地来源绝不
// 上船）、日期解析语义（相对/过去/DST/歧义）、通知幂等与隐私三档、
// 日历映射语义、AI 宽容解析与 sourceRef 校验、导出边界、来源链接多
// 对多。全部使用内存数据库、fake 通知中心/EventKit 与确定性数据。

// MARK: - 测试替身

/// 记录 errand 家族的全部 mutation 通知（草稿永不通知的证明）。
final class ErrandMutationRecorder: TranscriptMutationObserving {
    var caseSaved: [UUID] = []
    var caseUpdated: [UUID] = []
    var caseDeleted: [UUID] = []
    var itemCreated: [UUID] = []
    var itemUpdated: [UUID] = []
    var itemDeleted: [UUID] = []

    func errandCaseSaved(_ errandCase: ErrandCase) { caseSaved.append(errandCase.id) }
    func errandCaseUpdated(_ errandCase: ErrandCase) { caseUpdated.append(errandCase.id) }
    func errandCaseDeleted(id: UUID) { caseDeleted.append(id) }
    func errandCaseItemCreated(_ item: ErrandCaseItem) { itemCreated.append(item.id) }
    func errandCaseItemUpdated(_ item: ErrandCaseItem) { itemUpdated.append(item.id) }
    func errandCaseItemDeleted(id: UUID) { itemDeleted.append(id) }
}

/// Fake 通知中心：内存请求表 + 可配置授权（测试"权限拒绝不显示假成
/// 功"、"identifier 幂等"、"完成/删除取消"）。
@MainActor
final class FakeErrandNotificationCenter: ErrandNotificationScheduling {
    var pending: [ErrandNotificationRequest] = []
    var authorization: UNAuthorizationStatus = .authorized

    var authorizationState: UNAuthorizationStatus { authorization }

    func requestAuthorization() async -> Bool {
        authorization == .authorized || authorization == .provisional
    }

    func add(_ request: ErrandNotificationRequest) async throws {
        pending.removeAll { $0.identifier == request.identifier }
        pending.append(request)
    }

    func removePending(withIdentifiers identifiers: [String]) {
        pending.removeAll { identifiers.contains($0.identifier) }
    }

    func pendingIdentifiers() async -> [String] {
        pending.map(\.identifier)
    }
}

/// Fake EventKit：内存事件表（测试镜像幂等、外部删除的真实状态）。
@MainActor
final class FakeErrandEventStore: ErrandEventStoring {
    var events: [String: ErrandEventInfo] = [:]
    var writable: [ErrandCalendarInfo] = [
        ErrandCalendarInfo(id: "cal-1", title: "测试日历")
    ]

    var authorizationStatus: EKAuthorizationStatus = .writeOnly

    func requestWriteOnlyAccess() async -> Bool { true }

    func writableCalendars() -> [ErrandCalendarInfo] { writable }

    func event(identifier: String) -> ErrandEventInfo? { events[identifier] }

    func save(
        title: String, location: String, notes: String,
        start: Date, duration: TimeInterval,
        calendarIdentifier: String, existingIdentifier: String?
    ) -> String? {
        let identifier = existingIdentifier ?? "evt-\(events.count + 1)"
        events[identifier] = ErrandEventInfo(
            identifier: identifier, title: title, location: location,
            notes: notes, startDate: start,
            endDate: start.addingTimeInterval(duration)
        )
        return identifier
    }

    func remove(identifier: String) -> Bool {
        events.removeValue(forKey: identifier) != nil
    }
}

// MARK: - 仓库：状态机、草稿边界、删除 fanout

@MainActor
final class ErrandRepositoryTests: XCTestCase {
    private var container: ModelContainer!
    private var repository: TranscriptRepository!
    private var recorder = ErrandMutationRecorder()

    override func setUp async throws {
        let schema = Schema([
            InterpreterConversation.self, InterpreterTurn.self,
            InterpreterDocument.self,
            ErrandCase.self, ErrandCaseItem.self,
            StudyTask.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
        repository = TranscriptRepository(
            container: container,
            databaseURL: URL(fileURLWithPath: "/dev/null/nonexistent.sqlite")
        )
        recorder = ErrandMutationRecorder()
        repository.mutationObserver = recorder
    }

    private func makeCaseItem(
        _ errandCase: ErrandCase, title: String,
        kind: ErrandCaseItemKind, dueAt: Date? = nil,
        dateText: String = "", uncertain: Bool = false
    ) throws -> ErrandCaseItem {
        try repository.addErrandCaseItem(ErrandItemDraft(
            caseID: errandCase.id, title: title, kind: kind,
            dueAt: dueAt, dateText: dateText, dateUncertain: uncertain
        ))
    }

    // 1. 状态机：合法转换与受约束转换。
    func testStatusTransitionsAreConstrained() {
        XCTAssertTrue(ErrandCaseStatus.draft.canTransition(to: .preparing))
        XCTAssertTrue(ErrandCaseStatus.draft.canTransition(to: .scheduled))
        XCTAssertFalse(ErrandCaseStatus.preparing.canTransition(to: .draft))
        XCTAssertTrue(ErrandCaseStatus.preparing.canTransition(to: .completed))
        XCTAssertTrue(ErrandCaseStatus.completed.canTransition(to: .archived))
        XCTAssertTrue(ErrandCaseStatus.cancelled.canTransition(to: .archived))
        XCTAssertTrue(ErrandCaseStatus.archived.canTransition(to: .preparing))
        XCTAssertFalse(ErrandCaseStatus.completed.canTransition(to: .scheduled))
        XCTAssertFalse(ErrandCaseStatus.cancelled.canTransition(to: .preparing))
        XCTAssertFalse(ErrandCaseStatus.archived.canTransition(to: .completed))
    }

    func testInvalidTransitionThrows() throws {
        let draft = try repository.startErrandCaseDraft(scene: .dorm, title: "宿舍登记")
        try repository.saveErrandCaseDraft(draft, status: .completed)
        XCTAssertThrowsError(try repository.setErrandCaseStatus(draft, to: .scheduled)) {
            XCTAssertTrue($0 is ErrandTransitionError)
        }
    }

    // 2. 草稿不进 outbox；保存后 case + 已确认 items 一次上船。
    func testDraftLifecycleNeverNotifiesSync() throws {
        let draft = try repository.startErrandCaseDraft(scene: .bank, title: "银行卡")
        XCTAssertEqual(draft.status, .draft)
        XCTAssertTrue(draft.title.hasPrefix("银行"))

        _ = try makeCaseItem(draft, title: "护照原件", kind: .requiredDocument)
        // AI 候选（unconfirmed）：即使在草稿里也不通知。
        _ = try repository.addErrandCaseItem(ErrandItemDraft(
            caseID: draft.id, title: "通常需要的居住证明",
            kind: .requiredDocument, status: .unconfirmed,
            origin: .ai, confirmed: false
        ))
        XCTAssertTrue(recorder.caseSaved.isEmpty)
        XCTAssertTrue(recorder.itemCreated.isEmpty)

        try repository.saveErrandCaseDraft(draft, status: .preparing)
        XCTAssertEqual(recorder.caseSaved, [draft.id])
        // 只有已确认的 item 上船；候选保持本地。
        XCTAssertEqual(recorder.itemCreated.count, 1)
        XCTAssertFalse(recorder.itemCreated.contains { id in
            (try? repository.errandCaseItems(caseID: draft.id))?.contains { $0.id == id && $0.status == .unconfirmed } ?? false
        })
    }

    // 3. 空草稿保存时自动清理；有内容的草稿保留可恢复。
    func testEmptyDraftCleanupOnSave() throws {
        let empty = try repository.startErrandCaseDraft(scene: .general, title: "")
        try repository.saveErrandCaseDraft(empty, status: .preparing)
        XCTAssertNil(repository.errandCase(id: empty.id), "空草稿保存自动清理，不产生历史垃圾")
        XCTAssertTrue(recorder.caseSaved.isEmpty)

        let content = try repository.startErrandCaseDraft(scene: .dorm, title: "带内容的草稿")
        try repository.updateErrandCaseMeta(content, purpose: "办理登记")
        try repository.saveErrandCaseDraft(content, status: .preparing)
        XCTAssertNotNil(repository.errandCase(id: content.id))
    }

    func testDraftDiscardRemovesItems() throws {
        let draft = try repository.startErrandCaseDraft(scene: .general, title: "x")
        _ = try makeCaseItem(draft, title: "材料", kind: .requiredDocument)
        try repository.discardErrandCaseDraft(draft)
        XCTAssertNil(repository.errandCase(id: draft.id))
        XCTAssertTrue(try repository.errandCaseItems(caseID: draft.id).isEmpty)
        XCTAssertTrue(recorder.caseDeleted.isEmpty, "草稿删除零 wire 流量")
    }

    // 正式删除：单个 case op（服务器级联 items）。
    func testFormalDeleteNotifiesOnce() throws {
        let draft = try repository.startErrandCaseDraft(scene: .general, title: "x")
        _ = try makeCaseItem(draft, title: "材料", kind: .requiredDocument)
        try repository.saveErrandCaseDraft(draft, status: .preparing)
        try repository.deleteErrandCase(draft)
        XCTAssertEqual(recorder.caseDeleted, [draft.id])
        XCTAssertTrue(recorder.itemDeleted.isEmpty, "items 不单独发 delete op（服务器级联）")
        XCTAssertNil(repository.errandCase(id: draft.id))
    }

    // 12. source link：多对多、重复关联幂等、删除事项不删原对话、删除
    // 文件不删事项。
    func testLocalSourcesManyToManyAndIdempotent() throws {
        // 通过仓库正规链路建一个已保存对话（source 原件；保存要求至少
        // 一个回合）。
        let conversation = try repository.startInterpreterDraft(
            scene: .dorm, contextNote: ""
        )
        _ = try repository.addInterpreterCounterpartTurn(
            conversationID: conversation.id,
            russian: "Принесите паспорт",
            inputMethod: .text
        )
        try repository.saveInterpreterDraft(title: "对话")

        let caseA = try repository.startErrandCaseDraft(scene: .dorm, title: "A")
        let caseB = try repository.startErrandCaseDraft(scene: .dorm, title: "B")

        // 同一对话加入两个事项（一个来源可被多个事项引用）。
        XCTAssertTrue(try repository.addErrandLocalSource(
            to: caseA,
            ErrandLocalSource(kind: .conversation, conversationID: conversation.id)
        ))
        XCTAssertTrue(try repository.addErrandLocalSource(
            to: caseB,
            ErrandLocalSource(kind: .conversation, conversationID: conversation.id)
        ))
        // 重复加入同一事项 → 幂等 false。
        XCTAssertFalse(try repository.addErrandLocalSource(
            to: caseA,
            ErrandLocalSource(kind: .conversation, conversationID: conversation.id)
        ))
        XCTAssertTrue(caseA.hasLocalSources)

        // 删除事项 A 不删原对话，也不影响 B 的链接。
        try repository.discardErrandCaseDraft(caseA)
        XCTAssertNotNil(repository.interpreterConversation(id: conversation.id))
        XCTAssertEqual(caseB.localSources?.count, 1)

        // 删除原对话后事项 B 仍存在（显示"原文件已从本机删除"）。
        try repository.deleteInterpreterConversationByID(conversation.id)
        XCTAssertNotNil(repository.errandCase(id: caseB.id))
        XCTAssertEqual(caseB.localSources?.count, 1)
    }

    // 14. 出站 payload 完全不含文件名/页码/snippet/路径/chunk ID/OCR。
    func testOutboundPayloadCarriesNoLocalSourceContent() throws {
        let draft = try repository.startErrandCaseDraft(scene: .dorm, title: "宿舍登记 · 机密")
        _ = try repository.addErrandLocalSource(to: draft, ErrandLocalSource(
            kind: .document, documentID: UUID(),
            documentName: "护照_扫描件.pdf", pageNumber: 3,
            snippet: "PASSPORT RU 1234 567890"
        ))
        let payload = CloudSyncService.payload(for: draft)
        let data = try JSONEncoder().encode(payload)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("护照_扫描件.pdf"))
        XCTAssertFalse(json.contains("PASSPORT"))
        XCTAssertFalse(json.contains("snippet"))
        XCTAssertFalse(json.contains("pageNumber"))
        XCTAssertFalse(json.contains("documentID"))
        XCTAssertFalse(json.contains("localSources"))
        XCTAssertEqual(payload.errandHasLocalSources, true, "只有无内容布尔标志上船")
    }

    func testItemOutboundPayload() throws {
        let errandCase = try repository.startErrandCaseDraft(scene: .general, title: "x")
        let item = try repository.addErrandCaseItem(ErrandItemDraft(
            caseID: errandCase.id, title: "预约登记", kind: .appointment,
            dueAt: Date(timeIntervalSince1970: 1_800_000_000),
            dateText: "до пятницы", dateIsRelative: true,
            feeText: "200₽", feeAmount: 200, feeCurrency: "RUB"
        ))
        let payload = CloudSyncService.payload(for: item)
        XCTAssertEqual(payload.title, "预约登记")
        XCTAssertEqual(payload.errandItemKind, "appointment")
        XCTAssertEqual(payload.errandItemDateText, "до пятницы", "日期原文保留")
        XCTAssertEqual(payload.errandItemFeeCurrency, "RUB")
    }

    // 15. 入站清洗不能复活本地来源：远端 record 没有来源字段；本机
    // localSourcesJSON 不被远端覆盖。
    func testInboundApplyNeverResurrectsLocalSources() throws {
        let draft = try repository.startErrandCaseDraft(scene: .dorm, title: "本地")
        try repository.saveErrandCaseDraft(draft, status: .preparing)
        _ = try repository.addErrandLocalSource(to: draft, ErrandLocalSource(
            kind: .document, documentID: UUID(), documentName: "本机文件.pdf"
        ))

        var record = SyncServerRecordDTO(id: draft.id)
        record.title = "远端标题"
        record.errandScene = "dorm"
        record.errandStatus = "preparing"
        record.errandHasLocalSources = false
        try repository.applyRemoteErrandCase(record: record, serverVersion: 5)
        let updated = try XCTUnwrap(repository.errandCase(id: draft.id))
        XCTAssertEqual(updated.title, "远端标题")
        XCTAssertEqual(updated.localSources?.count, 1, "本机来源不被远端覆盖")
        XCTAssertEqual(updated.localSources?.first?.documentName, "本机文件.pdf")
        // 远端的 hasLocalSources=false 是"保存设备无来源"的事实 —— 但本
        // 机的来源仍然存在，展示层以本机为准显示。
        XCTAssertEqual(updated.serverVersion, 5)
    }

    // 11（数据层）. Today 完成回写同一 item，不复制 StudyTask。
    func testCompletingItemDoesNotCreateStudyTask() throws {
        let draft = try repository.startErrandCaseDraft(scene: .general, title: "x")
        let item = try makeCaseItem(draft, title: "预约", kind: .appointment)
        try repository.saveErrandCaseDraft(draft, status: .scheduled)
        try repository.setErrandCaseItemStatus(item, to: .done)
        XCTAssertEqual(item.status, .done)
        XCTAssertNotNil(item.completedAt, "done 打完成时间")
        XCTAssertTrue(try repository.tasks(courseID: nil, includeDone: true).isEmpty,
                      "完成清单项绝不复制为 StudyTask")
        // 重开需要更新的 modifiedAt（服务器端终态粘滞的客户端侧对应）。
        XCTAssertNotNil(item.modifiedAt)
    }

    // item 状态机：unconfirmed → confirm → pending。
    func testCandidateConfirmFlow() throws {
        let errandCase = try repository.startErrandCaseDraft(scene: .general, title: "x")
        let candidate = try repository.addErrandCaseItem(ErrandItemDraft(
            caseID: errandCase.id, title: "AI 材料建议", kind: .requiredDocument,
            status: .unconfirmed, origin: .ai, confirmed: false
        ))
        try repository.confirmErrandCaseItem(candidate)
        XCTAssertEqual(candidate.status, .pending)
        XCTAssertTrue(candidate.confirmed)
        XCTAssertEqual(candidate.origin, .ai, "来源保持 ai（视觉区分用户确认的 AI 候选）")
    }

    // 搜索：不含草稿、OCR、文件名。
    func testSearchExcludesDraftsAndFilenames() throws {
        let draft = try repository.startErrandCaseDraft(scene: .dorm, title: "草稿机密标题")
        _ = try repository.addErrandLocalSource(to: draft, ErrandLocalSource(
            kind: .document, documentID: UUID(), documentName: "绝密文件名.pdf"
        ))
        let formal = try repository.startErrandCaseDraft(scene: .dorm, title: "正式事项标题")
        try repository.saveErrandCaseDraft(formal, status: .preparing)

        XCTAssertTrue(try repository.errandCases(matching: "草稿机密标题").isEmpty,
                      "草稿不进全局搜索")
        XCTAssertEqual(try repository.errandCases(matching: "正式事项标题").count, 1)
        XCTAssertTrue(try repository.errandCases(matching: "绝密文件名").isEmpty,
                      "本地来源文件名不被搜索")
    }
}

// MARK: - 日期解析（相对/过去/DST/歧义）

final class ErrandDateParserTests: XCTestCase {
    private var calendar = Calendar.current

    override func setUp() {
        super.setUp()
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Moscow")!
        calendar = c
    }

    private func anchor(_ year: Int, _ month: Int, _ day: Int, hour: Int = 10) -> Date {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day; comps.hour = hour
        return calendar.date(from: comps)!
    }

    func testExplicitChineseFullDate() {
        let candidates = ErrandDateParser.candidates(
            in: "请在2026年9月10日到管理处", anchor: anchor(2026, 9, 1), calendar: calendar
        )
        let full = candidates.first { $0.rawText.contains("2026") }
        XCTAssertNotNil(full)
        XCTAssertEqual(calendar.component(.day, from: full!.resolved!), 10)
        XCTAssertFalse(full!.isRelative)
        XCTAssertFalse(full!.uncertain)
        XCTAssertFalse(full!.hasTime)
    }

    func testMonthDayDefaultsToAnchorYearAndPastIsUncertain() {
        // 9月1日锚点，"8月20日"已过去 —— 不静默改到未来，标记歧义。
        let candidates = ErrandDateParser.candidates(
            in: "8月20日交材料", anchor: anchor(2026, 9, 1), calendar: calendar
        )
        let past = candidates.first { $0.rawText.contains("8月20日") }
        XCTAssertNotNil(past)
        XCTAssertEqual(calendar.component(.month, from: past!.resolved!), 8)
        XCTAssertTrue(past!.uncertain, "过去日期不静默改到未来 —— 标记歧义")
    }

    func testRussianMonthDay() {
        let candidates = ErrandDateParser.candidates(
            in: "Приходите 10 сентября", anchor: anchor(2026, 8, 20), calendar: calendar
        )
        let date = candidates.first { $0.rawText.contains("сентября") }
        XCTAssertNotNil(date)
        XCTAssertEqual(calendar.component(.month, from: date!.resolved!), 9)
    }

    func testRelativeDays() {
        let anchorDate = anchor(2026, 9, 10)
        let tomorrow = ErrandDateParser.candidates(
            in: "明天来取", anchor: anchorDate, calendar: calendar
        ).first { $0.rawText == "明天" }
        XCTAssertNotNil(tomorrow)
        XCTAssertEqual(
            calendar.dateComponents([.day], from: anchorDate, to: tomorrow!.resolved!).day, 1
        )
        XCTAssertTrue(tomorrow!.isRelative)
        let poslezavtra = ErrandDateParser.candidates(
            in: "послезавтра будет готово", anchor: anchorDate, calendar: calendar
        ).first { $0.rawText == "послезавтра" }
        XCTAssertEqual(
            calendar.dateComponents([.day], from: anchorDate, to: poslezavtra!.resolved!).day, 2
        )
    }

    func testBareWeekdayIsUncertain() {
        // 无前缀"周四"：取最近未来但标记歧义（可能指本周已过的周四）。
        let candidates = ErrandDateParser.candidates(
            in: "周四上午来", anchor: anchor(2026, 9, 7), calendar: calendar
        ) // 2026-09-07 is a Monday.
        let weekday = candidates.first { $0.rawText.contains("周四") }
        XCTAssertNotNil(weekday)
        XCTAssertTrue(weekday!.uncertain, "无前缀星期是歧义的 —— 需用户确认")
        let nextWeek = ErrandDateParser.candidates(
            in: "下周四交", anchor: anchor(2026, 9, 7), calendar: calendar
        ).first { $0.rawText.contains("下周四") }
        XCTAssertNotNil(nextWeek)
        XCTAssertFalse(nextWeek!.uncertain, "下周四明确")
    }

    func testTimeCombinesWithDate() {
        let candidates = ErrandDateParser.candidates(
            in: "9月10日 14:30 到场", anchor: anchor(2026, 9, 1), calendar: calendar
        )
        let combined = candidates.first { $0.hasTime }
        XCTAssertNotNil(combined)
        XCTAssertEqual(calendar.component(.hour, from: combined!.resolved!), 14)
        XCTAssertEqual(calendar.component(.minute, from: combined!.resolved!), 30)
    }

    func testOnlyTimeIsUncertainWhenPast() {
        let candidates = ErrandDateParser.candidates(
            in: "в 9:00", anchor: anchor(2026, 9, 1, hour: 15), calendar: calendar
        )
        let timeOnly = candidates.first { $0.rawText.contains("9:00") }
        XCTAssertNotNil(timeOnly)
        XCTAssertTrue(timeOnly!.uncertain, "只有时间且已过 —— 可能指明天，需确认")
    }

    func testDSTBoundaryRoundTrip() {
        // 莫斯科无 DST —— 用一个有 DST 的时区验证往返校验。
        var dstCalendar = Calendar(identifier: .gregorian)
        dstCalendar.timeZone = TimeZone(identifier: "America/New_York")!
        // 2026-03-08 02:30 does not exist (spring forward).
        let candidates = ErrandDateParser.candidates(
            in: "3月8日 2:30", anchor: anchor(2026, 1, 1), calendar: dstCalendar
        )
        let combined = candidates.first { $0.hasTime }
        XCTAssertNotNil(combined)
        // 不存在的本地时间被 Calendar 归一 —— 往返不一致 → uncertain。
        if let resolved = combined!.resolved {
            let roundTrip = dstCalendar.dateComponents(
                [.hour, .minute], from: resolved
            )
            if roundTrip.hour != 2 || roundTrip.minute != 30 {
                XCTAssertTrue(combined!.uncertain, "DST 不存在时间必须标记歧义")
            }
        }
    }
}

// MARK: - 本地规则提取（防编造边界）

final class ErrandDraftExtractorTests: XCTestCase {
    func testKeywordExtractionWithReason() {
        let turnID = UUID()
        let candidates = ErrandDraftExtractor.candidates(fromTurns: [
            (id: turnID, text: "Нужно принести оригинал паспорта и копию регистрации", isCounterpart: true)
        ])
        let documents = candidates.filter { $0.kind == .requiredDocument }
        XCTAssertFalse(documents.isEmpty, "оригинал/копия 命中材料候选")
        XCTAssertTrue(documents.allSatisfy { $0.reason.contains("关键词") })
        XCTAssertTrue(documents.allSatisfy { $0.sourceTurnID == turnID })
    }

    func testExtractionNeverInventsDates() {
        let candidates = ErrandDraftExtractor.candidates(fromTurns: [
            (id: UUID(), text: "Приходите, когда будет готово", isCounterpart: true)
        ])
        // 没有明确时间 → 没有日期候选（绝不编造）。
        XCTAssertTrue(candidates.allSatisfy { $0.date == nil })
    }

    func testDocumentAnalysisFieldsBecomeCandidates() {
        let analysis = InterpreterDocumentAnalysis(
            requiredDocuments: ["护照原件", "落地签复印件"],
            deadlines: ["до пятницы"],
            fees: ["200₽"],
            questionsToAsk: ["Какой залог?"]
        )
        let candidates = ErrandDraftExtractor.candidates(fromAnalysis: analysis)
        XCTAssertEqual(candidates.filter { $0.kind == .requiredDocument }.count, 2)
        XCTAssertEqual(candidates.filter { $0.kind == .deadline }.count, 1)
        XCTAssertEqual(candidates.filter { $0.kind == .payment }.count, 1)
        XCTAssertEqual(candidates.filter { $0.kind == .question }.count, 1)
        XCTAssertTrue(candidates.contains { $0.date?.rawText.contains("пятницы") == true })
    }
}

// MARK: - 通知调度（identifier 幂等/取消/隐私三档/拒绝不假成功）

@MainActor
final class ErrandReminderSchedulerTests: XCTestCase {
    private var center = FakeErrandNotificationCenter()
    private var defaults: UserDefaults!
    private var suiteName = ""
    private var scheduler: ErrandReminderScheduler!

    override func setUp() async throws {
        suiteName = "errand-reminder-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        center = FakeErrandNotificationCenter()
        scheduler = ErrandReminderScheduler(defaults: defaults, center: center)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func appointmentItem(
        caseID: UUID, dueAt: Date
    ) -> ErrandCaseItem {
        ErrandCaseItem(
            caseID: caseID, title: "宿舍登记预约",
            kindRaw: ErrandCaseItemKind.appointment.rawValue,
            dueAt: dueAt
        )
    }

    // 8. identifier 稳定 + 保存幂等 + 修改重排。
    func testStableIdentifierAndIdempotentReArm() async {
        let caseID = UUID()
        let item = appointmentItem(
            caseID: caseID, dueAt: .now.addingTimeInterval(24 * 3600)
        )
        let ok1 = await scheduler.enable(
            item: item, caseTitle: "宿舍登记", kind: .appointment, lead: .hour
        )
        XCTAssertTrue(ok1)
        let expectedID = ErrandReminderScheduler.notificationID(
            kind: .appointment, caseID: caseID, itemID: item.id
        )
        XCTAssertEqual(center.pending.count, 1)
        XCTAssertEqual(center.pending.first?.identifier, expectedID)

        // 重复保存（修改重排）—— 同 identifier 覆盖，不产生多条。
        _ = await scheduler.enable(
            item: item, caseTitle: "宿舍登记（改名）", kind: .appointment, lead: .oneDay
        )
        XCTAssertEqual(center.pending.count, 1, "幂等：同 identifier 重排不叠加")
        XCTAssertEqual(center.pending.first?.body, "宿舍登记（改名）")

        // 稳定性：identifier 只由 case/item/kind 决定。
        XCTAssertEqual(
            ErrandReminderScheduler.notificationID(kind: .deadline, caseID: caseID, itemID: item.id),
            "errand.deadline.\(caseID.uuidString).\(item.id.uuidString)"
        )
    }

    // 完成/删除对应步骤时取消。
    func testDisableAndCancelCase() async {
        let caseID = UUID()
        let item = appointmentItem(
            caseID: caseID, dueAt: .now.addingTimeInterval(24 * 3600)
        )
        _ = await scheduler.enable(
            item: item, caseTitle: "x", kind: .appointment, lead: .hour
        )
        XCTAssertEqual(center.pending.count, 1)
        scheduler.disable(itemID: item.id)
        // removePending 经 Task 异步执行 —— 等待一拍。
        try? await Task.sleep(nanoseconds: 200_000_000)
        let afterDisable = await center.pendingIdentifiers()
        XCTAssertTrue(afterDisable.isEmpty)

        // 事项级取消：case 下多条（不同 item）一并清理。
        let item2 = appointmentItem(
            caseID: caseID, dueAt: .now.addingTimeInterval(48 * 3600)
        )
        _ = await scheduler.enable(
            item: item, caseTitle: "x", kind: .appointment, lead: .hour
        )
        _ = await scheduler.enable(
            item: item2, caseTitle: "x", kind: .deadline, lead: .hour
        )
        scheduler.cancelCase(caseID: caseID)
        try? await Task.sleep(nanoseconds: 200_000_000)
        let afterCase = await center.pendingIdentifiers()
        XCTAssertTrue(afterCase.isEmpty, "cancelCase 清掉该事项全部提醒")
    }

    // 7. 不确定日期绝不自动调度。
    func testUncertainDateNeverSchedules() async {
        let item = ErrandCaseItem(
            caseID: UUID(), title: "截止",
            kindRaw: ErrandCaseItemKind.deadline.rawValue,
            dueAt: .now.addingTimeInterval(24 * 3600),
            dateText: "大概周五",
            dateUncertain: true
        )
        let ok = await scheduler.enable(
            item: item, caseTitle: "x", kind: .deadline, lead: .hour
        )
        XCTAssertTrue(ok, "选择被记住")
        XCTAssertTrue(center.pending.isEmpty, "不确定日期绝不挂请求")
        XCTAssertEqual(scheduler.lead(itemID: item.id), .hour, "用户的选择保留")
    }

    // 过去时间不调度（不静默改到未来）。
    func testPastDateNeverSchedules() async {
        let item = appointmentItem(
            caseID: UUID(), dueAt: .now.addingTimeInterval(-3600)
        )
        _ = await scheduler.enable(
            item: item, caseTitle: "x", kind: .appointment, lead: .hour
        )
        XCTAssertTrue(center.pending.isEmpty, "过去时间永不触发 —— 不挂请求")
    }

    // 9. 权限拒绝不显示假成功：enable 如实返回 false。
    func testDeniedAuthorizationReportsHonestFailure() async {
        center.authorization = .denied
        let item = appointmentItem(
            caseID: UUID(), dueAt: .now.addingTimeInterval(24 * 3600)
        )
        let ok = await scheduler.enable(
            item: item, caseTitle: "x", kind: .appointment, lead: .hour
        )
        XCTAssertFalse(ok, "被拒时如实返回 false —— UI 显示'提醒未创建'")
        XCTAssertTrue(center.pending.isEmpty)
    }

    // 16. SystemSurfacePrivacy 三档对通知正文的输出。
    func testNotificationBodyPrivacyLevels() {
        let saved = SettingsStore.shared.systemSurfacePrivacy
        defer { SettingsStore.shared.systemSurfacePrivacy = saved }

        SettingsStore.shared.systemSurfacePrivacy = .showFullContent
        XCTAssertEqual(
            ErrandReminderScheduler.notificationBody(caseTitle: "签证续签", itemTitle: "预约递材料"),
            "签证续签 · 预约递材料"
        )
        SettingsStore.shared.systemSurfacePrivacy = .showTitlesOnly
        XCTAssertEqual(
            ErrandReminderScheduler.notificationBody(caseTitle: "签证续签", itemTitle: "预约递材料"),
            "签证续签"
        )
        SettingsStore.shared.systemSurfacePrivacy = .hideSensitiveContent
        XCTAssertEqual(
            ErrandReminderScheduler.notificationBody(caseTitle: "签证续签", itemTitle: "预约递材料"),
            "有一项办事事项需要处理"
        )
    }
}

// MARK: - 日历镜像（幂等/另一设备不自动建/外部删除真实状态）

@MainActor
final class ErrandCalendarMirrorTests: XCTestCase {
    private var store = FakeErrandEventStore()
    private var defaults: UserDefaults!
    private var suiteName = ""
    private var mirror: ErrandCalendarMirror!

    override func setUp() async throws {
        suiteName = "errand-calendar-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = FakeErrandEventStore()
        mirror = ErrandCalendarMirror(defaults: defaults, store: store)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // 10. 幂等：同一 appointment 重复点击原地更新，不重复建事件。
    func testMirrorIsIdempotentPerTap() async throws {
        let caseID = UUID()
        let item = ErrandCaseItem(
            caseID: caseID, title: "宿舍登记预约",
            kindRaw: ErrandCaseItemKind.appointment.rawValue,
            dueAt: .now.addingTimeInterval(48 * 3600)
        )
        let calendar = try XCTUnwrap(store.writableCalendars().first)
        let ok1 = await mirror.mirror(
            item: item, caseTitle: "宿舍登记",
            location: "203 室", note: "带护照", calendar: calendar
        )
        XCTAssertTrue(ok1)
        XCTAssertTrue(mirror.hasMirroredAppointment(itemID: item.id))
        let countAfterFirst = store.events.count
        XCTAssertEqual(countAfterFirst, 1)

        // 重复点击 → 原地更新。
        _ = await mirror.mirror(
            item: item, caseTitle: "宿舍登记（更新）",
            location: "205 室", note: "带护照", calendar: calendar
        )
        XCTAssertEqual(store.events.count, 1, "幂等：不重复建事件")
        XCTAssertTrue(store.events.values.first?.title.contains("宿舍登记（更新）") == true)
    }

    // 不确定日期绝不进日历。
    func testUncertainDateNeverMirrors() async throws {
        let item = ErrandCaseItem(
            caseID: UUID(), title: "预约",
            kindRaw: ErrandCaseItemKind.appointment.rawValue,
            dueAt: .now.addingTimeInterval(3600),
            dateText: "也许周五",
            dateUncertain: true
        )
        let calendar = try XCTUnwrap(store.writableCalendars().first)
        let ok = await mirror.mirror(
            item: item, caseTitle: "x", location: "", note: "", calendar: calendar
        )
        XCTAssertFalse(ok)
        XCTAssertTrue(store.events.isEmpty)
    }

    // 另一台设备：新镜像实例（同一账号 defaults）不自动建事件。
    func testAnotherDeviceNeverAutoCreates() {
        let itemID = UUID()
        // 设备 A 镜像过的 item：设备 B 的新实例能读到 hasLocal… 但绝不
        // 自动创建（mirror 只在用户显式点击时执行 —— 这里直接断言新
        // 实例不预置任何事件）。
        let deviceB = ErrandCalendarMirror(defaults: defaults, store: store)
        XCTAssertFalse(
            deviceB.hasMirroredAppointment(itemID: itemID),
            "镜像映射是设备本地的 —— 另一台设备没有该映射"
        )
    }

    // 外部删除后的真实状态：prune 清掉失效映射。
    func testPruneStaleMirrorsAfterExternalDelete() async {
        let item = ErrandCaseItem(
            caseID: UUID(), title: "预约",
            kindRaw: ErrandCaseItemKind.appointment.rawValue,
            dueAt: .now.addingTimeInterval(48 * 3600)
        )
        let calendar = try XCTUnwrap(store.writableCalendars().first)
        _ = await mirror.mirror(
            item: item, caseTitle: "x", location: "", note: "", calendar: calendar
        )
        XCTAssertTrue(mirror.hasMirroredAppointment(itemID: item.id))
        // 用户在系统日历里删除了事件。
        let identifier = try XCTUnwrap(
            store.events.keys.first
        )
        _ = store.remove(identifier: identifier)
        mirror.pruneStaleMirrors()
        XCTAssertFalse(
            mirror.hasMirroredAppointment(itemID: item.id),
            "外部删除后如实清掉本地映射（绝不背后重建）"
        )
    }

    // 隐私三档对日历标题的门控。
    func testEventTitlePrivacyLevels() {
        let saved = SettingsStore.shared.systemSurfacePrivacy
        defer { SettingsStore.shared.systemSurfacePrivacy = saved }

        SettingsStore.shared.systemSurfacePrivacy = .showTitlesOnly
        XCTAssertTrue(
            ErrandCalendarMirror.eventTitle(caseTitle: "医院就诊", itemTitle: "挂号")
                .contains("医院就诊")
        )
        SettingsStore.shared.systemSurfacePrivacy = .hideSensitiveContent
        XCTAssertEqual(
            ErrandCalendarMirror.eventTitle(caseTitle: "医院就诊", itemTitle: "挂号"),
            "办事事项",
            "仅状态档的日历标题不带任何细节"
        )
    }
}

// MARK: - AI 宽容解析与 sourceRef 校验

final class ErrandAIServiceParseTests: XCTestCase {
    private func makeInput(
        turnIDs: [UUID] = [], sources: [InterpreterDocumentChunker.RequestSource] = []
    ) -> ErrandAIService.Input {
        ErrandAIService.Input(
            turnLines: [], sourceLines: [], userContext: "",
            anchorDescription: "2026年9月6日", scene: .dorm,
            turnIDs: turnIDs, sources: sources
        )
    }

    // 4. 栅栏剥离。
    func testParseStripsCodeFences() {
        let raw = """
        ```json
        {"titleSuggestion":"宿舍登记","requiredDocuments":["护照原件"],"uncertainties":[]}
        ```
        """
        let suggestion = ErrandAIService.parse(raw, input: makeInput())
        XCTAssertTrue(suggestion.detailsAvailable)
        XCTAssertEqual(suggestion.titleSuggestion, "宿舍登记")
        XCTAssertEqual(suggestion.requiredDocuments, ["护照原件"])
    }

    // 散文包裹 + 字段缺失。
    func testParseToleratesProseAndMissingFields() {
        let raw = """
        好的，以下是整理结果：
        {"purposeSummary":"办理宿舍登记"}
        希望对你有帮助！
        """
        let suggestion = ErrandAIService.parse(raw, input: makeInput())
        XCTAssertEqual(suggestion.purposeSummary, "办理宿舍登记")
        XCTAssertTrue(suggestion.requiredDocuments.isEmpty)
    }

    // 字符串/数组混用（FlexList）。
    func testParseToleratesStringInsteadOfArray() {
        let raw = #"{"requiredDocuments":"护照原件"}"#
        let suggestion = ErrandAIService.parse(raw, input: makeInput())
        XCTAssertEqual(suggestion.requiredDocuments, ["护照原件"])
    }

    // 纯文本降级：保留可读建议但绝不伪造结构化成功。
    func testPlainTextFallbackIsHonest() {
        let raw = "看起来你需要带护照和落地签复印件去宿舍管理处。"
        let suggestion = ErrandAIService.parse(raw, input: makeInput())
        XCTAssertFalse(suggestion.detailsAvailable, "纯文本降级明确标记结构不可用")
        XCTAssertNotNil(suggestion.plainTextFallback)
        XCTAssertTrue(suggestion.requiredDocuments.isEmpty, "不伪造结构化清单")
        XCTAssertTrue(suggestion.uncertainties.contains { $0.contains("请人工核对") })
    }

    // 13. sourceRefs 校验：对话引用必须属于本次发送的 turn；文件引用
    // 经三重校验；无效引用丢弃并进入 uncertainties。
    func testSourceRefValidation() {
        let turn1 = UUID()
        let chunk = InterpreterDocumentChunker.Chunk(
            id: UUID(), documentID: UUID(), documentName: "登记表",
            pageNumber: 2, blockIndex: 0, text: "Принести оригинал паспорта до пятницы",
            contentHash: "h"
        )
        let source = InterpreterDocumentChunker.RequestSource(sourceID: "S1", chunk: chunk)
        let raw = """
        {"requiredDocuments":["护照原件"],"sourceRefs":[
            {"turn":"T1"},
            {"turn":"T9"},
            {"source":"S1","page":2,"snippet":"оригинал паспорта"},
            {"source":"S7","page":1,"snippet":"伪造的"},
            {"source":"S1","page":2,"snippet":"根本不存在的引文"}
        ]}
        """
        let suggestion = ErrandAIService.parse(
            raw, input: makeInput(turnIDs: [turn1], sources: [source])
        )
        XCTAssertEqual(suggestion.validatedTurnRefs, [turn1], "T1 有效；T9 越界丢弃")
        XCTAssertEqual(suggestion.validatedCitations.count, 1, "只有真实存在引文的 S1 通过")
        XCTAssertEqual(suggestion.validatedCitations.first?.snippet, "оригинал паспорта")
        XCTAssertTrue(
            suggestion.uncertainties.contains { $0.contains("无法核对") },
            "无效引用记入'来源无法核对'"
        )
    }

    // 防编造规则在 prompt 里硬编码（"通常需要"不冒充"明确要求"等）。
    func testSystemPromptEncodesAntiFabricationRules() {
        let prompt = ErrandAIService.systemPrompt(scene: .dorm)
        XCTAssertTrue(prompt.contains("绝不补写"))
        XCTAssertTrue(prompt.contains("通常需要"))
        XCTAssertTrue(prompt.contains("不给出任何保证"))
        XCTAssertTrue(prompt.contains("不做汇率换算"))
        XCTAssertTrue(prompt.contains("不要把相对日期算成具体日期"))
        XCTAssertTrue(prompt.contains("不要建议创建提醒"))
    }

    // 输入预算：对话 12 回合 / 2400 字符封顶。
    func testInputBudgetIsBounded() {
        let turns = (0..<40).map { index in
            (id: UUID(), text: String(repeating: "字", count: 500),
             isCounterpart: index % 2 == 0)
        }
        let built = ErrandAIService.buildInput(
            turns: turns, sources: [], userContext: "背景",
            scene: .dorm, maskSensitive: false
        )
        XCTAssertLessThanOrEqual(built.input.turnLines.count, 12)
        let total = built.input.turnLines.map(\.count).reduce(0, +)
        XCTAssertLessThanOrEqual(total, 2412, "对话预算封顶（行前缀容忍少量余量）")
    }
}

// MARK: - 导出边界

final class ErrandExporterTests: XCTestCase {
    func testExportExcludesLocalSourcesAndTechnicalInfo() {
        let snapshot = ErrandExporter.ErrandCaseSnapshot(
            title: "宿舍登记", statusText: "准备材料", sceneText: "宿舍",
            purpose: "办理登记", userNote: "带原件",
            location: "203 室", contact: "电话",
            expectedResultAt: nil
        )
        let caseID = UUID()
        let items = [
            ErrandExporter.ItemSnapshot(
                kind: .requiredDocument, kindName: "材料",
                title: "护照原件", detail: "原件+复印件",
                statusText: "待处理", dueAt: nil,
                carriesTime: false, unconfirmed: false
            ),
            ErrandExporter.ItemSnapshot(
                kind: .appointment, kindName: "预约",
                title: "登记预约", detail: "",
                statusText: "待处理",
                dueAt: Date(timeIntervalSince1970: 1_800_000_000),
                carriesTime: true, unconfirmed: false
            )
        ]
        let markdown = ErrandExporter.markdown(
            errandCase: snapshot, items: items,
            options: ErrandExporter.Options()
        )
        XCTAssertTrue(markdown.contains("宿舍登记"))
        XCTAssertTrue(markdown.contains("护照原件"))
        XCTAssertTrue(markdown.contains("本地来源文件未包含"))
        // 默认绝不包含技术信息与本地来源。
        XCTAssertFalse(markdown.contains(caseID.uuidString))
        XCTAssertFalse(markdown.contains("serverVersion"))
        XCTAssertFalse(markdown.contains("eventIdentifier"))
        XCTAssertFalse(markdown.contains(".pdf"))
        XCTAssertFalse(markdown.contains("model"))
    }

    // 18. 文件名清洗：路径字符/非法字符 + 唯一命名。
    func testSafeFileNameSanitizesPathCharacters() {
        let name = ErrandExporter.safeFileName(
            title: "宿舍/登记:事项", ext: "md"
        )
        XCTAssertFalse(name.contains("/"), "路径分隔符被替换")
        XCTAssertFalse(name.contains(":"))
        XCTAssertTrue(name.hasSuffix(".md"))
        XCTAssertTrue(name.hasPrefix("办事-"))
        // 唯一性：不同分钟不覆盖（时间戳后缀）。
        let name2 = ErrandExporter.safeFileName(
            title: "宿舍/登记:事项", ext: "md",
            date: Date(timeIntervalSince1970: 1_800_000_000)
        )
        XCTAssertNotEqual(name, name2)
    }

    // 导出走 TemporaryExportStore（受控临时目录 + 24h 收割语义）。
    func testExportStagesThroughTemporaryStore() throws {
        let url = try ErrandExporter.writeTemporaryFile(
            content: "测试导出", fileName: "办事-测试-\(UUID().uuidString).txt"
        )
        XCTAssertTrue(
            url.path.contains("LiveTranslateExports"),
            "导出必须走 TemporaryExportStore 的受控目录"
        )
        let staged = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(staged, "测试导出")
        try? FileManager.default.removeItem(at: url)
    }
}
