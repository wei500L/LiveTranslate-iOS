import Foundation

/// 确定性预分类 — the local, explainable first pass over an inbox item
/// BEFORE any model call. Pure function of the item's metadata (UTType
/// hints, file name, URL/text presence, obvious date wording) and the
/// user's own course/teacher names. It only PROPOSES a category — it
/// never creates anything, and uncertain stays uncertain.
enum InboxClassifier {
    /// The local category proposal.
    enum Kind: String, Codable, Sendable, Equatable {
        case material          // 课程资料 (pdf / text / md / other files)
        case classroomImage    // 课堂图片 (images from a class context)
        case examNotice        // 考试通知 (exam wording + date)
        case homework          // 作业 (assignment wording + deadline)
        case timetable         // 课程表 (schedule-looking image/text)
        case classNote         // 课堂笔记 (text worth keeping as a note)
        case webLink           // 网页链接 (URL-only content)
        case uncertain         // 尚不确定

        var displayName: String {
            switch self {
            case .material: return String(localized: "课程资料", comment: "inbox category")
            case .classroomImage: return String(localized: "课堂图片", comment: "inbox category")
            case .examNotice: return String(localized: "考试通知", comment: "inbox category")
            case .homework: return String(localized: "作业", comment: "inbox category")
            case .timetable: return String(localized: "课程表", comment: "inbox category")
            case .classNote: return String(localized: "课堂笔记", comment: "inbox category")
            case .webLink: return String(localized: "网页链接", comment: "inbox category")
            case .uncertain: return String(localized: "尚不确定", comment: "inbox category")
            }
        }

        var symbol: String {
            switch self {
            case .material: return "doc.richtext"
            case .classroomImage: return "photo"
            case .examNotice: return "exclamationmark.square"
            case .homework: return "checklist"
            case .timetable: return "calendar"
            case .classNote: return "note.text"
            case .webLink: return "link"
            case .uncertain: return "questionmark.square.dashed"
            }
        }
    }

    /// One course the item's names match (never auto-applied — the user
    /// confirms).
    struct CourseMatch: Equatable, Sendable {
        var courseID: UUID
        var courseName: String
        /// What matched (课程名 / 教师名), for the reason line.
        var matchedOn: String
    }

    struct Result: Equatable, Sendable {
        var kind: Kind
        /// Explainable, user-facing reason (规则可解释).
        var reason: String
        /// Suggested MaterialKind when the item looks like a material.
        var suggestedMaterialKindRaw: String?
        var courseMatch: CourseMatch?
        /// Obvious date/time wording found in the text (kept verbatim).
        var detectedDateText: String?
    }

    /// Classifies one item against the user's courses.
    ///
    /// - Parameter courses: (id, name, teacherName) of every course.
    static func classify(
        item: SharedInboxItem,
        courses: [(id: UUID, name: String, teacher: String)]
    ) -> Result {
        // 1. Course/teacher name matching runs on every label the item
        //    carries (file name, title, URL title, text prefix).
        let courseMatch = matchCourse(
            labels: [item.title, fileNameOnly(item), item.urlTitle,
                     String(item.textContent.prefix(400))],
            courses: courses
        )

        // 2. Obvious date wording in the text (дата / 日期 / deadline).
        let dateText = detectDateWording(in: item.textContent)

        switch item.payloadKind {
        case .url:
            var reason = "来自浏览器的链接分享"
            if let courseMatch {
                reason += "；提到「\(courseMatch.courseName)」（\(courseMatch.matchedOn)）"
            }
            if !item.textContent.isEmpty { reason += "；附有选中文本" }
            return Result(
                kind: .webLink,
                reason: reason,
                suggestedMaterialKindRaw: MaterialKind.reading.rawValue,
                courseMatch: courseMatch,
                detectedDateText: dateText
            )

        case .text:
            return classifyText(
                text: item.textContent, title: item.title,
                courseMatch: courseMatch, dateText: dateText
            )

        case .file:
            switch item.fileHints.family {
            case .image:
                // An image with timetable wording is likely a schedule
                // screenshot; with exam wording, an exam notice.
                if looksLikeTimetable(item.title, item.textContent) {
                    return Result(
                        kind: .timetable,
                        reason: "图片内容像课程表（\(item.title)）",
                        courseMatch: courseMatch,
                        detectedDateText: dateText
                    )
                }
                var reason = "分享的图片（\(item.fileHints.mimeType.isEmpty ? "图片" : item.fileHints.mimeType)）"
                if let courseMatch {
                    reason += "；提到「\(courseMatch.courseName)」（\(courseMatch.matchedOn)）"
                }
                // Images shared mid-class default to classroom-image
                // suggestions; the detail view lets the user pick
                // 资料 or 课堂图片.
                return Result(
                    kind: .classroomImage,
                    reason: reason,
                    suggestedMaterialKindRaw: nil,
                    courseMatch: courseMatch,
                    detectedDateText: dateText
                )
            case .pdf, .text, .markdown, .other:
                // Document-ish files are material candidates; kind hints
                // come from the file name.
                var reason = "分享的文件（\(item.fileHints.family == .pdf ? "PDF" : "文档")）"
                if let courseMatch {
                    reason += "；提到「\(courseMatch.courseName)」（\(courseMatch.matchedOn)）"
                }
                return Result(
                    kind: .material,
                    reason: reason,
                    suggestedMaterialKindRaw: suggestedKind(fileName: fileNameOnly(item)),
                    courseMatch: courseMatch,
                    detectedDateText: dateText
                )
            }
        }
    }

    // MARK: - Text classification

