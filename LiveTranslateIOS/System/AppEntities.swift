import Foundation
import AppIntents

/// Lightweight App Entities for system interactions (Shortcuts
/// parameters, Spotlight handoff). They expose ONLY what a system
/// surface needs — a stable id, title, course name, date and a short
/// status — never transcripts, images, PDFs, API keys or the SwiftData
/// object graph. Queries resolve against the REAL repository; failures
/// return empty results, never fabricated sample data.

// MARK: - Course

struct CourseEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "课程"
    static let defaultQuery = CourseEntityQuery()

    let id: UUID
    let name: String
    let teacherName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    static func from(_ course: Course) -> CourseEntity {
        CourseEntity(id: course.id, name: course.name, teacherName: course.teacherName)
    }
}

struct CourseEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [CourseEntity] {
        let results = await AppIntentHost.withEnvironment { environment in
            identifiers.compactMap { id in
                (try? environment.repository.course(id: id)).flatMap { $0 }
            }
        }
        return (results ?? []).map(CourseEntity.from)
    }

    @MainActor
    func suggestedEntities() async throws -> [CourseEntity] {
        let results = await AppIntentHost.withEnvironment { environment in
            (try? environment.repository.courses()) ?? []
        }
        return (results ?? [])
            .filter { !$0.isArchived }
            .map(CourseEntity.from)
    }

    func defaultResult() async -> CourseEntity? { nil }
}

// MARK: - Exam

struct ExamEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "考试"
    static let defaultQuery = ExamEntityQuery()

    let id: UUID
    let title: String
    let courseName: String
    let examDate: Date?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }

    static func from(
        _ exam: Exam, courseName: String
    ) -> ExamEntity {
        ExamEntity(
            id: exam.id, title: exam.title,
            courseName: courseName, examDate: exam.examDate
        )
    }
}

struct ExamEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [ExamEntity] {
        let results = await AppIntentHost.withEnvironment { environment in
            identifiers.compactMap { id in
                (try? environment.repository.exam(id: id)).flatMap { $0 }
            }
        }
        guard let exams = results else { return [] }
        var entities: [ExamEntity] = []
        for exam in exams {
            entities.append(
                ExamEntity.from(exam, courseName: await courseName(of: exam))
            )
        }
        return entities
    }

    @MainActor
    func suggestedEntities() async throws -> [ExamEntity] {
        let results = await AppIntentHost.withEnvironment { environment in
            (try? environment.repository.exams(courseID: nil, includeCandidates: false)) ?? []
        }
        guard let exams = results else { return [] }
        var entities: [ExamEntity] = []
        for exam in exams.filter({ $0.status == .scheduled }).prefix(10) {
            entities.append(
                ExamEntity.from(exam, courseName: await courseName(of: exam))
            )
        }
        return entities
    }

    func defaultResult() async -> ExamEntity? { nil }

    @MainActor
    private func courseName(of exam: Exam) async -> String {
        let name = await AppIntentHost.withEnvironment { environment -> String in
            guard let courseID = exam.courseID else { return "" }
            return (try? environment.repository.course(id: courseID)).flatMap { $0 }?.name ?? ""
        }
        return name ?? ""
    }
}

// MARK: - Study plan item

struct StudyPlanItemEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "学习计划项"
    static let defaultQuery = StudyPlanItemEntityQuery()

    let id: UUID
    let title: String
    let courseName: String
    let dateKey: String
    let estimatedMinutes: Int
    let isDone: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

struct StudyPlanItemEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [StudyPlanItemEntity] {
        let results = await AppIntentHost.withEnvironment { environment in
            identifiers.compactMap { id in
                (try? environment.repository.studyPlanItem(id: id)).flatMap { $0 }
            }
        }
        return (results ?? []).map(StudyPlanItemEntity.init)
    }

    /// Today's undone items (the natural Shortcuts suggestions).
    @MainActor
    func suggestedEntities() async throws -> [StudyPlanItemEntity] {
        let results = await AppIntentHost.withEnvironment { environment in
            let todayKey = Exam.dateKey(.now)
            return (try? environment.repository.studyPlanItems(dateKey: todayKey)) ?? []
        }
        return (results ?? [])
            .filter { $0.status != .done && $0.status != .skipped }
            .map(StudyPlanItemEntity.init)
    }

    func defaultResult() async -> StudyPlanItemEntity? { nil }
}

private extension StudyPlanItemEntity {
    init(item: StudyPlanItem) {
        self.init(
            id: item.id,
            title: item.title,
            courseName: "",
            dateKey: item.itemDateKey,
            estimatedMinutes: item.estimatedMinutes,
            isDone: item.status == .done
        )
    }
}
