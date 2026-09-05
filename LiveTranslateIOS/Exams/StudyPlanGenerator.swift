import Foundation

/// The deterministic, explainable study-plan algorithm (学习计划生成).
///
/// The model never schedules: AI only SUGGESTS topics and task wording;
/// concrete dates and capacities come from THIS code so every placement
/// can be explained ("周一容量 60 分钟，主题 A 占 45 分钟").
///
/// Inputs: the user's capacity settings, the exam's topics (importance +
/// self-rating + status), the course's materials (page counts), open
/// tasks with due dates, due-card counts, class occurrences (capacity
/// blocked by actual class time) and the plan's completion state.
///
/// Guarantees:
/// - nothing is scheduled in the past, on rest days, or over capacity
///   without the unplaced list saying so;
/// - the final day(s) before the exam are reserved for 考前最终复习;
/// - completed items and user-edited items are preserved on regeneration
///   (the caller keeps them; the generator only re-plans the rest);
/// - the output is a PREVIEW — nothing persists until the user saves.
enum StudyPlanGenerator {

    // MARK: - Inputs

    /// Everything the generator needs; every field is real data.
    struct Input {
        var exam: Exam
        var settings: StudyPlanDraft
        /// The exam's topics (focus first when planning study order).
        var topics: [ExamTopic]
        /// The course's materials (page counts → reading time).
        var materials: [(id: UUID, title: String, pageCount: Int)]
        /// Open tasks with due dates (kind `.task` items must land
        /// before their deadlines).
        var openTasks: [(id: UUID, title: String, dueAt: Date)]
        /// How many cards are currently due / will come due during the
        /// window (rough daily review load).
        var dueCardCount: Int
        /// The course's class occurrences inside the window (each blocks
        /// its duration from that day's capacity — 上课时间不是学习时间).
        var classOccurrences: [(start: Date, durationMinutes: Int)]
    }

    // MARK: - Output

    /// The generated preview: items + an honest unplaced list.
    struct Output {
        /// Planned items (NOT persisted — preview only).
        var items: [StudyPlanItemDraft]
        /// Work that did not fit — shown as 当前时间不足以完成全部内容.
        var unplaced: [String]
        /// Per-day capacity summary (the explainable schedule view).
        var daySummaries: [DaySummary]
        /// Total planned minutes.
        var totalPlannedMinutes: Int
    }

    struct DaySummary: Identifiable {
        var dateKey: String
        var date: Date
        var capacityMinutes: Int
        var plannedMinutes: Int
        var itemTitles: [String]

        var id: String { dateKey }
    }

    // MARK: - Tuning (explicit, explainable constants)

    /// Minutes per PDF page (conservative reading pace).
    static let minutesPerPage = 4
    /// Maximum contiguous study block; longer work is split.
    static let maxBlockMinutes = 45
    /// Reading 学习整理 (one classroom's AI review) estimate.
    static let reviewMinutes = 20
    /// Per-task completion estimate.
    static let taskMinutes = 30
    /// Daily card-review block when includeCards is on.
    static let cardsMinutes = 20
    /// Term-review block every termIntervalDays.
    static let termsMinutes = 15
    static let termIntervalDays = 3
    /// The 考前最终复习 block per reserved final day.
    static let finalReviewMinutes = 60
    /// Minimum leftover capacity worth filling with a small item.
    static let minUsableMinutes = 15

    // MARK: - Generation

