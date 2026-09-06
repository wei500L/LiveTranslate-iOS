import XCTest
import SwiftData
@testable import LiveTranslateIOS

// 第十九轮 柜台办理重构测试：主/次语言排版决策（纯函数）、时间线层级、
// 自动跟随状态机、办事上下文隐私门控、快捷回复目录、Show Mode 锁定与
// 给对方看的普通俄语、文件 chip 移除不删文件、Demo 种子状态。
// 全部使用内存数据库与确定性虚构数据（绝不触网络/麦克风/真实服务）。

// MARK: - 排版决策（InterpreterTurnPresentation）

final class InterpreterPresentationTests: XCTestCase {
    private func counterpartTurn(
        status: InterpreterTurnTranslationStatus,
        chinese: String = "",
        stressed: String = ""
    ) -> InterpreterTurn {
        InterpreterTurn(
            conversationID: UUID(),
            speakerRaw: InterpreterSpeaker.counterpart.rawValue,
            directionRaw: InterpreterDirection.ru2zh.rawValue,
            inputMethodRaw: InterpreterInputMethod.audio.rawValue,
            sequence: 1,
            sourceText: "У вас есть копия паспорта?",
            plainRussian: "У вас есть копия паспорта?",
            stressedRussian: stressed,
            chineseText: chinese,
            translationStatusRaw: status.rawValue
        )
    }

    private func userTurn(
        status: InterpreterTurnTranslationStatus = .completed,
        russian: String = "Да, я записан на сегодня.",
        stressed: String = "",
        backTranslation: String = "",
        modifiedAt: Date? = nil
    ) -> InterpreterTurn {
        InterpreterTurn(
            conversationID: UUID(),
            speakerRaw: InterpreterSpeaker.user.rawValue,
            directionRaw: InterpreterDirection.zh2ru.rawValue,
            inputMethodRaw: InterpreterInputMethod.text.rawValue,
            sequence: 2,
            sourceText: "是的，我预约了今天。",
            plainRussian: russian,
            stressedRussian: stressed,
            chineseText: "是的，我预约了今天。",
            backTranslation: backTranslation,
            translationStatusRaw: status.rawValue,
            modifiedAt: modifiedAt
        )
    }

    // 1. 对方成功回合：中文为主、俄语为次。
    func testCounterpartCompletedChinesePrimaryRussianSecondary() {
        let turn = counterpartTurn(
            status: .completed,
            chinese: "您有护照复印件吗？"
        )
        let presentation = InterpreterTurnPresentation.make(
            turn: turn, isTranslating: false, showStress: false
        )
        XCTAssertEqual(presentation.primaryText, "您有护照复印件吗？")
        XCTAssertEqual(presentation.primaryLanguage, .chinese)
        XCTAssertEqual(presentation.secondaryText, "У вас есть копия паспорта?")
        XCTAssertEqual(presentation.secondaryLanguage, .russian)
        XCTAssertEqual(presentation.secondaryLabel, "俄语原文")
        XCTAssertNil(presentation.statusText)
    }

    // 2. 我的成功回合：普通俄语为主、中文原意为次。
    func testUserCompletedRussianPrimaryChineseSecondary() {
        let turn = userTurn(backTranslation: "是的，我预约了今天上午。")
        let presentation = InterpreterTurnPresentation.make(
            turn: turn, isTranslating: false, showStress: false
        )
        XCTAssertEqual(presentation.primaryText, "Да, я записан на сегодня.")
        XCTAssertEqual(presentation.primaryLanguage, .russian)
        XCTAssertEqual(presentation.secondaryText, "是的，我预约了今天。")
        XCTAssertEqual(presentation.secondaryLanguage, .chinese)
        XCTAssertEqual(presentation.secondaryLabel, "我的原意")
        // 给对方看 / 朗读 / 复制都使用普通俄语（绝不用带重音版本）。
        XCTAssertEqual(presentation.presentableRussian, "Да, я записан на сегодня.")
        XCTAssertEqual(presentation.speakText, "Да, я записан на сегодня.")
        XCTAssertEqual(presentation.copyText, "Да, я записан на сегодня.")
    }

