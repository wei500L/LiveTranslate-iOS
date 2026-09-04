import Foundation
import Observation
import UniformTypeIdentifiers

// Share Extension receive pipeline: NSExtensionItem/NSItemProvider →
// typed classification (UTType first, then the actual representation) →
// staged App Group payload + manifest commit.
//
// The extension deliberately does NOTHING else: no SwiftData, no model
// load, no AI, no OCR, no server calls, no course picker. Everything
// complex happens in the main app's inbox screen.
//
// @MainActor: the receive loop only awaits continuations; the heavy
// streaming IO happens inside the provider's completion handlers on
// background queues (SharedInboxStore is a Sendable value type).

/// What one NSItemProvider was classified as, and how to receive it.
enum SharePayloadPlan: Equatable {
    /// A web URL (with optional accompanying text/title).
    case webURL
    /// A file of a concrete type (pdf / image / text file / anything).
    case file
    /// Plain text only.
    case text

    static func plan(for provider: NSItemProvider) -> SharePayloadPlan {
        let identifiers = provider.registeredTypeIdentifiers
        // A web URL representation distinguishes a URL share from a file
        // share (files may also register public.url — as a file:// URL —
        // which the receiver rejects and falls through to the file path).
        if identifiers.contains(UTType.url.identifier) {
            return .webURL
        }
        // Any concrete non-URL data type (pdf, jpeg, png, heic, webp,
        // txt, md, docx, …) is received as a FILE.
        if identifiers.contains(where: { id in
            guard let type = UTType(id) else { return false }
            return type.conforms(to: .data) && !type.conforms(to: .url)
        }) {
            return .file
        }
        return .text
    }
}

/// Receives the system share into the shared inbox. One instance per
/// extension activation.
@MainActor
@Observable
final class ShareInboxReceiver {
    struct ItemProgress: Equatable, Sendable {
        var label: String
        enum State: Equatable, Sendable {
            case receiving
            case done
            case failed(String)
        }
        var state: State
    }

    struct Outcome: Sendable {
        var received: Int
        var failed: [String]
        /// Providers beyond the per-share cap (reported, never hidden).
        var skipped: Int
    }

    private let store: SharedInboxStore?
    private let scopeKey: String
    private(set) var progress: [ItemProgress] = []
    private(set) var isFinished = false

    init(store: SharedInboxStore?) {
        self.store = store
        self.scopeKey = store?.activeScope ?? SharedInboxScopeStore.guestScope
    }

    // MARK: - Receive

    /// Receives every provider of every extension item. Each item is
    /// staged and committed INDEPENDENTLY — one failure never discards
    /// the others.
    @discardableResult
    func receive(items: [NSExtensionItem]) async -> Outcome {
        guard let store else {
            isFinished = true
            return Outcome(received: 0, failed: ["无法访问共享存储"], skipped: 0)
        }
        // Flatten (item, provider) pairs — multi-file and multi-image
        // shares arrive as multiple providers.
        var providers: [(item: NSExtensionItem, provider: NSItemProvider)] = []
        for item in items {
            for provider in item.attachments ?? [] {
                providers.append((item, provider))
            }
        }
        let skipped = max(0, providers.count - SharedInboxStore.maxItemsPerShare)
        if providers.count > SharedInboxStore.maxItemsPerShare {
            providers.removeLast(skipped)
        }

        var outcome = Outcome(received: 0, failed: [], skipped: skipped)
        for (item, provider) in providers {
            let label = provider.suggestedName ?? item.attributedTitle?.string
                ?? Self.fallbackLabel(for: provider)
            progress.append(ItemProgress(label: label, state: .receiving))
            let index = progress.count - 1

            do {
                try await receiveOne(item: item, provider: provider, store: store)
                progress[index].state = .done
                outcome.received += 1
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription
                    ?? String(localized: "接收失败", comment: "share extension")
                progress[index].state = .failed(reason)
                outcome.failed.append("\(label)：\(reason)")
            }
        }
        isFinished = true
        return outcome
    }

    private func receiveOne(
        item: NSExtensionItem, provider: NSItemProvider, store: SharedInboxStore
    ) async throws {
        switch SharePayloadPlan.plan(for: provider) {
        case .webURL:
            try await receiveWebURL(item: item, provider: provider, store: store)
        case .file:
            try await receiveFile(provider: provider, store: store)
        case .text:
            try await receiveText(item: item, provider: provider, store: store)
        }
    }

    // MARK: - URL shares

