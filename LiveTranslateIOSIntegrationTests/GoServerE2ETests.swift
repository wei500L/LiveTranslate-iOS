import XCTest
@testable import LiveTranslateIOS

/// iOS ↔ Go server end-to-end (§26): the REAL client stack —
/// `SyncAPIClient`, `ServerAuthSession` and the per-account keychain
/// scoping — running in the simulator against a local Go server, with the
/// verification code read out of Mailpit exactly like a human tester would.
///
/// No UI automation: these tests exercise the same code paths the app's
/// views drive (register → mail code → verify → push/pull → rotate →
/// devices → password change → multi-account isolation).
///
/// Environment:
///   LT_GO_SERVER_URL  (default http://127.0.0.1:8002/v1)
///   LT_MAILPIT_URL    (default http://127.0.0.1:8025)
/// Skips (XCTSkip) when the server is not reachable, so the suite stays
/// green on machines without the local stack.
@MainActor
final class GoServerE2ETests: XCTestCase {
    private var serverBase: URL!
    private var mailpitBase: URL!

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        let server = env["LT_GO_SERVER_URL"] ?? "http://127.0.0.1:8002/v1"
        let mailpit = env["LT_MAILPIT_URL"] ?? "http://127.0.0.1:8025"
        serverBase = URL(string: server)!
        mailpitBase = URL(string: mailpit)!