    // 3. pending / translating / failed：原文先稳定落位，不显示伪骨架。
    func testPendingTranslatingFailedUseSourceAsPrimary() {
        for (status, translating) in [
            (InterpreterTurnTranslationStatus.pending, false),
            (InterpreterTurnTranslationStatus.pending, true),
            (InterpreterTurnTranslationStatus.failed, false),
        ] {
            let counterpart = counterpartTurn(status: status)
            let counterpartPresentation = InterpreterTurnPresentation.make(
                turn: counterpart, isTranslating: translating, showStress: false
            )
            XCTAssertEqual(counterpartPresentation.primaryText, "У вас есть копия паспорта?")
            XCTAssertEqual(counterpartPresentation.primaryLanguage, .russian)
            XCTAssertEqual(counterpartPresentation.secondaryText, "")
            XCTAssertNotNil(counterpartPresentation.statusText)

            let user = userTurn(status: status)
            let userPresentation = InterpreterTurnPresentation.make(
                turn: user, isTranslating: translating, showStress: false
            )
            XCTAssertEqual(userPresentation.primaryText, "是的，我预约了今天。")
            XCTAssertEqual(userPresentation.primaryLanguage, .chinese)
            XCTAssertEqual(userPresentation.secondaryText, "")
            XCTAssertNil(userPresentation.presentableRussian)
        }
    }

    // 4. 失败：重试直接可见。
    func testFailedShowsInlineRetry() {
        let turn = counterpartTurn(status: .failed)
        let presentation = InterpreterTurnPresentation.make(
            turn: turn, isTranslating: false, showStress: false
        )
        XCTAssertTrue(presentation.showsRetryInline)
        XCTAssertEqual(presentation.primaryActions, [.retryTranslation])
        XCTAssertEqual(presentation.phase, .failed)
    }

    // 5. 重音版本可用时不替换普通俄语主文本（我的回合）。
    func testStressVariantDoesNotReplacePlainPrimary() {
        let turn = userTurn(stressed: "Да, я запи́сан на сего́дня.")
        let presentation = InterpreterTurnPresentation.make(
            turn: turn, isTranslating: false, showStress: true
        )
        XCTAssertTrue(presentation.hasStressVariant)
        XCTAssertEqual(presentation.primaryText, "Да, я записан на сегодня.")
        XCTAssertEqual(presentation.presentableRussian, "Да, я записан на сегодня.")
    }

    // 对方回合 + showStress：原文层切换为带重音版本（同层，不并列两大段）。
    func testCounterpartShowStressSwapsSecondaryToStressed() {
        let stressed = "У вас есть ко́пия па́спорта?"
        let withoutStress = InterpreterTurnPresentation.make(
            turn: counterpartTurn(status: .completed, chinese: "您有护照复印件吗？"),
            isTranslating: false, showStress: false
        )
        XCTAssertEqual(withoutStress.secondaryText, "У вас есть копия паспорта?")

        let withStress = InterpreterTurnPresentation.make(
            turn: counterpartTurn(status: .completed, chinese: "您有护照复印件吗？", stressed: stressed),
            isTranslating: false, showStress: true
        )
        XCTAssertEqual(withStress.secondaryText, stressed)
        XCTAssertEqual(withStress.primaryText, "您有护照复印件吗？")
    }

    // 6. 等价回译不重复占位；不等价时区分"我的原意 / 回译核对"。
    func testEquivalentBackTranslationNotRepeated() {
        // 等价（仅标点差异）→ 回译不进入展开区。
        let equivalent = userTurn(backTranslation: "是的，我预约了今天。")
        let equivalentPresentation = InterpreterTurnPresentation.make(
            turn: equivalent, isTranslating: false, showStress: false
        )
        XCTAssertFalse(equivalentPresentation.backTranslationDiffers)
        let rows = InterpreterTurnPresentation.supplementRows(
            for: equivalent, presentation: equivalentPresentation
        )
        XCTAssertFalse(rows.contains { $0.title == "回译核对" })

        // 不等价 → 展开区出现"回译核对"。
        let differing = userTurn(backTranslation: "是的，我登记在今天上午。")
        let differingPresentation = InterpreterTurnPresentation.make(
            turn: differing, isTranslating: false, showStress: false
        )
        XCTAssertTrue(differingPresentation.backTranslationDiffers)
        let differingRows = InterpreterTurnPresentation.supplementRows(
            for: differing, presentation: differingPresentation
        )
        XCTAssertTrue(differingRows.contains { $0.title == "回译核对" })
    }

