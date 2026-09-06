import Foundation

/// 填写参考导出（第二十一轮，可选）：按字段顺序导出俄文标签、中文
/// 解释与用户值为 TXT/Markdown —— 走 TemporaryExportStore（24h 受控
/// 生命周期）。明确写"填写参考，不是已提交表单"；不含 UUID、模型名、
/// API Key、OCR 全文或绝对路径；不生成伪 PDF 或类似官方表格的文件。
enum InterpreterFormReferenceExporter {

    struct Options: Sendable, Equatable {
        /// 是否包含用户填写值（导出前由用户确认）。
        var includeValues: Bool
        init(includeValues: Bool) {
            self.includeValues = includeValues
        }
    }

    /// 导出文本（纯 Markdown 列表 —— 纯文本查看器可读）。
    static func text(
        documentName: String,
        draft: InterpreterFormDraft,
        options: Options
    ) -> String {
        var lines: [String] = []
        lines.append("# 填写参考：\(sanitizeFileName(documentName))")
        lines.append("")
        lines.append("> 填写参考，不是已提交表单。正式填写请在纸质或官方电子表单中完成。")
        lines.append("")
        let progress = InterpreterFormDraftProgress.summary(of: draft)
        lines.append("字段 \(progress.total) 项：已填 \(progress.filled)、未填 \(progress.empty)、待确认 \(progress.needsConfirmation)、不适用 \(progress.notApplicable)。")
        lines.append("")
        for field in draft.fields {
            let status = InterpreterFormDraftField.effectiveStatus(field: field)
            var line = "- **\(field.russianLabel)**"
            if !field.chineseMeaning.isEmpty {
                line += "（\(field.chineseMeaning)）"
            }
            if field.requirement == .required {
                line += " 【必填】"
            }
            if let page = field.pageNumber {
                line += " 【第\(page)页】"
            }
            line += " —— \(status.displayName)"
            lines.append(line)
            if options.includeValues {
                if !field.userValue.isEmpty {
                    lines.append("  值：\(field.userValue)")
                }
                if !field.chineseSourceText.isEmpty {
                    lines.append("  中文原文：\(field.chineseSourceText)")
                }
            }
            if !field.userNote.isEmpty {
                lines.append("  备注：\(field.userNote)")
            }
            if let hint = field.formatHint, !hint.isEmpty {
                lines.append("  格式提示：\(hint)")
            }
        }
        lines.append("")
        lines.append("本参考只保存在本机导出目录，24 小时后自动清理。")
        return lines.joined(separator: "\n")
    }

    /// 文件名（绝不携带证件号/邮箱；重音等字符拍平）。
    static func suggestedFileName(documentName: String) -> String {
        let base = sanitizeFileName(documentName)
        let stamp = Self.timestamp()
        return "填写参考-\(base.isEmpty ? "表单" : base)-\(stamp).md"
    }

    private static func sanitizeFileName(_ name: String) -> String {
        let stem = (name as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespaces)
        guard !stem.isEmpty else { return "表单" }
        let allowed = stem.map { character -> Character in
            character.isLetter || character.isNumber || character == " " || character == "-" || character == "_"
                ? character : "_"
        }
        return String(allowed.prefix(40))
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMdd-HHmm"
        return formatter.string(from: .now)
    }
}
