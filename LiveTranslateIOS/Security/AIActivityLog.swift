import Foundation
import Observation
import OSLog

/// Pre-request AI privacy disclosure (round 17) — the ONE vocabulary
/// every model call site uses to describe what it sends. Two consumers:
///   1. the send-preview UI (随身翻译 already shows most of it — this
///      struct makes the description uniform);
///   2. the local AI activity log (metadata ONLY — never content).
struct AIRequestDisclosure: Sendable, Equatable {
    /// Which feature issued the request (user-recognizable name).
    var feature: AIFeature
    /// The endpoint host the request went to (no scheme path query, no
    /// key — a user-recognizable name like "api.example.com").
    var host: String
    /// What kind of TEXT rode the request.
    var textCategory: AITextCategory
    /// Characters of user content in the request (rounded counts, no
    /// content).
    var characterCount: Int
    /// How many images rode the request.
    var imageCount: Int
    /// Whether the local sensitive-masker covered obvious secrets
    /// (passport/card/phone/email) in the text that was sent.
    var masked: Bool
    /// Whether the request was an explicit user action (vs. a background
    /// pipeline pass like classroom live translation).
    var userTriggered: Bool

    /// Send-preview copy (the honest "what will leave this device" line).
    var previewSummary: String {
        var parts: [String] = [feature.displayName]
        parts.append(host.isEmpty ? "自定义服务" : host)
        if imageCount > 0 {
            parts.append("\(imageCount) 张图片")
        }
        if textCategory != .none {
            parts.append(textCategory.displayName)
        }
        if masked {
            parts.append("已自动遮盖敏感信息")
        }
        return parts.joined(separator: " · ")
    }
}

enum AIFeature: String, Codable, Sendable, CaseIterable, Equatable {
    case classroomTranslation     // 课堂实时翻译(后台流水线)
    case interpreterReply         // 随身翻译回复
    case interpreterDocumentAnalysis  // 随身翻译文件分析
    case interpreterDocumentQA    // 随身翻译文件问答
    case interpreterFieldCheck    // 随身翻译字段核对
    case interpreterFormTextTranslation // 表单自由文本翻译为俄语
    case interpreterPagesAnalysis // 随身翻译页面图像分析
    case studyReview              // 课后复习整理
    case materialDigest           // 资料导读
    case courseAssistant          // 课程助手问答
    case attachmentAnalysis       // 课堂图片理解
    case visualQA                 // 视觉问答
    case inboxSuggestion          // 收件箱智能识别
    case examParsing              // 考试信息识别
    case scheduleImport           // 课表图片导入
    case learningCard             // 学习卡片生成
    case errandOrganizing         // 办事事项 AI 整理

    var displayName: String {
        switch self {
        case .classroomTranslation: return "课堂翻译"
        case .interpreterReply: return "随身翻译回复"
        case .interpreterDocumentAnalysis: return "文件分析"
        case .interpreterDocumentQA: return "文件问答"
        case .interpreterFieldCheck: return "字段核对"
        case .interpreterFormTextTranslation: return "表单文本翻译"
        case .interpreterPagesAnalysis: return "页面图像分析"
        case .studyReview: return "复习整理"
        case .materialDigest: return "资料导读"
        case .courseAssistant: return "课程助手"
        case .attachmentAnalysis: return "图片理解"
        case .visualQA: return "视觉问答"
        case .inboxSuggestion: return "收件箱识别"
        case .examParsing: return "考试识别"
        case .scheduleImport: return "课表导入"
        case .learningCard: return "学习卡片"
        case .errandOrganizing: return "办事整理"
        }
    }
}

enum AITextCategory: String, Codable, Sendable, Equatable {
    case none
    case transcript      // 课堂转录(俄语原文/中文翻译)
    case ocr             // OCR 识别文本
    case userInput       // 用户手动输入
    case documentText    // 随身翻译文件文本(已遮盖或未遮盖)
    case notes           // 笔记
    case mixed           // 混合来源

    var displayName: String {
        switch self {
        case .none: return ""
        case .transcript: return "课堂转录"
        case .ocr: return "OCR 文本"
        case .userInput: return "手动输入"
        case .documentText: return "文件文本"
        case .notes: return "笔记"
        case .mixed: return "混合文本"
        }
    }
}

/// What a call site knows that the transport layer does not: which
/// feature is calling and whether the user explicitly triggered it. Set
/// via Task-local at each model call site; the transport services merge
/// it with what ONLY they know (sizes, image count, host, outcome) to
/// record the activity entry.
struct AICallContext: Sendable, Equatable {
    var feature: AIFeature
    var textCategory: AITextCategory
    var masked: Bool = false
    var userTriggered: Bool = true
}

enum AICallScope {
    @TaskLocal static var current: AICallContext?

