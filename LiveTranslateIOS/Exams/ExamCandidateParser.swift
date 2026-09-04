import Foundation

/// 考试信息智能识别 — the exam-candidate extraction layer. This is an
/// ASSISTED entry flow (the ScheduleImageParser pattern): the model only
/// PROPOSES candidates; nothing here writes to the store. Persistence
/// happens in the confirmation UI only after explicit user review, via
/// `addExam(draft: .pending …)` — device-local rows that never notify
/// sync, never register notifications and never generate plans.
///
/// Two entry modes over the EXISTING clients (no second client):
/// - IMAGE sources (教师通知截图 / 黑板照片 / 资料图片) ride
///   `AttachmentAnalysisModelService` (the multimodal transport);
/// - TEXT sources (PDF 通知文本 / 课堂转录 / 笔记 / 视觉问答结果) ride
///   `StudyReviewModelService` (the text transport).
///
/// Honesty rules baked into the prompt and the decoder:
/// - no date is ever guessed; relative dates (下周三) keep their ORIGINAL
///   wording and a candidate date computed from the SOURCE's timestamp;
/// - uncertain fields carry flags rendered as text warnings;
/// - the source reference (attachment/material/session id) rides along
///   into `ExamSource` for the confirmation UI.
struct ExamCandidateParser {

    /// One exam candidate — every field is a SUGGESTION.
    struct Candidate: Identifiable, Sendable, Equatable {
        var id = UUID()
        var title: String
        var kind: ExamKind
        /// "YYYY-MM-DD" or "" when the source names no date (не guessed).
        var dateKey: String
        /// "HH:MM" or "" when unknown.
        var timeText: String
        var location: String
        /// The original relative wording (下周三 …) — shown verbatim.
        var relativeWording: String
        /// 考试范围 (free text from the source).
        var scopeText: String
        /// 教师要求.
        var requirements: String
        /// Model-uncertainty flags — rendered as text, never hidden.
        var dateUncertain: Bool
        var timeUncertain: Bool
        var kindUncertain: Bool
        var locationUncertain: Bool
        /// The candidate's source (for the confirmation UI's citation).
        var source: ExamSource

