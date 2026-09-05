import Foundation
import CoreSpotlight
import UniformTypeIdentifiers
import OSLog

/// Core Spotlight indexing for the real library entities: Course,
/// ClassroomSession, CourseMaterial, Exam, StudyTask (and StudyPlanItem
/// as the review surface's jump target). Deliberately EXCLUDED:
/// transcripts, notes, OCR text, API keys, paths, unconfirmed inbox
/// candidates — Spotlight previews show titles, course names, dates and
/// a short non-sensitive summary only.
///
/// Lifecycle: index on entity mutation (via the mutation observer),
/// delete on entity deletion, clear on profile switch, batched full
/// rebuild. Failures never block repository saves (all calls are
/// fire-and-forget with logged errors).
///
/// Routing: no custom URL scheme — items carry a CSSearchableItem
/// activity identifier the app resolves through the unified
/// SystemRouteCoordinator on `NSUserActivityType` / Spotlight
/// continuation.
@MainActor
enum SpotlightEntityKind: String, CaseIterable, Sendable {
    case course = "course"
    case session = "session"
    case material = "material"
    case exam = "exam"
    case task = "task"
    case planItem = "planItem"

    /// Domain identifier (namespaces the index per entity type).
    var domain: String { "com.livetranslate.ios.spotlight.\(rawValue)" }

    /// Stable item identifier: "kind:<uuid>" — the routing key.
    static func identifier(kind: SpotlightEntityKind, id: UUID) -> String {
        "\(kind.rawValue):\(id.uuidString)"
    }
}

@MainActor
final class SpotlightIndexer {
    private static let logger = Logger(
        subsystem: "com.livetranslate.ios", category: "spotlight"
    )
    /// Identifier prefix recognized on Spotlight continuation.
    static let activityType = "com.livetranslate.ios.spotlight"

    // MARK: - Routing

    /// Parse a Spotlight item identifier back into a route. Nil when the
    /// identifier is not ours (foreign identifiers are ignored).
    static func route(forIdentifier identifier: String) -> SystemRouteRequest? {
        let parts = identifier.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let kind = SpotlightEntityKind(rawValue: String(parts[0])),
              let id = UUID(uuidString: String(parts[1])) else { return nil }
        switch kind {
        case .course: return .course(id)
        case .session: return .session(id)
        case .material: return .material(id, page: nil)
        case .exam: return .exam(id)
        case .task: return .inbox(nil)
        case .planItem: return .planItem(id)
        }
    }

    // MARK: - Indexing (single entity)

    func index(
        id: UUID, kind: SpotlightEntityKind,
        repository: any ClassroomRepositoryProtocol, scopeKey: String
    ) {
        guard let item = buildItem(id: id, kind: kind, repository: repository) else { return }
        CSSearchableIndex.default().indexSearchableItems([item]) { error in
            if let error {
                Self.logger.info("spotlight index failed: \(error.localizedDescription)")
            }
        }
    }

