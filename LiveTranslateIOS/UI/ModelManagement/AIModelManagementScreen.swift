import SwiftUI

/// AI model management (offline translation GGUFs + the image model):
/// per-model install state, download/pause/resume, delete, re-verify,
/// set-as-current. Same card pattern as the ASR `ModelManagementScreen`.
struct AIModelManagementScreen: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var confirmDelete: LocalAIModelKind?

    var body: some View {
        List {
            ForEach(LocalAIModelKind.allCases) { kind in
                AIModelCard(
                    kind: kind,
                    state: environment.aiModelManager.states[kind],
                    isProviderSelected: selectedProviderUses(kind),
                    onInstall: { environment.aiModelManager.install(kind) },
                    onPause: { environment.aiModelManager.pause(kind) },
                    onResume: { environment.aiModelManager.resume(kind) },
                    onDelete: { confirmDelete = kind },
                    onReverify: { Task { await environment.aiModelManager.reverify(kind) } },
                    onUse: { selectProvider(kind) }
                )
            }
        }
        .navigationTitle(String(localized: "翻译模型管理"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshStates() }
        .confirmationDialog(
            confirmDelete.map { String(format: String(localized: "删除“%@”？这会从本机移除模型文件。"), $0.userTitle) } ?? "",
            isPresented: Binding(
                get: { confirmDelete != nil },
                set: { if !$0 { confirmDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let kind = confirmDelete {
                Button(String(localized: "删除"), role: .destructive) {
                    Task {
                        try? await environment.aiModelManager.delete(kind)
                        await refreshStates()
                    }
                    confirmDelete = nil
                }
            }
        }
    }

    /// Refresh install states (file-presence + sizes) on appear.
    private func refreshStates() async {
        environment.aiModelManager.refreshStates()
        // Post-appear integrity pass for already-installed models (same
        // lazy discipline as the ASR screen: a fresh scan proves nothing,
        // so verify hashes once per visit).
        for kind in LocalAIModelKind.allCases
        where environment.aiModelManager.state(kind).isInstalled {
            await environment.aiModelManager.reverify(kind)
        }
    }

    private func selectedProviderUses(_ kind: LocalAIModelKind) -> Bool {
        environment.settings.translationProvider.localModelKind == kind
    }

    private func selectProvider(_ kind: LocalAIModelKind) {
        switch kind {
        case .hyMT2: environment.settings.translationProvider = .hyMT2
        case .milmmt46: environment.settings.translationProvider = .milmmt46
        case .gemmaE2B: break // the image model is selected per-use, not as a provider
        }
    }
}

private struct AIModelCard: View {
    let kind: LocalAIModelKind
    let state: LocalAIModelManager.InstallState?
    let isProviderSelected: Bool
    let onInstall: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onDelete: () -> Void
    let onReverify: () -> Void
    let onUse: () -> Void

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                header
                if let state {
                    detailRows(state)
                    if let progress = state.downloadProgress {
                        ProgressView(value: min(max(progress, 0), 1))
                            .accessibilityLabel(Text("Download progress"))
                    }
                    if let error = state.error, !error.isEmpty {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    actionButtons(state)
                } else {
                    ProgressView()
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.userTitle).font(.headline)
                Text(kind.userSubtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isProviderSelected {
                StatusChip(text: String(localized: "Current"), tint: .blue)
            }
        }
    }

    @ViewBuilder
    private func detailRows(_ state: LocalAIModelManager.InstallState) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            LabeledRow(
                label: String(localized: "Status"),
                value: state.isInstalled
                    ? String(localized: "Installed")
                    : String(localized: "Not installed")
            )
            LabeledRow(
                label: String(localized: "On-device size"),
                value: state.installedBytes > 0 ? Format.bytes(state.installedBytes) : "—"
            )
            LabeledRow(
                label: String(localized: "Version"),
                value: state.version.isEmpty ? "—" : String(state.version.prefix(8))
            )
            LabeledRow(
                label: String(localized: "SHA256"),
                value: state.integrityVerified == true
                    ? String(localized: "Verified")
                    : state.integrityVerified == false
                        ? String(localized: "Failed")
                        : String(localized: "Not checked")
            )
            if let loadedAt = state.lastLoadedAt {
                LabeledRow(label: String(localized: "Last loaded"), value: Format.date(loadedAt))
            }
        }
        .font(.subheadline)
    }

    @ViewBuilder
    private func actionButtons(_ state: LocalAIModelManager.InstallState) -> some View {
        HStack(spacing: 10) {
            if state.downloadProgress != nil {
                if state.isPaused {
                    Button(String(localized: "Resume"), action: onResume)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(String(localized: "Pause"), action: onPause)
                        .buttonStyle(.bordered)
                }
            } else if !state.isInstalled {
                Button(String(localized: "Download"), action: onInstall)
                    .buttonStyle(.borderedProminent)
            }

            Button(String(localized: "Re-verify"), action: onReverify)
                .buttonStyle(.bordered)
                .disabled(!state.isInstalled || state.isVerifying)
            if state.isVerifying {
                ProgressView().controlSize(.small)
            }

            if state.isInstalled {
                Button(String(localized: "Delete"), role: .destructive, action: onDelete)
                    .buttonStyle(.bordered)
            }

            if state.isInstalled, kind.isTranslationModel, !isProviderSelected {
                Button(String(localized: "使用此模型"), action: onUse)
                    .buttonStyle(.borderedProminent)
            }
        }
        .font(.footnote)
        if kind == .gemmaE2B {
            Text(String(localized: "图片理解模型在需要分析图片时自动加载、用完即释放，无需手动选择。"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
