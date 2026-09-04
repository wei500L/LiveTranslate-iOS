import SwiftUI

// Shared presentation components for the course-material library.

extension MaterialFormat {
    var symbol: String {
        switch self {
        case .pdf: return "doc.richtext"
        case .text: return "doc.plaintext"
        case .markdown: return "doc.text"
        case .image: return "photo"
        case .link: return "link"
        case .other: return "doc"
        }
    }
}

extension MaterialExtractionStatus {
    /// Honest, user-facing state chips — distinct states are never
    /// collapsed into one 处理中.
    var statusChip: (text: String, tint: Color)? {
        switch self {
        case .pending: return ("待读取", LTColors.accentCyan)
        case .extracting: return ("读取中", LTColors.accentCyan)
        case .completed: return nil
        case .partial: return ("部分读取", LTColors.warning)
        case .failed: return ("读取失败", LTColors.warning)
        case .unsupported: return ("暂不支持内容提取", LTColors.textTertiary)
        }
    }
}

extension MaterialDigestStatus {
    var statusChip: (text: String, tint: Color)? {
        switch self {
        case .pending: return nil
        case .analyzing: return ("整理中", LTColors.accentCyan)
        case .completed: return nil
        case .partial: return ("整理未完成", LTColors.warning)
        case .failed: return ("整理失败", LTColors.warning)
        }
    }
}

/// One material row: format icon, title, meta line (kind · pages ·
/// date), and honest state chips (extraction / digest are DIFFERENT
/// states and never merged).
struct MaterialRow: View {
    let material: CourseMaterial
    var showsCourse: Bool = false
    var courseName: String? = nil

    var body: some View {
        HStack(spacing: LTSpacing.m) {
            LTIconBadge(
                symbol: material.format.symbol,
                tint: material.ownsFile ? LTColors.accentBlue : LTColors.accentCyan,
                size: 38
            )
            VStack(alignment: .leading, spacing: LTSpacing.xxs) {
                Text(material.title.isEmpty ? material.originalFileName : material.title)
                    .font(LTTypography.cardTitle)
                    .foregroundStyle(LTColors.textPrimary)
                    .lineLimit(2)
                HStack(spacing: LTSpacing.xs) {
                    Text(metaLine)
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textTertiary)
                        .lineLimit(1)
                }
                if !chips.isEmpty {
                    HStack(spacing: LTSpacing.xxs) {
                        ForEach(chips, id: \.text) { chip in
                            StatusChip(text: chip.text, tint: chip.tint)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LTColors.textTertiary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(material.title), \(metaLine)"))
    }

    private var metaLine: String {
        var parts: [String] = [material.kind.displayName]
        if material.pageCount > 0 {
            parts.append(material.pageCount == 1 ? "1 页" : "\(material.pageCount) 页")
        }
        if material.isLink {
            parts.append("链接")
        } else if !material.ownsFile {
            parts.append("来自课堂图片")
        }
        if showsCourse, let courseName {
            parts.append(courseName)
        } else if material.courseID == nil {
            parts.append("未归类")
        }
        return parts.joined(separator: " · ")
    }

    private var chips: [(text: String, tint: Color)] {
        var result: [(String, Color)] = []
        if let chip = material.extractionStatus.statusChip {
            result.append((chip.text, chip.tint))
        }
        if let chip = material.digestStatus.statusChip {
            result.append((chip.text, chip.tint))
        }
        return result
    }
}

/// The import source picker row set (导入来源): Files picker — real
/// document types only, no fake sources.
enum MaterialImportSource: String, CaseIterable, Identifiable {
    case files
    case attachment

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .files: return "从「文件」导入"
        case .attachment: return "从课堂图片选取"
        }
    }

    var symbol: String {
        switch self {
        case .files: return "folder"
        case .attachment: return "photo.on.rectangle"
        }
    }
}
