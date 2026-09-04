import Foundation

// Shared-inbox data model — the ONLY types compiled into BOTH the main
// app and the Share Extension target (SharedInboxKit). The kit is
// deliberately dependency-free (Foundation only — no SwiftData, no
// SwiftUI, no networking): the extension must be able to receive content
// without touching the app's stack, and the app must organize it
// afterwards against the same on-disk contract.
//
// Storage boundary (see SharedInboxStore): an App Group container with a
// versioned manifest + per-item payload directories. Inbox items are
// DEVICE-LOCAL: they never enter SwiftData, never reach the sync outbox,
// and never touch the server. Only after the user confirms do the
// resulting formal entities (material / exam candidate / task candidate /
// schedule / note / attachment) join the normal sync chains.

// MARK: - Payload kinds

/// What one inbox item physically carries.
enum SharedInboxPayloadKind: String, Codable, Sendable, Equatable {
    /// A staged file (PDF / image / TXT / Markdown / any other file the
    /// system handed the extension — bytes live under the item directory).
    case file
    /// Pure shared text (no file).
    case text
    /// A shared URL (optionally with the page title and/or the sender's
    /// selected text — both are preserved).
    case url
}

/// File classification hints captured at receive time (UTType/MIME/
/// extension — the same three signals the material pipeline uses; never
/// the extension alone).
struct SharedInboxFileHints: Codable, Sendable, Equatable {
    var mimeType: String = ""
    /// UTType identifier ("" when unknown).
    var utTypeIdentifier: String = ""
    /// Lower-cased file extension as received ("" when none).
    var fileExtension: String = ""
    /// Coarse content family used by list rows and local pre-classification.
    var family: FileFamily = .other

    enum FileFamily: String, Codable, Sendable, Equatable {
        case pdf
        case image
        case text
        case markdown
        case other
    }
}

// MARK: - Item

/// One received share. Metadata lives in the manifest; bytes (if any)
/// live in the item's payload directory. Everything the organizing UI
/// needs to make a decision rides here — the file itself is only needed
/// for previews and the eventual formal import.
struct SharedInboxItem: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var receivedAt: Date
    /// Owning local profile at the moment the share ARRIVED: "guest" or
    /// an account UUID string (non-sensitive — never an email or token).
    /// Items are never moved between scopes automatically.
    var scopeKey: String
    /// The sharing app's bundle identifier ("" when unavailable).
    var sourceBundleID: String = ""
    /// A short display label for the source (e.g. "Safari", "Telegram").
    var sourceDisplayName: String = ""

    // Content
    var payloadKind: SharedInboxPayloadKind
    /// Original file name / page title / first line of shared text — the
    /// primary row label. Never empty for a well-formed item.
    var title: String = ""
    /// File-only hints (empty strings elsewhere).
    var fileHints: SharedInboxFileHints = SharedInboxFileHints()
    /// Staged file size in bytes (0 for text/url).
    var fileSize: Int64 = 0
    /// SHA-256 hex of the staged bytes ("" for text/url). Same-bytes ≠
    /// same business meaning: duplicates are SURFACED, never dropped.
    var contentHash: String = ""
    /// File name relative to the store's items root ("" for text/url).
    var relativeFilePath: String = ""
    /// Shared text (kind .text), or the sender's selected text that
    /// accompanied a URL (kind .url). Bounded at receive time.
    var textContent: String = ""
    /// The shared URL absolute string (kind .url only).
    var url: String = ""
    /// System-provided page title for URL shares ("" when none).
    var urlTitle: String = ""

    // Lifecycle
    var status: SharedInboxItemStatus = .received
    /// Human-readable failure reason ("" = none). Kept small — this is a
    /// summary, not a log.
    var errorSummary: String = ""
    /// Local pre-classification + AI suggestions as JSON (written by the
    /// app's inspect pass; "" before inspection). The payload is
    /// versioned by InboxSuggestionPayload.
    var suggestionJSON: String = ""
    /// Idempotency ledger: every CONFIRMED action records its operation
    /// id here the moment it succeeds, so a retry / relaunch never
    /// duplicates a formal entity.
    var completedOperations: [SharedInboxOperationRecord] = []
    /// Which suggested actions the user selected during the current
    /// processing round (operation ids; consumed by the executor).
    var selectedOperationIDs: [UUID] = []

    init(
        id: UUID = UUID(),
        receivedAt: Date = .now,
        scopeKey: String,
        payloadKind: SharedInboxPayloadKind,
        title: String
    ) {
        self.id = id
        self.receivedAt = receivedAt
        self.scopeKey = scopeKey
        self.payloadKind = payloadKind
        self.title = title
    }
}

