import Foundation

/// 课表图片智能导入 — the timetable parsing business layer. This is an
/// ASSISTED entry flow: the multimodal model proposes candidates, the
/// user reviews and edits each one BEFORE anything is created. Nothing
/// here writes to the store — persistence happens in
/// ScheduleImageImportView only after explicit confirmation, through the
/// normal addSchedule/addException mutations (sync + reminders follow
/// the standard chain).
///
/// Reuses the existing multimodal transport (AttachmentAnalysisModelService)
/// — no second multimodal client. Uncertain fields carry flags the UI
/// renders as warnings (时间不确定 / 单双周不明确 / 教室无法识别).
struct ScheduleImageParser {
    /// One candidate class parsed from the image. Every field is a
    /// SUGGESTION — the user confirms before it exists.
    struct Candidate: Identifiable, Sendable, Equatable {
        var id = UUID()
        /// Suggested course name (match against existing courses or
        /// create a new one).
        var courseName: String
        var weekday: Int
        var startSecs: Int
        var endSecs: Int
        var recurrence: ScheduleRecurrence
        var teacher: String
        var location: String
        /// Model-uncertainty flags — rendered as text, never hidden.
        var timeUncertain: Bool
        var parityUncertain: Bool
        var locationUncertain: Bool
        var teacherUncertain: Bool

        /// Whether the row passes minimum viability (a course name and
        /// plausible times).
        var isViable: Bool {
            !courseName.trimmingCharacters(in: .whitespaces).isEmpty
                && endSecs > startSecs
                && weekday >= 0 && weekday <= 6
        }
    }

    /// Parse result: candidates + what the model could not see.
    struct Parsed: Sendable, Equatable {
        var candidates: [Candidate]
        /// The model's note on overall completeness (missing semester
        /// range etc.) — nil when it saw everything it needed.
        var missingInfo: String?
    }

    let service: any AttachmentAnalysisModelService

    func parse(imageData: Data, imageMIME: String) async throws -> Parsed {
        let text = try await service.complete(
            systemPrompt: Self.systemPrompt,
            userPrompt: Self.userPrompt,
            imageData: imageData,
            imageMIME: imageMIME,
            maxTokens: 4000
        )
        return Self.decode(text)
    }

    // MARK: - Prompt

    static let systemPrompt = """
    你是一名课程表解析助手。用户会给你一张大学课程表（截图或照片）。\
    请提取每一条课程安排，严格输出 JSON，不要输出任何其他文本。

    JSON 格式：
    {"candidates":[{"course":"课程名称","weekday":1,"start":"10:30","end":"12:05",\
    "recurrence":"weekly|biweekly|odd_weeks|even_weeks","teacher":"教师名（可为空）",\
    "location":"教室（可为空）","time_uncertain":false,"parity_uncertain":false,\
    "location_uncertain":false,"teacher_uncertain":false}],"missing_info":"缺少的信息说明（无则省略）"}

    规则：
    - weekday 用数字：0=周日,1=周一,…,6=周六。
    - start/end 是 24 小时制 HH:MM。
    - 单双周信息不明确时 recurrence 填 weekly 并把 parity_uncertain 设为 true。
    - 任何不确定的字段都把对应的 *_uncertain 设为 true，不要猜测后装作确定。
    - 课程表里没有的信息（如学期范围）在 missing_info 里说明，不要编造。
    """

    static let userPrompt = "请解析这张课程表图片，按系统规定的 JSON 格式输出。"

    // MARK: - Decode

    static func decode(_ text: String) -> Parsed {
        // The model may wrap JSON in a code fence — strip it.
        var payload = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if payload.hasPrefix("```") {
            if let firstNewline = payload.firstIndex(of: "\n") {
                payload = String(payload[payload.index(after: firstNewline)...])
            }
            if let closing = payload.range(of: "```", options: .backwards) {
                payload = String(payload[payload.startIndex..<closing.lowerBound])
            }
            payload = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = payload.data(using: .utf8) else { return Parsed(candidates: [], missingInfo: nil) }

        struct Wire: Decodable {
            struct WireCandidate: Decodable {
                var course: String?
                var weekday: Int?
                var start: String?
                var end: String?
                var recurrence: String?
                var teacher: String?
                var location: String?
                var timeUncertain: Bool?
                var parityUncertain: Bool?
                var locationUncertain: Bool?
                var teacherUncertain: Bool?

                enum CodingKeys: String, CodingKey {
                    case course, weekday, start, end, recurrence, teacher, location
                    case timeUncertain = "time_uncertain"
                    case parityUncertain = "parity_uncertain"
                    case locationUncertain = "location_uncertain"
                    case teacherUncertain = "teacher_uncertain"
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
        let candidates = (wire.candidates ?? []).compactMap { c in
            Candidate(
                courseName: (c.course ?? "").trimmingCharacters(in: .whitespaces),
                weekday: min(max(c.weekday ?? 1, 0), 6),
                startSecs: Self.parseTime(c.start) ?? 0,
                endSecs: Self.parseTime(c.end) ?? 0,
                recurrence: ScheduleRecurrence(rawValue: c.recurrence ?? "") ?? .weekly,
                teacher: c.teacher ?? "",
                location: c.location ?? "",
                timeUncertain: c.timeUncertain ?? false,
                parityUncertain: c.parityUncertain ?? false,
                locationUncertain: c.locationUncertain ?? false,
                teacherUncertain: c.teacherUncertain ?? false
            )
        }
        return Parsed(candidates: candidates, missingInfo: wire.missingInfo)
    }

    /// "10:30" / "10.30" / "10时30分" → seconds since midnight.
    static func parseTime(_ string: String?) -> Int? {
        guard let string else { return nil }
        let normalized = string
            .replacingOccurrences(of: "：", with: ":")
            .replacingOccurrences(of: ".", with: ":")
            .replacingOccurrences(of: "时", with: ":")
            .replacingOccurrences(of: "分", with: "")
        let parts = normalized.split(separator: ":")
        guard parts.count >= 1, let hour = Int(parts[0]) else { return nil }
        let minute = parts.count >= 2 ? (Int(parts[1]) ?? 0) : 0
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return hour * 3600 + minute * 60
    }
}