    // 7. 编辑过的回合标注"已编辑"（不伪装成原始 ASR）。
    func testEditedTurnMarked() {
        let edited = userTurn(modifiedAt: Date())
        let presentation = InterpreterTurnPresentation.make(
            turn: edited, isTranslating: false, showStress: false
        )
        XCTAssertTrue(presentation.isEdited)

        let original = userTurn()
        let originalPresentation = InterpreterTurnPresentation.make(
            turn: original, isTranslating: false, showStress: false
        )
        XCTAssertFalse(originalPresentation.isEdited)
    }

    // 8. 高频动作随角色和状态变化（折叠态 2~3 个）。
    func testPrimaryActionsByRoleAndPhase() {
        // 对方成功：播放 + 复制（无俄语译文时对方回合也可朗读原文）。
        let counterpart = InterpreterTurnPresentation.make(
            turn: counterpartTurn(status: .completed, chinese: "您有护照复印件吗？"),
            isTranslating: false, showStress: false
        )
        XCTAssertEqual(counterpart.primaryActions, [.speakRussian, .copyPrimary])

        // 我的成功：播放 + 复制 + 给对方看。
        let user = InterpreterTurnPresentation.make(
            turn: userTurn(), isTranslating: false, showStress: false
        )
        XCTAssertEqual(user.primaryActions, [.speakRussian, .copyPrimary, .presentToCounterpart])

        // 等待/翻译中：无高频动作（只有结构性的展开按钮）。
        let pending = InterpreterTurnPresentation.make(
            turn: counterpartTurn(status: .pending), isTranslating: false, showStress: false
        )
        XCTAssertTrue(pending.primaryActions.isEmpty)

        // 失败：重试可见。
        let failed = InterpreterTurnPresentation.make(
            turn: userTurn(status: .failed), isTranslating: false, showStress: false
        )
        XCTAssertEqual(failed.primaryActions, [.retryTranslation])
    }

    // 9. 低频动作进入 overflow（编辑/重译/删除）。
    func testOverflowActionsForCompletedTurns() {
        let completed = InterpreterTurnPresentation.make(
            turn: userTurn(), isTranslating: false, showStress: false
        )
        XCTAssertEqual(completed.overflowActions, [.editSource, .retryTranslation, .deleteTurn])

        let pending = InterpreterTurnPresentation.make(
            turn: counterpartTurn(status: .pending), isTranslating: false, showStress: false
        )
        XCTAssertTrue(pending.overflowActions.isEmpty)
    }

    // 10. 文件分析回合（有中文摘要、无俄语）：读中文摘要为主文本。
    func testDocumentAnalysisTurnReadsChineseSummary() {
        let turn = InterpreterTurn(
            conversationID: UUID(),
            speakerRaw: InterpreterSpeaker.user.rawValue,
            directionRaw: InterpreterDirection.zh2ru.rawValue,
            inputMethodRaw: InterpreterInputMethod.text.rawValue,
            sequence: 3,
            sourceText: "请解释文件：登记表",
            chineseText: "这是一份演示用的宿舍入住登记表。",
            translationStatusRaw: InterpreterTurnTranslationStatus.completed.rawValue
        )
        let presentation = InterpreterTurnPresentation.make(
            turn: turn, isTranslating: false, showStress: false
        )
        XCTAssertEqual(presentation.primaryText, "这是一份演示用的宿舍入住登记表。")
        XCTAssertEqual(presentation.primaryLanguage, .chinese)
        XCTAssertNil(presentation.presentableRussian)
    }

    // 11. VoiceOver 摘要：角色与状态 → 主译文 → 原文。
    func testAccessibilitySummaryOrdering() {
        let turn = counterpartTurn(status: .completed, chinese: "您有护照复印件吗？")
        let presentation = InterpreterTurnPresentation.make(
            turn: turn, isTranslating: false, showStress: false
        )
        XCTAssertEqual(
            presentation.accessibilitySummary,
            "对方说，您有护照复印件吗？，У вас есть копия паспорта?"
        )

        let failed = InterpreterTurnPresentation.make(
            turn: counterpartTurn(status: .failed), isTranslating: false, showStress: false
        )
        XCTAssertTrue(failed.accessibilitySummary.hasPrefix("对方说，翻译失败"))
    }
}

// MARK: - 时间线层级与跟随状态机

