import Foundation
import Observation

/// Main-app facade over the shared inbox store: loads the CURRENT
/// profile's items, runs the inspect pass (local classification + AI
/// suggestions), and exposes the counts the entry points show. The store
/// itself is the App Group SharedInboxStore — the coordinator is rebuilt
/// on profile switches (it belongs to the AppEnvironment) but the store
/// and manifest are shared; items are filtered by the profile's scopeKey
/// (a share always belongs to the profile that was active when it
/// arrived; switching accounts never moves items).
@MainActor
@Observable
final class InboxCoordinator {
    /// nil = the App Group is unavailable (entitlement missing) — the UI
    /// honestly explains instead of showing a dead entry.
    private let store: SharedInboxStore?
    let scopeKey: String

    private(set) var items: [SharedInboxItem] = []
    private(set) var isLoaded = false
    private(set) var storeUnavailable = false

    /// Services read LIVE (settings changes rebuild them in place).
    private let imageServiceProvider: () -> (any AttachmentAnalysisModelService)?
    private let textServiceProvider: () -> (any StudyReviewModelService)?

    init(
        store: SharedInboxStore?,
        imageServiceProvider: @escaping () -> (any AttachmentAnalysisModelService)? = { nil },
        textServiceProvider: @escaping () -> (any StudyReviewModelService)? = { nil }
    ) {
        self.store = store
        self.scopeKey = store?.activeScope ?? SharedInboxScopeStore.guestScope
        self.imageServiceProvider = imageServiceProvider
        self.textServiceProvider = textServiceProvider
        self.storeUnavailable = store == nil
    }

    // MARK: - Loading

    func reload() {
        guard let store else {
            items = []
            isLoaded = true
            return
        }
        let manifest = store.loadManifest()
        items = manifest.items
            .filter { $0.scopeKey == scopeKey }
            .sorted { $0.receivedAt > $1.receivedAt }
        isLoaded = true
    }

    /// Launch / foreground reconciliation: interrupted transients roll
    /// back, missing payloads are marked failed, orphans are reaped.
    func reconcile() {
        store?.reconcile()
        reload()
    }

    // MARK: - Derived

    /// Items still needing the user's attention (home entry, badges).
    var pendingItems: [SharedInboxItem] {
        items.filter { $0.status.isPending }
    }

    var pendingCount: Int { pendingItems.count }

    var failedCount: Int {
        items.filter { $0.status == .failed }.count
    }

    func item(id: UUID) -> SharedInboxItem? {
        items.first { $0.id == id }
    }

    func statistics() -> SharedInboxStore.Statistics? {
        store?.statistics()
    }

    // MARK: - Inspect (local classification + AI suggestions)

