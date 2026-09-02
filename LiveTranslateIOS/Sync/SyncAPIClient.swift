import Foundation
import OSLog

/// Error taxonomy shared by the auth and sync clients. The category drives
/// retry behavior: `retryable` backs off and retries, `auth` refreshes the
/// token (once) then surfaces 登录已过期 if that fails, `permanent` drops
/// the operation with a user-visible failure, `upgradeRequired` maps to
/// 需要更新 App.
enum SyncAPIError: Error, Sendable {
    case notConfigured
    case badResponse
    case retryable(reason: String)
    case authExpired
    case permanent(code: String, reason: String)
    case upgradeRequired
    case rateLimited(retryAfter: TimeInterval?)
    case serverUnavailable(retryAfter: TimeInterval?)

    var isRetryable: Bool {
        switch self {
        case .retryable, .serverUnavailable: return true
        case .rateLimited: return true
        default: return false
        }
    }

    var localizedDescription: String {
        switch self {
        case .notConfigured:
            return String(localized: "云端同步未配置服务器地址")
        case .badResponse:
            return String(localized: "服务器返回了无法理解的数据")
        case .retryable(let reason):
            return String(localized: "暂时无法连接云端服务器（\(reason)）")
        case .authExpired:
            return String(localized: "登录已过期，请重新登录")
        case .permanent(let code, _):
            return String(localized: "云端同步拒绝了该操作（\(code)）")
        case .upgradeRequired:
            return String(localized: "需要更新 App 才能继续同步")
        case .rateLimited:
            return String(localized: "云端服务器繁忙，稍后自动重试")
        case .serverUnavailable:
            return String(localized: "云端服务器暂时不可用")
        }
    }
}

