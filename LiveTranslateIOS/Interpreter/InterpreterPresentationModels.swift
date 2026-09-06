import Foundation

// 随身翻译（Interpreter）纯展示模型 —— 第十九轮柜台办理重构。
//
// 本文件只做一件事：把持久化的 InterpreterTurn / ErrandCase 派生成排版
// 决策，让 SwiftUI View 不再从十几个可选字符串里猜布局。派生是纯函数：
// - 不导入 SwiftUI / SwiftData（依赖方向：View → 本模型 → 领域模型）；
// - 不写库、不进 outbox、不上传（展开/聚焦/跟随全是 UI 状态）；
// - 主次语言由说话角色决定：对方说俄语 → 中文翻译是第一视觉层级；
//   我用中文回复 → 普通俄语译文是第一视觉层级（也是 TTS 与"给对方
//   看"的唯一来源；带重音文本只用于学习核对，默认折叠）。

// MARK: - 回合排版

/// 回合主文本/次文本的语言（由角色 + 状态决定，不由视图猜）。
enum InterpreterTextLanguage: Equatable, Sendable {
    case chinese
    case russian
}

/// 翻译阶段（UI 视角）：落库 pending、请求进行中、完成、失败。
/// 取消（CancellationError）从不落库也不进 UI —— 这里没有 cancelled 态。
enum InterpreterTurnPhase: Equatable, Sendable {
    case pending
    case translating
    case completed
    case failed
}

/// 一个回合在时间线中的层级（当前聚焦 / 最近 / 历史）。
enum InterpreterTimelineEmphasis: Equatable, Sendable {
    case current
    case recent
    case history
}

/// 回合高频动作（折叠态直接可见）与低频动作（overflow 菜单）。
/// 纯枚举：View 负责映射成按钮，这里决定"哪些动作、什么顺序"。
enum InterpreterTurnAction: Equatable, Hashable, Sendable {
    case speakRussian
    case copyPrimary
    case presentToCounterpart
    case retryTranslation
    case editSource
    case deleteTurn
}

/// 一个回合的完整排版决策（从 InterpreterTurn 派生，纯函数）。
struct InterpreterTurnPresentation: Equatable, Sendable {
    let turnID: UUID
    /// 角色：对方（counterpart）或我（user）。
    let role: InterpreterSpeaker
    /// 主文本 —— 该回合当前状态下的第一视觉层级内容。
    let primaryText: String
    let primaryLanguage: InterpreterTextLanguage
    /// 次文本 —— 核对层（可为空串：pending/translating/failed 时无次文本）。
    let secondaryText: String
    let secondaryLanguage: InterpreterTextLanguage
    /// 次文本标签（例如"俄语原文""我的原意"；空串 = 不显示标签）。
    let secondaryLabel: String
    /// 是否有可用的带重音版本（校验通过的 stressedRussian）。
    let hasStressVariant: Bool
    let phase: InterpreterTurnPhase
    /// 用户编辑过原文（modifiedAt 非 nil —— 诚实标注，不伪装原始 ASR）。
    let isEdited: Bool
    /// 该回合引用了仅存本机的文件来源。
    let hasLocalSources: Bool
    /// 中文原意与回译是否信息不等价（不等价时展开区分列"我的原意 /
    /// 回译核对"；等价时回译不重复占位）。
    let backTranslationDiffers: Bool
    /// 折叠态高频动作（2~3 个 + 展开结构按钮由视图处理）。
    let primaryActions: [InterpreterTurnAction]
    /// 低频动作（overflow Menu：编辑原文 / 重新翻译 / 删除）。
    let overflowActions: [InterpreterTurnAction]
    /// 状态行文案（pending/translating/failed；completed 为 nil）。
    let statusText: String?
    /// 状态是否需要直接可见的重试入口（失败时 true）。
    let showsRetryInline: Bool
    /// 复制动作使用的文本（主文本；空时回退原文）。
    let copyText: String
    /// 朗读文本（普通俄语；无俄语时为 nil —— 绝不朗读带重音文本）。
    let speakText: String?
    /// 给对方看锁定的俄语（普通俄语；仅我的回合且已生成）。
    let presentableRussian: String?
    /// VoiceOver 摘要：角色与状态 → 主译文 → 原文。
    let accessibilitySummary: String