    /// Wraps one model call with its privacy context — the transport
    /// service reads it when recording the activity entry. One line at
    /// each domain call site; the transport layer adds what only it
    /// knows (sizes, images, host, outcome).
    static func with<T: Sendable>(
        _ context: AICallContext,
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await $current.withValue(context, operation: operation)
    }

    /// Non-throwing overload for outcomes-style calls (the classroom
    /// pipeline's translate returns a result instead of throwing).
    static func with<T: Sendable>(
        _ context: AICallContext,
        _ operation: @Sendable () async -> T
    ) async -> T {
        await $current.withValue(context, operation: operation)
    }
}

/// Local AI data activity log (round 17). Metadata only:
/// time / feature / text+image categories / character count / masked /
/// outcome / provider host. NEVER the request body, prompt, model
/// response, Authorization, key, full URL or query string. Local to this
/// device + this profile (lives in the account directory), 30-day
/// retention, clearable, and NEVER synced, indexed or logged. This is a
/// local ledger — NOT a provider-side audit log.
@MainActor
@Observable
final class AIActivityLog {
    private static let logger = Logger(
        subsystem: "com.livetranslate.ios", category: "ai-activity"
    )

    static let retention: TimeInterval = 30 * 24 * 3600

    struct Entry: Codable, Identifiable, Sendable, Equatable {
        var id: UUID = UUID()
        var occurredAt: Date = .now
        var feature: AIFeature
        var textCategory: AITextCategory
        var characterCount: Int
        var imageCount: Int
        var masked: Bool
        var outcome: Outcome
        /// Endpoint host only (no key, no path, no query).
        var host: String

        enum Outcome: String, Codable, Sendable {
            case success, cancelled, failed
        }
    }

    /// The active profile's log — registered by AppEnvironment at
    /// composition (the store-holder convention). The transport services
    /// record through this holder; demo/test compositions leave it nil
    /// and nothing is recorded.
    nonisolated(unsafe) static var shared: AIActivityLog?

    private(set) var entries: [Entry] = []

    private let fileURL: URL

    /// The active profile's log (account dir or the guest global file).
    init(accountID: UUID?) {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir: URL
        if let accountID {
            dir = AccountScope.accountDirectory(accountID: accountID)
                .appendingPathComponent("AIActivity", isDirectory: true)
        } else {
            dir = support.appendingPathComponent("AIActivity", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Metadata only — but it describes WHAT was sent WHERE: same
        // protection class as the interpreter documents (locked-
        // inaccessible, excluded from backup).
        FileProtection.apply(.sensitiveLocalDocument, to: dir)
        self.fileURL = dir.appendingPathComponent("activity.json")
        load()
    }

    /// Test log with a throwaway file.
    init(fileURL: URL) {
        self.fileURL = fileURL
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        load()
    }

    // MARK: - Recording (transport services)

    /// Records one request outcome. Called by the transport layer with
    /// the merged disclosure. Cancellation is recorded as cancellation —
    /// never as a failure.
    func record(
        feature: AIFeature, textCategory: AITextCategory,
        characterCount: Int, imageCount: Int, masked: Bool,
        outcome: Entry.Outcome, host: String
    ) {
        entries.append(Entry(
            feature: feature,
            textCategory: textCategory,
            characterCount: characterCount,
            imageCount: imageCount,
            masked: masked,
            outcome: outcome,
            host: host
        ))
        prune()
        persist()
    }

    /// Transport-side convenience: merges the Task-local call context
    /// (feature/masked) with transport-known facts. Call-context-less
    /// requests are NOT recorded (an unattributed ledger row would be
    /// noise, not honesty).
    nonisolated static func recordTransport(
        characterCount: Int, imageCount: Int,
        outcome: Entry.Outcome, host: String
    ) async {
        guard let context = AICallScope.current else { return }
        let feature = context.feature
        let textCategory = context.textCategory
        let masked = context.masked
        await MainActor.run {
            shared?.record(
                feature: feature, textCategory: textCategory,
                characterCount: characterCount, imageCount: imageCount,
                masked: masked, outcome: outcome, host: host
            )
        }
    }

    // MARK: - User actions (privacy center)

    func clear() {
        entries.removeAll()
        persist()
    }

    var totalBytes: Int64 {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: fileURL.path
        )
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: - Persistence (activity.json: metadata only)

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data)
        else { return }
        entries = decoded
        prune()
    }

    private func prune(asOf now: Date = .now) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        let fresh = entries.filter { $0.occurredAt > cutoff }
        if fresh.count != entries.count {
            entries = fresh
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        do {
            try FileProtection.write(data, to: fileURL, class: .sensitiveLocalDocument)
        } catch {
            Self.logger.error("ai activity persist failed (metadata only)")
        }
    }
}