    /// Runs the inspect pass for one item: deterministic classification
    /// always; AI actions when a model service is configured. The result
    /// (including an honest aiError) persists on the item — the user can
    /// close and come back without paying for another model call.
    /// `force` re-runs the AI pass on demand (重新识别).
    func inspect(
        itemID: UUID,
        courses: [(id: UUID, name: String, teacher: String)],
        force: Bool = false
    ) async {
        guard let store, let current = store.loadManifest().items.first(where: { $0.id == itemID })
        else { return }

        if !force, current.status != .received, current.status != .inspecting {
            // Already inspected — only re-run when the caller explicitly
            // refreshes.
            return
        }
        store.updateItem(id: itemID) { item in
            item.status = .inspecting
        }
        reload()

        var payload = InboxSuggestionPayload.decode(current.suggestionJSON) ?? InboxSuggestionPayload()
        // 1. Local, deterministic, explainable.
        let local = InboxClassifier.classify(item: current, courses: courses)
        payload.local = InboxLocalClassification(
            kindRaw: local.kind.rawValue,
            reason: local.reason,
            suggestedMaterialKindRaw: local.suggestedMaterialKindRaw,
            matchedCourseID: local.courseMatch?.courseID,
            matchedCourseName: local.courseMatch?.courseName,
            detectedDateText: local.detectedDateText
        )

        // 2. AI actions (optional; failure is recorded, not fatal).
        let imageService = imageServiceProvider()?.isConfiguredNow == true
            ? imageServiceProvider() : nil
        let textService = textServiceProvider()?.isConfiguredNow == true
            ? textServiceProvider() : nil
        if imageService == nil && textService == nil {
            payload.aiError = String(
                localized: "模型服务尚未配置——可手动归类，所有操作照常可用。",
                comment: "inbox ai"
            )
            payload.aiActions = []
            payload.aiRanAt = nil
        } else {
            let service = InboxSuggestionService(
                imageService: imageService, textService: textService
            )
            do {
                let result = try await service.suggest(
                    item: current,
                    payloadURL: store.payloadURL(for: current),
                    courseNames: courses.map(\.name),
                    referenceDate: current.receivedAt
                )
                // Resolve suggested course NAMES against the user's real
                // courses (exact match only — never a fuzzy guess).
                payload.aiActions = result.actions
                payload.aiMissingInfo = result.missingInfo
                payload.aiError = nil
                payload.aiRanAt = .now
            } catch {
                payload.aiError = (error as? LocalizedError)?.errorDescription
                    ?? String(localized: "识别未完成——可手动归类。", comment: "inbox ai")
                payload.aiActions = []
                payload.aiRanAt = .now
            }
        }

        if let json = payload.encodedJSON() {
            store.updateItem(id: itemID) { item in
                item.suggestionJSON = json
                item.status = .needsConfirmation
            }
        } else {
            store.updateItem(id: itemID) { item in
                item.status = .needsConfirmation
            }
        }
        reload()
    }

    /// Suggestion payload of one item (decoded; nil before inspection).
    func suggestions(for item: SharedInboxItem) -> InboxSuggestionPayload? {
        InboxSuggestionPayload.decode(item.suggestionJSON)
    }

    // MARK: - Selection / deletion lifecycle

    /// Persists the user's checkbox state for an item's actions.
    func updateSelection(itemID: UUID, selectedIDs: [UUID]) {
        guard let store,
              var payload = InboxSuggestionPayload.decode(
                  store.loadManifest().items.first { $0.id == itemID }?.suggestionJSON ?? ""
              )
        else { return }
        for index in payload.aiActions.indices {
            payload.aiActions[index].isSelected = selectedIDs.contains(payload.aiActions[index].id)
        }
        persistSuggestions(itemID: itemID, payload: payload)
    }

    /// Writes a suggestion payload (selection edits) back to the item.
    func persistSuggestions(itemID: UUID, payload: InboxSuggestionPayload) {
        guard let json = payload.encodedJSON() else { return }
        store?.updateItem(id: itemID) { item in
            item.suggestionJSON = json
            item.selectedOperationIDs = payload.aiActions
                .filter(\.isSelected)
                .map(\.id)
        }
        reload()
    }

    func deleteItems(ids: [UUID]) {
        store?.removeItems(ids: ids)
        reload()
    }

    func clearCompleted() {
        store?.removeCompletedItems()
        reload()
    }

    /// The staged payload URL (previews + import source). Views never
    /// build inbox paths themselves.
    func payloadURL(for item: SharedInboxItem) -> URL? {
        store?.payloadURL(for: item)
    }

    func payloadData(for item: SharedInboxItem) -> Data? {
        store?.payloadData(for: item)
    }
}

/// Local (deterministic) classification result persisted on the item.
struct InboxLocalClassification: Codable, Equatable, Sendable {
    var kindRaw: String
    var reason: String
    var suggestedMaterialKindRaw: String?
    var matchedCourseID: UUID?
    var matchedCourseName: String?
    var detectedDateText: String?

    var kind: InboxClassifier.Kind {
        InboxClassifier.Kind(rawValue: kindRaw) ?? .uncertain
    }
}
