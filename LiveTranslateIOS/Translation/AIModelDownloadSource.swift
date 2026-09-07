import Foundation

/// Where the on-device AI models are downloaded FROM. The bytes are
/// identical either way — the client verifies every file against its own
/// bundled manifest (SHA256 + size) regardless of source, so the choice
/// is purely about network reachability (Hugging Face direct vs. the
/// user's own cloud-sync server, which the operator pre-populates with
/// `livetranslate-server download-models`).
enum AIModelDownloadSource: String, CaseIterable, Identifiable, Sendable, Equatable {
    /// Direct from Hugging Face at the manifest's pinned revisions
    /// (the default; matches the previous behavior exactly).
    case huggingFace
    /// From the user's own cloud-sync server (`/v1/models/ai/…`, Bearer
    /// authenticated, Range resumable). Requires a configured server
    /// (CloudSyncServerURL) whose operator ran download-models.
    case server

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .huggingFace: return String(localized: "平台直连（Hugging Face）")
        case .server: return String(localized: "云端服务器")
        }
    }

    var footerText: String {
        switch self {
        case .huggingFace:
            return String(localized: "从 Hugging Face 固定 revision 直接下载（默认）。文件完整性同样按清单 SHA256 校验。")
        case .server:
            return String(localized: "从你自己的同步服务器下载（管理员需先运行 livetranslate-server download-models 预下载）。需要已登录且服务器已配置；文件校验与平台直连完全一致。")
        }
    }

    /// Resolve the URL for one manifest file under this source.
    ///
    /// - Hugging Face: the manifest's pinned URL, untouched.
    /// - Server: `<CloudSyncServerURL>/models/ai/<modelID>/<file>` — the
    ///   server's catalog id/filename contract. Returns nil when no
    ///   server is configured (the caller surfaces an honest error
    ///   instead of silently falling back to another source).
    func resolvedURL(
        manifestURL: String, modelID: String, filePath: String, serverBaseURL: URL?
    ) -> URL? {
        switch self {
        case .huggingFace:
            return URL(string: manifestURL)
        case .server:
            guard let base = serverBaseURL else { return nil }
            return Self.serverURL(base: base, modelID: modelID, filePath: filePath)
        }
    }

    /// `<base>/models/ai/<modelID>/<filePath>` with exactly one slash
    /// between each component (tolerates trailing-slash bases).
    static func serverURL(base: URL, modelID: String, filePath: String) -> URL? {
        var baseComponents = URLComponents(url: base, resolvingAgainstBaseURL: false)
        guard baseComponents != nil else { return nil }
        let baseText = base.absoluteString
        var text = baseText.hasSuffix("/") ? String(baseText.dropLast()) : baseText
        text += "/models/ai/\(modelID)/\(filePath)"
        return URL(string: text)
    }

    /// Whether the server source is even selectable in this build/session
    /// (a server URL must be baked in via CloudSyncServerURL).
    static var serverAvailable: Bool {
        ServerConfiguration.baseURL != nil
    }
}

/// Everything one AI-model install needs to know about its download
/// source: the selected source, the server base URL (server source only)
/// and a Bearer token snapshot. Resolved per install — token rotation
/// between installs is picked up on the next download.
struct AIModelDownloadContext: Sendable, Equatable {
    var source: AIModelDownloadSource
    var serverBaseURL: URL?
    var authToken: String?
}

/// One row of the server's `GET /v1/models/ai` index (id + on-disk
/// presence), used by the management screen to show 服务器已备/未备
/// before a multi-GB download starts.
struct AIModelServerIndexEntry: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let file: String
    let bytes: Int
    let sha256: String
    let installed: Bool
}

enum AIModelServerIndex {
    /// Fetch the server's model index. Throws on transport/HTTP errors —
    /// callers surface the failure honestly (never a fake "not
    /// installed").
    static func fetch(base: URL, accessToken: String) async throws -> [AIModelServerIndexEntry] {
        var baseText = base.absoluteString
        if baseText.hasSuffix("/") { baseText = String(baseText.dropLast()) }
        guard let url = URL(string: baseText + "/models/ai") else {
            throw TranslationError.fatal("invalid server URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw TranslationError.retryable("服务器模型目录不可用（HTTP \(http.statusCode)）")
        }
        do {
            return try JSONDecoder().decode([AIModelServerIndexEntry].self, from: data)
        } catch {
            throw TranslationError.fatal("服务器模型目录格式无法解析。")
        }
    }
}
