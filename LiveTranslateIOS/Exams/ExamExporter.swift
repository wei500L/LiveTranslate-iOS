import Foundation

/// Exam-center exports:
/// - 单场考试 `.ics` (reuses the ScheduleICSExporter helpers' conventions);
/// - 单场考试复习计划 Markdown;
/// - 一周学习安排 Markdown;
/// - 学习计划 JSON.
///
/// Provenance (source citations) rides along as text; internal file
/// paths, API keys, raw model requests and EventKit identifiers NEVER
/// appear in exports.
enum ExamExporter {

    // MARK: - Exam .ics

    /// One VEVENT per exam (title, time-or-day, location, scope in the
    /// description). Nil when the exam has no date.
    static func examICS(_ exam: Exam, courseName: String?) -> URL? {
        guard let day = exam.examDate else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let stamp = formatter.string(from: .now)

        let calendar = Calendar.current
        var startComponents = calendar.dateComponents([.year, .month, .day], from: day)
        if exam.startSecs >= 0 {
            startComponents.hour = exam.startSecs / 3600
            startComponents.minute = (exam.startSecs % 3600) / 60
        } else {
            startComponents.hour = 9
            startComponents.minute = 0
        }
        guard let start = calendar.date(from: startComponents) else { return nil }
        let duration = exam.endSecs > exam.startSecs && exam.startSecs >= 0
            ? TimeInterval(exam.endSecs - exam.startSecs)
            : 90 * 60
        let end = start.addingTimeInterval(duration)

        let localFormatter = DateFormatter()
        localFormatter.locale = Locale(identifier: "en_US_POSIX")
        localFormatter.timeZone = .current
        localFormatter.dateFormat = "yyyyMMdd'T'HHmmss"

        var summary = exam.title
        if let courseName, !courseName.isEmpty {
            summary = "\(courseName) · \(exam.title)"
        }
        var description = exam.scopeText
        if !exam.note.isEmpty {
            description = description.isEmpty ? exam.note : description + "\n" + exam.note
        }

        var lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//LiveTranslate//Exam//ZH",
            "CALSCALE:GREGORIAN",
            "BEGIN:VEVENT",
            "UID:livetranslate-exam-\(exam.id.uuidString)",
            "DTSTAMP:\(stamp)",
            "SUMMARY:\(icsEscape(summary))",
            "DTSTART:\(localFormatter.string(from: start))",
            "DTEND:\(localFormatter.string(from: end))",
        ]
        if !exam.location.isEmpty {
            lines.append("LOCATION:\(icsEscape(exam.location))")
        }
        if !description.isEmpty {
            lines.append("DESCRIPTION:\(icsEscape(description))")
        }
        lines.append("END:VEVENT")
        lines.append("END:VCALENDAR")

