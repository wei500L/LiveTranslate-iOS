import Foundation
import PDFKit
import UIKit

/// AI 智能识别 — the inbox's multi-action suggestion pass over the
/// EXISTING model services (the multimodal AttachmentAnalysisModelService
/// for images / rendered PDF pages, the text StudyReviewModelService for
/// text, URL+text and PDF text layers). No new API key, no second client:
/// unconfigured services produce NO actions and an honest explanation —
/// manual classification stays fully usable offline.
///
/// One notification may carry several things at once (a PDF handout + an
/// exam date + a homework requirement), so the model returns a LIST of
/// suggested actions; the user ticks each one before anything is created.
/// Nothing here writes to the store — persistence happens only through
/// InboxActionExecutor after explicit confirmation.
struct InboxSuggestionService {
    let imageService: (any AttachmentAnalysisModelService)?
    let textService: (any StudyReviewModelService)?

    struct Result: Sendable, Equatable {
        var actions: [InboxSuggestedAction]
        var missingInfo: String?
    }

    enum SuggestError: LocalizedError {
        case modelNotConfigured

        var errorDescription: String? {
            String(localized: "模型服务尚未配置，可手动归类。", comment: "inbox ai")
        }
    }

    /// How much local text is fed to the model (the same budget mindset
    /// as the digest chunking — bounded, honest).
    static let textBudget = 4_000
    static let maxTokens = 3_000

    func suggest(
        item: SharedInboxItem,
        payloadURL: URL?,
        courseNames: [String],
        referenceDate: Date
    ) async throws -> Result {
        // Build the bounded source text the model gets to see.
        var sourceText = ""
        var imageData: Data?
        var imageMIME = ""

        switch item.payloadKind {
        case .url:
            var parts: [String] = []
            if !item.urlTitle.isEmpty { parts.append("页面标题：\(item.urlTitle)") }
            parts.append("链接：\(item.url)")
            if !item.textContent.isEmpty { parts.append("分享时的文字：\n\(item.textContent)") }
            sourceText = parts.joined(separator: "\n")
        case .text:
            sourceText = item.textContent
        case .file:
            switch item.fileHints.family {
            case .pdf:
                guard let payloadURL else { break }
                sourceText = Self.pdfTextSample(url: payloadURL, budget: Self.textBudget)
                // A scanned PDF has no text layer — the model sees a
                // rendered FIRST PAGE instead (не the whole document).
                if sourceText.isEmpty {
                    let rendered = Self.pdfFirstPageImage(url: payloadURL)
                    imageData = rendered?.data
                    imageMIME = "image/jpeg"
                }
            case .image:
                imageData = payloadURL.flatMap { try? Data(contentsOf: $0) }
                imageMIME = item.fileHints.mimeType.isEmpty
                    ? "image/jpeg" : item.fileHints.mimeType
            case .text, .markdown, .other:
                if let payloadURL {
                    if let data = try? Data(contentsOf: payloadURL),
                       let text = String(data: data, encoding: .utf8) {
                        sourceText = String(text.prefix(Self.textBudget))
                    }
                }
            }
        }

        guard !sourceText.isEmpty || imageData != nil else {
            throw SuggestError.modelNotConfigured
        }

        let prompt = Self.userPrompt(
            sourceLabel: item.title, referenceDate: referenceDate,
            courseNames: courseNames
        )

        let raw: String
        if let imageData, let imageService {
            raw = try await AICallScope.with(
                AICallContext(feature: .inboxSuggestion, textCategory: .userInput)
            ) {
                try await imageService.complete(
                    systemPrompt: Self.systemPrompt,
                    userPrompt: prompt + "\n\n来源内容（图片）：",
                    imageData: imageData,
                    imageMIME: imageMIME,
                    maxTokens: Self.maxTokens
                )
            }
        } else if let textService, !sourceText.isEmpty {
            raw = try await AICallScope.with(
                AICallContext(feature: .inboxSuggestion, textCategory: .mixed)
            ) {
                try await textService.complete(
                    systemPrompt: Self.systemPrompt,
                    userPrompt: prompt + "\n\n来源内容：\n" + sourceText,
                    maxTokens: Self.maxTokens
                )
            }
        } else {
            // Image without a configured multimodal service, or text
            // without a configured text service.
            throw SuggestError.modelNotConfigured
        }

        return Self.decode(raw, sourceTitle: item.title, sourceText: sourceText)
    }

    // MARK: - Local PDF sampling (no model, no store)

    /// First pages' TEXT LAYER only (born-digital PDFs), bounded. A
    /// scanned PDF honestly returns "" (the caller falls back to the
    /// first-page image).
    static func pdfTextSample(url: URL, budget: Int) -> String {
        guard let document = PDFDocument(url: url) else { return "" }
        let pages = min(3, document.pageCount)
        var parts: [String] = []
        var total = 0
        for index in 0..<pages {
            guard let page = document.page(at: index) else { continue }
            let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { continue }
            parts.append(text)
            total += text.count
            if total >= budget { break }
        }
        return String(parts.joined(separator: "\n").prefix(budget))
    }