final class InterpreterTimelineLogicTests: XCTestCase {
    // 层级带：最新=current，前两个=recent，更早=history。
    func testTimelineEmphasisBands() {
        XCTAssertEqual(
            InterpreterTimelineLayout.emphasis(forTurnAt: 4, totalCount: 5), .current
        )
        XCTAssertEqual(
            InterpreterTimelineLayout.emphasis(forTurnAt: 3, totalCount: 5), .recent
        )
        XCTAssertEqual(
            InterpreterTimelineLayout.emphasis(forTurnAt: 2, totalCount: 5), .recent
        )
        XCTAssertEqual(
            InterpreterTimelineLayout.emphasis(forTurnAt: 1, totalCount: 5), .history
        )
        XCTAssertEqual(
            InterpreterTimelineLayout.emphasis(forTurnAt: 0, totalCount: 1), .current
        )
        XCTAssertEqual(
            InterpreterTimelineLayout.emphasis(forTurnAt: 0, totalCount: 0), .history
        )
    }

    // 删除聚焦（最新）回合 → 聚焦邻近（新的最新）回合。
    func testFocusNeighborAfterDeletion() {
        let conversationID = UUID()
        var turns: [InterpreterTurn] = []
        for sequence in 1...3 {
            turns.append(InterpreterTurn(
                conversationID: conversationID,
                speakerRaw: InterpreterSpeaker.counterpart.rawValue,
                directionRaw: InterpreterDirection.ru2zh.rawValue,
                inputMethodRaw: InterpreterInputMethod.audio.rawValue,
                sequence: sequence,
                sourceText: "Текст \(sequence)"
            ))
        }
        XCTAssertEqual(InterpreterTimelineLayout.focusNeighbor(afterDeletionIn: turns), turns[2].id)
        turns.removeLast()
        XCTAssertEqual(InterpreterTimelineLayout.focusNeighbor(afterDeletionIn: turns), turns[1].id)
        turns.removeAll()
        XCTAssertNil(InterpreterTimelineLayout.focusNeighbor(afterDeletionIn: turns))
    }

    // 自动跟随状态机：底部跟随 → 回看暂停 + 未读 → 回到最新恢复。
    func testFollowStateMachine() {
        var follow = InterpreterFollowState()
        // 初始：跟随。
        XCTAssertTrue(follow.isFollowing)
        XCTAssertEqual(follow.unreadCount, 0)

        // 底部 → 新回合落地：仍跟随、零未读（视图负责滚动）。
        follow.userScrolled(nearBottom: true)
        follow.turnLanded()
        XCTAssertTrue(follow.isFollowing)
        XCTAssertEqual(follow.unreadCount, 0)

        // 用户回看 → 暂停；新回合只计未读，不拉回底部。
        follow.userScrolled(nearBottom: false)
        XCTAssertFalse(follow.isFollowing)
        follow.turnLanded()
        follow.turnLanded()
        XCTAssertEqual(follow.unreadCount, 2)

        // 回到最新 → 恢复跟随并清零未读。
        follow.resumeFollowing()
        XCTAssertTrue(follow.isFollowing)
        XCTAssertEqual(follow.unreadCount, 0)

        // 再次贴底同样清零。
        follow.userScrolled(nearBottom: false)
        follow.turnLanded()
        XCTAssertEqual(follow.unreadCount, 1)
        follow.userScrolled(nearBottom: true)
        XCTAssertTrue(follow.isFollowing)
        XCTAssertEqual(follow.unreadCount, 0)
    }
}

// MARK: - 办事上下文与快捷回复（纯模型）

final class InterpreterCounterContextTests: XCTestCase {
    @MainActor
    private func makeCase() -> (ErrandCase, [ErrandCaseItem]) {
        let errandCase = ErrandCase(
            title: "宿舍入住登记",
            sceneRaw: InterpreterScene.dorm.rawValue,
            statusRaw: ErrandCaseStatus.preparing.rawValue
        )
        func item(
            _ title: String, kind: ErrandCaseItemKind,
            status: ErrandCaseItemStatus = .pending
        ) -> ErrandCaseItem {
            ErrandCaseItem(
                caseID: errandCase.id,
                title: title,
                kindRaw: kind.rawValue,
                statusRaw: status.rawValue,
                sequence: 0
            )
        }
        let items = [
            item("护照原件", kind: .requiredDocument),
            item("落地签复印件", kind: .requiredDocument),
            item("登记完成后多久能拿到门禁卡？", kind: .question),
            item("是否需要缴纳押金？", kind: .question),
            item("已备好的照片", kind: .requiredDocument, status: .done),
        ]
        return (errandCase, items)
    }

