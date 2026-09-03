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
            return String(localized: "重置凭证无效或已过期，请重新发起重置")
        case "mail transport unavailable":
            return String(localized: "服务器邮件服务暂不可用，请稍后再试")
        case "device not found":
            return String(localized: "设备不存在或已移除")
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