/// Low-level HTTP client for the sync API. An actor: one instance per
/// app, all requests serialized through it, 401s trigger exactly one
/// single-flight token refresh and one request replay.
actor SyncAPIClient {
    private static let logger = Logger(
        subsystem: "com.livetranslate.ios", category: "sync-api"
    )

    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(baseURL: URL) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 90
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    // MARK: - Public endpoints

    func appleLogin(
        identityToken: String, device: SyncDeviceDTO
    ) async throws -> SyncTokenPairDTO {
        struct Body: Codable {
            let identityToken: String
            let device: SyncDeviceDTO
        }
        return try await post(
            "auth/apple", body: Body(identityToken: identityToken, device: device)
        )
    }

    func refreshTokens(_ refreshToken: String) async throws -> SyncTokenPairDTO {
        struct Body: Codable { let refreshToken: String }
        return try await post("auth/refresh", body: Body(refreshToken: refreshToken))
    }

    #if DEBUG
    /// Development login (POST /v1/auth/dev). Debug builds only — never
    /// compiled into Release, and the server 404s it unless
    /// DEV_LOGIN_ENABLED is on. It can never serve as production auth.
    func devLogin(devName: String, device: SyncDeviceDTO) async throws -> SyncTokenPairDTO {
        struct Body: Codable {
            let devName: String
            let device: SyncDeviceDTO
        }
        return try await post("auth/dev", body: Body(devName: devName, device: device))
    }
    #endif

    func logout(refreshToken: String) async throws {
        struct Body: Codable { let refreshToken: String }
        _ = try await postEmptyResponse("auth/logout", body: Body(refreshToken: refreshToken))
    }

    func me(accessToken: String) async throws -> SyncMeDTO {
        try await get("account/me", accessToken: accessToken)
    }

    func push(
        _ request: SyncPushRequestDTO, accessToken: String
    ) async throws -> SyncPushResponseDTO {
        try await post("sync/push", body: request, accessToken: accessToken)
    }

    func pull(
        cursor: Int, limit: Int, accessToken: String
    ) async throws -> SyncPullResponseDTO {
        struct PullDTO: Codable {
            let schemaVersion: Int
            let changes: [SyncPullChangeDTO]
            let nextCursor: Int
            let hasMore: Bool
        }
        let dto: PullDTO = try await get(
            "sync/pull?cursor=\(cursor)&limit=\(limit)", accessToken: accessToken
        )
        return SyncPullResponseDTO(
            schemaVersion: dto.schemaVersion,
            changes: dto.changes,
            nextCursor: dto.nextCursor,
            hasMore: dto.hasMore
        )
    }

    func status(accessToken: String) async throws -> SyncStatusResponseDTO {
        try await get("sync/status", accessToken: accessToken)
    }

    func deleteCloudData(accessToken: String) async throws {
        _ = try await request(
            "account/cloud-data", method: "DELETE", accessToken: accessToken
        )
    }

    func deleteAccount(accessToken: String) async throws {
        _ = try await request("account", method: "DELETE", accessToken: accessToken)
    }

    // MARK: - Plumbing

    private func endpoint(_ path: String) -> URL {
        baseURL.appendingPathComponent(path)
    }

    private func get<Body: Decodable>(
        _ path: String, accessToken: String
    ) async throws -> Body {
        let (data, response) = try await request(
            path, method: "GET", accessToken: accessToken
        )
        return try decode(data: data, response: response)
    }

    private func post<Body: Decodable, Payload: Encodable>(
        _ path: String, body: Payload, accessToken: String? = nil
    ) async throws -> Body {
        let (data, response) = try await request(
            path, method: "POST", body: body, accessToken: accessToken
        )
        return try decode(data: data, response: response)
    }

    private func postEmptyResponse<Payload: Encodable>(
        _ path: String, body: Payload
    ) async throws {
        _ = try await request(path, method: "POST", body: body)
    }

    private func request<Payload: Encodable>(
        _ path: String, method: String, body: Payload? = nil, accessToken: String? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        var urlRequest = URLRequest(url: endpoint(path))
        urlRequest.httpMethod = method
        if let accessToken {
            urlRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = try encoder.encode(body)
        }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError where error.code == .cancelled {
            throw SyncAPIError.retryable(reason: "cancelled")
        } catch {
            throw SyncAPIError.retryable(reason: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SyncAPIError.badResponse
        }
        switch http.statusCode {
        case 200..<300:
            return (data, http)
        case 401:
            throw SyncAPIError.authExpired
        case 429:
            throw SyncAPIError.rateLimited(retryAfter: http.retryAfter)
        case 502, 503, 504:
            throw SyncAPIError.serverUnavailable(retryAfter: http.retryAfter)
        default:
            // Surface schema-version rejections as upgrade-required so the
            // UI shows 需要更新 App instead of 网络错误.
            if let detail = Self.errorCode(in: data), detail == "client_schema_unsupported" {
                throw SyncAPIError.upgradeRequired
            }
            if let api = try? decoder.decode(APIErrorBody.self, from: data) {
                throw SyncAPIError.permanent(code: "\(http.statusCode)", reason: api.detail)
            }
            throw SyncAPIError.permanent(
                code: "\(http.statusCode)", reason: "HTTP \(http.statusCode)"
            )
        }
    }

    private func request(
        _ path: String, method: String, accessToken: String
    ) async throws -> (Data, HTTPURLResponse) {
        try await request(path, method: method, body: Optional<Never>.none, accessToken: accessToken)
    }

    private func decode<Body: Decodable>(
        data: Data, response: HTTPURLResponse
    ) throws -> Body {
        do {
            return try decoder.decode(Body.self, from: data)
        } catch {
            Self.logger.error(
                "decode failed on \(response.url?.path ?? "?", privacy: .public): \(String(describing: error), privacy: .public)"
            )
            throw SyncAPIError.badResponse
        }
    }

    private struct APIErrorBody: Decodable {
        let detail: String

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            detail = (try? container.decode(String.self, forKey: .detail))
                ?? (try? container.decode([String].self, forKey: .detail))?.joined(separator: "; ")
                ?? "unknown error"
        }

        enum CodingKeys: String, CodingKey { case detail }
    }

    private static func errorCode(in data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let detail = object["detail"] as? [String: Any] else { return nil }
        return detail["errorCode"] as? String
    }
}

private extension HTTPURLResponse {
    /// Parses a `Retry-After` header (seconds form) the server may send on
    /// 429/503 so the outbox respects it.
    var retryAfter: TimeInterval? {
        guard let raw = value(forHTTPHeaderField: "Retry-After") else { return nil }
        return TimeInterval(raw)
    }
}