    /// Renders the PDF's first page to a bounded JPEG for the multimodal
    /// pass (never the whole document).
    static func pdfFirstPageImage(
        url: URL, maxDimension: CGFloat = 1024
    ) -> (data: Data, pixelSize: CGSize)? {
        guard let document = PDFDocument(url: url),
              let page = document.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let scale = min(
            maxDimension / max(bounds.width, 1), maxDimension / max(bounds.height, 1), 2
        )
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let thumbnail = page.thumbnail(of: size, for: .mediaBox)
        guard let data = thumbnail.jpegData(compressionQuality: 0.72) else { return nil }
        return (data, size)
    }

    // MARK: - Prompt

    static let systemPrompt = """
    你是一名课程信息整理助手。用户会给你一条从其他应用分享到 LiveTranslate 的内容\
    （教师通知、图片、PDF、链接、文本）。请判断它对一名在俄语区上学的学生有什么用途，\
    并建议一个或多个后续动作，严格输出 JSON，不要输出任何其他文本。

    JSON 格式：
    {"actions":[
      {"type":"material","material_kind":"lecture|homework|lab|reading|exam|other",\
    "course":"匹配的课程名（没有就留空）","note":"一句建议理由"},
      {"type":"attachment"},
      {"type":"exam","title":"考试名称","kind":"midterm|final|quiz|lab|oral|report|defense|custom",\
    "date":"YYYY-MM-DD 或空字符串","time":"HH:MM 或空字符串","location":"","relative_wording":"原文时间表述",\
    "scope":"考试范围","requirements":"要求","date_uncertain":false,"time_uncertain":false,\
    "kind_uncertain":false,"location_uncertain":false},
      {"type":"task","title":"作业标题","detail":"要求说明","due":"YYYY-MM-DD 或空字符串",\
    "priority":"low|normal|high","uncertainty":"不确定之处"},
      {"type":"schedule","course":"课程名","weekday":1,"start":"10:30","end":"12:05",\
    "recurrence":"weekly|biweekly|odd_weeks|even_weeks","teacher":"","location":"",\
    "time_uncertain":false,"parity_uncertain":false,"location_uncertain":false,"teacher_uncertain":false},
      {"type":"note","text":"值得保存为课堂笔记的内容（仅在内容确实像笔记时建议）"}
    ],"missing_info":"来源中缺少的重要信息（无则省略）"}

    规则（必须遵守）：
    - 内容像讲义/习题/阅读材料时建议 material；课堂或黑板照片建议 attachment；\
    明确提到考试的建议 exam；提到作业或截止时间的建议 task；课程表建议 schedule；\
    文字本身值得保存的建议 note。可以同时建议多个动作。
    - course 只在明确匹配用户提供的课程列表时填写，不要猜。
    - 日期时间绝不猜测：原文只说下周三时，date 填换算结果并把 date_uncertain 设为 true，\
    relative_wording 保留原文。
    - 无法判断的字段留空并把对应 *_uncertain 设为 true。
    - 一条通知里可能同时包含资料、考试和作业——都要建议。
    """

    static func userPrompt(
        sourceLabel: String, referenceDate: Date, courseNames: [String]
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "y年M月d日 EEEE HH:mm"
        let courses = courseNames.isEmpty ? "（用户还没有课程）" : courseNames.joined(separator: "、")
        return """
        请分析这条分享内容的用途并给出建议动作，按系统规定的 JSON 格式输出。
        来源标题：\(sourceLabel)
        参考时间（用于换算相对日期）：\(formatter.string(from: referenceDate))
        用户的课程列表：\(courses)
        """
    }

    // MARK: - Decode (tolerant — one bad action never discards the rest)

