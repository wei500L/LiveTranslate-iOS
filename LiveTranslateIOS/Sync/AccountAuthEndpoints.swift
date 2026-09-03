import Foundation

// Email/password account endpoints (Go server §3) + device management.
// All errors surface as SyncAPIError; the server's `{"detail": …}` text is
// carried in `.permanent(reason:)` so the auth UI can map it to Chinese.

extension SyncAPIClient {
    // MARK: - Email/password account flows

    struct EmailRegisterBody: Encodable {
        let email: String
        let password: String
        let displayName: String
        let device: SyncDeviceDTO?
    }

    struct GenericAck: Decodable {
        let sent: Bool?
        let detail: String?
    }

    /// POST /auth/register — always answers 200 with a generic body
    /// (anti-enumeration); no tokens are issued until the email is verified.
    func emailRegister(
        email: String, password: String, displayName: String, device: SyncDeviceDTO?
    ) async throws {
        struct Body: Encodable {
            let email: String
            let password: String
            let displayName: String
            let device: SyncDeviceDTO?
        }
        _ = try await post(
            "auth/register",
            body: Body(email: email, password: password, displayName: displayName, device: device)
        ) as GenericAck
    }

    /// POST /auth/email/verify — consumes the 6-digit code and returns the
    /// first token pair (the account becomes active).
    func emailVerify(email: String, code: String, device: SyncDeviceDTO?) async throws -> SyncTokenPairDTO {
        struct Body: Encodable {
            let email: String
            let code: String
            let device: SyncDeviceDTO?
        }
        return try await post("auth/email/verify", body: Body(email: email, code: code, device: device))
    }

    /// POST /auth/email/resend — 429 with Retry-After while the cooldown
    /// is active.
    func emailResendCode(email: String) async throws {
        struct Body: Encodable { let email: String }
        _ = try await post("auth/email/resend", body: Body(email: email)) as GenericAck
    }

    /// POST /auth/login — email + password. 401 with a unified detail for
    /// unknown email and wrong password alike.
    func emailLogin(email: String, password: String, device: SyncDeviceDTO) async throws -> SyncTokenPairDTO {
        struct Body: Encodable {
            let email: String
            let password: String
            let device: SyncDeviceDTO
        }
        return try await post("auth/login", body: Body(email: email, password: password, device: device))
    }

    // MARK: - Password management

    /// POST /auth/password/forgot — always 200 with a generic body.
    func forgotPassword(email: String) async throws {
        struct Body: Encodable { let email: String }
        _ = try await post("auth/password/forgot", body: Body(email: email)) as GenericAck
    }

    /// POST /auth/password/reset — consumes the mailed token, sets the new
    /// password and revokes every refresh token of the account.
    func resetPassword(token: String, newPassword: String) async throws {
        struct Body: Encodable {
            let token: String
            let newPassword: String
        }
        _ = try await post("auth/password/reset", body: Body(token: token, newPassword: newPassword)) as GenericAck
    }

    /// POST /me/password/change — requires the current password; revokes
    /// every OTHER device's tokens.
    func changePassword(current: String, new: String, accessToken: String) async throws {
        struct Body: Encodable {
            let currentPassword: String
            let newPassword: String
        }
        _ = try await post(
            "me/password/change",
            body: Body(currentPassword: current, newPassword: new),
            accessToken: accessToken
        ) as GenericAck
    }

    // MARK: - Devices

    struct DeviceListBody: Decodable {
        let devices: [SyncDeviceSessionDTO]
    }

    /// GET /me/devices — the caller's device sessions (never other
    /// accounts').
    func listDevices(accessToken: String) async throws -> [SyncDeviceSessionDTO] {
        let body: DeviceListBody = try await get("me/devices", accessToken: accessToken)
        return body.devices
    }

    /// DELETE /me/devices/{id} — revokes that device's tokens.
    func revokeDevice(id: UUID, accessToken: String) async throws {
        _ = try await request("me/devices/\(id.uuidString)", method: "DELETE", accessToken: accessToken)
    }

    /// POST /auth/logout-all — revokes every refresh token of the account.
    func logoutAll(accessToken: String) async throws {
        _ = try await request("auth/logout-all", method: "POST", accessToken: accessToken)
    }
}

/// One device session of the signed-in account (GET /me/devices).
struct SyncDeviceSessionDTO: Decodable, Sendable, Identifiable {
    let deviceId: UUID
    let name: String?
    let appVersion: String?
    let lastSeenAt: Date?
    let revokedAt: Date?
    let current: Bool?

    var id: UUID { deviceId }
}