    /// 派生入口 —— 唯一的主/次文本决策点。
    ///
    /// | 回合 | 主文本 | 次文本 |
    /// | --- | --- | --- |
    /// | 对方俄语，翻译成功 | 中文翻译 | 俄语原文（设置开启时带重音） |
    /// | 对方俄语，翻译中 | 俄语原文 | （状态行：正在翻译） |
    /// | 对方俄语，翻译失败 | 俄语原文 | （状态行 + 内联重试） |
    /// | 我输入中文，生成成功 | 普通俄语译文 | 中文原意 |
    /// | 我输入中文，生成中 | 中文原文 | （状态行：正在生成俄语） |
    /// | 我输入中文，生成失败 | 中文原文 | （状态行 + 内联重试） |
    static func make(
        turn: InterpreterTurn,
        isTranslating: Bool,
        showStress: Bool
    ) -> InterpreterTurnPresentation {
        let phase = Self.phase(of: turn, isTranslating: isTranslating)
        let isCounterpart = turn.direction == .ru2zh
        let hasStress = !turn.stressedRussian.isEmpty
        let edited = turn.modifiedAt != nil

        // 主/次文本（按角色 + 阶段）。
        let primaryText: String
        let primaryLanguage: InterpreterTextLanguage
        let secondaryText: String
        let secondaryLanguage: InterpreterTextLanguage
        let secondaryLabel: String

        if isCounterpart {
            switch phase {
            case .completed:
                primaryText = turn.chineseText.isEmpty ? turn.sourceText : turn.chineseText
                primaryLanguage = turn.chineseText.isEmpty ? .russian : .chinese
                // 原文层：设置开启且有重音版本时显示带重音俄语（同层切换，
                // 不并列两大段）。
                secondaryText = (showStress && hasStress)
                    ? turn.stressedRussian
                    : turn.sourceText
                secondaryLanguage = .russian
                secondaryLabel = "俄语原文"
            default:
                // pending / translating / failed：俄语原文先稳定落位，
                // 绝不显示伪中文骨架。
                primaryText = turn.sourceText
                primaryLanguage = .russian
                secondaryText = ""
                secondaryLanguage = .russian
                secondaryLabel = ""
            }
        } else {
            // 我的回复。文件分析回合（有中文摘要、无俄语）读中文摘要。
            switch phase {
            case .completed where !turn.plainRussian.isEmpty:
                primaryText = turn.plainRussian
                primaryLanguage = .russian
                secondaryText = turn.sourceText
                secondaryLanguage = .chinese
                secondaryLabel = "我的原意"
            case .completed:
                // 文件分析回合：用户读的是中文摘要（无俄语可展示）。
                primaryText = turn.chineseText.isEmpty ? turn.sourceText : turn.chineseText
                primaryLanguage = .chinese
                secondaryText = turn.sourceText
                secondaryLanguage = .chinese
                secondaryLabel = "我的提问"
            default:
                primaryText = turn.sourceText
                primaryLanguage = .chinese
                secondaryText = ""
                secondaryLanguage = .chinese
                secondaryLabel = ""
            }
        }

        // 状态行。
        let statusText: String? = {
            switch phase {
            case .completed: return nil
            case .pending:
                return isCounterpart ? "等待翻译" : "等待生成俄语"
            case .translating:
                return isCounterpart ? "正在翻译…" : "正在生成俄语…"
            case .failed:
                return isCounterpart ? "翻译失败，原文已保留" : "生成失败，中文已保留"
            }
        }()

        // 高频 / 低频动作。
        var primaryActions: [InterpreterTurnAction] = []
        if phase == .completed {
            if !turn.plainRussian.isEmpty {
                primaryActions.append(.speakRussian)
            }
            primaryActions.append(.copyPrimary)
            if !isCounterpart && !turn.plainRussian.isEmpty {
                primaryActions.append(.presentToCounterpart)
            }
        } else if phase == .failed {
            // 失败：重试必须直接可见（不藏在展开区）。
            primaryActions.append(.retryTranslation)
        }
        var overflowActions: [InterpreterTurnAction] = []
        if phase == .completed || phase == .failed {
            overflowActions.append(contentsOf: [.editSource, .retryTranslation, .deleteTurn])
        }

        let copyText = primaryText.isEmpty ? turn.sourceText : primaryText
        let speakText = turn.plainRussian.isEmpty ? nil : turn.plainRussian
        let presentableRussian: String?
        if !isCounterpart, phase == .completed, !turn.plainRussian.isEmpty {
            presentableRussian = turn.plainRussian
        } else {
            presentableRussian = nil
        }

        // VoiceOver 摘要：角色与状态 → 主译文 → 原文（展开前不重复朗读
        // 重音版本）。
        var summaryParts: [String] = []
        summaryParts.append(turn.speaker.displayName)
        if edited { summaryParts.append("已编辑") }
        if let statusText {
            summaryParts.append(statusText)
        } else {
            summaryParts.append(primaryText)
            if !secondaryText.isEmpty {
                summaryParts.append(secondaryText)
            }
        }

        return InterpreterTurnPresentation(
            turnID: turn.id,
            role: turn.speaker,
            primaryText: primaryText,
            primaryLanguage: primaryLanguage,
            secondaryText: secondaryText,
            secondaryLanguage: secondaryLanguage,
            secondaryLabel: secondaryLabel,
            hasStressVariant: hasStress,
            phase: phase,
            isEdited: edited,
            hasLocalSources: !turn.localSourcesJSON.isEmpty
                || (turn.details?.hasLocalSources == true),
            backTranslationDiffers: Self.backTranslationDiffers(turn),
            primaryActions: primaryActions,
            overflowActions: overflowActions,
            statusText: statusText,
            showsRetryInline: phase == .failed,
            copyText: copyText,
            speakText: speakText,
            presentableRussian: presentableRussian,
            accessibilitySummary: summaryParts.joined(separator: "，")
        )
    }

