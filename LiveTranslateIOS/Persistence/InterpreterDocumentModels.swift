import Foundation
import SwiftData

/// 随身翻译（interpreter）的本地文件上下文：用户在办事现场拍摄、扫描、
/// 导入或从智能收件箱复制的文档。设备本地实体 —— 原始文件、OCR 文本、
/// 缩略图与来源锚点一律不进 outbox、不上传服务器；只有用户明确提交为
/// 对话回合的文字才沿 InterpreterConversation/InterpreterTurn 的既有同
/// 步链路走。
///
/// 惯例与仓库其余实体一致：跨实体引用存裸 UUID（conversationID），
/// 不用 SwiftData relationship；serverVersion 不存在（本实体永不同步）。
/// 文件布局由 InterpreterDocumentStore 管理（View 不得自行拼路径）。
@Model
final class InterpreterDocument {
    @Attribute(.unique) var id: UUID
    /// 所属对话（裸 UUID 引用；草稿对话的文档同样落库）。
    var conversationID: UUID
    /// camera | scan | photos | files | inbox（InterpreterDocumentSource.rawValue）。
    var sourceRaw: String
    /// 原始文件名（导入时的名字，展示用）。
    var originalFileName: String
    /// UTType/MIME 分类结果（pdf | image | text | markdown | other）。
    var formatRaw: String
    var mimeType: String
    var fileSize: Int64
    /// 原始字节 SHA-256（同会话内重复导入提示的依据；跨账号绝不共享）。
    var contentHash: String
    /// 页数（文本/单图 = 1；导入时 PDF 探测）。
    var pageCount: Int
    /// importing | imported | extracting | ready | partiallyExtracted | failed
    /// （InterpreterDocumentStatus.rawValue；本地状态机，绝不同步）。
    var statusRaw: String
    /// 原始文件相对路径（store 根内的相对路径；绝不存绝对路径）。
    var originalRelativePath: String
    /// 本地提取结果 sidecar 相对路径（空 = 尚无提取结果）。
    var extractionRelativePath: String
    /// 用户是否允许把选定内容发送给模型（默认 true；隐私闸门）。
    var allowsModelUse: Bool
    /// 保存会话后是否在本机保留原始文件（keepOriginals；用户在结束时选择）。
    var keepOriginalFile: Bool
    /// 提取算法版本（缓存失效依据；当前 "1"）。
    var extractionVersion: String
    /// 失败/中断的人类可读摘要（"" = 无）。
    var errorSummary: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        conversationID: UUID,
        sourceRaw: String,
        originalFileName: String,
        formatRaw: String,
        mimeType: String,
        fileSize: Int64 = 0,
        contentHash: String = "",
        pageCount: Int = 1,
        statusRaw: String = InterpreterDocumentStatus.importing.rawValue,
        originalRelativePath: String = "",
        extractionRelativePath: String = "",
        allowsModelUse: Bool = true,
        keepOriginalFile: Bool = true,
        extractionVersion: String = "1",
        errorSummary: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.conversationID = conversationID
        self.sourceRaw = sourceRaw
        self.originalFileName = originalFileName
        self.formatRaw = formatRaw
        self.mimeType = mimeType
        self.fileSize = fileSize
        self.contentHash = contentHash
        self.pageCount = pageCount
        self.statusRaw = statusRaw
        self.originalRelativePath = originalRelativePath
        self.extractionRelativePath = extractionRelativePath
        self.allowsModelUse = allowsModelUse
        self.keepOriginalFile = keepOriginalFile
        self.extractionVersion = extractionVersion
        self.errorSummary = errorSummary
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var source: InterpreterDocumentSource {
        get { InterpreterDocumentSource(rawValue: sourceRaw) ?? .files }
        set { sourceRaw = newValue.rawValue }
    }

    var format: InterpreterDocumentFormat {
        get { InterpreterDocumentFormat(rawValue: formatRaw) ?? .other }
        set { formatRaw = newValue.rawValue }
    }

    var status: InterpreterDocumentStatus {
        get { InterpreterDocumentStatus(rawValue: statusRaw) ?? .failed }
        set { statusRaw = newValue.rawValue }
    }
}

/// 文档来源。
enum InterpreterDocumentSource: String, Codable, Sendable, CaseIterable {
    case camera      // 相机拍摄单页
    case scan        // VisionKit 文档扫描（多页）
    case photos      // 相册选择
    case files       // Files 导入
    case inbox       // 智能收件箱（复制进受控生命周期）