    // 隐私档位门控：仅状态时标题为 nil（通用标签），计数保留。
    func testPrivacyGating() {
        let (errandCase, items) = makeCase()
        let full = InterpreterCounterContext.make(
            errandCase: errandCase, items: items,
            hasLocalDocuments: true,
            surfacePrivacy: .showFullContent
        )
        XCTAssertEqual(full.caseTitle, "宿舍入住登记")
        XCTAssertEqual(full.displayTitle, "宿舍入住登记")
        XCTAssertEqual(full.pendingQuestionCount, 2)
        XCTAssertEqual(full.pendingMaterialCount, 2)  // 已完成不计
        XCTAssertTrue(full.hasLocalDocuments)
        XCTAssertEqual(full.scene, .dorm)

        let hidden = InterpreterCounterContext.make(
            errandCase: errandCase, items: items,
            hasLocalDocuments: false,
            surfacePrivacy: .hideSensitiveContent
        )
        XCTAssertNil(hidden.caseTitle)
        XCTAssertEqual(hidden.displayTitle, "正在办理的事项")
        XCTAssertEqual(hidden.pendingQuestionCount, 2)
        XCTAssertFalse(hidden.hasLocalDocuments)
    }

    // 快捷回复：AI 建议优先、本地短语补足、去重、上限。
    func testQuickReplyCatalogMerge() {
        let merged = InterpreterQuickReplyCatalog.merged(
            aiSuggestions: ["我明天带来复印件", "好的，我明白了"],
            scene: .dorm
        )
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged[0].origin, .aiSuggestion)
        XCTAssertEqual(merged[0].text, "我明天带来复印件")
        // "好的，我明白了" 同时在 AI 建议与本地目录 —— 去重。
        XCTAssertEqual(merged.filter { $0.text == "好的，我明白了" }.count, 1)
        XCTAssertFalse(merged.contains { $0.text == "请您再说慢一点" })

        // 无模型（无 AI 建议）：本地短语完整可用。
        let localOnly = InterpreterQuickReplyCatalog.merged(
            aiSuggestions: [], scene: .dorm
        )
        XCTAssertEqual(localOnly.count, 3)
        XCTAssertTrue(localOnly.allSatisfy { $0.origin == .local })
        // 办文件场景的通用追问在目录里。
        let catalog = InterpreterQuickReplyCatalog.localPhrases(for: .dorm)
        XCTAssertTrue(catalog.contains("需要原件还是复印件？"))
        XCTAssertTrue(catalog.contains("可以写下来或在文件上指给我看吗？"))
    }
}

// MARK: - ViewModel 行为（内存环境）

@MainActor
final class InterpreterCounterViewModelTests: XCTestCase {
    private var environment: AppEnvironment!
    private var repository: TranscriptRepository!
    private var container: ModelContainer!
    private var suiteName: String!

    override func setUp() async throws {
        let schema = AppEnvironment.librarySchema
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
        suiteName = "interpreter-counter-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let settings = SettingsStore(defaults: defaults)
        repository = TranscriptRepository(
            container: container,
            databaseURL: URL(fileURLWithPath: "/dev/null/nonexistent.sqlite")
        )
        let translationBox = TranslationServiceBox()
        translationBox.set(DemoTranslationService())
        environment = AppEnvironment(
            capabilities: AppEnvironment.Capabilities(
                requestsMicrophonePermission: false,
                assumesMicrophoneAuthorized: true
            ),
            modelContainer: container,
            settings: settings,
            engineManager: DemoEngineManager(),
            keychain: DemoKeychainStore(),
            repository: repository,
            modelManager: DemoModelManager(),
            benchmarkRunner: ASRBenchmarkRunner(
                engineManager: ASREngineManager(settings: settings)
            ),
            coordinator: DemoLiveCoordinator(),
            translationService: DemoTranslationService(),
            translationServiceBox: translationBox,
            bookmarks: BookmarkStore(defaults: defaults, repository: repository),
            cloudSync: nil
        )
    }

