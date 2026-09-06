import Foundation

/// 办事事项的确定性日期/时间解析（本地规则 —— 无 AI、无网络也能从对
/// 话与文件分析中提取日期候选）。
///
/// 诚实原则：
/// - 解析结果只是候选 —— 只有用户确认后才成为可提醒时间；
/// - 原文（rawText）永远保留（"до пятницы" 不被翻译成"周五"就丢掉）；
/// - 相对日期以锚点（来源时间）+ 用户当前时区换算，并标记 isRelative；
/// - 过去日期绝不静默改到未来：按字面换算，UI 显示"该时间已过去"；
/// - 歧义（无前缀的"周四"、只有时间没有日期、DST 不存在/重复的本地
///   时间）一律 uncertain = true —— 不确定日期绝不自动调度提醒；
/// - 每个候选带可解释理由（本地规则只生成候选，必须显示理由）。
enum ErrandDateParser {
    /// 一个日期/时间候选。
    struct Candidate: Equatable, Sendable, Identifiable {
        var id: String { rawText }
        /// 原文（保留原样 —— 俄语原文不被替换）。
        var rawText: String
        /// 换算后的时刻（nil = 无法确定到时刻）。
        var resolved: Date?
        /// 是否为相对日期换算（明天/后天/через неделю…）。
        var isRelative: Bool
        /// 是否仍有歧义（无前缀星期、仅时间无日期、DST 边界…）。
        var uncertain: Bool
        /// 是否带具体时间（否则只有日期 —— UI 要求用户选时间或接受
        /// 标注清楚的本地默认值）。
        var hasTime: Bool
        /// 可解释理由（显示给用户）。
        var reason: String
    }

    // MARK: - 中文数字/星期映射

    private static let zhWeekdays: [String: Int] = [
        "一": 2, "二": 3, "三": 4, "四": 5, "五": 6, "六": 7, "日": 1, "天": 1
    ]
    private static let ruWeekdays: [String: Int] = [
        "понедельник": 2, "вторник": 3, "среду": 4, "среда": 4,
        "четверг": 5, "пятницу": 6, "пятница": 6,
        "субботу": 7, "суббота": 7, "воскресенье": 1
    ]
    private static let ruMonths: [String: Int] = [
        "января": 1, "февраля": 2, "марта": 3, "апреля": 4, "мая": 5,
        "июня": 6, "июля": 7, "августа": 8, "сентября": 9, "октября": 10,
        "ноября": 11, "декабря": 12
    ]

    // MARK: - 入口