    var displayName: String {
        switch self {
        case .camera: return "拍摄"
        case .scan: return "扫描"
        case .photos: return "相册"
        case .files: return "文件"
        case .inbox: return "收件箱"
        }
    }
}

/// 文档格式（沿用 MaterialFormat 语义，但独立枚举 —— 不与资料库共享）。
enum InterpreterDocumentFormat: String, Codable, Sendable {
    case pdf
    case image       // JPEG/PNG/HEIC/WebP
    case text        // .txt
    case markdown    // .md
    case other       // DOC/DOCX 等 —— 仅保存预览，明确"暂不支持内容提取"

    var displayName: String {
        switch self {
        case .pdf: return "PDF"
        case .image: return "图片"
        case .text: return "文本"
        case .markdown: return "Markdown"
        case .other: return "文档"
        }
    }
}

/// 文档状态机（全部本地，绝不同步）：
///
///     importing → imported → extracting → ready
///                                   ↘ partiallyExtracted / failed
///
/// - `importing` 中断（App 被杀）→ 启动回滚为 failed（可重试删除重导）；
/// - `extracting` 中断 → 回滚 imported（可重新提取）；
/// - `partiallyExtracted` 列出成功页与失败页，只重试失败页。
enum InterpreterDocumentStatus: String, Codable, Sendable {
    case importing
    case imported
    case extracting
    case ready
    case partiallyExtracted
    case failed

    var displayName: String {
        switch self {
        case .importing: return "导入中"
        case .imported: return "已导入"
        case .extracting: return "提取中"
        case .ready: return "已就绪"
        case .partiallyExtracted: return "部分提取"
        case .failed: return "失败"
        }
    }
}

// MARK: - 提取结果 sidecar（纯值类型，不进 SwiftData）

/// 一页的提取结果。
struct InterpreterDocumentPageText: Codable, Equatable, Sendable {
    /// 1-based 页码。
    var pageNumber: Int
    /// PDF 文字层 / 文本文件内容（空 = 无文字层）。
    var extractedText: String
    /// Vision OCR 文本（空 = 未运行/无结果）。
    var ocrText: String
    /// 本页平均 OCR 置信度（0-1；-1 = 未知/未运行）。API 可用时记录。
    var ocrConfidence: Double
    /// 本页 OCR 状态（none/pending/running/done/failed）。
    var ocrStatusRaw: String

    init(
        pageNumber: Int,
        extractedText: String = "",
        ocrText: String = "",
        ocrConfidence: Double = -1,
        ocrStatusRaw: String = InterpreterPageOCRStatus.none.rawValue
    ) {
        self.pageNumber = pageNumber
        self.extractedText = extractedText
        self.ocrText = ocrText
        self.ocrConfidence = ocrConfidence
        self.ocrStatusRaw = ocrStatusRaw
    }

    /// 本页有效文本：文字层优先，否则 OCR（与 MaterialPage.effectiveText
    /// 相同的 effective-first 规则）。
    var effectiveText: String {
        let extracted = extractedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extracted.isEmpty { return extracted }
        return ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum CodingKeys: String, CodingKey {
        case pageNumber, extractedText, ocrText, ocrConfidence, ocrStatusRaw
    }
}

enum InterpreterPageOCRStatus: String, Codable, Sendable {
    case none
    case running
    case done
    case failed

    /// 是否为可重试的失败态。
    var isFailed: Bool { self == .failed }
}

/// 整份文档的提取结果（sidecar JSON —— 设备本地，绝不进 wire）。
struct InterpreterDocumentExtraction: Codable, Equatable, Sendable {
    /// 页结果，按页码升序。
    var pages: [InterpreterDocumentPageText]
    /// 提取算法版本（与 InterpreterDocument.extractionVersion 对齐）。
    var extractionVersion: String

    init(pages: [InterpreterDocumentPageText] = [], extractionVersion: String = "1") {
        self.pages = pages.sorted { $0.pageNumber < $1.pageNumber }
        self.extractionVersion = extractionVersion
    }

    /// 解码容错：坏 JSON → nil（绝不崩溃）。
    static func decode(_ json: String) -> InterpreterDocumentExtraction? {
        guard !json.isEmpty else { return nil }
        return try? JSONDecoder().decode(InterpreterDocumentExtraction.self, from: Data(json.utf8))
    }

    func encodedJSON() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