    static func generate(_ input: Input, now: Date = .now) -> Output {
        let calendar = Calendar.current
        guard let examDate = input.exam.examDate else {
            return Output(items: [], unplaced: ["考试日期无效"], daySummaries: [], totalPlannedMinutes: 0)
        }

        // 1. Day list: from max(settings.start, today) to the exam date,
        //    excluding rest weekdays. The last `finishEarlyDays` days are
        //    reserved for final review (first pass must finish before).
        let today = calendar.startOfDay(for: now)
        let settingsStart = calendar.startOfDay(
            for: Exam.parseDateKey(input.settings.startDateKey) ?? today
        )
        let windowStart = max(settingsStart, today) // never in the past
        let restDays = Set(input.settings.restDays)

        var days: [PlanDay] = []
        var cursor = windowStart
        while cursor <= examDate {
            let weekday = calendar.component(.weekday, from: cursor)
            let isRest = restDays.contains(weekday)
            let isWeekend = weekday == 1 || weekday == 7
            let baseCapacity = isWeekend
                ? input.settings.weekendMinutes
                : input.settings.weekdayMinutes
            days.append(PlanDay(
                date: cursor,
                dateKey: Exam.dateKey(cursor),
                isRestDay: isRest,
                capacityMinutes: isRest ? 0 : baseCapacity
            ))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        // 2. Capacity reductions: class occurrences block their duration;
        //    blocked time-ranges subtract their minutes from that day.
        for occurrence in input.classOccurrences {
            let day = calendar.startOfDay(for: occurrence.start)
            guard let index = days.firstIndex(where: { $0.date == day }) else { continue }
            days[index].capacityMinutes = max(
                0, days[index].capacityMinutes - occurrence.durationMinutes
            )
        }
        let blocked = input.settings.blockedTimes
        if !blocked.isEmpty {
            for index in days.indices {
                let weekday = calendar.component(.weekday, from: days[index].date)
                let applicable = blocked.filter { $0.weekdays.isEmpty || $0.weekdays.contains(weekday) }
                // Split: the one-liner exceeds the type-checker's budget.
                var blockedMinutes = 0
                for block in applicable {
                    blockedMinutes += (block.endSecs - block.startSecs) / 60
                }
                days[index].capacityMinutes = max(0, days[index].capacityMinutes - blockedMinutes)
            }
        }

        // 3. Reserve final-review days (考试日期变化后重排由用户触发).
        let finishEarly = max(0, input.settings.finishEarlyDays)
        let firstPassDays = finishEarly >= days.count
            ? [] : Array(days.prefix(max(0, days.count - finishEarly)))
        let finalDays = finishEarly >= days.count ? days : Array(days.suffix(finishEarly))

        // 4. Work units in priority order:
        //    a. tasks with deadlines (must land before due);
        //    b. focus/high topics first pass (importance × self-rating);
        //    c. material reading chunks;
        //    d. classroom-review items;
        //    e. recurring cards/terms blocks.
        var queue: [WorkUnit] = []

        if input.settings.includeTasks {
            for task in input.openTasks {
                queue.append(WorkUnit(
                    title: "完成作业：\(task.title)",
                    kind: .task,
                    minutes: taskMinutes,
                    source: PlanItemSource(
                        materialID: nil, pageNumber: nil, sessionID: nil,
                        taskID: task.id, topicID: nil, courseID: nil, attachmentID: nil
                    ),
                    deadline: task.dueAt
                ))
            }
        }

        // Topics ordered: focus list first, then importance desc, then
        // weakest self-rating first.
        let focusIDs = Set(input.settings.focusTopics)
        let topics = input.topics
            .filter { $0.status != .mastered }
            .sorted { lhs, rhs in
                let lFocus = focusIDs.contains(lhs.id)
                let rFocus = focusIDs.contains(rhs.id)
                if lFocus != rFocus { return lFocus }
                if lhs.importance != rhs.importance { return lhs.importance == .high }
                return lhs.selfRating.rawValue < rhs.selfRating.rawValue
            }
        for topic in topics {
            let base: Int
            switch topic.importance {
            case .high: base = 90
            case .normal: base = 60
            case .low: base = 45
            }
            let multiplier: Double
            switch topic.selfRating {
            case .none: multiplier = 1.5
            case .vague: multiplier = 1.25
            case .basic: multiplier = 1.0
            case .proficient: multiplier = 0.5
            }
            let minutes = Int((Double(base) * multiplier / Double(maxBlockMinutes))
                .rounded(.up)) * maxBlockMinutes
            let needsSecond = topic.importance == .high || topic.importance == .normal
            queue.append(WorkUnit(
                title: "学习主题：\(topic.title)",
                kind: .topic,
                minutes: minutes,
                source: PlanItemSource(
                    materialID: nil, pageNumber: nil, sessionID: nil,
                    taskID: nil, topicID: topic.id, courseID: nil, attachmentID: nil
                ),
                deadline: nil
            ))
            if needsSecond {
                queue.append(WorkUnit(
                    title: "复习主题：\(topic.title)",
                    kind: .topic,
                    minutes: maxBlockMinutes,
                    source: PlanItemSource(
                        materialID: nil, pageNumber: nil, sessionID: nil,
                        taskID: nil, topicID: topic.id, courseID: nil, attachmentID: nil
                    ),
                    deadline: nil
                ))
            }
        }

        if input.settings.includeMaterials {
            for material in input.materials where material.pageCount > 0 {
                var page = 1
                let totalPages = material.pageCount
                while page <= totalPages {
                    let chunkPages = min(30, totalPages - page + 1)
                    let minutes = chunkPages * minutesPerPage
                    queue.append(WorkUnit(
                        title: "阅读《\(material.title)》第 \(page)–\(page + chunkPages - 1) 页",
                        kind: .material,
                        minutes: minutes,
                        source: PlanItemSource(
                            materialID: material.id, pageNumber: page, sessionID: nil,
                            taskID: nil, topicID: nil, courseID: nil, attachmentID: nil
                        ),
                        deadline: nil
                    ))
                    page += chunkPages
                }
            }
        }

        // 5. Place: deadline items first (before their due day), then the
        //    queue in order; split oversized units across days; small
        //    units need a day with enough room.
        var items: [StudyPlanItemDraft] = []
        var unplaced: [String] = []
        var order = 0

        func place(_ unit: WorkUnit) {
            var remaining = unit.minutes
            var deadlineKey: String? = nil
            if let deadline = unit.deadline {
                deadlineKey = Exam.dateKey(deadline)
            }
            var started = false
            for index in days.indices {
                guard remaining > 0 else { break }
                let day = days[index]
                if day.isRestDay { continue }
                if let deadlineKey, day.dateKey > deadlineKey { break }
                // Deadline units may not land on the final-review days
                // unless their deadline says otherwise; general units stay
                // in the first-pass window.
                let inFinalDays = finalDays.contains { $0.dateKey == day.dateKey }
                if inFinalDays && deadlineKey == nil { continue }

                let room = day.capacityMinutes - day.plannedMinutes
                guard room >= minUsableMinutes else { continue }
                let chunk = min(room, remaining, maxBlockMinutes)
                guard chunk >= minUsableMinutes else { continue }
                let title = unit.minutes > maxBlockMinutes && started
                    ? "\(unit.title)（续）"
                    : unit.title
                items.append(StudyPlanItemDraft(
                    planID: UUID(), // replaced by the real plan id at save
                    examID: input.exam.id,
                    itemDateKey: day.dateKey,
                    title: title,
                    kind: unit.kind,
                    estimatedMinutes: chunk,
                    itemOrder: order,
                    source: unit.source
                ))
                order += 1
                day.plannedMinutes += chunk
                remaining -= chunk
                started = true
            }
            if remaining > 0 {
                unplaced.append("\(unit.title)（剩余 \(remaining) 分钟无法安排）")
            }
        }

        // Deadline-bound first (tasks before their due dates).
        let deadlineUnits = queue.filter { $0.deadline != nil }
        let openUnits = queue.filter { $0.deadline == nil }
        for unit in deadlineUnits { place(unit) }
        for unit in openUnits { place(unit) }

        // 6. Recurring blocks: cards review every other day; terms every
        //    third day (only when capacity remains — never forced).
        if input.settings.includeCards {
            for (offset, index) in firstPassDays.indices.enumerated() {
                guard offset % 2 == 0 else { continue }
                let day = firstPassDays[index]
                guard !day.isRestDay,
                      day.capacityMinutes - day.plannedMinutes >= cardsMinutes else { continue }
                let title = input.dueCardCount > 0
                    ? "复习到期卡片（当前到期 \(input.dueCardCount) 张）"
                    : "复习卡片"
                items.append(StudyPlanItemDraft(
                    planID: UUID(),
                    examID: input.exam.id,
                    itemDateKey: day.dateKey,
                    title: title,
                    kind: .cards,
                    estimatedMinutes: cardsMinutes,
                    itemOrder: order,
                    source: PlanItemSource(
                        materialID: nil, pageNumber: nil, sessionID: nil,
                        taskID: nil, topicID: nil, courseID: input.exam.courseID, attachmentID: nil
                    )
                ))
                order += 1
                day.plannedMinutes += cardsMinutes
            }
            // Terms ride the card blocks' days (every third).
            for (offset, index) in firstPassDays.indices.enumerated() {
                guard offset % termIntervalDays == 0 else { continue }
                let day = firstPassDays[index]
                guard !day.isRestDay,
                      day.capacityMinutes - day.plannedMinutes >= termsMinutes else { continue }
                items.append(StudyPlanItemDraft(
                    planID: UUID(),
                    examID: input.exam.id,
                    itemDateKey: day.dateKey,
                    title: "复习术语",
                    kind: .terms,
                    estimatedMinutes: termsMinutes,
                    itemOrder: order,
                    source: PlanItemSource(
                        materialID: nil, pageNumber: nil, sessionID: nil,
                        taskID: nil, topicID: nil, courseID: input.exam.courseID, attachmentID: nil
                    )
                ))
                order += 1
                day.plannedMinutes += termsMinutes
            }
        }

        // 7. Final-review days: one consolidated block each (the exam's
        //    scope + focus topics — the explainable 考前复习).
        for day in finalDays where !day.isRestDay {
            let room = day.capacityMinutes - day.plannedMinutes
            guard room >= minUsableMinutes else {
                unplaced.append("考前复习（\(day.dateKey)）当天容量不足")
                continue
            }
            items.append(StudyPlanItemDraft(
                planID: UUID(),
                examID: input.exam.id,
                itemDateKey: day.dateKey,
                title: "考前最终复习" + (focusIDs.isEmpty ? "" : "：重点主题"),
                kind: .review,
                estimatedMinutes: min(room, finalReviewMinutes),
                itemOrder: order,
                source: PlanItemSource(
                    materialID: nil, pageNumber: nil, sessionID: nil,
                    taskID: nil, topicID: input.settings.focusTopics.first,
                    courseID: nil, attachmentID: nil
                )
            ))
            order += 1
            day.plannedMinutes += min(room, finalReviewMinutes)
        }

        // 8. Sort by date + order; build the explainable summaries.
        items.sort { lhs, rhs in
            if lhs.itemDateKey != rhs.itemDateKey { return lhs.itemDateKey < rhs.itemDateKey }
            return lhs.itemOrder < rhs.itemOrder
        }
        let summaries = days.map { day in
            DaySummary(
                dateKey: day.dateKey,
                date: day.date,
                capacityMinutes: day.capacityMinutes,
                plannedMinutes: day.plannedMinutes,
                itemTitles: items.filter { $0.itemDateKey == day.dateKey }.map(\.title)
            )
        }
        let total = items.reduce(0) { $0 + $1.estimatedMinutes }

        return Output(
            items: items,
            unplaced: unplaced,
            daySummaries: summaries,
            totalPlannedMinutes: total
        )
    }

    // MARK: - Replan diff

    /// What a regeneration changes (the preview before the user accepts).
    struct ReplanDiff {
        /// Items untouched by the replan: done/skipped/deferred-with-
        /// history and every user-edited row.
        var kept: [StudyPlanItem]
        /// Old pending, non-edited items the replan replaces.
        var replaced: [StudyPlanItem]
        /// New placements.
        var generated: [StudyPlanItemDraft]
        /// Work that no longer fits.
        var unplaced: [String]
    }

    /// Regenerates the schedule for an EXISTING plan: completed,
    /// skipped and user-edited items stay untouched; only pending,
    /// non-edited items are re-planned from today onward.
    static func regenerate(
        plan: StudyPlan, existingItems: [StudyPlanItem], input: Input, now: Date = .now
    ) -> ReplanDiff {
        let kept = existingItems.filter { item in
            item.userEdited
                || item.status == .done
                || item.status == .skipped
                || (item.status == .deferred && item.actualMinutes > 0)
        }
        let replaced = existingItems.filter { item in
            !kept.contains { $0.id == item.id }
        }
        var generatedInput = input
        generatedInput.settings.startDateKey = Exam.dateKey(now)
        let output = generate(generatedInput, now: now)
        return ReplanDiff(
            kept: kept,
            replaced: replaced,
            generated: output.items,
            unplaced: output.unplaced
        )
    }

    // MARK: - Internals

    private final class PlanDay {
        let date: Date
        let dateKey: String
        let isRestDay: Bool
        var capacityMinutes: Int
        var plannedMinutes = 0

        init(date: Date, dateKey: String, isRestDay: Bool, capacityMinutes: Int) {
            self.date = date
            self.dateKey = dateKey
            self.isRestDay = isRestDay
            self.capacityMinutes = capacityMinutes
        }
    }

    private struct WorkUnit {
        var title: String
        var kind: StudyPlanItemKind
        var minutes: Int
        var source: PlanItemSource
        var deadline: Date?
    }
}