    private static func phase(
        of turn: InterpreterTurn, isTranslating: Bool
    ) -> InterpreterTurnPhase {
        if isTranslating { return .translating }
        if turn.translationFailed { return .failed }
        if turn.translationCompleted { return .completed }
        return .pending
    }

    /// 中文原意与回译的信息等价判断：忽略首尾空白与常见终止标点
    /// （中英问号/叹号/句号/逗号）后比较。等价 → 回译不单独占位。
    private static func backTranslationDiffers(_ turn: InterpreterTurn) -> Bool {
        guard !turn.backTranslation.isEmpty, !turn.sourceText.isEmpty else { return false }
        return normalize(turn.backTranslation) != normalize(turn.sourceText)
    }

    private static func normalize(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let punctuation = CharacterSet(charactersIn: "。？！?!.,，、；;")
        return trimmed.trimmingCharacters(in: punctuation)
    }

    // MARK: - 展开区补充信息

    /// 展开态的补充信息行（默认折叠的核对内容）。
    struct SupplementRow: Equatable, Identifiable, Sendable {
        enum Value: Equatable, Sendable {
            case text(String)
            case list([String])
        }

        let id: String
        let title: String
        let value: Value
    }

    /// 展开区行（纯数据；本地文件来源块由视图从 turn.localSources 渲染，
    /// 因为它需要实时的 availableDocumentIDs 判断）。
    static func supplementRows(
        for turn: InterpreterTurn,
        presentation: InterpreterTurnPresentation
    ) -> [SupplementRow] {
        var rows: [SupplementRow] = []
        if turn.direction == .zh2ru {
            if !turn.plainRussian.isEmpty {
                rows.append(SupplementRow(
                    id: "plain", title: "普通俄语", value: .text(turn.plainRussian)
                ))
            }
            if !turn.stressedRussian.isEmpty {
                rows.append(SupplementRow(
                    id: "stressed", title: "带重音俄语", value: .text(turn.stressedRussian)
                ))
            } else {
                rows.append(SupplementRow(
                    id: "stressed", title: "带重音俄语", value: .text("暂未生成重音标注")
                ))
            }
            if presentation.backTranslationDiffers {
                rows.append(SupplementRow(
                    id: "back", title: "回译核对", value: .text(turn.backTranslation)
                ))
            }
        } else {
            if !turn.stressedRussian.isEmpty {
                rows.append(SupplementRow(
                    id: "stressed", title: "带重音俄语", value: .text(turn.stressedRussian)
                ))
            }
        }
        if let details = turn.details {
            if !details.detailsAvailable {
                rows.append(SupplementRow(
                    id: "plain-only",
                    title: "详细解释",
                    value: .text("本次为纯文本翻译，详细解释不可用")
                ))
            }
            if let intent = details.intentSummary, !intent.isEmpty {
                rows.append(SupplementRow(
                    id: "intent", title: "意图", value: .text(intent)
                ))
            }
            if let keywords = details.keywords, !keywords.isEmpty {
                rows.append(SupplementRow(
                    id: "keywords", title: "关键词", value: .list(keywords)
                ))
            }
            if let ambiguity = details.ambiguity, !ambiguity.isEmpty {
                rows.append(SupplementRow(
                    id: "ambiguity", title: "歧义", value: .text(ambiguity)
                ))
            }
            if let polite = details.politeAlternative, !polite.isEmpty {
                rows.append(SupplementRow(
                    id: "polite", title: "更礼貌的表达", value: .text(polite)
                ))
            }
            if let simple = details.simpleAlternative, !simple.isEmpty {
                rows.append(SupplementRow(
                    id: "simple", title: "更简单的表达", value: .text(simple)
                ))
            }
            if let uncertainties = details.uncertainties, !uncertainties.isEmpty {
                rows.append(SupplementRow(
                    id: "uncertainties", title: "不确定项", value: .list(uncertainties)
                ))
            }
        }
        return rows
    }
}

