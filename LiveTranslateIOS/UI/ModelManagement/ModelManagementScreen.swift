import SwiftUI

/// Model management: per-backend install state, download/pause/resume,
/// delete, re-verify, set-as-current.
struct ModelManagementScreen: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var confirmDelete: ASRBackendKind?

    var body: some View {
        List {
            ForEach(ASRBackendKind.allCases) { kind in
                BackendCard(
                    kind: kind,
                    state: environment.modelManager.states[kind],
                    sessionActive: environment.engineManager.sessionActive,
                    isPreferred: environment.settings.preferredBackend == kind,
                    onInstall: { Task { await environment.modelManager.install(kind) } },
                    onPause: { Task { await environment.modelManager.pause(kind) } },
                    onResume: { Task { await environment.modelManager.resume(kind) } },
                    onDelete: { confirmDelete = kind },
                    onReverify: { Task { await environment.modelManager.reverify(kind) } },
                    onSetPreferred: { environment.settings.preferredBackend = kind }
                )
            }
        }
        .navigationTitle(String(localized: "Model Management"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await environment.modelManager.refreshStates() }
        .confirmationDialog(
            confirmDelete.map { String(format: String(localized: "Delete %@? This removes the model files from this device."), $0.displayName) } ?? "",
            isPresented: Binding(
                get: { confirmDelete != nil },
                set: { if !$0 { confirmDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let kind = confirmDelete {
                Button(String(localized: "Delete"), role: .destructive) {
                    Task {
                        await environment.modelManager.delete(kind)
                        await environment.modelManager.refreshStates()
                    }
                    confirmDelete = nil
                }
            }
        }
    }
}

private struct BackendCard: View {
    let kind: ASRBackendKind
    let state: ModelManager.BackendInstallState?
    let sessionActive: Bool
    let isPreferred: Bool
    let onInstall: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onDelete: () -> Void
    let onReverify: () -> Void
    let onSetPreferred: () -> Void

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
                Text(kind.displayName).font(.headline)
                Text(kind.positioning).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isPreferred {
                StatusChip(text: String(localized: "Current"), tint: .blue)
            }
        }
    }

    @ViewBuilder
    private func detailRows(_ state: ModelManager.BackendInstallState) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            LabeledRow(
                label: String(localized: "Status"),
                value: state.isInstalled
                    ? (state.coreMLCompiled == false && kind == .coreMLFP16
                       ? String(localized: "Downloaded — not compiled yet")
                       : String(localized: "Installed"))
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
            if kind == .coreMLFP16 {
                LabeledRow(
                    label: String(localized: "Core ML compiled"),
                    value: state.coreMLCompiled == true ? "✓" : "—"
                )
            }
            if let loadedAt = state.lastLoadedAt {
                LabeledRow(label: String(localized: "Last loaded"), value: Format.date(loadedAt))
            }
            if let rtf = state.lastRTF {
                LabeledRow(label: String(localized: "Last RTF"), value: String(format: "%.2f", rtf))
            }
        }
        .font(.subheadline)
    }

    @ViewBuilder
    private func actionButtons(_ state: ModelManager.BackendInstallState) -> some View {
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
                    .disabled(sessionActive)
                if !isPreferred {
                    Button(String(localized: "Use this backend"), action: onSetPreferred)
                        .buttonStyle(.borderedProminent)
                        .disabled(sessionActive)
                }
            }
        }
        .font(.footnote)
        if sessionActive {
            Text(String(localized: "Stop the running session to delete or switch backends."))
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }
}
