import Foundation
import SwiftUI

/// 随身翻译记录导出：双语 TXT 与 Markdown。导出内容包含时间、说话方、
/// 普通俄语、带重音俄语、中文翻译与用户主动选择的详细解释（关键词、
/// 备选表达）。绝不导出模型名、API 地址、文件路径或 Keychain 信息。
enum InterpreterExporter {
    /// 一个回合的导出投影（值类型，脱离 SwiftData 模型）。
    struct TurnExport: Sendable {
        var speaker: InterpreterSpeaker
        var direction: InterpreterDirection
        var sourceText: String
        var plainRussian: String
        var stressedRussian: String
        var chineseText: String
        var backTranslation: String
        var createdAt: Date
        var details: InterpreterTurnDetails?
    }

    struct ConversationExport: Sendable {
        var title: String
        var scene: InterpreterScene
        var startedAt: Date
        var turns: [TurnExport]
    }

    // MARK: - Render

    /// 双语 TXT。
    static func bilingualText(_ conversation: ConversationExport) -> String {
        var lines: [String] = []
        let header = "\(conversation.title) · \(conversation.scene.displayName)"
        lines.append(header)
        lines.append(String(repeating: "—", count: 24))
        for turn in conversation.turns {
            let time = Self.timeFormatter.string(from: turn.createdAt)
            lines.append("")
            lines.append("[\(time)] \(turn.speaker.displayName)")
            if turn.direction == .ru2zh {
                if !turn.plainRussian.isEmpty {
                    lines.append("RU: \(turn.plainRussian)")
                }
                if !turn.chineseText.isEmpty {
                    lines.append("中: \(turn.chineseText)")
                }
            } else {
                if !turn.chineseText.isEmpty {
                    lines.append("中: \(turn.chineseText)")
                }
                if !turn.plainRussian.isEmpty {
                    lines.append("RU: \(turn.plainRussian)")
                }
                if !turn.backTranslation.isEmpty {
                    lines.append("回译: \(turn.backTranslation)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Markdown（含用户主动选择的详细解释）。
    static func markdown(_ conversation: ConversationExport) -> String {
        var lines: [String] = []
        lines.append("# \(conversation.title)")
        lines.append("")
        lines.append("- 场景：\(conversation.scene.displayName)")
        lines.append("- 时间：\(Self.timeFormatter.string(from: conversation.startedAt))")
        lines.append("")
        for turn in conversation.turns {
            let time = Self.timeFormatter.string(from: turn.createdAt)
            lines.append("## \(turn.speaker.displayName)（\(time)）")
            lines.append("")
            if turn.direction == .ru2zh {
                if !turn.stressedRussian.isEmpty {
                    lines.append("> \(turn.stressedRussian)")
                    lines.append("")
                }
                if !turn.chineseText.isEmpty {
                    lines.append(turn.chineseText)
                    lines.append("")
                }
            } else {
                if !turn.chineseText.isEmpty {
                    lines.append("**\(turn.chineseText)**")
                    lines.append("")
                }
                if !turn.stressedRussian.isEmpty {
                    lines.append("> \(turn.stressedRussian)")
                    lines.append("")
                } else if !turn.plainRussian.isEmpty {
                    lines.append("> \(turn.plainRussian)")
                    lines.append("")
                }
                if !turn.backTranslation.isEmpty {
                    lines.append("回译：\(turn.backTranslation)")
                    lines.append("")
                }
            }
            if let details = turn.details, details.detailsAvailable {
                if let intent = details.intentSummary, !intent.isEmpty {
                    lines.append("- 意图：\(intent)")
                }
                if let keywords = details.keywords, !keywords.isEmpty {
                    lines.append("- 关键词：\(keywords.joined(separator: "、"))")
                }
                if let polite = details.politeAlternative, !polite.isEmpty {
                    lines.append("- 更礼貌：\(polite)")
                }
                if let simple = details.simpleAlternative, !simple.isEmpty {
                    lines.append("- 更简单：\(simple)")
                }
                if let uncertainties = details.uncertainties, !uncertainties.isEmpty {
                    lines.append("- 不确定项：\(uncertainties.joined(separator: "；"))")
                }
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - File

    /// 建议文件名："LiveTranslate-随身翻译-<title>-<yyyyMMdd-HHmm>.<ext>"。
    static func suggestedFileName(title: String, ext: String, date: Date = .now) -> String {
        let sanitized = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "LiveTranslate-随身翻译-\(sanitized)-\(formatter.string(from: date)).\(ext)"
    }

    /// 写临时文件供系统分享（TranscriptExporter 惯例）。
    static func writeTemporaryFile(content: String, fileName: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try content.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// 从 SwiftData 模型构建导出投影（主线程调用）。
    @MainActor
    static func export(
        conversation: InterpreterConversation,
        turns: [InterpreterTurn]
    ) -> ConversationExport {
        ConversationExport(
            title: conversation.title,
            scene: conversation.scene,
            startedAt: conversation.startedAt,
            turns: turns.map { turn in
                TurnExport(
                    speaker: turn.speaker,
                    direction: turn.direction,
                    sourceText: turn.sourceText,
                    plainRussian: turn.plainRussian,
                    stressedRussian: turn.stressedRussian,
                    chineseText: turn.chineseText,
                    backTranslation: turn.backTranslation,
                    createdAt: turn.createdAt,
                    details: turn.details
                )
            }
        )
    }
}