    func remove(id: UUID, kind: SpotlightEntityKind) {
        let identifier = SpotlightEntityKind.identifier(kind: kind, id: id)
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: [identifier]) { error in
            if let error {
                Self.logger.info("spotlight delete failed: \(error.localizedDescription)")
            }
        }
    }

    /// Profile switch / account removal: the old scope's entries leave
    /// the system index (deleting by domain covers every entity type).
    func deactivate() {
        let index = CSSearchableIndex.default()
        for kind in SpotlightEntityKind.allCases {
            index.deleteSearchableItems(withDomainIdentifiers: [kind.domain]) { error in
                if let error {
                    Self.logger.info("spotlight deactivate failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Full rebuild, batched (the spec's "全量重建必须分批"). Rare: after a
    /// full sync pull or data restore.
    func rebuildAll(
        repository: any ClassroomRepositoryProtocol, scopeKey: String
    ) {
        deactivate()
        Task { [weak self] in
            guard let self else { return }
            // Batches of ~50 items per index call, one kind at a time —
            // a multi-thousand-row store never blocks on one giant call.
            var batch: [CSSearchableItem] = []
            func flush() {
                guard !batch.isEmpty else { return }
                let items = batch
                batch = []
                CSSearchableIndex.default().indexSearchableItems(items) { error in
                    if let error {
                        Self.logger.info("spotlight rebuild batch failed: \(error.localizedDescription)")
                    }
                }
            }
            let courses = (try? repository.courses()) ?? []
            for course in courses {
                if let item = self.item(for: .course, course: course) { batch.append(item); if batch.count >= 50 { flush() } }
            }
            let sessions = (try? repository.sessions(matching: "")) ?? []
            for session in sessions {
                // Lightweight summary only — entries never load here.
                let summary = SessionSummary(
                    id: session.id,
                    title: session.title,
                    startTime: session.startTime,
                    entryCount: session.entryCount
                )
                if let item = self.sessionItem(summary: summary, id: session.id) { batch.append(item); if batch.count >= 50 { flush() } }
            }
            let materials = (try? repository.materials(courseID: nil)) ?? []
            for material in materials {
                if let item = self.item(for: .material, material: material) { batch.append(item); if batch.count >= 50 { flush() } }
            }
            let exams = (try? repository.exams(courseID: nil, includeCandidates: false)) ?? []
            for exam in exams {
                if let item = self.item(for: .exam, exam: exam, repository: repository) { batch.append(item); if batch.count >= 50 { flush() } }
            }
            let tasks = (try? repository.tasks(courseID: nil, includeDone: true)) ?? []
            for task in tasks where task.status != .pendingConfirm {
                if let item = self.item(for: .task, task: task, repository: repository) { batch.append(item); if batch.count >= 50 { flush() } }
            }
            flush()
        }
    }

    // MARK: - Item assembly (non-sensitive fields only)

    private func buildItem(
        id: UUID, kind: SpotlightEntityKind,
        repository: any ClassroomRepositoryProtocol
    ) -> CSSearchableItem? {
        switch kind {
        case .course:
            guard let course = try? repository.course(id: id) else { return nil }
            return item(for: .course, course: course)
        case .session:
            guard let summary = repository.sessionSummary(id: id) else { return nil }
            return sessionItem(summary: summary, id: id)
        case .material:
            guard let material = try? repository.material(id: id) else { return nil }
            return item(for: .material, material: material)
        case .exam:
            guard let exam = try? repository.exam(id: id) else { return nil }
            return item(for: .exam, exam: exam, repository: repository)
        case .task:
            guard let task = try? repository.tasks(matching: id.uuidString).first,
                  task.id == id else { return nil }
            return item(for: .task, task: task, repository: repository)
        case .planItem:
            // Plan items surface via in-app search; plan-item indexing is
            // intentionally skipped (keeps the system index lean).
            return nil
        }
    }

    /// Session indexing works off the lightweight summary (title, course
    /// name, duration, entry count) — never the entries.
    private func sessionItem(
        summary: SessionSummary, id: UUID
    ) -> CSSearchableItem? {
        let attributes = CSSearchableItemAttributeSet(contentType: UTType.item)
        attributes.title = summary.title
        attributes.contentCreationDate = summary.startTime
        return CSSearchableItem(
            uniqueIdentifier: SpotlightEntityKind.identifier(kind: .session, id: id),
            domainIdentifier: SpotlightEntityKind.session.domain,
            attributeSet: attributes
        )
    }

    private func item(for kind: SpotlightEntityKind, course: Course) -> CSSearchableItem? {
        let attributes = CSSearchableItemAttributeSet(contentType: UTType.item)
        attributes.title = course.name
        attributes.contentDescription = courseDescription(course)
        attributes.keywords = nonEmpty([course.teacherName, course.location])
        return CSSearchableItem(
            uniqueIdentifier: SpotlightEntityKind.identifier(kind: kind, id: course.id),
            domainIdentifier: kind.domain,
            attributeSet: attributes
        )
    }

    private func item(for kind: SpotlightEntityKind, material: CourseMaterial) -> CSSearchableItem? {
        let attributes = CSSearchableItemAttributeSet(contentType: UTType.item)
        attributes.title = material.title
        attributes.contentDescription = materialDescription(material)
        return CSSearchableItem(
            uniqueIdentifier: SpotlightEntityKind.identifier(kind: kind, id: material.id),
            domainIdentifier: kind.domain,
            attributeSet: attributes
        )
    }

    private func item(
        for kind: SpotlightEntityKind, exam: Exam,
        repository: any ClassroomRepositoryProtocol
    ) -> CSSearchableItem? {
        let attributes = CSSearchableItemAttributeSet(contentType: UTType.item)
        attributes.title = exam.title
        attributes.contentDescription = examDescription(exam, repository: repository)
        return CSSearchableItem(
            uniqueIdentifier: SpotlightEntityKind.identifier(kind: kind, id: exam.id),
            domainIdentifier: kind.domain,
            attributeSet: attributes
        )
    }

    private func item(
        for kind: SpotlightEntityKind, task: StudyTask,
        repository: any ClassroomRepositoryProtocol
    ) -> CSSearchableItem? {
        guard task.status != .pendingConfirm else { return nil }
        let attributes = CSSearchableItemAttributeSet(contentType: UTType.item)
        attributes.title = task.title
        attributes.contentDescription = taskDescription(task)
        let item = CSSearchableItem(
            uniqueIdentifier: SpotlightEntityKind.identifier(kind: kind, id: task.id),
            domainIdentifier: kind.domain,
            attributeSet: attributes
        )
        // A due task stops surfacing in Spotlight once it is over due —
        // the item-level expiration (the attribute-set date was removed
        // from the SDK).
        if let dueAt = task.dueAt { item.expirationDate = dueAt }
        return item
    }

    // MARK: - Descriptions (short, non-sensitive)

    private func courseDescription(_ course: Course) -> String {
        var parts: [String] = []
        if !course.teacherName.isEmpty { parts.append("教师 \(course.teacherName)") }
        if !course.location.isEmpty { parts.append(course.location) }
        return parts.isEmpty ? "课程" : parts.joined(separator: " · ")
    }

    private func materialDescription(_ material: CourseMaterial) -> String {
        var parts: [String] = ["\(material.kind.displayName)资料"]
        if material.pageCount > 0 { parts.append("\(material.pageCount) 页") }
        return parts.joined(separator: " · ")
    }

    private func examDescription(
        _ exam: Exam, repository: any ClassroomRepositoryProtocol
    ) -> String {
        var parts: [String] = [exam.kind.displayName]
        if let date = exam.examDate {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "M月d日"
            parts.append(formatter.string(from: date))
        }
        if let courseID = exam.courseID,
           let course = try? repository.course(id: courseID) {
            parts.append(course.name)
        }
        return parts.joined(separator: " · ")
    }

    private func taskDescription(_ task: StudyTask) -> String {
        var parts: [String] = ["待办"]
        if let dueAt = task.dueAt {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "M月d日"
            parts.append(formatter.string(from: dueAt))
        }
        return parts.joined(separator: " · ")
    }

    private func nonEmpty(_ values: [String]) -> [String] {
        values.filter { !$0.isEmpty }
    }
}