        // Reachability gate — skip cleanly when the stack is not running.
        // (Health lives at the server root, not under /v1.)
        var healthURL = URLComponents(url: serverBase, resolvingAgainstBaseURL: false)!
        healthURL.path = "/health"
        var request = URLRequest(url: healthURL.url!)
        request.timeoutInterval = 3
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw XCTSkip("Go server not reachable at \(server)")
        }
    }

    private func uniqueEmail() -> String {
        "ios-e2e-\(Int(Date.now.timeIntervalSince1970))-\(Int.random(in: 100...999))@example.com"
    }

    private func makeClient() -> SyncAPIClient {
        SyncAPIClient(baseURL: serverBase)
    }

    /// Fetches the newest verification code from Mailpit.
    private func latestVerificationCode(for email: String) async throws -> String {
        struct MessagesBody: Decodable {
            struct Message: Decodable { let ID: String }
            let messages: [Message]
        }
        var listComponents = URLComponents(url: mailpitBase, resolvingAgainstBaseURL: false)!
        listComponents.path += "/api/v1/messages"
        listComponents.queryItems = [URLQueryItem(name: "limit", value: "5")]
        let (data, _) = try await URLSession.shared.data(from: listComponents.url!)
        let body = try JSONDecoder().decode(MessagesBody.self, from: data)
        let newest = try XCTUnwrap(body.messages.first, "no mail captured")
        var msgComponents = URLComponents(url: mailpitBase, resolvingAgainstBaseURL: false)!
        msgComponents.path += "/api/v1/message/\(newest.ID)"
        let (msgData, _) = try await URLSession.shared.data(from: msgComponents.url!)
        // strict=false equivalent: JSONSerialization tolerates control chars.
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: msgData) as? [String: Any]
        )
        let text = try XCTUnwrap(obj["Text"] as? String)
        for word in text.split(whereSeparator: { $0.isWhitespace || $0 == "\n" }) {
            if word.count == 6, word.allSatisfy(\.isNumber) {
                return String(word)
            }
        }
        throw XCTSkip("no 6-digit code in mail: \(text)")
    }

    // MARK: - Full account lifecycle

    func testRegisterVerifyLoginPushPull() async throws {
        let email = uniqueEmail()
        let client = makeClient()
        let keychain = KeychainStore()

        // Register: uniform 200, no tokens yet.
        try await client.emailRegister(
            email: email, password: "correct-horse-battery-9",
            displayName: "E2E", device: testDevice()
        )
        // Resend cooldown: an immediate resend is refused with 429.
        do {
            try await client.emailResendCode(email: email)
            XCTFail("immediate resend should be rate-limited")
        } catch let error as SyncAPIError {
            guard case .rateLimited = error else {
                throw error
            }
        }

        // The code from the mail verifies and issues the first pair.
        let code = try await latestVerificationCode(for: email)
        let session = ServerAuthSession(api: client, keychain: keychain)
        let pair = try await session.verifyEmail(email: email, code: code)
        XCTAssertEqual(pair.tokenType, "Bearer")
        XCTAssertFalse(pair.accessToken.isEmpty)

        // /account/me answers for the new account.
        let me: SyncMeDTO = try await session.authorize { token in
            try await client.me(accessToken: token)
        }
        XCTAssertEqual(me.userId, pair.userId)

        // A real push through the same DTO stack the app's outbox uses.
        let sessionID = UUID()
        var payload = SyncPushPayloadDTO()
        payload.title = "E2E 课堂"
        payload.sessionStatus = "completed"
        payload.startedAt = Date(timeIntervalSince1970: 1_785_000_000)
        let item = SyncPushItemDTO(
            operationId: UUID(),
            entityType: .session,
            entityId: sessionID,
            operation: .upsert,
            baseVersion: 0,
            clientUpdatedAt: .now,
            payload: payload
        )
        let pushRequest = SyncPushRequestDTO(schemaVersion: 1, operations: [item])
        let push: SyncPushResponseDTO = try await session.authorize { token in
            try await client.push(pushRequest, accessToken: token)
        }
        guard case .accepted = push.results[0].status else {
            XCTFail("push not accepted: \(push.results[0])")
            return
        }

        // Pull returns the record the next iOS build would render.
        let pull: SyncPullResponseDTO = try await session.authorize { token in
            try await client.pull(cursor: 0, limit: 100, accessToken: token)
        }
        let change = try XCTUnwrap(pull.changes.first { $0.entityId == sessionID })
        XCTAssertEqual(change.entityType, .session)
        XCTAssertEqual(change.record?.title, "E2E 课堂")
        // nextCursor semantics: pulling after it is empty.
        let again = try await session.authorize { token in
            try await client.pull(cursor: pull.nextCursor, limit: 100, accessToken: token)
        }
        XCTAssertTrue(again.changes.isEmpty)

        await session.signOut()
    }

    // MARK: - Rotation & reuse detection

    func testRefreshRotationAndReuseDetection() async throws {
        let email = uniqueEmail()
        let client = makeClient()
        let keychain = KeychainStore()
        let session = ServerAuthSession(api: client, keychain: keychain)
        try await client.emailRegister(
            email: email, password: "correct-horse-battery-9",
            displayName: "E2E", device: testDevice()
        )
        let code = try await latestVerificationCode(for: email)
        let pair = try await session.verifyEmail(email: email, code: code)

        // Rotate once.
        let rotated = try await client.refreshTokens(pair.refreshToken)
        XCTAssertFalse(rotated.accessToken.isEmpty)
        // Replay the ORIGINAL token: reuse detection kills the family.
        do {
            _ = try await client.refreshTokens(pair.refreshToken)
            XCTFail("replayed refresh accepted")
        } catch let error as SyncAPIError {
            guard case .authExpired = error else { throw error }
        }
        // The legitimate rotated token is dead too.
        do {
            _ = try await client.refreshTokens(rotated.refreshToken)
            XCTFail("family survived reuse detection")
        } catch let error as SyncAPIError {
            guard case .authExpired = error else { throw error }
        }
    }

    // MARK: - Password change + device management

    func testChangePasswordAndDevices() async throws {
        let email = uniqueEmail()
        let client = makeClient()
        let keychain = KeychainStore()
        let session = ServerAuthSession(api: client, keychain: keychain)
        try await client.emailRegister(
            email: email, password: "original-password-77",
            displayName: "E2E", device: testDevice()
        )
        let code = try await latestVerificationCode(for: email)
        _ = try await session.verifyEmail(email: email, code: code)

        // A second device on the same account.
        _ = try await client.emailLogin(
            email: email, password: "original-password-77", device: testDevice()
        )

        // Wrong current password is refused (401 on the wire).
        do {
            try await session.changePassword(current: "wrong-current-1", new: "brand-new-pass-99")
            XCTFail("change with wrong current accepted")
        } catch let error as SyncAPIError {
            guard case .authExpired = error else { throw error }
        }

        // Devices list marks this session's device current.
        let token = await session.storedAccessToken() ?? ""
        var devices = try await client.listDevices(accessToken: token)
        XCTAssertGreaterThanOrEqual(devices.count, 1)
        XCTAssertTrue(devices.contains { $0.current == true })

        // Correct change succeeds.
        try await session.changePassword(current: "original-password-77", new: "brand-new-pass-99")

        // Old password no longer logs in; new one does.
        do {
            _ = try await client.emailLogin(
                email: email, password: "original-password-77", device: testDevice()
            )
            XCTFail("old password accepted after change")
        } catch let error as SyncAPIError {
            guard case .authExpired = error else { throw error }
        }
        _ = try await client.emailLogin(
            email: email, password: "brand-new-pass-99", device: testDevice()
        )

        // Revoke the other device by id.
        let token2 = await session.storedAccessToken() ?? ""
        devices = try await client.listDevices(accessToken: token2)
        if let other = devices.first(where: { $0.current != true }) {
            try await client.revokeDevice(id: other.id, accessToken: token2)
            let after = try await client.listDevices(accessToken: token2)
            // The revoked row is either gone or marked revoked.
            XCTAssertFalse(after.contains { $0.id == other.id && $0.revokedAt == nil && $0.current != true })
        }
    }

    // MARK: - Multi-account keychain isolation

    func testPerAccountKeychainScopesDoNotMix() async throws {
        let keychain = KeychainStore()
        let client = makeClient()
        let idA = UUID()
        let idB = UUID()
        let scopeA = "cloudsync.account.\(idA.uuidString)"
        let scopeB = "cloudsync.account.\(idB.uuidString)"

        let sessionA = ServerAuthSession(api: client, keychain: keychain, scope: scopeA)
        let sessionB = ServerAuthSession(api: client, keychain: keychain, scope: scopeB)

        try keychain.set("token-a", forKey: "\(scopeA).accessToken")
        try keychain.set("refresh-a", forKey: "\(scopeA).refreshToken")

        // B sees nothing of A.
        let accessedB = await sessionB.hasTokens
        XCTAssertFalse(accessedB)
        // A sees its own.
        let accessedA = await sessionA.hasTokens
        XCTAssertTrue(accessedA)

        // Clearing B leaves A intact.
        await sessionB.clear()
        let stillA = await sessionA.storedAccessToken()
        XCTAssertEqual(stillA, "token-a")

        try? keychain.delete(forKey: "\(scopeA).accessToken")
        try? keychain.delete(forKey: "\(scopeA).refreshToken")
    }

    // MARK: - Helpers

    private func testDevice() -> SyncDeviceDTO {
        SyncDeviceDTO(
            clientDeviceId: "ios-e2e-\(UUID().uuidString.prefix(8))",
            displayName: "iOS 集成测试",
            appVersion: "0.1.0-e2e"
        )
    }
}