    /// 从一段文本提取日期/时间候选（确定性规则；锚点 = 来源时间）。
    static func candidates(
        in text: String,
        anchor: Date = .now,
        calendar: Calendar = .current
    ) -> [Candidate] {
        var result: [Candidate] = []
        let lowered = text.lowercased()

        // --- 显式完整日期（中文）: 2026年9月10日 / 9月10日 / 9月10号 ---
        let zhFull = try? NSRegularExpression(pattern: #"(\d{4})\s*年\s*(\d{1,2})\s*月\s*(\d{1,2})\s*[日号期]?"#)
        let zhMonthDay = try? NSRegularExpression(pattern: #"(?<!\d)(\d{1,2})\s*月\s*(\d{1,2})\s*[日号期]"#)
        if let zhFull {
            for match in zhFull.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard match.numberOfRanges == 4,
                      let y = groupInt(match, at: 1, in: text),
                      let m = groupInt(match, at: 2, in: text),
                      let d = groupInt(match, at: 3, in: text),
                      (1...12).contains(m), (1...31).contains(d)
                else { continue }
                var comps = calendar.dateComponents([.year, .month, .day], from: anchor)
                comps.year = y; comps.month = m; comps.day = d
                if let date = calendar.date(from: comps) {
                    result.append(Candidate(
                        rawText: substring(match.range, in: text),
                        resolved: date, isRelative: false,
                        uncertain: date < anchor,
                        hasTime: false,
                        reason: "文本中的完整日期（\(y)年\(m)月\(d)日）"
                    ))
                }
            }
        }
        if let zhMonthDay {
            for match in zhMonthDay.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard match.numberOfRanges == 3,
                      let m = groupInt(match, at: 1, in: text),
                      let d = groupInt(match, at: 2, in: text),
                      (1...12).contains(m), (1...31).contains(d)
                else { continue }
                var comps = calendar.dateComponents([.year, .month, .day], from: anchor)
                comps.month = m; comps.day = d
                if let date = calendar.date(from: comps) {
                    // 年份缺省：换算到锚点年份；若已在过去，属于"可能指明年"
                    // 的歧义 —— 标记不确定，绝不静默改到未来。
                    result.append(Candidate(
                        rawText: substring(match.range, in: text),
                        resolved: date, isRelative: false,
                        uncertain: date < anchor,
                        hasTime: false,
                        reason: "文本中的日期（\(m)月\(d)日，年份按来源推断）"
                    ))
                }
            }
        }

        // --- 俄语月日: 10 сентября ---
        for (monthName, month) in ruMonths {
            let pattern = #"(?<!\d)(\d{1,2})\s*"# + monthName
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)) {
                guard let d = groupInt(match, at: 1, in: lowered),
                      (1...31).contains(d) else { continue }
                var comps = calendar.dateComponents([.year, .month, .day], from: anchor)
                comps.month = month; comps.day = d
                if let date = calendar.date(from: comps) {
                    result.append(Candidate(
                        rawText: substring(match.range, in: lowered),
                        resolved: date, isRelative: false,
                        uncertain: date < anchor,
                        hasTime: false,
                        reason: "Дата в тексте (\(d) \(monthName), год по контексту)"
                    ))
                }
            }
        }

        // --- 数字日期（俄语习惯）: 10.09 / 10.09.2026 ---
        if let dotDate = try? NSRegularExpression(pattern: #"(?<!\d)(\d{1,2})\.(\d{1,2})(?:\.(\d{2,4}))?(?!\d)"#) {
            for match in dotDate.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let d = groupInt(match, at: 1, in: text),
                      let m = groupInt(match, at: 2, in: text),
                      (1...12).contains(m), (1...31).contains(d) else { continue }
                var comps = calendar.dateComponents([.year, .month, .day], from: anchor)
                if match.numberOfRanges == 4, match.range(at: 3).location != NSNotFound,
                   let y = groupInt(match, at: 3, in: text) {
                    comps.year = y < 100 ? 2000 + y : y
                }
                comps.month = m; comps.day = d
                if let date = calendar.date(from: comps) {
                    result.append(Candidate(
                        rawText: substring(match.range, in: text),
                        resolved: date, isRelative: false,
                        uncertain: date < anchor,
                        hasTime: false,
                        reason: "Числовая дата в тексте (день.месяц)"
                    ))
                }
            }
        }

        // --- 中文相对日 ---
        let zhRelatives: [(String, Int, String)] = [
            ("大后天", 3, "相对日期：大后天（按来源时间换算）"),
            ("后天", 2, "相对日期：后天（按来源时间换算）"),
            ("明天", 1, "相对日期：明天（按来源时间换算）"),
            ("今天", 0, "相对日期：今天")
        ]
        for (word, offset, reason) in zhRelatives {
            if text.contains(word) {
                let date = calendar.date(byAdding: .day, value: offset, to: anchor) ?? anchor
                result.append(Candidate(
                    rawText: word, resolved: calendar.startOfDay(for: date),
                    isRelative: true, uncertain: false, hasTime: false, reason: reason
                ))
            }
        }
        if text.contains("下周") || lowered.contains("следующ") {
            let date = calendar.date(byAdding: .weekOfYear, value: 1, to: anchor) ?? anchor
            result.append(Candidate(
                rawText: text.contains("下周") ? "下周" : "следующая неделя",
                resolved: calendar.startOfDay(for: date),
                isRelative: true, uncertain: true, hasTime: false,
                reason: "相对日期：下周（具体哪一天需确认）"
            ))
        }

        // --- 俄语相对日 ---
        let ruRelatives: [(String, Int, String)] = [
            ("послезавтра", 2, "Относительная дата: послезавтра"),
            ("завтра", 1, "Относительная дата: завтра"),
            ("сегодня", 0, "Относительная дата: сегодня")
        ]
        for (word, offset, reason) in ruRelatives {
            if lowered.contains(word) {
                let date = calendar.date(byAdding: .day, value: offset, to: anchor) ?? anchor
                result.append(Candidate(
                    rawText: word, resolved: calendar.startOfDay(for: date),
                    isRelative: true, uncertain: false, hasTime: false, reason: reason
                ))
            }
        }
        if lowered.contains("через неделю") {
            let date = calendar.date(byAdding: .weekOfYear, value: 1, to: anchor) ?? anchor
            result.append(Candidate(
                rawText: "через неделю", resolved: calendar.startOfDay(for: date),
                isRelative: true, uncertain: false, hasTime: false,
                reason: "Относительная дата: через неделю"
            ))
        }

        // --- 中文星期（本周/下周前缀消歧；无前缀 = 歧义） ---
        if let zhWeek = try? NSRegularExpression(pattern: #"(本周|这周|下周|下下周)?周([一二三四五六日天])"#) {
            for match in zhWeek.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard match.numberOfRanges == 3,
                      let weekdayChar = groupString(match, at: 2, in: text),
                      let weekday = zhWeekdays[weekdayChar] else { continue }
                let prefix = match.range(at: 1).location == NSNotFound
                    ? nil : groupString(match, at: 1, in: text)
                var uncertain = false
                var days = weekday - calendar.component(.weekday, from: anchor)
                if let prefix {
                    if prefix == "下周" || prefix == "下下周" {
                        let weekOffset = prefix == "下周" ? 1 : 2
                        let currentWeekday = calendar.component(.weekday, from: anchor)
                        days = weekday - currentWeekday + 7 * weekOffset
                    }
                    if days <= 0 { days += 7 }
                } else {
                    // 无前缀的"周四"：可能指本周已过的周四，也可能指下周
                    // —— 取最近的未来，但标记歧义（不静默替用户决定）。
                    if days <= 0 { days += 7 }
                    uncertain = true
                }
                let date = calendar.date(byAdding: .day, value: days, to: anchor) ?? anchor
                result.append(Candidate(
                    rawText: substring(match.range, in: text),
                    resolved: calendar.startOfDay(for: date),
                    isRelative: true, uncertain: uncertain, hasTime: false,
                    reason: uncertain
                        ? "星期提及（未指明本周/下周 —— 取最近的未来，需确认）"
                        : "星期提及（\(prefix ?? "")周\(weekdayChar)）"
                ))
            }
        }

        // --- 俄语星期 ---
        for (word, weekday) in ruWeekdays {
            guard lowered.contains(word) else { continue }
            var days = weekday - calendar.component(.weekday, from: anchor)
            if days <= 0 { days += 7 }
            let date = calendar.date(byAdding: .day, value: days, to: anchor) ?? anchor
            result.append(Candidate(
                rawText: word, resolved: calendar.startOfDay(for: date),
                isRelative: true, uncertain: true, hasTime: false,
                reason: "День недели (без указания недели — ближайший будущий, требует подтверждения)"
            ))
        }

        // --- 时间（HH:MM 优先；其次中文时段点数；俄语 в Ч часа） ---
        var timeCandidates: [(text: String, hour: Int, minute: Int, reason: String)] = []
        if let hhmm = try? NSRegularExpression(pattern: #"(?<!\d)([01]?\d|2[0-3]):([0-5]\d)(?!\d)"#) {
            for match in hhmm.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let h = groupInt(match, at: 1, in: text),
                      let m = groupInt(match, at: 2, in: text) else { continue }
                timeCandidates.append((
                    substring(match.range, in: text), h, m, "文本中的时间（时:分）"
                ))
            }
        }
        if let zhHour = try? NSRegularExpression(pattern: #"(上午|早上|中午|下午|傍晚|晚上)?(\d{1,2})\s*[点时](半|三刻|\s*\d{1,2}\s*分?)?"#) {
            for match in zhHour.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard match.numberOfRanges == 4,
                      let h = groupInt(match, at: 2, in: text), (0...23).contains(h)
                else { continue }
                let period = match.range(at: 1).location == NSNotFound
                    ? nil : groupString(match, at: 1, in: text)
                var hour = h
                if period == "下午" || period == "傍晚" || period == "晚上" {
                    if h < 12 { hour = h + 12 }
                } else if period == "中午" {
                    hour = 12
                } else if period == nil, h <= 6 {
                    // 裸"6点"在办事语境里多半是下午 —— 标记歧义交给用户。
                    hour = h
                }
                var minute = 0
                if match.range(at: 3).location != NSNotFound {
                    let minutePart = groupString(match, at: 3, in: text) ?? ""
                    if minutePart.contains("半") { minute = 30 }
                    else if minutePart.contains("三刻") { minute = 45 }
                    else if let m = Int(minutePart.filter(\.isNumber)) { minute = min(m, 59) }
                }
                timeCandidates.append((
                    substring(match.range, in: text), hour, minute,
                    "文本中的时间（中文时段）"
                ))
            }
        }

        // --- 时间与最近的日期候选组合（同一短语内出现时） ---
        var combined: [Candidate] = []
        for dateCandidate in result {
            guard var dateComps = calendar.dateComponents(
                [.year, .month, .day], from: dateCandidate.resolved ?? anchor
            ) as DateComponents? else { continue }
            if let time = timeCandidates.first {
                dateComps.hour = time.hour
                dateComps.minute = time.minute
                // DST 边界：往返校验 —— 不存在/重复的本地时间会被 Calendar
                // 归一化，往返不一致即标记歧义。
                if let date = calendar.date(from: dateComps) {
                    let roundTrip = calendar.dateComponents(
                        [.year, .month, .day, .hour, .minute], from: date
                    )
                    let dstAmbiguous = roundTrip.hour != time.hour || roundTrip.minute != time.minute
                    combined.append(Candidate(
                        rawText: "\(dateCandidate.rawText) \(time.text)",
                        resolved: date,
                        isRelative: dateCandidate.isRelative,
                        uncertain: dateCandidate.uncertain || dstAmbiguous,
                        hasTime: true,
                        reason: dstAmbiguous
                            ? "日期 + 时间（夏令时边界时间不存在，已按本地规则归一 —— 需确认）"
                            : dateCandidate.reason + " + " + time.reason
                    ))
                }
            }
        }
        if !combined.isEmpty {
            result.append(contentsOf: combined)
        } else if !timeCandidates.isEmpty, result.isEmpty {
            // 只有时间没有日期：今天的该时刻；已过 = 可能指明天（歧义）。
            let time = timeCandidates[0]
            var comps = calendar.dateComponents([.year, .month, .day], from: anchor)
            comps.hour = time.hour; comps.minute = time.minute
            let today = calendar.date(from: comps)
            result.append(Candidate(
                rawText: time.text, resolved: today,
                isRelative: false, uncertain: today == nil || today! < anchor,
                hasTime: true,
                reason: "只有时间（日期缺省为今天；已过则需确认是否明天）"
            ))
        }

        // 去重（同原文取信息更全的一条）并按原文排序（稳定输出）。
        var best: [String: Candidate] = [:]
        for candidate in result {
            if let existing = best[candidate.rawText] {
                if !candidate.hasTime && existing.hasTime { continue }
                if candidate.uncertain && !existing.uncertain { continue }
            }
            best[candidate.rawText] = candidate
        }
        return best.values.sorted { $0.rawText < $1.rawText }
    }

    // MARK: - Helpers

    private static func groupInt(
        _ match: NSTextCheckingResult, at: Int, in text: String
    ) -> Int? {
        guard let value = groupString(match, at: at, in: text) else { return nil }
        return Int(value)
    }

    private static func groupString(
        _ match: NSTextCheckingResult, at: Int, in text: String
    ) -> String? {
        guard match.range(at: at).location != NSNotFound,
              let range = Range(match.range(at: at), in: text) else { return nil }
        return String(text[range])
    }

    private static func substring(_ nsRange: NSRange, in text: String) -> String {
        guard let range = Range(nsRange, in: text) else { return "" }
        return String(text[range])
    }
}
