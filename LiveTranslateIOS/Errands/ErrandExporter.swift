import Foundation

/// 办事事项导出（TXT/Markdown，走系统分享 + TemporaryExportStore）。
///
/// 默认包含：标题/状态/场景、用户确认的目的、清单及完成状态、已确认
/// 预约/截止/跟进/地点/费用/联系方式、用户备注、"本地来源文件未包含"。
/// 默认绝不包含：文件名、路径、页码、citation/snippet、OCR、对话全文、
/// AI 模型名/endpoint/Key/台账、notification identifier、eventIdentifier、
/// serverVersion、UUID。
enum ErrandExporter {
    struct Options: Sendable, Equatable {
        /// 是否附对话摘录（必须逐条选择 + 预览 + 敏感遮盖 —— 不能一个
        /// 模糊开关导出整段历史）。
        var includeConversationExcerpts: Bool = false
        var format: Format = .markdown
        enum Format: String, Sendable, CaseIterable {
            case markdown = "Markdown"
            case plainText = "TXT"
        }
    }

    struct TurnExcerpt: Sendable, Equatable, Identifiable {
        var id: UUID
        var text: String
        var isCounterpart: Bool
    }

    // MARK: - 文本生成

    static func markdown(
        errandCase: ErrandCaseSnapshot,
        items: [ItemSnapshot],
        options: Options,
        excerpts: [TurnExcerpt] = []
    ) -> String {
        var lines: [String] = []
        lines.append("# \(errandCase.title)")
        lines.append("")
        lines.append("- 状态：\(errandCase.statusText)")
        lines.append("- 场景：\(errandCase.sceneText)")
        if !errandCase.purpose.isEmpty {
            lines.append("- 目的：\(errandCase.purpose)")
        }
        if !errandCase.location.isEmpty {
            lines.append("- 地点：\(errandCase.location)")
        }
        if !errandCase.contact.isEmpty {
            lines.append("- 联系方式：\(errandCase.contact)")
        }
        if let expected = errandCase.expectedResultAt {
            lines.append("- 预计结果：\(format(expected))")
        }
        lines.append("")

        func section(_ title: String, _ kind: ErrandCaseItemKind, symbol: String) {
            let rows = items.filter { $0.kind == kind && !$0.unconfirmed }
            guard !rows.isEmpty else { return }
            lines.append("## \(title)")
            for row in rows {
                let mark: String
                switch row.statusText {
                case "已完成": mark = "[x]"
                case "已跳过": mark = "[-]"
                default: mark = "[ ]"
                }
                var line = "- \(mark) \(row.title)"
                if !row.detail.isEmpty { line += "（\(row.detail)）" }
                if let dueAt = row.dueAt, row.carriesTime {
                    line += " · \(row.kindName) \(format(dueAt))"
                }
                lines.append(line)
            }
            lines.append("")
        }
        section("要带的材料", .requiredDocument, symbol: "")
        section("要完成的动作", .action, symbol: "")
        section("到现场要问的问题", .question, symbol: "")
        section("预约 · 截止 · 跟进", .appointment, symbol: "")
        section("费用", .payment, symbol: "")

        if !errandCase.userNote.isEmpty {
            lines.append("## 备注")
            lines.append(errandCase.userNote)
            lines.append("")
        }

        if options.includeConversationExcerpts, !excerpts.isEmpty {
            lines.append("## 对话摘录（用户逐条选择）")
            for excerpt in excerpts {
                lines.append("- \(excerpt.isCounterpart ? "对方" : "我")：\(excerpt.text)")
            }
            lines.append("")
        }

        lines.append("> 本地来源文件未包含在导出中（文件与引用仅保存在原设备）。")
        return lines.joined(separator: "\n")
    }

    static func plainText(
        errandCase: ErrandCaseSnapshot,
        items: [ItemSnapshot],
        options: Options,
        excerpts: [TurnExcerpt] = []
    ) -> String {
        // 同一结构的纯文本形态（Markdown 去掉标记）。
        let markdown = markdown(errandCase: errandCase, items: items, options: options, excerpts: excerpts)
        return markdown
            .replacingOccurrences(of: "# ", with: "")
            .replacingOccurrences(of: "## ", with: "")
            .replacingOccurrences(of: "- [x] ", with: "✓ ")
            .replacingOccurrences(of: "- [-] ", with: "- ")
            .replacingOccurrences(of: "- [ ] ", with: "□ ")
            .replacingOccurrences(of: "> ", with: "")
            .replacingOccurrences(of: "- ", with: "· ")
    }

    // MARK: - 文件落地（TemporaryExportStore，24 小时收割）

    /// 导出文件名清洗：去掉路径与非法字符（/ : 等），唯一命名不覆盖。
    static func safeFileName(title: String, ext: String, date: Date = .now) -> String {
        let cleaned = title
            .replacingOccurrences(of: "/", with: "／")
            .replacingOccurrences(of: ":", with: "：")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MMdd-HHmm"
        let stamp = formatter.string(from: date)
        let base = cleaned.isEmpty ? "办事事项" : String(cleaned.prefix(40))
        return "办事-\(base)-\(stamp).\(ext)"
    }

    @discardableResult
    static func writeTemporaryFile(content: String, fileName: String) throws -> URL {
        try TemporaryExportStore().stage(
            fileName: fileName, data: Data(content.utf8)
        )
    }

    private static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter.string(from: date)
    }

    // MARK: - 快照（Sendable 值类型 —— 导出与 UI 解耦）

    struct ErrandCaseSnapshot: Sendable, Equatable {
        var title: String
        var statusText: String
        var sceneText: String
        var purpose: String
        var userNote: String
        var location: String
        var contact: String
        var expectedResultAt: Date?
    }

    struct ItemSnapshot: Sendable, Equatable {
        var kind: ErrandCaseItemKind
        var kindName: String
        var title: String
        var detail: String
        var statusText: String
        var dueAt: Date?
        var carriesTime: Bool
        var unconfirmed: Bool
    }

    static func snapshot(_ errandCase: ErrandCase) -> ErrandCaseSnapshot {
        ErrandCaseSnapshot(
            title: errandCase.title,
            statusText: errandCase.status.displayName,
            sceneText: errandCase.scene.displayName,
            purpose: errandCase.purpose,
            userNote: errandCase.userNote,
            location: errandCase.location,
            contact: errandCase.contact,
            expectedResultAt: errandCase.expectedResultAt
        )
    }

    static func snapshot(_ item: ErrandCaseItem) -> ItemSnapshot {
        ItemSnapshot(
            kind: item.kind,
            kindName: item.kind.displayName,
            title: item.title,
            detail: item.detail,
            statusText: item.status.displayName,
            dueAt: item.dueAt,
            carriesTime: item.kind.carriesTime,
            unconfirmed: item.status == .unconfirmed
        )
    }
}
