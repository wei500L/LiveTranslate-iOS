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
    /// `invitationCode` is required when the server runs invite_only.
    func emailRegister(
        email: String, password: String, displayName: String,
        invitationCode: String = "", device: SyncDeviceDTO?
    ) async throws {
        struct Body: Encodable {
            let email: String
            let password: String
            let displayName: String
            let invitationCode: String?
            let device: SyncDeviceDTO?
        }
        _ = try await post(
            "auth/register",
            body: Body(
                email: email, password: password, displayName: displayName,
                invitationCode: invitationCode.isEmpty ? nil : invitationCode,
                device: device
            )
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

    // MARK: - Server capabilities

    /// GET /auth/capabilities — public registration/sign-in posture. Falls
    /// back to a safe "disabled" at the CALLER's discretion on failure;
    /// this method only throws on network problems.
    func capabilities() async throws -> SyncCapabilitiesDTO {
        try await getPublic("auth/capabilities")
    }

    // MARK: - Account profile (账号与安全)

    /// GET /me — the enriched profile (email, verification state, sign-in
    /// methods, device/session counts).
    func meProfile(accessToken: String) async throws -> SyncMeProfileDTO {
        try await get("me", accessToken: accessToken)
    }

    /// PATCH /me — update the display name ONLY (the server rejects any
    /// role/status/userId attempt structurally; the request body here
    /// carries displayName alone). Returns the updated public user.
    func updateDisplayName(_ displayName: String, accessToken: String) async throws -> SyncPublicUserDTO {
        struct Body: Encodable { let displayName: String }
        return try await patch("me", body: Body(displayName: displayName), accessToken: accessToken)
    }

    /// POST /me/email/change — step 1 of the login-email change: re-auth
    /// with the current password; a verification code goes to the NEW
    /// address. The response names the target address + expiry.
    func requestEmailChange(
        currentPassword: String, newEmail: String, accessToken: String
    ) async throws -> EmailChangeStateDTO {
        struct Body: Encodable {
            let currentPassword: String
            let newEmail: String
        }
        return try await post("me/email/change", body: Body(currentPassword: currentPassword, newEmail: newEmail), accessToken: accessToken)
    }

    /// POST /me/email/verify — step 2: consume the code. The server swaps
    /// the email atomically, signs out every OTHER device and returns a
    /// FRESH token pair for this device.
    func verifyEmailChange(code: String, device: SyncDeviceDTO, accessToken: String) async throws -> SyncTokenPairDTO {
        struct Body: Encodable {
            let code: String
            let device: SyncDeviceDTO
        }
        return try await post("me/email/verify", body: Body(code: code, device: device), accessToken: accessToken)
    }

    /// POST /me/apple/bind — link the verified Apple identity to the
    /// signed-in account.
    func bindApple(identityToken: String, accessToken: String) async throws {
        struct Body: Encodable { let identityToken: String }
        struct Ack: Decodable { let bound: Bool? }
        _ = try await post("me/apple/bind", body: Body(identityToken: identityToken), accessToken: accessToken) as Ack
    }

    /// DELETE /me/apple — unbind the Apple sign-in method (password
    /// re-verification; the server refuses when it is the last method).
    func unbindApple(currentPassword: String, accessToken: String) async throws {
        struct Body: Encodable { let currentPassword: String }
        // request() already rejects non-2xx with the mapped error; the 200
        // body is an {"bound": false} ack we do not need to read.
        _ = try await request(
            "me/apple", method: "DELETE",
            body: Body(currentPassword: currentPassword), accessToken: accessToken
        )
    }
}

/// Target/expiry of a pending email change (POST /me/email/change).
struct EmailChangeStateDTO: Decodable, Sendable {
    var sent: Bool?
    var targetEmail: String?
    var expiresAt: Date?
}

/// A 200 body with nothing we need to read.
struct EmptyAck: Decodable {}

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