        let fileName = "LiveTranslate-考试-\(safeNameFragment(exam.title))-\(Int(Date().timeIntervalSince1970)).ics"
        guard let data = (lines.joined(separator: "\r\n") + "\r\n").data(using: .utf8) else {
            return nil
        }
        do {
            return try TemporaryExportStore().stage(fileName: fileName, data: data)
        } catch {
            return nil
        }
    }

    private static func icsEscape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    // MARK: - Exam plan Markdown

    /// 单场考试复习计划 Markdown：countdown, topics with self-ratings,
    /// the day-by-day plan, honest preparation numbers.
    static func examPlanMarkdown(
        exam: Exam,
        courseName: String?,
        topics: [ExamTopic],
        plan: StudyPlan?,
        items: [StudyPlanItem]
    ) -> URL? {
        var lines: [String] = ["# \(exam.title)", ""]
        if let courseName, !courseName.isEmpty {
            lines.append("课程：\(courseName)")
        }
        if let date = exam.examDate {
            lines.append("日期：\(date.formatted(date: .long, time: .omitted))\(exam.hasTime ? " \(timeLabel(exam))" : "")")
            if let days = exam.daysUntilExam {
                lines.append(days >= 0 ? "距考试还有 \(days) 天" : "考试已结束")
            }
        }
        if !exam.location.isEmpty { lines.append("地点：\(exam.location)") }
        if !exam.scopeText.isEmpty { lines.append(contentsOf: ["", "## 考试范围", "", exam.scopeText]) }

        if !topics.isEmpty {
            lines.append(contentsOf: ["", "## 知识主题", ""])
            for topic in topics {
                var marks = [topic.importance.displayName, topic.selfRating.displayName, topic.status.displayName]
                if let source = topic.source {
                    marks.append("来源：\(source.kind == .user ? "手动添加" : "AI 建议，已确认")")
                }
                lines.append("- \(topic.title)（\(marks.joined(separator: " · "))）")
            }
        }

        if let plan, !items.isEmpty {
            lines.append(contentsOf: ["", "## 学习计划（\(plan.status.displayName)）", ""])
            let grouped = Dictionary(grouping: items, by: \.itemDateKey)
            for dateKey in grouped.keys.sorted() {
                guard let date = Exam.parseDateKey(dateKey) else { continue }
                lines.append("### \(date.formatted(date: .abbreviated, time: .omitted))")
                for item in grouped[dateKey]!.sorted(by: { $0.itemOrder < $1.itemOrder }) {
                    let mark = item.status == .done ? "✅" : item.status == .skipped ? "⏭" : "•"
                    let actual = item.actualMinutes > 0 ? "（实际 \(item.actualMinutes) 分钟）" : ""
                    lines.append("- \(mark) \(item.title)（预计 \(item.estimatedMinutes) 分钟）\(actual)")
                }
                lines.append("")
            }
        }

        lines.append(contentsOf: ["", "---", "", "由 LiveTranslate 生成"])
        return writeMarkdown(lines, fileName: "LiveTranslate-复习计划-\(exam.title)")
    }

    /// 一周学习安排 Markdown (7 days from a start date).
    static func weekScheduleMarkdown(
        itemsByDate: [String: [StudyPlanItem]],
        startDate: Date,
        examTitles: (UUID) -> String?
    ) -> URL? {
        let calendar = Calendar.current
        var lines: [String] = ["# 一周学习安排", ""]
        for offset in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startDate) else { continue }
            let key = Exam.dateKey(day)
            lines.append("## \(day.formatted(.dateTime.weekday(.wide).day().month()))")
            let dayItems = itemsByDate[key] ?? []
            if dayItems.isEmpty {
                lines.append("- 无安排")
            } else {
                for item in dayItems.sorted(by: { $0.itemOrder < $1.itemOrder }) {
                    let examPart = item.examID.flatMap(examTitles).map { "【\($0)】" } ?? ""
                    lines.append("- \(examPart)\(item.title)（预计 \(item.estimatedMinutes) 分钟）")
                }
            }
            lines.append("")
        }
        lines.append(contentsOf: ["---", "", "由 LiveTranslate 生成"])
        return writeMarkdown(lines, fileName: "LiveTranslate-一周学习安排-\(Exam.dateKey(startDate))")
    }

    // MARK: - Plan JSON

    /// 学习计划 JSON (plan settings + items; source references are ids
    /// only — no file paths, no EventKit identifiers).
    static func planJSON(
        exam: Exam, plan: StudyPlan, items: [StudyPlanItem]
    ) -> URL? {
        struct ItemPayload: Codable {
            var id: UUID
            var date: String
            var title: String
            var kind: String
            var estimatedMinutes: Int
            var actualMinutes: Int
            var status: String
            var order: Int
        }
        struct PlanPayload: Codable {
            var exam: String
            var examDate: String
            var planID: UUID
            var title: String
            var startDate: String
            var endDate: String
            var weekdayMinutes: Int
            var weekendMinutes: Int
            var restDays: [Int]
            var finishEarlyDays: Int
            var status: String
            var items: [ItemPayload]
        }
        let payload = PlanPayload(
            exam: exam.title,
            examDate: exam.examDateKey,
            planID: plan.id,
            title: plan.title,
            startDate: plan.startDateKey,
            endDate: plan.endDateKey,
            weekdayMinutes: plan.weekdayMinutes,
            weekendMinutes: plan.weekendMinutes,
            restDays: plan.restDays,
            finishEarlyDays: plan.finishEarlyDays,
            status: plan.statusRaw,
            items: items.map {
                ItemPayload(
                    id: $0.id, date: $0.itemDateKey, title: $0.title,
                    kind: $0.kindRaw, estimatedMinutes: $0.estimatedMinutes,
                    actualMinutes: $0.actualMinutes, status: $0.statusRaw,
                    order: $0.itemOrder
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload) else { return nil }
        // Round 17: a receiver-meaningful date stamp instead of an
        // internal UUID fragment; the export rides the controlled store.
        let stamp = Self.planFileStamp.string(from: .now)
        do {
            return try TemporaryExportStore().stage(
                fileName: "LiveTranslate-学习计划-\(stamp).json", data: data
            )
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

    private static func timeLabel(_ exam: Exam) -> String {
        guard exam.startSecs >= 0 else { return "" }
        let hour = exam.startSecs / 3600
        let minute = (exam.startSecs % 3600) / 60
        var label = String(format: "%02d:%02d", hour, minute)
        if exam.endSecs > exam.startSecs {
            label += String(format: "–%02d:%02d", exam.endSecs / 3600, (exam.endSecs % 3600) / 60)
        }
        return label
    }

    private static func writeMarkdown(_ lines: [String], fileName: String) -> URL? {
        guard let data = lines.joined(separator: "\n").data(using: .utf8) else {
            return nil
        }
        return try? TemporaryExportStore().stage(fileName: fileName + ".md", data: data)
    }

    private static let planFileStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter
    }()

    /// File-system-safe export name fragment (round 17: exam titles with
    /// "/" used to silently break the export by naming a phantom
    /// subdirectory).
    static func safeNameFragment(_ raw: String) -> String {
        raw.replacingOccurrences(of: "[\\\\/:*?\"<>|\\s]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