    private static func classifyText(
        text: String, title: String,
        courseMatch: CourseMatch?, dateText: String?
    ) -> Result {
        let lowered = text.lowercased()
        let examWording = ["экзамен", "зачёт", "зачет", "контрольная", "考试", "测验"]
            .contains { lowered.contains($0) }
        let homeworkWording = ["домашнее задание", "дз", "задачник", "作业", "习题"]
            .contains { lowered.contains($0) }
        let deadlineWording = ["до ", "сдать", "deadline", "截止", "下节课"]
            .contains { lowered.contains($0) }

        if examWording {
            return Result(
                kind: .examNotice,
                reason: "文本提到考试安排" + (dateText != nil ? "，且包含日期" : ""),
                suggestedMaterialKindRaw: MaterialKind.exam.rawValue,
                courseMatch: courseMatch,
                detectedDateText: dateText
            )
        }
        if homeworkWording || deadlineWording {
            return Result(
                kind: .homework,
                reason: "文本提到作业或截止时间",
                suggestedMaterialKindRaw: MaterialKind.homework.rawValue,
                courseMatch: courseMatch,
                detectedDateText: dateText
            )
        }
        if looksLikeTimetable(title, text) {
            return Result(
                kind: .timetable,
                reason: "文本内容像课程安排",
                courseMatch: courseMatch,
                detectedDateText: dateText
            )
        }
        // Long structured text is worth keeping as a note; short text
        // stays uncertain (the user decides).
        if text.count >= 40 {
            return Result(
                kind: .classNote,
                reason: "分享的文本内容（可存为笔记或资料）",
                suggestedMaterialKindRaw: MaterialKind.reading.rawValue,
                courseMatch: courseMatch,
                detectedDateText: dateText
            )
        }
        return Result(
            kind: .uncertain,
            reason: "内容较短，无法确定归类",
            suggestedMaterialKindRaw: nil,
            courseMatch: courseMatch,
            detectedDateText: dateText
        )
    }

    // MARK: - Helpers

    private static func fileNameOnly(_ item: SharedInboxItem) -> String {
        guard item.payloadKind == .file else { return "" }
        // The relative path ends in payload.<ext>; the original name was
        // kept in the title (base name) + hints extension.
        return item.title + (item.fileHints.fileExtension.isEmpty
            ? "" : ".\(item.fileHints.fileExtension)")
    }

    /// Course/teacher matching: the course name (or teacher surname)
    /// appears in one of the item's labels.
    static func matchCourse(
        labels: [String], courses: [(id: UUID, name: String, teacher: String)]
    ) -> CourseMatch? {
        let haystack = labels
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .lowercased()
        guard !haystack.isEmpty else { return nil }
        // Longest course name wins (高等数学 II beats 高等数学).
        for course in courses.sorted(by: { $0.name.count > $1.name.count }) {
            let name = course.name.trimmingCharacters(in: .whitespaces)
            guard name.count >= 2 else { continue }
            if haystack.contains(name.lowercased()) {
                return CourseMatch(courseID: course.id, courseName: course.name, matchedOn: "课程名")
            }
        }
        for course in courses {
            let teacher = course.teacher.trimmingCharacters(in: .whitespaces)
            // Match the first word of the teacher name (Иванова М.А. →
            // Иванова) — surnames are the stable part.
            guard let surname = teacher.split(separator: " ").first, surname.count >= 4 else { continue }
            if haystack.contains(teacher.lowercased())
                || haystack.contains(surname.lowercased()) {
                return CourseMatch(courseID: course.id, courseName: course.name, matchedOn: "教师名")
            }
        }
        return nil
    }

    /// Obvious date/time wording (kept verbatim, never resolved here —
    /// relative dates belong to the AI/parser layer and the user's eyes).
    static func detectDateWording(in text: String) -> String? {
        let patterns = [
            #"\d{1,2}[./]\d{1,2}([./]\d{2,4})?"#,          // 15.03 / 15/03/2026
            #"\d{4}-\d{2}-\d{2}"#,                          // 2026-03-15
            #"\d{1,2}月\d{1,2}日"#,                          // 3月15日
            #"(до|сдать|deadline|截止)[^。\n]{0,14}"#,       // до пятницы / 截止周五
            #"(本周|下周|下下周)[一二三四五六日天]"#,            // 下周三
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(
                   in: text, range: NSRange(text.startIndex..., in: text)
               ),
               let range = Range(match.range, in: text) {
                let found = String(text[range])
                if !found.trimmingCharacters(in: .whitespaces).isEmpty { return found }
            }
        }
        return nil
    }

    /// Timetable wording (расписание = schedule).
    static func looksLikeTimetable(_ title: String, _ text: String) -> Bool {
        let haystack = (title + "\n" + text).lowercased()
        return ["расписание", "课程表", "课表", "timetable"].contains {
            haystack.contains($0)
        }
    }

    /// MaterialKind hint from the file name (the same honest vocabulary
    /// as the import sheet's default).
    static func suggestedKind(fileName: String) -> String? {
        let lowered = fileName.lowercased()
        if lowered.contains("лекц") || lowered.contains("讲义") || lowered.contains("lecture") {
            return MaterialKind.lecture.rawValue
        }
        if lowered.contains("задач") || lowered.contains("习题") || lowered.contains("homework") {
            return MaterialKind.homework.rawValue
        }
        if lowered.contains("лаб") || lowered.contains("实验") || lowered.contains("lab") {
            return MaterialKind.lab.rawValue
        }
        if lowered.contains("экзамен") || lowered.contains("考试") || lowered.contains("exam") {
            return MaterialKind.exam.rawValue
        }
        return MaterialKind.other.rawValue
    }
}