    static func decode(_ text: String, sourceTitle: String, sourceText: String) -> Result {
        guard let payload = Self.jsonPayload(from: text),
              let data = payload.data(using: .utf8) else {
            return Result(actions: [], missingInfo: String(localized: "无法解析模型输出", comment: "inbox ai"))
        }

        struct Wire: Decodable {
            struct WireAction: Decodable {
                var type: String?
                var note: String?
                // material
                var materialKind: String?
                var course: String?
                // exam
                var title: String?
                var kind: String?
                var date: String?
                var time: String?
                var location: String?
                var relativeWording: String?
                var scope: String?
                var requirements: String?
                var dateUncertain: Bool?
                var timeUncertain: Bool?
                var kindUncertain: Bool?
                var locationUncertain: Bool?
                // task
                var detail: String?
                var due: String?
                var priority: String?
                var uncertainty: String?
                // schedule
                var weekday: Int?
                var start: String?
                var end: String?
                var recurrence: String?
                var teacher: String?
                var parityUncertain: Bool?
                var teacherUncertain: Bool?
                // note
                var noteText: String?
            }
            var actions: [WireAction]?
            var missingInfo: String?
        }

        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else {
            return Result(actions: [], missingInfo: String(localized: "无法解析模型输出", comment: "inbox ai"))
        }

        var actions: [InboxSuggestedAction] = []
        for raw in wire.actions ?? [] {
            guard let type = raw.type else { continue }
            switch type {
            case "material":
                var action = InboxSuggestedAction(
                    kind: .saveAsMaterial, title: "保存为课程资料"
                )
                if let kindRaw = raw.materialKind,
                   MaterialKind(rawValue: kindRaw) != nil {
                    action.materialKindRaw = kindRaw
                }
                if let note = raw.note, !note.isEmpty {
                    action.title = "保存为课程资料 · \(note)"
                }
                actions.append(action)
            case "attachment":
                actions.append(InboxSuggestedAction(
                    kind: .attachToSession, title: "存为课堂图片（需选择课堂）"
                ))
            case "exam":
                let title = (raw.title ?? "").trimmingCharacters(in: .whitespaces)
                guard !title.isEmpty else { continue }
                var dateKey = (raw.date ?? "").trimmingCharacters(in: .whitespaces)
                var dateUncertain = raw.dateUncertain ?? false
                let wording = (raw.relativeWording ?? "").trimmingCharacters(in: .whitespaces)
                if dateKey.isEmpty, !wording.isEmpty,
                   let resolved = ExamCandidateParser.resolveRelativeDate(wording, from: .now) {
                    dateKey = Exam.dateKey(resolved)
                    dateUncertain = true
                }
                var action = InboxSuggestedAction(
                    kind: .createExamCandidate, title: "记录考试候选：\(title)"
                )
                action.examCandidate = ExamCandidateSnapshot(
                    title: title,
                    kindRaw: ExamKind(rawValue: raw.kind ?? "")?.rawValue ?? ExamKind.custom.rawValue,
                    dateKey: dateKey,
                    timeText: (raw.time ?? "").trimmingCharacters(in: .whitespaces),
                    location: raw.location ?? "",
                    relativeWording: wording,
                    scopeText: raw.scope ?? "",
                    requirements: raw.requirements ?? "",
                    dateUncertain: dateUncertain,
                    timeUncertain: raw.timeUncertain ?? false,
                    kindUncertain: raw.kindUncertain ?? false,
                    locationUncertain: raw.locationUncertain ?? false
                )
                actions.append(action)
            case "task":
                let title = (raw.title ?? "").trimmingCharacters(in: .whitespaces)
                guard !title.isEmpty else { continue }
                var action = InboxSuggestedAction(
                    kind: .createTaskCandidate, title: "创建作业候选：\(title)"
                )
                action.taskCandidate = TaskCandidateSnapshot(
                    title: title,
                    detail: raw.detail ?? "",
                    priorityRaw: raw.priority == "high" || raw.priority == "low"
                        ? raw.priority! : "normal",
                    dueAt: parseDateKey(raw.due ?? ""),
                    uncertainty: raw.uncertainty ?? ""
                )
                actions.append(action)
            case "schedule":
                let course = (raw.course ?? "").trimmingCharacters(in: .whitespaces)
                guard !course.isEmpty else { continue }
                var action = InboxSuggestedAction(
                    kind: .importSchedule, title: "导入课程表：\(course)"
                )
                action.scheduleCandidate = ScheduleCandidateSnapshot(
                    courseName: course,
                    weekday: min(max(raw.weekday ?? 1, 0), 6),
                    startSecs: ScheduleImageParser.parseTime(raw.start) ?? 0,
                    endSecs: ScheduleImageParser.parseTime(raw.end) ?? 0,
                    recurrenceRaw: ScheduleRecurrence(
                        rawValue: raw.recurrence ?? ""
                    )?.rawValue ?? ScheduleRecurrence.weekly.rawValue,
                    teacher: raw.teacher ?? "",
                    location: raw.location ?? "",
                    timeUncertain: raw.timeUncertain ?? false,
                    parityUncertain: raw.parityUncertain ?? false,
                    locationUncertain: raw.locationUncertain ?? false,
                    teacherUncertain: raw.teacherUncertain ?? false
                )
                actions.append(action)
            case "note":
                let note = (raw.noteText ?? "").trimmingCharacters(in: .whitespaces)
                guard !note.isEmpty else { continue }
                var action = InboxSuggestedAction(
                    kind: .saveAsNote, title: "保存为课堂笔记（需选择课堂）"
                )
                action.noteText = note
                actions.append(action)
            default:
                continue
            }
        }
        return Result(actions: actions, missingInfo: wire.missingInfo)
    }

    private static func parseDateKey(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return Exam.parseDateKey(trimmed)
    }

    /// Code-fence tolerant JSON extraction (the shared convention — same
    /// job as AttachmentAnalysisParser.jsonPayload, kept local so the
    /// inbox layer does not reach into the attachments domain).
    static func jsonPayload(from text: String) -> String? {
        var payload = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if payload.hasPrefix("```") {
            if let firstNewline = payload.firstIndex(of: "\n") {
                payload = String(payload[payload.index(after: firstNewline)...])
            }
            if let closing = payload.range(of: "```", options: .backwards) {
                payload = String(payload[..<closing.lowerBound])
            }
        }
        guard payload.hasPrefix("{") else { return nil }
        return payload
    }
}
