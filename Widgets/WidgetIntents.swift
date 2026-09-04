import Foundation
import AppIntents

// Widget / Live-Activity button intents — the ONLY code that runs in the
// extension process on user interaction. Two honest mechanisms:
//
// 1. NAVIGATION intents (openAppWhenRun = true): persist a
//    SystemRouteRequest in the App Group, then the system opens the app,
//    which consumes the route through the unified SystemRouteCoordinator.
//    Recording never starts from here — the start chain (permission,
//    resources, confirmation) lives in the app.
//
// 2. COMMAND intents (no app opening): enqueue a SystemCommand
//    (pause/resume) scoped to the session the snapshot reported, and post
//    the Darwin wake-up. The running app (kept alive by background audio)
//    consumes it against the real coordinator; if the app is gone, the
//    command expires honestly at the next foreground.
//
// Nothing here touches SwiftData, Keychain, ASR or the network.

// MARK: - Navigation intents

/// Opens the app and routes to one destination. Parameterized by a
/// raw-value route tag so a single intent type serves every static
/// destination (widgets pass the tag they render for).
struct OpenLiveTranslateRouteIntent: AppIntent {
    static let title: LocalizedStringResource = "打开 LiveTranslate"
    static let openAppWhenRun = true

    /// Destination tags mirroring SystemRouteRequest's static cases.
    enum Destination: String, AppEnum, CaseIterable {
        case currentClassroom
        case endClassroomConfirmation
        case todayStudy
        case inbox
        case captureBlackboard
        case nextClass
        case newSession

        static var typeDisplayRepresentation: TypeDisplayRepresentation {
            "目的地"
        }
        static var caseDisplayRepresentations: [Destination: DisplayRepresentation] = [
            .currentClassroom: "当前课堂",
            .endClassroomConfirmation: "结束课堂",
            .todayStudy: "今日学习",
            .inbox: "收件箱",
            .captureBlackboard: "拍黑板",
            .nextClass: "下一堂课",
            .newSession: "新建课堂"
        ]
    }

    @Parameter(title: "目的地")
    var destination: Destination

    init() {}

    init(destination: Destination) {
        self.destination = destination
    }

    func perform() async throws -> some IntentResult {
        let route: SystemRouteRequest = switch destination {
        case .currentClassroom: .currentClassroom
        case .endClassroomConfirmation: .endClassroomConfirmation
        case .todayStudy: .todayStudy
        case .inbox: .inbox(nil)
        case .captureBlackboard: .captureBlackboard
        case .nextClass: .nextClass
        case .newSession: .newSession
        }
        SystemRouteStore.push(route)
        return .result()
    }
}

/// Opens one classroom record / exam / material via its stable persisted
/// id (resolved honestly by the app; deleted targets get real feedback).
struct OpenEntityRouteIntent: AppIntent {
    static let title: LocalizedStringResource = "打开内容"
    static let openAppWhenRun = true

    enum EntityKind: String {
        case session, exam, material, course, planItem
    }

    @Parameter(title: "实体类型")
    var kindRaw: String

    @Parameter(title: "ID")
    var idString: String

    /// Optional material page.
    @Parameter(title: "页码")
    var page: Int?

    init() {}

    init(kind: EntityKind, id: UUID, page: Int? = nil) {
        self.kindRaw = kind.rawValue
        self.idString = id.uuidString
        self.page = page
    }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: idString) else { return .result() }
        let route: SystemRouteRequest = switch EntityKind(rawValue: kindRaw) {
        case .session: .session(id)
        case .exam: .exam(id)
        case .material: .material(id, page: page)
        case .course: .course(id)
        case .planItem: .planItem(id)
        case nil: .currentClassroom
        }
        SystemRouteStore.push(route)
        return .result()
    }
}

// MARK: - Classroom command intents (Live Activity buttons)

/// Pause the running classroom — a real command, validated by the app
/// against the live coordinator state.
struct PauseClassroomCommandIntent: AppIntent {
    static let title: LocalizedStringResource = "暂停课堂"

    init() {}

    func perform() async throws -> some IntentResult {
        guard let snapshot = currentSnapshot(),
              let classroom = snapshot.classroom else { return .result() }
        SystemCommandStore.enqueue(SystemCommand(
            id: UUID(),
            kind: .pauseClassroom,
            sessionID: classroom.sessionID,
            activityID: nil,
            scopeKey: snapshot.scopeKey,
            createdAt: .now
        ))
        return .result()
    }
}

/// Resume a paused classroom — real command, same validation.
struct ResumeClassroomCommandIntent: AppIntent {
    static let title: LocalizedStringResource = "继续课堂"

    init() {}

    func perform() async throws -> some IntentResult {
        guard let snapshot = currentSnapshot(),
              let classroom = snapshot.classroom else { return .result() }
        SystemCommandStore.enqueue(SystemCommand(
            id: UUID(),
            kind: .resumeClassroom,
            sessionID: classroom.sessionID,
            activityID: nil,
            scopeKey: snapshot.scopeKey,
            createdAt: .now
        ))
        return .result()
    }
}

// MARK: - Study command intents

struct PauseStudyCommandIntent: AppIntent {
    static let title: LocalizedStringResource = "暂停学习"

    init() {}

    func perform() async throws -> some IntentResult {
        guard let snapshot = currentSnapshot(),
              let study = snapshot.study else { return .result() }
        SystemCommandStore.enqueue(SystemCommand(
            id: UUID(),
            kind: .pauseStudy,
            sessionID: nil,
            activityID: study.activityID,
            scopeKey: snapshot.scopeKey,
            createdAt: .now
        ))
        return .result()
    }
}

struct ResumeStudyCommandIntent: AppIntent {
    static let title: LocalizedStringResource = "继续学习"

    init() {}

    func perform() async throws -> some IntentResult {
        guard let snapshot = currentSnapshot(),
              let study = snapshot.study else { return .result() }
        SystemCommandStore.enqueue(SystemCommand(
            id: UUID(),
            kind: .resumeStudy,
            sessionID: nil,
            activityID: study.activityID,
            scopeKey: snapshot.scopeKey,
            createdAt: .now
        ))
        return .result()
    }
}

// MARK: - Helpers

/// Reads the CURRENT profile's snapshot (scope-filtered) — the extension's
/// only source of live business state.
private func currentSnapshot() -> WidgetSnapshot? {
    let store = SystemSnapshotStore()
    let scope = SystemScope.currentScopeKey(defaults: SystemSnapshotStore.defaults)
    return store.load(activeScopeKey: scope)
}
