import SwiftUI

/// 设备管理: the signed-in account's device sessions. Other devices can be
/// signed out individually; 退出所有设备 covers the lost-phone case.
struct DeviceManagementView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var devices: [SyncDeviceSessionDTO]?
    @State private var form = AuthFormState()
    @State private var confirmLogoutAll = false

    var body: some View {
        Form {
            if let errorText = form.errorText {
                Section { AuthErrorText(message: errorText) }
            }
            if let devices {
                Section {
                    if devices.isEmpty {
                        Text(String(localized: "暂无其它设备"))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(devices) { device in
                        deviceRow(device)
                    }
                } header: {
                    Text(String(localized: "已登录设备"))
                } footer: {
                    Text(String(localized: "移除设备会使其云端登录立即失效（正在进行的课堂不受影响，本机记录会保留）。"))
                }
                Section {
                    Button(String(localized: "退出所有设备"), role: .destructive) {
                        confirmLogoutAll = true
                    }
                    .disabled(form.isBusy)
                }
            } else if form.isBusy {
                Section {
                    HStack {
                        ProgressView()
                        Text(String(localized: "正在加载…"))
                    }
                }
            }
        }
        .navigationTitle(String(localized: "登录设备"))
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(LTBackground())
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog(
            String(localized: "退出所有设备？本机也会退出登录。"),
            isPresented: $confirmLogoutAll,
            titleVisibility: .visible
        ) {
            Button(String(localized: "退出所有设备"), role: .destructive) {
                Task { await logoutAll() }
            }
        }
    }

    @ViewBuilder
    private func deviceRow(_ device: SyncDeviceSessionDTO) -> some View {
        HStack {
            Image(systemName: device.current == true
                ? "iphone.gen3.radiowaves.left.and.right"
                : "iphone.gen3")
                .foregroundStyle(device.current == true ? LTColors.accentBlue : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(rowTitle(device))
                Text(rowSubtitle(device))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if device.current == true {
                Text(String(localized: "本机"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LTColors.accentBlue)
            } else {
                Button(String(localized: "移除"), role: .destructive) {
                    Task { await revoke(device) }
                }
                .font(.caption)
                .disabled(form.isBusy)
            }
        }
    }

    private func rowTitle(_ device: SyncDeviceSessionDTO) -> String {
        if let name = device.name, !name.isEmpty { return name }
        return String(localized: "未命名设备")
    }

    private func rowSubtitle(_ device: SyncDeviceSessionDTO) -> String {
        var parts: [String] = []
        if let seen = device.lastSeenAt {
            parts.append(relativeTime(seen))
        }
        if let version = device.appVersion, !version.isEmpty {
            parts.append("v\(version)")
        }
        return parts.joined(separator: " · ")
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: .now)
    }

    private func load() async {
        guard let sync = environment.cloudSync else { return }
        guard form.begin() else { return }
        defer { form.end() }
        do {
            devices = try await sync.listDevices()
            form.clearError()
        } catch {
            form.fail(error: error)
        }
    }

    private func revoke(_ device: SyncDeviceSessionDTO) async {
        guard let sync = environment.cloudSync else { return }
        guard form.begin() else { return }
        defer { form.end() }
        do {
            try await sync.revokeDevice(device.id)
            await load()
        } catch {
            form.fail(error: error)
        }
    }

    private func logoutAll() async {
        guard let sync = environment.cloudSync else { return }
        guard form.begin() else { return }
        defer { form.end() }
        do {
            try await sync.logoutAllDevices()
            devices = []
        } catch {
            form.fail(error: error)
        }
    }
}