        var isViable: Bool {
            !title.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    struct Parsed: Sendable, Equatable {
        var candidates: [Candidate]
        /// What the model could not see (no explicit date etc.).
        var missingInfo: String?
    }

    let imageService: (any AttachmentAnalysisModelService)?
    let textService: (any StudyReviewModelService)?

    // MARK: - Image entry

    func parseImage(
        imageData: Data, imageMIME: String,
        sourceKind: ExamSource.SourceKind, sourceID: UUID?,
        sourceTimestamp: Date
    ) async throws -> Parsed {
        guard let imageService else {
            throw ParseError.modelNotConfigured
        }
        let text = try await imageService.complete(
            systemPrompt: Self.systemPrompt,
            userPrompt: Self.userPrompt(sourceTimestamp: sourceTimestamp),
            imageData: imageData,
            imageMIME: imageMIME,
            maxTokens: 3000
        )
        return Self.decode(
            text,
            sourceKind: sourceKind,
            sourceID: sourceID,
            sourceTimestamp: sourceTimestamp
        )
    }

    // MARK: - Text entry

    func parseText(
        _ sourceText: String,
        sourceKind: ExamSource.SourceKind, sourceID: UUID?,
        sourceTimestamp: Date
    ) async throws -> Parsed {
        guard let textService else {
            throw ParseError.modelNotConfigured
        }
        let prompt = Self.userPrompt(sourceTimestamp: sourceTimestamp)
            + "\n\n来源内容：\n" + sourceText
        let text = try await textService.complete(
            systemPrompt: Self.systemPrompt,
            userPrompt: prompt,
            maxTokens: 3000
        )
        return Self.decode(
            text,
            sourceKind: sourceKind,
            sourceID: sourceID,
            sourceTimestamp: sourceTimestamp
        )
    }

    enum ParseError: LocalizedError {
        case modelNotConfigured

        var errorDescription: String? {
            switch self {
            case .modelNotConfigured:
                return String(localized: "考试识别的模型服务尚未配置。")
            }
        }
    }

    // MARK: - Prompt

    static let systemPrompt = """
    你是一名考试信息解析助手。用户会给你一段可能包含考试安排的内容\
    （教师通知、黑板照片、课程通知、课堂转录或笔记）。请提取其中明确提到\
    的考试安排，严格输出 JSON，不要输出任何其他文本。

    JSON 格式：
    {"candidates":[{"title":"考试名称","kind":"midterm|final|quiz|lab|oral|\
    report|defense|custom","date":"YYYY-MM-DD 或空字符串","time":"HH:MM 或空字符串",\
    "location":"地点（可为空）","relative_wording":"原文中的时间表述（如 下周三，\
    可为空）","scope":"考试范围（可为空）","requirements":"教师要求（可为空）",\
    "date_uncertain":false,"time_uncertain":false,"kind_uncertain":false,\
    "location_uncertain":false}],"missing_info":"来源中没有说明的信息（无则省略）"}

    规则（必须遵守）：
    - 只提取明确提到的考试。没有明确说考试的，不要生成候选。
    - 日期不确定时 date 填空字符串，并在 relative_wording 里保留原文表述。\
    绝不猜测日期、年份或时间。
    - 相对时间（下周三、月底）先按用户提供的参考时间换算为候选日期填入 date，\
    同时在 relative_wording 保留原文，并把 date_uncertain 设为 true 供用户确认。
    - 无法判断考试类型、时间、地点时，把对应 *_uncertain 设为 true，不要猜。
    - 教师提到的考试范围和要求用简短中文概括，不添加原文没有的内容。
    """

    static func userPrompt(sourceTimestamp: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "y年M月d日 EEEE HH:mm"
        return """
        请解析这段内容中提到的考试安排，按系统规定的 JSON 格式输出。\
        参考时间（用于换算相对日期）：\(formatter.string(from: sourceTimestamp))
        """
    }

    // MARK: - Decode

    static func decode(
        _ text: String,
        sourceKind: ExamSource.SourceKind,
        sourceID: UUID?,
        sourceTimestamp: Date
    ) -> Parsed {
        guard let payload = AttachmentAnalysisParser.jsonPayload(from: text),
              let data = payload.data(using: .utf8) else {
            return Parsed(candidates: [], missingInfo: "无法解析模型输出")
        }

        struct Wire: Decodable {
            struct WireCandidate: Decodable {
                var title: String?
                var kind: String?
                var date: String?
                var time: String?
                var location: String?
                var relativeWord: String?
                var scope: String?
                var requirements: String?
                var dateUncertain: Bool?
                var timeUncertain: Bool?
                var kindUncertain: Bool?
                var locationUncertain: Bool?

                enum CodingKeys: String, CodingKey {
                    case title, kind, date, time, location, scope, requirements
                    case relativeWord = "relative_wording"
                    case dateUncertain = "date_uncertain"
                    case timeUncertain = "time_uncertain"
                    case kindUncertain = "kind_uncertain"
                    case locationUncertain = "location_uncertain"
                }
            }
            var candidates: [WireCandidate]?
            var missingInfo: String?

            enum CodingKeys: String, CodingKey {
                case candidates
                case missingInfo = "missing_info"
            }
        }

        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else {
            return Parsed(candidates: [], missingInfo: "无法解析模型输出")
        }
        let candidates = (wire.candidates ?? []).compactMap { c -> Candidate? in
            let title = (c.title ?? "").trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return nil }
            // A relative date is converted against the SOURCE timestamp;
            // the wording rides along for the user to confirm.
            var dateKey = (c.date ?? "").trimmingCharacters(in: .whitespaces)
            var dateUncertain = c.dateUncertain ?? false
            let wording = (c.relativeWord ?? "").trimmingCharacters(in: .whitespaces)
            if dateKey.isEmpty, !wording.isEmpty {
                if let resolved = resolveRelativeDate(wording, from: sourceTimestamp) {
                    dateKey = Exam.dateKey(resolved)
                    dateUncertain = true
                }
            }
            // Uncertainty flags become the source's visible warnings.
            var flags: [String] = []
            if dateUncertain { flags.append(String(localized: "日期不确定")) }
            if c.timeUncertain ?? false { flags.append(String(localized: "时间不确定")) }
            if c.kindUncertain ?? false { flags.append(String(localized: "考试类型不确定")) }
            if c.locationUncertain ?? false { flags.append(String(localized: "地点不确定")) }
            return Candidate(
                title: title,
                kind: ExamKind(rawValue: c.kind ?? "") ?? .custom,
                dateKey: dateKey,
                timeText: (c.time ?? "").trimmingCharacters(in: .whitespaces),
                location: c.location ?? "",
                relativeWording: wording,
                scopeText: c.scope ?? "",
                requirements: c.requirements ?? "",
                dateUncertain: dateUncertain,
                timeUncertain: c.timeUncertain ?? false,
                kindUncertain: c.kindUncertain ?? false,
                locationUncertain: c.locationUncertain ?? false,
                source: ExamSource(
                    kind: sourceKind,
                    sourceID: sourceID,
                    originalText: wording.isEmpty ? title : wording,
                    uncertainties: flags
                )
            )
        }
        return Parsed(candidates: candidates, missingInfo: wire.missingInfo)
    }

    /// 下周三-style resolution against the source timestamp (weekday
    /// names; "下周/下下周" prefixes). Returns nil when the wording does
    /// not name a weekday — never a guess.
    static func resolveRelativeDate(_ wording: String, from reference: Date) -> Date? {
        let calendar = Calendar.current
        var weeksAhead = 0
        var text = wording
        if text.contains("下下周") || text.contains("再下周") {
            weeksAhead = 2
        } else if text.contains("下周") {
            weeksAhead = 1
        } else if text.contains("本周") || text.contains("这周") || text.contains("这星期") || text.contains("本星期") {
            weeksAhead = 0
        }
        let weekdayNames: [(String, Int)] = [
            ("日", 1), ("一", 2), ("二", 3), ("三", 4),
            ("四", 5), ("五", 6), ("六", 7),
        ]
        // Find the LAST weekday mention in the wording (周三 wins over
        // 下周's 周).
        var weekday: Int?
        for (name, value) in weekdayNames {
            if text.contains("周\(name)") || text.contains("星期\(name)") || text.contains("礼拜\(name)") {
                weekday = value
            }
        }
        guard let weekday else { return nil }
        if weeksAhead == 0 && (text.contains("周") || text.contains("星期") || text.contains("礼拜")) == false {
            return nil
        }
        // Base: the reference week's start (week begins Sunday in this
        // calendar), moved forward by the requested weeks, then to the
        // named weekday.
        let refWeekday = calendar.component(.weekday, from: reference)
        let daysToWeekStart = refWeekday - 1
        guard let weekStart = calendar.date(
            byAdding: .day, value: -daysToWeekStart, to: reference
        ) else { return nil }
        let offset = weeksAhead * 7 + (weekday - 1)
        return calendar.date(byAdding: .day, value: offset, to: weekStart)
    }
}
