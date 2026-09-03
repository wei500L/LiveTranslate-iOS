import SwiftUI

// Shared pieces for the account auth forms: input semantics, client-side
// validation and Chinese mapping of the server's `{"detail": …}` texts.
// Passwords live ONLY in view @State — never in Keychain/UserDefaults.

extension SyncAPIError {
    /// The server-provided `detail` text carried by `.permanent`, when any.
    var serverDetail: String? {
        if case .permanent(_, let reason) = self { return reason }
        return nil
    }
}

enum AuthForm {
    // MARK: - Validation (client-side pre-flight; the server re-checks)

    /// Returns a Chinese error for a malformed email, nil when fine.
    static func emailProblem(_ raw: String) -> String? {
        let email = raw.trimmingCharacters(in: .whitespaces)
        if email.isEmpty { return nil } // required-ness is checked per form
        let pattern = #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#
        if email.range(of: pattern, options: .regularExpression) == nil {
            return String(localized: "邮箱格式不正确")
        }
        return nil
    }

    /// Local mirror of the server policy (length only — blocklist and
    /// similarity are the server's call). nil = fine.
    static func newPasswordProblem(_ raw: String) -> String? {
        let count = raw.count
        if count == 0 { return nil }
        if count < 10 { return String(localized: "密码至少 10 位")
        }
        if count > 128 { return String(localized: "密码最多 128 位") }
        return nil
    }

    static func confirmationProblem(_ pw: String, _ confirm: String) -> String? {
        guard !confirm.isEmpty else { return nil }
        return pw == confirm ? nil : String(localized: "两次输入的密码不一致")
    }

    /// Local mirror of the server's common-password blocklist (a subset is
    /// enough for the LIVE hint — the server remains the authority and
    /// re-checks on submit).
    private static let commonPasswords: Set<String> = [
        "password", "123456", "123456789", "12345678", "111111", "1234567",
        "password123", "qwerty123", "qwertyuiop", "iloveyou", "admin123",
        "letmein123", "livetranslate", "пароль", "пароль123", "11111111",
        "000000", "abc123456",
    ]

    /// Live-hint check only; nil-safety: empty counts as not-common so the
    /// hint row just stays neutral.
    static func isCommonPassword(_ raw: String) -> Bool {
        commonPasswords.contains(raw.lowercased())
    }

    // MARK: - Server error mapping (Go server detail texts → Chinese)

    /// Maps any thrown error to a user-presentable Chinese line.
    static func message(for error: Error) -> String {
        guard let apiError = error as? SyncAPIError else {
            return String(localized: "操作失败，请稍后再试")
        }
        if let detail = apiError.serverDetail {
            return mapServerDetail(detail)
        }
        return apiError.localizedDescription
    }

    private static func mapServerDetail(_ detail: String) -> String {
        switch detail {
        case "invalid email or password":
            return String(localized: "邮箱或密码错误")
        case "email not verified":
            return String(localized: "邮箱尚未验证，请先查收验证邮件")
        case "account is not available", "account unavailable":
            return String(localized: "账号当前不可用，请联系管理员")
        case "invalid or expired code":
            return String(localized: "验证码无效或已过期")
        case "too many attempts, request a new code":
            return String(localized: "尝试次数过多，请重新获取验证码")
        case "please wait before requesting another code",
             "please wait before retrying":
            return String(localized: "操作过于频繁，请稍后再试")
        case "too many attempts, try later", "too many requests":
            return String(localized: "尝试过于频繁，请稍后再试")
        case "invalid or expired reset token":
            return String(localized: "重置链接已过期、已使用或无效，请重新发起重置")
        case "mail transport unavailable":
            return String(localized: "服务器邮件服务暂不可用，请稍后再试")
        case "device not found":
            return String(localized: "设备不存在或已移除")
        case "registration is currently closed":
            return String(localized: "服务器当前未开放注册")
        case "this email is already in use":
            return String(localized: "该邮箱已被其他账号使用")
        case "the new email equals the current email":
            return String(localized: "新邮箱与当前邮箱相同")
        case "cannot remove the last sign-in method":
            return String(localized: "无法移除最后一种登录方式，请先设置密码")
        case "display name is too long":
            return String(localized: "显示名称过长")
        case "this Apple ID is already linked to another account":
            return String(localized: "该 Apple ID 已绑定到其他账号")
        case "no Apple account is linked":
            return String(localized: "该账号未绑定 Apple ID")
        default:
            // Password policy reasons: "password rejected: <reason>".
            if detail.hasPrefix("password rejected") {
                return mapPasswordReason(detail)
            }
            return detail
        }
    }

