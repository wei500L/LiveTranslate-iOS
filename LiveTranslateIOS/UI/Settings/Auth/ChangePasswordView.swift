import SwiftUI

/// 修改密码 for the signed-in email account. Requires the current
/// password; the server signs out every OTHER device.
struct ChangePasswordView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var errorText: String?
    @State private var isBusy = false
    @State private var isDone = false

    var body: some View {
        Form {
            if isDone {
                Section {
                    Label(
                        String(localized: "密码已修改。其它设备已退出登录，本机继续可用。"),
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(LTColors.accentGreen)
                }
            } else {
                Section {
                    AuthPasswordField(
                        text: $currentPassword,
                        prompt: String(localized: "当前密码")
                    )
                    AuthNewPasswordField(
                        text: $newPassword,
                        prompt: String(localized: "新密码（至少 10 位）")
                    )
                    AuthNewPasswordField(
                        text: $confirmPassword,
                        prompt: String(localized: "再次输入新密码")
                    )
                    if let errorText {
                        AuthErrorText(message: errorText)
                    }
                    AuthActionButton(
                        title: String(localized: "修改密码"),
                        isBusy: isBusy,
                        action: change
                    )
                    .listRowBackground(Color.clear)
                } header: {
                    Text(String(localized: "修改密码"))
                } footer: {
                    Text(String(localized: "修改后其它设备（包括丢失的设备）会被退出登录；本机不受影响。"))
                }
            }
        }
        .navigationTitle(String(localized: "修改密码"))
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(LTBackground())
    }

    private func change() {
        errorText = nil
        if currentPassword.isEmpty {
            errorText = String(localized: "请输入当前密码")
            return
        }
        if let problem = AuthForm.newPasswordProblem(newPassword)
            ?? AuthForm.confirmationProblem(newPassword, confirmPassword) {
            errorText = problem
            return
        }
        guard let sync = environment.cloudSync else { return }
        isBusy = true
        let current = currentPassword
        let new = newPassword
        Task {
            defer { isBusy = false }
            do {
                try await sync.changePassword(current: current, new: new)
                isDone = true
            } catch {
                errorText = AuthForm.message(for: error)
            }
        }
    }
}