// MARK: - 时间线层级

/// 时间线层级分配（纯函数：距最新回合的距离决定，不依赖几何测量）。
enum InterpreterTimelineLayout {
    /// 当前聚焦 = 最新回合；其前 2 个为 recent；更早为 history。
    static func emphasis(
        forTurnAt index: Int, totalCount: Int
    ) -> InterpreterTimelineEmphasis {
        guard totalCount > 0, index >= 0, index < totalCount else { return .history }
        let distance = totalCount - 1 - index
        switch distance {
        case 0: return .current
        case 1, 2: return .recent
        default: return .history
        }
    }

    /// 删除聚焦（最新）回合后的新聚焦：新的最新回合（无回合 → nil）。
    static func focusNeighbor(afterDeletionIn turns: [InterpreterTurn]) -> UUID? {
        turns.last?.id
    }
}

// MARK: - 自动跟随状态机

/// 时间线滚动跟随状态机（纯 UI 状态 —— 绝不写库、绝不进 outbox）。
///
/// 规则：
/// - 用户位于底部附近 → 跟随；新回合与完成翻译自动滚到底；
/// - 用户主动上滚回看 → 暂停跟随；新回合只累计未读，不拉回底部；
/// - 点击"回到最新" → 恢复跟随并清零未读。
struct InterpreterFollowState: Equatable, Sendable {
    var isFollowing = true
    var unreadCount = 0

    /// 滚动位置探测回调（带滞回：只在跨越阈值时翻转，防抖动）。
    mutating func userScrolled(nearBottom: Bool) {
        if nearBottom {
            isFollowing = true
            unreadCount = 0
        } else {
            isFollowing = false
        }
    }

    /// 新回合落定（final 落库）。跟随中由视图滚动；回看中只计未读。
    mutating func turnLanded() {
        if !isFollowing {
            unreadCount += 1
        }
    }

    /// 用户点击"回到最新"。
    mutating func resumeFollowing() {
        isFollowing = true
        unreadCount = 0
    }
}

// MARK: - 办事上下文条