    override func tearDown() async throws {
        if let suiteName {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
    }

    private func seedDraftTurns(count: Int) throws -> InterpreterConversation {
        let draft = try repository.startInterpreterDraft(scene: .dorm, contextNote: "")
        for index in 0..<count {
            _ = try repository.addInterpreterCounterpartTurn(
                conversationID: draft.id,
                russian: "Фраза \(index)",
                inputMethod: .audio
            )
        }
        return draft
    }

    // Show Mode 锁定：新回合落地不替换展示内容。
    func testPresentedTurnLockSurvivesNewTurns() throws {
        _ = try seedDraftTurns(count: 2)
        let viewModel = InterpreterViewModel(environment: environment)
        await viewModel.reload()
        XCTAssertEqual(viewModel.turns.count, 2)

        // 锁定第一回合。
        let locked = viewModel.turns[0]
        viewModel.presentTurn(locked)
        XCTAssertEqual(viewModel.presentedTurnID, locked.id)

        // 新回合落定（真实链路：repository 落库 + reload）：锁定不替换。
        _ = try repository.addInterpreterCounterpartTurn(
            conversationID: viewModel.conversation!.id,
            russian: "Новая фраза", inputMethod: .audio
        )
        await viewModel.reload()
        XCTAssertEqual(viewModel.turns.count, 3)
        XCTAssertEqual(viewModel.presentedTurnID, locked.id)

        // 删除被锁定的回合 → 展示关闭（不展示错误内容）。
        viewModel.deleteTurn(locked)
        XCTAssertNil(viewModel.presentedTurnID)
    }

    // 快捷回复/待问问题：只填输入框，不自动翻译、不发送。
    func testApplySuggestionOnlyFillsDraft() throws {
        _ = try seedDraftTurns(count: 0)
        let viewModel = InterpreterViewModel(environment: environment)
        await viewModel.reload()
        viewModel.applySuggestion("请问需要哪些材料？")
        XCTAssertEqual(viewModel.replyDraft, "请问需要哪些材料？")
        XCTAssertTrue(viewModel.translatingTurnIDs.isEmpty)
        XCTAssertFalse(viewModel.isTranslatingReply)
        XCTAssertTrue(viewModel.turns.isEmpty)
    }

    // 删除聚焦回合 → 聚焦邻近回合。
    func testDeleteFocusedTurnFocusesNeighbor() throws {
        _ = try seedDraftTurns(count: 3)
        let viewModel = InterpreterViewModel(environment: environment)
        await viewModel.reload()
        XCTAssertEqual(viewModel.focusedTurnID, viewModel.turns[2].id)
        let deleted = viewModel.turns[2]
        viewModel.deleteTurn(deleted)
        XCTAssertEqual(viewModel.turns.count, 2)
        XCTAssertEqual(viewModel.focusedTurnID, viewModel.turns[1].id)
    }

    // 办事上下文：有 case 时建立；无 case 时不显示（不造空占位）。
    func testErrandContextAttachAndSceneInheritance() throws {
        let errandCase = try repository.startErrandCaseDraft(
            scene: .dorm, title: "宿舍入住登记"
        )
        _ = try repository.addErrandCaseItem(ErrandItemDraft(
            caseID: errandCase.id, title: "护照原件", kind: .requiredDocument
        ))
        _ = try repository.addErrandCaseItem(ErrandItemDraft(
            caseID: errandCase.id, title: "何时领门禁卡？", kind: .question
        ))

        let viewModel = InterpreterViewModel(environment: environment)
        viewModel.attachErrandContext(caseID: errandCase.id)
        await viewModel.reload()
        // 事项场景优先于全局默认（无草稿时）。
        XCTAssertEqual(viewModel.scene, .dorm)
        XCTAssertNotNil(viewModel.counterContext)
        XCTAssertEqual(viewModel.counterContext?.caseTitle, "宿舍入住登记")
        XCTAssertEqual(viewModel.counterContext?.pendingQuestionCount, 1)
        XCTAssertEqual(viewModel.counterContext?.pendingMaterialCount, 1)

        // hideSensitiveContent：标题隐藏，计数保留。
        environment.settings.systemSurfacePrivacy = .hideSensitiveContent
        viewModel.refreshCounterContext()
        XCTAssertNil(viewModel.counterContext?.caseTitle)
        XCTAssertEqual(viewModel.counterContext?.displayTitle, "正在办理的事项")
        XCTAssertEqual(viewModel.counterContext?.pendingQuestionCount, 1)

        // 无 case：上下文为 nil。
        let plainViewModel = InterpreterViewModel(environment: environment)
        plainViewModel.attachErrandContext(caseID: nil)
        await plainViewModel.reload()
        XCTAssertNil(plainViewModel.counterContext)
    }

    // 文件 chip 移除：只清除页面选择，不删除文件。
    func testClearDocumentContextSelectionKeepsDocuments() throws {
        let draft = try seedDraftTurns(count: 1)
        let viewModel = InterpreterViewModel(environment: environment)
        await viewModel.reload()
        // 直接插入一份就绪文件行（内存容器 —— 与 repository 同一 context）。
        let document = InterpreterDocument(
            conversationID: draft.id,
            sourceRaw: InterpreterDocumentSource.scan.rawValue,
            originalFileName: "登记表（演示）.pdf",
            formatRaw: InterpreterDocumentFormat.pdf.rawValue,
            mimeType: "application/pdf",
            pageCount: 1,
            statusRaw: InterpreterDocumentStatus.ready.rawValue
        )
        container.mainContext.insert(document)
        try container.mainContext.save()
        viewModel.documentContext?.reload(conversationID: draft.id)
        XCTAssertEqual(viewModel.documentContext?.documents.count, 1)

        viewModel.clearDocumentContextSelection()
        XCTAssertEqual(
            viewModel.documentContext?.selectedPages[document.id],
            Set<Int>()
        )
        // 原文件仍在。
        XCTAssertEqual(viewModel.documentContext?.documents.count, 1)
        XCTAssertEqual(viewModel.documentContext?.documents.first?.id, document.id)
    }

    // 翻译服务配置状态如实（状态栏用）。
    func testModelConfiguredHonesty() {
        let viewModel = InterpreterViewModel(environment: environment)
        // 空的 studyServiceBox（默认）→ 未配置。
        XCTAssertFalse(viewModel.isModelConfigured)
    }
}

// MARK: - Demo 种子（Debug 构建）

@MainActor
final class InterpreterCounterDemoSeedTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let schema = AppEnvironment.librarySchema
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    // 完整对话种子：草稿可被恢复，覆盖成功/等待/失败/长文本/双方回合。
    func testCounterDemoSeedFullConversation() throws {
        let container = try makeContainer()
        DemoSeed.populateInterpreterCounterDemo(container: container, state: nil)
        let context = ModelContext(container)
        let drafts = try context.fetch(FetchDescriptor<InterpreterConversation>())
            .filter { $0.status == .draft }
        XCTAssertEqual(drafts.count, 1)
        let draft = drafts[0]
        XCTAssertEqual(draft.scene, .dorm)

        let turns = try context.fetch(FetchDescriptor<InterpreterTurn>())
            .filter { $0.conversationID == draft.id }
        XCTAssertEqual(turns.count, 7)
        // 各状态齐备。
        XCTAssertTrue(turns.contains { $0.translationFailed })
        XCTAssertTrue(turns.contains { $0.translationStatusRaw == "pending" })
        XCTAssertTrue(turns.contains { $0.directionRaw == "zh2ru" && !$0.plainRussian.isEmpty })
        XCTAssertTrue(turns.contains { $0.chineseText.count > 40 })  // 长文本
        // 成功回合带重音。
        XCTAssertTrue(turns.contains { !$0.stressedRussian.isEmpty })
    }

    // failure 状态：只有失败/等待回合（首屏即见重试）。
    func testCounterDemoSeedFailureState() throws {
        let container = try makeContainer()
        DemoSeed.populateInterpreterCounterDemo(container: container, state: "failure")
        let context = ModelContext(container)
        let turns = try context.fetch(FetchDescriptor<InterpreterTurn>())
        XCTAssertEqual(turns.count, 3)
        XCTAssertTrue(turns.allSatisfy {
            $0.translationFailed || $0.translationStatusRaw == "pending"
        })
    }

    // longtext 状态：只有超长回合。
    func testCounterDemoSeedLongTextState() throws {
        let container = try makeContainer()
        DemoSeed.populateInterpreterCounterDemo(container: container, state: "longtext")
        let context = ModelContext(container)
        let turns = try context.fetch(FetchDescriptor<InterpreterTurn>())
        XCTAssertEqual(turns.count, 2)
        XCTAssertTrue(turns.allSatisfy { $0.sourceText.count > 50 })
    }
}
