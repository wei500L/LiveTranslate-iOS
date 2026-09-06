import Foundation
import OSLog

/// Unified system-route consumer — the single place widget taps, Live
/// Activity buttons, control-center tiles, Spotlight results, App Intents
/// and notification taps land. Each source only PRODUCES a
/// SystemRouteRequest (persisted in the App Group or passed directly);
/// this coordinator maps it onto the existing AppFlow pending-route
/// vocabulary (it never invents its own navigation) and consumes the
/// App-Group queue exactly once per entry.
///
/// Scope discipline: a route stamped with another profile's scope key is
/// dropped (never executed against the new profile). Deleted targets get
/// honest feedback — the target screens already render 来源已不存在 /
/// 计划不存在 style empty states when an id resolves to nothing.
@MainActor
final class SystemRouteCoordinator {
    private static let logger = Logger(
        subsystem: "com.livetranslate.ios", category: "system-route"
    )

    private let environment: AppEnvironment
    private let scopeKey: String
    private let routeStore: SystemRouteStore

    init(environment: AppEnvironment, scopeKey: String) {
        self.environment = environment
        self.scopeKey = scopeKey
        self.routeStore = SystemRouteStore()
    }

    // MARK: - Queue consumption

    /// Consume every pending App-Group route (launch + foreground entry +
    /// Darwin wake while running under background audio). Scope-filtered,
    /// expired-filtered, each entry consumed exactly once; last-wins
    /// navigation (AppFlow holds a single pending route at a time, and a
    /// navigation resets the previous).
    func consumePendingRoutes(now: Date = .now) {
        let entries = routeStore.loadQueue()
        guard !entries.isEmpty else { return }
        let live = entries.filter { entry in
            // 10 minutes: a much older "go somewhere" is no longer what
            // the user wants; the app opens at the default tab instead.
            entry.createdAt > now.addingTimeInterval(-10 * 60)
        }
        var matchedScope = live.filter { $0.scopeKey == scopeKey }
        // Entries of other scopes can never execute here either — drop
        // them all (consume-once, no re-running stale routes forever).
        if matchedScope.isEmpty {
            routeStore.replace([])
            return
        }
        // Consume all, navigate to the LAST (most recent tap wins).
        let target = matchedScope.removeLast().route
        routeStore.replace([])
        navigate(to: target)
        Self.logger.info("system route consumed")
    }

    // MARK: - Direct navigation (Spotlight / in-app intents)

    /// Map a route onto the EXISTING AppFlow vocabulary. Presentation
    /// order is deterministic: the live-classroom cover first (a classroom
    /// route), then the selected tab, whose screen consumes its pending
    /// route on appear.
    func navigate(to route: SystemRouteRequest) {
        let flow = environment.flow
        switch route {
        case .currentClassroom:
            if environment.coordinator.isRunning {
                environment.presentLive()
            } else {
                // Honest: no classroom to return to — land on home, where
                // the start card + ongoing banner live.
                flow.selectedTab = .home
            }
        case .endClassroomConfirmation:
            if environment.coordinator.isRunning {
                environment.presentLive()
                // The live screen observes this flag and presents the
                // existing end-confirmation dialog.
                flow.requestEndConfirmation()
            } else {
                flow.selectedTab = .home
            }
        case .nextClass:
            // Land on home: the next-class card (with its full controlled
            // start chain) is always present there.
            flow.selectedTab = .home
        case .newSession:
            flow.requestNewSessionForm()
        case .interpreter:
            flow.requestInterpreterScreen()
        case .captureBlackboard:
            if environment.coordinator.isRunning {
                environment.presentLive()
                flow.requestBlackboardCapture()
            } else {
                // No running classroom: the honest path is the start
                // flow — the camera lives INSIDE a classroom.
                flow.requestNewSessionForm()
            }
        case .todayStudy:
            flow.openStudyPlanReminder()
        case .session(let id):
            flow.openSessionDetail(id, in: environment)
        case .course(let id):
            flow.openCourseDetail(id, in: environment)
        case .material(let id, let page):
            flow.openMaterialDetail(id, page: page, in: environment)
        case .exam(let id):
            flow.openExamReminder(examID: id)
        case .planItem(let id):
            flow.openPlanDetail(id, in: environment)
        case .inbox(let itemID):
            flow.openInboxRoute(itemID: itemID)
        case .errandCaseList:
            flow.requestErrandCaseList()
        case .errandCase(let id):
            flow.openErrandCaseDetail(id, in: environment)
        }
    }
}