    private static func mapPasswordReason(_ detail: String) -> String {
        switch detail {
        case let d where d.hasSuffix("password_too_short"):
            return String(localized: "密码至少 10 位")
        case let d where d.hasSuffix("password_too_long"):
            return String(localized: "密码最多 128 位")
        case let d where d.hasSuffix("password_common"):
            return String(localized: "密码过于常见，请换一个")
        case let d where d.hasSuffix("password_similar_to_account"):
            return String(localized: "密码与邮箱或昵称过于相似")
        case let d where d.hasSuffix("password_unsupported_characters"):
            return String(localized: "密码包含不支持的字符")
        default:
            return String(localized: "密码不满足安全要求")
        }
    }
}

// MARK: - Shared form state

/// Unified in-flight + inline-error state for EVERY auth form (login,
/// register, verify, change password, change email, bind/unbind, device
/// management). One shape instead of per-view ad-hoc pairs:
///
/// - `begin()` returns false while a request is in flight, so double
///   submits are structurally impossible (buttons also disable on isBusy);
/// - `fail(_:)` maps any thrown error through `AuthForm.message` — network
///   errors, validation failures, account suspension, login expiry and
///   version incompatibility each surface their own Chinese line;
/// - views read `errorText` for the inline `AuthErrorText` row.
@MainActor
@Observable
final class AuthFormState {
    private(set) var isBusy = false
    private(set) var errorText: String?

    /// Marks the form busy. Returns false when a request is already in
    /// flight (the caller simply returns — a second tap did nothing).
    @discardableResult
    func begin() -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        errorText = nil
        return true
    }

    /// Ends the in-flight window (defer in every submit task).
    func end() {
        isBusy = false
    }

    /// Records a mapped failure line for the inline error row.
    func fail(_ message: String) {
        errorText = message
    }

    /// Maps and records a thrown error.
    func fail(error: Error) {
        fail(AuthForm.message(for: error))
    }

    func clearError() {
        errorText = nil
    }

    /// Inline error row bound to this state (nil view when no error).
    var errorRow: AuthErrorText? {
        errorText.map { AuthErrorText(message: $0) }
    }
}

// MARK: - Field builders (iOS input semantics)

/// Email field: no capitalization/autocorrection, email keyboard.
struct AuthEmailField: View {
    @Binding var text: String
    var prompt: String = String(localized: "邮箱")

    var body: some View {
        TextField(prompt, text: $text, prompt: Text(prompt).foregroundColor(.secondary))
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(.emailAddress)
            .submitLabel(.next)
    }
}

/// Login password field — offers the system password autofill.
struct AuthPasswordField: View {
    @Binding var text: String
    var prompt: String = String(localized: "密码")

    var body: some View {
        SecureField(prompt, text: $text, prompt: Text(prompt).foregroundColor(.secondary))
            .textContentType(.password)
            .submitLabel(.go)
    }
}

/// New-password field (registration / reset / change) — offers the system
/// strong-password generator.
struct AuthNewPasswordField: View {
    @Binding var text: String
    var prompt: String = String(localized: "设置密码（至少 10 位）")

    var body: some View {
        SecureField(prompt, text: $text, prompt: Text(prompt).foregroundColor(.secondary))
            .textContentType(.newPassword)
            .submitLabel(.next)
    }
}

/// Inline error line used by every auth form.
struct AuthErrorText: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(LTColors.destructive)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Primary action button with an in-flight spinner.
struct AuthActionButton: View {
    let title: String
    var isBusy: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isBusy { ProgressView().tint(.white) }
                Text(title)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isBusy)
    }
}