    private func receiveWebURL(
        item: NSExtensionItem, provider: NSItemProvider, store: SharedInboxStore
    ) async throws {
        // The URL itself (loadItem may hand back URL / NSURL / String).
        let url: URL = try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier) { data, _ in
                switch data {
                case let url as URL:
                    continuation.resume(returning: url)
                case let url as NSURL:
                    continuation.resume(returning: url as URL)
                case let string as String:
                    continuation.resume(returning: URL(string: string) ?? URL(fileURLWithPath: "/"))
                default:
                    continuation.resume(throwing: ReceiveError.unreadable)
                }
            }
        }
        // A non-http(s) URL in a URL representation is really a FILE
        // share — receive it as a file instead of inventing a link.
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else {
            try await receiveFile(provider: provider, store: store)
            return
        }

        // Accompanying text: the share's selected text beats the plain-
        // text representation (which is often just the URL string).
        var accompanyingText = item.attributedContentText?.string ?? ""
        if accompanyingText.isEmpty,
           provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            let text: String? = await withCheckedContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { data, _ in
                    continuation.resume(returning: data as? String)
                }
            }
            if let text, text != url.absoluteString {
                accompanyingText = text
            }
        }
        let title = item.attributedTitle?.string ?? ""

        var entry = SharedInboxItem(
            scopeKey: scopeKey,
            payloadKind: .url,
            title: title.isEmpty ? (url.host ?? url.absoluteString) : title
        )
        entry.url = url.absoluteString
        entry.urlTitle = title
        entry.textContent = accompanyingText
        entry.sourceBundleID = ""
        store.appendReceivedItem(entry)
    }

    // MARK: - File shares

    private func receiveFile(provider: NSItemProvider, store: SharedInboxStore) async throws {
        // Prefer the most concrete registered type (the provider lists
        // its types most-specific first).
        let identifiers = provider.registeredTypeIdentifiers
        let fileType = identifiers.first { id in
            guard let type = UTType(id) else { return false }
            return type.conforms(to: .data) && !type.conforms(to: .url)
        } ?? identifiers.first ?? UTType.data.identifier

        let itemID = UUID()
        // loadFileRepresentation hands us a temp URL that is valid ONLY
        // inside its completion — the streaming copy into the App Group
        // happens right there, before the continuation resumes.
        let received: (name: String, staged: SharedInboxStore.StagedPayload) =
            try await withCheckedThrowingContinuation { continuation in
                provider.loadFileRepresentation(forTypeIdentifier: fileType) { url, error in
                    guard let url, error == nil else {
                        continuation.resume(throwing: error ?? ReceiveError.unreadable)
                        return
                    }
                    let name = url.lastPathComponent
                    let ext = (name as NSString).pathExtension.lowercased()
                    do {
                        let staged = try store.stagePayload(
                            itemID: itemID, source: url, preferredExtension: ext
                        )
                        continuation.resume(returning: (name, staged))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }

        let name = received.name
        var hints = SharedInboxFileHints()
        Self.fill(hints: &hints, fileName: name, typeIdentifier: fileType)

        let baseName = (name as NSString).deletingPathExtension
        var entry = SharedInboxItem(
            id: itemID,
            scopeKey: scopeKey,
            payloadKind: .file,
            title: baseName.isEmpty ? name : baseName
        )
        entry.fileHints = hints
        entry.fileSize = received.staged.byteCount
        entry.contentHash = received.staged.contentHash
        entry.relativeFilePath = received.staged.relativePath
        entry.sourceBundleID = ""
        store.appendReceivedItem(entry)
    }

    // MARK: - Text shares

    private func receiveText(
        item: NSExtensionItem, provider: NSItemProvider, store: SharedInboxStore
    ) async throws {
        let loaded: String? = await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { data, _ in
                continuation.resume(returning: data as? String)
            }
        }
        let text = (item.attributedContentText?.string ?? loaded ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ReceiveError.emptyPayload }

        let itemID = UUID()
        var entry = SharedInboxItem(
            scopeKey: scopeKey,
            payloadKind: .text,
            title: String(text.prefix(60))
        )
        // Long share text is real content: store the payload as a FILE
        // (bounded manifest field, no silent truncation).
        if text.utf8.count > SharedInboxStore.textByteLimit {
            let staged = try store.stageTextPayload(itemID: itemID, text: text)
            entry.payloadKind = .file
            entry.fileHints = SharedInboxFileHints(
                mimeType: "text/plain",
                utTypeIdentifier: UTType.plainText.identifier,
                fileExtension: "txt",
                family: .text
            )
            entry.fileSize = staged.byteCount
            entry.contentHash = staged.contentHash
            entry.relativeFilePath = staged.relativePath
            entry.textContent = ""
        } else {
            entry.textContent = text
        }
        entry.sourceBundleID = ""
        store.appendReceivedItem(entry)
    }

    // MARK: - Hints

    private static func fill(
        hints: inout SharedInboxFileHints, fileName: String, typeIdentifier: String
    ) {
        let ext = (fileName as NSString).pathExtension.lowercased()
        let type = UTType(filenameExtension: ext) ?? UTType(typeIdentifier)
        hints.fileExtension = ext
        hints.utTypeIdentifier = type?.identifier ?? typeIdentifier
        hints.mimeType = type?.preferredMIMEType ?? ""
        hints.family = family(of: type, fileName: fileName)
    }

    static func family(of type: UTType?, fileName: String) -> SharedInboxFileHints.FileFamily {
        if let type {
            if type.conforms(to: .pdf) { return .pdf }
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .text) {
                let ext = (fileName as NSString).pathExtension.lowercased()
                return ext == "md" || ext == "markdown" || ext == "mdown" ? .markdown : .text
            }
        }
        switch (fileName as NSString).pathExtension.lowercased() {
        case "pdf": return .pdf
        case "jpg", "jpeg", "png", "heic", "heif", "webp": return .image
        case "txt": return .text
        case "md", "markdown", "mdown": return .markdown
        default: return .other
        }
    }

    static func fallbackLabel(for provider: NSItemProvider) -> String {
        if let id = provider.registeredTypeIdentifiers.first, let type = UTType(id) {
            return type.localizedDescription ?? String(localized: "内容", comment: "share extension")
        }
        return String(localized: "内容", comment: "share extension")
    }

    enum ReceiveError: Error, LocalizedError {
        case unreadable
        case emptyPayload

        var errorDescription: String? {
            switch self {
            case .unreadable: return String(localized: "无法读取分享内容", comment: "share extension")
            case .emptyPayload: return String(localized: "分享内容为空", comment: "share extension")
            }
        }
    }
}