// MARK: - AppFlow additions (pending-route vocabulary)

/// Route parking the system layer adds to AppFlow — same consume-once
/// pattern as the notification reminder routes. The route coordinator
/// resolves EXISTENCE itself (honest feedback for deleted ids); the
/// screens only consume the ids.
extension AppFlow {
    /// A session detail push (Spotlight / widget / intent). Validates the
    /// id against the repository first — deleted targets never navigate.
    func openSessionDetail(_ id: UUID, in environment: AppEnvironment) {
        guard environment.repository.sessionSummary(id: id) != nil else {
            selectedTab = .records
            environment.reportMissingTarget("这堂课的记录已不存在")
            return
        }
        selectedTab = .records
        pendingSystemSessionID = id
    }

    func openCourseDetail(_ id: UUID, in environment: AppEnvironment) {
        guard ((try? environment.repository.course(id: id)) ?? nil) != nil else {
            selectedTab = .records
            environment.reportMissingTarget("这门课程已不存在")
            return
        }
        selectedTab = .records
        pendingSystemCourseID = id
    }

    func openMaterialDetail(_ id: UUID, page: Int?, in environment: AppEnvironment) {
        guard ((try? environment.repository.material(id: id)) ?? nil) != nil else {
            selectedTab = .records
            environment.reportMissingTarget("这份资料已不存在")
            return
        }
        selectedTab = .records
        pendingSystemMaterialID = id
        pendingSystemMaterialPage = page
    }

    func openPlanDetail(_ itemID: UUID, in environment: AppEnvironment) {
        guard let item = (try? environment.repository.studyPlanItem(id: itemID)) ?? nil else {
            openStudyPlanReminder()
            environment.reportMissingTarget("这个学习计划项已不存在")
            return
        }
        selectedTab = .review
        pendingSystemPlanID = item.planID
    }

    func openInboxRoute(itemID: UUID?) {
        selectedTab = .home
        if let itemID {
            pendingInboxItemID = itemID
        }
    }

    /// One errand case's detail (Spotlight / intent / widget tap).
    /// Validates the id against the repository first — deleted targets
    /// land on the errand list with honest feedback.
    func openErrandCaseDetail(_ id: UUID, in environment: AppEnvironment) {
        guard environment.repository.errandCase(id: id) != nil else {
            requestErrandCaseList()
            environment.reportMissingTarget("这个办事事项已不存在")
            return
        }
        selectedTab = .home
        pendingErrandCaseID = id
    }

    /// The errand-case list (a surface asked to show 办事事项 — navigation
    /// only, nothing is created or armed).
    func requestErrandCaseList() {
        selectedTab = .home
        pendingErrandCaseList = true
    }

    func consumeErrandCaseListRoute() {
        pendingErrandCaseList = false
    }

    var pendingErrandCaseList: Bool {
        get { systemRouteStorage.errandCaseList }
        set { systemRouteStorage.errandCaseList = newValue }
    }

    // MARK: Pending ids (consume-once, in-memory only)

    var pendingSystemSessionID: UUID? {
        get { systemRouteStorage.sessionID }
        set { systemRouteStorage.sessionID = newValue }
    }
    var pendingSystemCourseID: UUID? {
        get { systemRouteStorage.courseID }
        set { systemRouteStorage.courseID = newValue }
    }
    var pendingSystemMaterialID: UUID? {
        get { systemRouteStorage.materialID }
        set { systemRouteStorage.materialID = newValue }
    }
    var pendingSystemMaterialPage: Int? {
        get { systemRouteStorage.materialPage }
        set { systemRouteStorage.materialPage = newValue }
    }
    var pendingSystemPlanID: UUID? {
        get { systemRouteStorage.planID }
        set { systemRouteStorage.planID = newValue }
    }
}

/// Backing storage for the system-layer pending routes (kept in one
/// struct so the consume methods stay one-liners).
@MainActor
struct SystemRouteStorage {
    var sessionID: UUID?
    var courseID: UUID?
    var materialID: UUID?
    var materialPage: Int?
    var planID: UUID?
    var errandCaseList: Bool = false
}