// MARK: - Status

/// Inbox item lifecycle.
///
///     received → inspecting → needsConfirmation → processing
///                                                    ├→ completed
///                                                    ├→ partiallyProcessed → (retry) processing
///                                                    └→ failed
///
/// `inspecting`/`processing` are transient on-disk markers: at launch the
/// app reconciles any item stuck in them back to a safe state
/// (needsConfirmation / partiallyProcessed) — never silently re-runs
/// actions (the operation ledger keeps confirmed work idempotent).
enum SharedInboxItemStatus: String, Codable, Sendable, Equatable {
    case received
    case inspecting
    case needsConfirmation
    case processing
    case partiallyProcessed
    case completed
    case failed

    var displayName: String {
        switch self {
        case .received: return String(localized: "待整理", comment: "inbox status")
        case .inspecting: return String(localized: "识别中", comment: "inbox status")
        case .needsConfirmation: return String(localized: "待确认", comment: "inbox status")
        case .processing: return String(localized: "正在导入", comment: "inbox status")
        case .partiallyProcessed: return String(localized: "部分完成", comment: "inbox status")
        case .completed: return String(localized: "已完成", comment: "inbox status")
        case .failed: return String(localized: "失败", comment: "inbox status")
        }
    }

    /// Whether the item still needs user attention.
    var isPending: Bool {
        switch self {
        case .received, .inspecting, .needsConfirmation, .failed: return true
        case .processing, .partiallyProcessed, .completed: return false
        }
    }
}

// MARK: - Operation ledger

/// One confirmed-and-executed action. Written to the manifest IMMEDIATELY
/// after the action succeeds, before the next action starts — a kill
/// mid-batch resumes with the successes already accounted for.
struct SharedInboxOperationRecord: Codable, Equatable, Sendable, Identifiable {
    /// The suggested action's stable operation id (idempotency key).
    var id: UUID
    /// Raw value of SharedInboxActionKind (kept as a string so old
    /// manifests survive new action kinds).
    var kindRaw: String
    /// When the action completed.
    var finishedAt: Date
    /// The formal entity the action created (e.g. the material id) —
    /// shown in the item detail as the real, tappable outcome.
    var resultingEntityID: UUID?
    /// Short display label for the ledger row.
    var label: String = ""
}

/// Action kinds (mirrored as a string in the ledger records). The enum
/// lives in the app-side inbox layer; the shared kit only persists the
/// raw value.
enum SharedInboxActionKindRaw {
    static let saveAsMaterial = "saveAsMaterial"
    static let linkAsMaterial = "linkAsMaterial"
    static let attachToSession = "attachToSession"
    static let createExamCandidate = "createExamCandidate"
    static let createTaskCandidate = "createTaskCandidate"
    static let importSchedule = "importSchedule"
    static let saveAsNote = "saveAsNote"
}

// MARK: - Scope (App Group defaults)

/// The non-sensitive active-profile marker the main app publishes for
/// the Share Extension. The extension reads ONLY this key from the App
/// Group defaults — never the keychain, never account labels/emails.
enum SharedInboxScopeStore {
    static let scopeKey = "sharedinbox.activeScope"
    /// Value used when no profile was ever published (fresh install, or
    /// an app version older than the inbox).
    static let guestScope = "guest"

    static func readActiveScope(defaults: UserDefaults?) -> String {
        guard let defaults,
              let value = defaults.string(forKey: scopeKey),
              !value.isEmpty
        else { return guestScope }
        return value
    }

    static func writeActiveScope(_ scope: String, defaults: UserDefaults?) {
        defaults?.set(scope, forKey: scopeKey)
    }
}
