import Foundation

/// Student-facing exports of learning material: the course term book, the
/// study cards and the task list — Markdown/CSV/TSV/JSON shapes that map
/// onto how students actually reuse this data (notes, spreadsheets,
/// Anki-like card importers).
///
/// All content comes from REAL saved rows only — exports never call a
/// model and never fabricate data.
enum LearningExporter {

    // MARK: Term book

    /// 课程术语 Markdown.
    static func termsMarkdown(course: Course, terms: [GlossaryTerm]) -> String {
        var lines: [String] = []
        lines.append("# \(course.name) · 术语本")
        lines.append("")
        lines.append("> 共 \(terms.count) 个术语 · 导出于 \(Self.dateStamp())")
        lines.append("")
        for term in terms {
            var line = "- **\(term.russian)**"
            if !term.partOfSpeech.isEmpty { line += "（\(term.partOfSpeech)）" }
            line += " — \(term.chinese)"
            lines.append(line)
            if !term.explanation.isEmpty { lines.append("  - \(term.explanation)") }
            if !term.userNote.isEmpty { lines.append("  - 备注：\(term.userNote)") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 课程术语 CSV（俄语, 中文, 词性, 解释, 备注, 状态, 收藏）.
    static func termsCSV(course: Course, terms: [GlossaryTerm]) -> String {
        var rows: [String] = ["俄语,中文,词性,解释,备注,状态,收藏"]
        for term in terms {
            rows.append([
                term.russian, term.chinese, term.partOfSpeech,
                term.explanation, term.userNote,
                TermBookView.statusName(term.status),
                term.isFavorite ? "是" : "否",
            ].map(csvField).joined(separator: ","))
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: Study cards

    /// 学习卡片 TSV — the common card-importer shape:
    /// 正面<TAB>背面<TAB>课程<TAB>标签.
    static func cardsTSV(course: Course, cards: [StudyCard]) -> String {
        var rows: [String] = ["正面\t背面\t课程\t标签"]
        for card in cards {
            rows.append([
                card.front, card.back, course.name, card.type.displayName,
            ].map(tsvField).joined(separator: "\t"))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    /// 学习卡片 CSV.
    static func cardsCSV(course: Course, cards: [StudyCard]) -> String {
        var rows: [String] = ["正面,背面,类型,课程,备注,复习次数,阶段"]
        for card in cards {
            rows.append([
                card.front, card.back, card.type.displayName, course.name,
                card.userNote, "\(card.reviewCount)", card.stageRaw,
            ].map(csvField).joined(separator: ","))
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: Tasks

    /// 作业清单 Markdown.
    static func tasksMarkdown(course: Course, tasks: [StudyTask]) -> String {
        var lines: [String] = []
        lines.append("# \(course.name) · 作业清单")
        lines.append("")
        let open = tasks.filter { $0.status == .pending }
        let done = tasks.filter { $0.status == .done }
        lines.append("## 待完成（\(open.count)）")
        lines.append("")
        if open.isEmpty {
            lines.append("- （无）")
        }
        for task in open {
            lines.append(taskLine(task))
        }
        lines.append("")
        lines.append("## 已完成（\(done.count)）")
        lines.append("")
        for task in done {
            lines.append(taskLine(task))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func taskLine(_ task: StudyTask) -> String {
        var line = "- [\(task.status == .done ? "x" : " ")] \(task.title)"
        if let dueAt = task.dueAt {
            line += "（截止 \(dueAt.formatted(date: .abbreviated, time: .shortened))）"
        }
        if !task.detail.isEmpty { line += "\n  - \(task.detail)" }
        if !task.userNote.isEmpty { line += "\n  - 备注：\(task.userNote)" }
        return line
    }

    // MARK: Full learning material JSON

    /// 完整课程学习资料 JSON（terms + cards + tasks with their real
    /// scheduling state — a backup-quality snapshot, no prompts, no
    /// model outputs).
    static func fullJSON(course: Course, terms: [GlossaryTerm], cards: [StudyCard], tasks: [StudyTask]) -> String {
        struct TermDTO: Codable {
            var id: String; var russian: String; var chinese: String
            var explanation: String; var partOfSpeech: String; var userNote: String
            var courseID: String?; var isFavorite: Bool; var status: String
            var sourceSessionIDs: [String]; var createdAt: Date
        }
        struct CardDTO: Codable {
            var id: String; var front: String; var back: String; var type: String
            var origin: String; var userNote: String; var courseID: String?
            var sessionID: String?; var sourceTermID: String?
            var stage: String; var reviewCount: Int; var intervalHours: Int
            var dueAt: Date?; var lastReviewedAt: Date?; var lastGrade: String?
            var createdAt: Date
        }
        struct TaskDTO: Codable {
            var id: String; var title: String; var detail: String
            var priority: String; var status: String; var origin: String
            var uncertainty: String; var userNote: String
            var dueAt: Date?; var completedAt: Date?; var courseID: String?
            var sessionID: String?; var createdAt: Date
        }
        struct Payload: Codable {
            var schemaVersion: Int
            var exportedAt: Date
            var courseID: String
            var courseName: String
            var terms: [TermDTO]
            var cards: [CardDTO]
            var tasks: [TaskDTO]
        }
        let payload = Payload(
            schemaVersion: 1,
            exportedAt: .now,
            courseID: course.id.uuidString,
            courseName: course.name,
            terms: terms.map {
                TermDTO(
                    id: $0.id.uuidString, russian: $0.russian, chinese: $0.chinese,
                    explanation: $0.explanation, partOfSpeech: $0.partOfSpeech,
                    userNote: $0.userNote, courseID: $0.courseID?.uuidString,
                    isFavorite: $0.isFavorite, status: $0.statusRaw,
                    sourceSessionIDs: $0.sourceSessionIDs.map(\.uuidString),
                    createdAt: $0.createdAt
                )
            },
            cards: cards.map {
                CardDTO(
                    id: $0.id.uuidString, front: $0.front, back: $0.back,
                    type: $0.typeRaw, origin: $0.originRaw, userNote: $0.userNote,
                    courseID: $0.courseID?.uuidString, sessionID: $0.sessionID?.uuidString,
                    sourceTermID: $0.sourceTermID?.uuidString, stage: $0.stageRaw,
                    reviewCount: $0.reviewCount, intervalHours: $0.intervalHours,
                    dueAt: $0.dueAt, lastReviewedAt: $0.lastReviewedAt,
                    lastGrade: $0.lastGradeRaw.isEmpty ? nil : $0.lastGradeRaw,
                    createdAt: $0.createdAt
                )
            },
            tasks: tasks.map {
                TaskDTO(
                    id: $0.id.uuidString, title: $0.title, detail: $0.detail,
                    priority: $0.priorityRaw, status: $0.statusRaw, origin: $0.originRaw,
                    uncertainty: $0.uncertainty, userNote: $0.userNote,
                    dueAt: $0.dueAt, completedAt: $0.completedAt,
                    courseID: $0.courseID?.uuidString, sessionID: $0.sessionID?.uuidString,
                    createdAt: $0.createdAt
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: Temp files

    /// The student-facing learning export formats.
    enum LearningExportKind: String, CaseIterable, Identifiable {
        case termsMarkdown = "术语 Markdown"
        case termsCSV = "术语 CSV"
        case cardsTSV = "卡片 TSV"
        case cardsCSV = "卡片 CSV"
        case tasksMarkdown = "作业清单 Markdown"
        case fullJSON = "完整学习资料 JSON"

        var id: String { rawValue }
    }

    /// Renders one export kind and writes it to a temp file (nil on
    /// failure — the caller shows the honest failure alert).
    static func writeTemporaryFile(
        kind: LearningExportKind, course: Course,
        terms: [GlossaryTerm], cards: [StudyCard], tasks: [StudyTask]
    ) -> URL? {
        let content: String
        let fileName: String
        let safeName = course.name.replacingOccurrences(of: "/", with: "-")
        switch kind {
        case .termsMarkdown:
            content = termsMarkdown(course: course, terms: terms)
            fileName = "\(safeName)-术语.md"
        case .termsCSV:
            content = termsCSV(course: course, terms: terms)
            fileName = "\(safeName)-术语.csv"
        case .cardsTSV:
            content = cardsTSV(course: course, cards: cards)
            fileName = "\(safeName)-卡片.tsv"
        case .cardsCSV:
            content = cardsCSV(course: course, cards: cards)
            fileName = "\(safeName)-卡片.csv"
        case .tasksMarkdown:
            content = tasksMarkdown(course: course, tasks: tasks)
            fileName = "\(safeName)-作业清单.md"
        case .fullJSON:
            content = fullJSON(course: course, terms: terms, cards: cards, tasks: tasks)
            fileName = "\(safeName)-学习资料.json"
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(fileName)
        do {
            try content.data(using: .utf8)?.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    // MARK: Escaping

    /// CSV field: quoted when it contains a comma, quote or newline;
    /// embedded quotes doubled (RFC 4180).
    private static func csvField(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    /// TSV field: tabs and newlines collapse to spaces (a literal tab
    /// would break the column layout of every card importer).
    private static func tsvField(_ field: String) -> String {
        field
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private static func dateStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        return formatter.string(from: .now)
    }
}