/// 从 ErrandCase 进入随身翻译时的轻量上下文（最多一到两行的状态条）。
/// 隐私：surfacePrivacy 为"仅状态"（hideSensitiveContent）时标题为
/// nil —— 状态条只显示通用标签与计数，不显示事项标题、文件名或问题。
struct InterpreterCounterContext: Equatable, Sendable {
    let caseID: UUID
    /// 受 SystemSurfacePrivacy 门控的事项标题（nil = 隐私档位隐藏）。
    let caseTitle: String?
    let scene: InterpreterScene
    let pendingQuestionCount: Int
    let pendingMaterialCount: Int
    let hasLocalDocuments: Bool

    /// 状态条标题（隐私隐藏时使用通用标签 —— 不泄露事项内容）。
    var displayTitle: String {
        if let caseTitle { return caseTitle }
        return "正在办理的事项"
    }

    static func make(
        errandCase: ErrandCase,
        items: [ErrandCaseItem],
        hasLocalDocuments: Bool,
        surfacePrivacy: SystemSurfacePrivacy
    ) -> InterpreterCounterContext {
        let pending = items.filter { $0.status == .pending }
        return InterpreterCounterContext(
            caseID: errandCase.id,
            caseTitle: surfacePrivacy.showsTitles ? errandCase.title : nil,
            scene: errandCase.scene,
            pendingQuestionCount: pending.filter { $0.kind == .question }.count,
            pendingMaterialCount: pending.filter { $0.kind == .requiredDocument }.count,
            hasLocalDocuments: hasLocalDocuments
        )
    }
}

// MARK: - 快捷回复

/// 快捷回复建议：本地静态短语（无模型完整可用）与同次 AI 建议（来自
/// 最近对方回合 details）在视觉上区分。
struct InterpreterQuickReply: Equatable, Identifiable, Sendable {
    enum Origin: Equatable, Sendable {
        case local
        case aiSuggestion
    }

    var id: String { text }
    let text: String
    let origin: Origin
}

/// 本地静态快捷短语目录（中文，经现有 zh→ru 真实翻译链生成俄语 ——
/// 绝不硬编码生产翻译结果；不含模型猜测的护照号、地址或费用）。
enum InterpreterQuickReplyCatalog {
    /// 办理文件场景的通用追问。
    static let documentPhrases: [String] = [
        "请问需要哪些材料？",
        "需要原件还是复印件？",
        "我应该在哪里签字？",
        "什么时候可以领取？",
        "还需要补交别的文件吗？",
        "可以写下来或在文件上指给我看吗？",
    ]

    static func localPhrases(for scene: InterpreterScene) -> [String] {
        switch scene {
        case .general, .school:
            return ["好的，我明白了", "请您再说慢一点"] + documentPhrases
        case .dorm:
            return ["好的，我明白了", "请您再说慢一点"] + documentPhrases
        case .bank:
            return ["好的，我明白了", "请您再说慢一点"] + documentPhrases
        case .hospital:
            return ["好的，我明白了", "请您再说慢一点", "请问需要预约吗？"] + documentPhrases
        case .migration, .telecom, .post:
            return ["好的，我明白了", "请您再说慢一点"] + documentPhrases
        }
    }

    /// 合并建议（AI 建议优先，本地补足；最多 limit 个）。
    static func merged(
        aiSuggestions: [String], scene: InterpreterScene, limit: Int = 3
    ) -> [InterpreterQuickReply] {
        var result: [InterpreterQuickReply] = []
        var seen = Set<String>()
        for suggestion in aiSuggestions where !suggestion.isEmpty {
            guard result.count < limit, !seen.contains(suggestion) else { continue }
            seen.insert(suggestion)
            result.append(InterpreterQuickReply(text: suggestion, origin: .aiSuggestion))
        }
        for phrase in localPhrases(for: scene) {
            guard result.count < limit, !seen.contains(phrase) else { continue }
            seen.insert(phrase)
            result.append(InterpreterQuickReply(text: phrase, origin: .local))
        }
        return result
    }
}
