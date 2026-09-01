import SwiftUI

/// Live translation tab: status header, waveform, bilingual subtitle feed,
/// and session controls.
struct LiveScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var viewModel = LiveViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.needsOnboarding {
                    OnboardingView(
                        coreMLBytes: viewModel.coreMLDownloadBytes,
                        sherpaBytes: viewModel.sherpaDownloadBytes,
                        onInstall: { kind in
                            Task { await viewModel.install(kind) }
                        },
                        onLater: { viewModel.dismissOnboarding() }
                    )
                } else {
                    liveContent
                }
            }
            .navigationTitle(String(localized: "Live"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            viewModel.attach(environment)
            await viewModel.bootstrap()
        }
    }

    private var liveContent: some View {
        VStack(spacing: 0) {
            statusHeader
            errorBanner
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(viewModel.entries) { entry in
                            SubtitleCard(
                                entry: entry,
                                onRetryTranslation: {
                                    Task { await viewModel.retryFailedTranslations() }
                                }
                            )
                            .id(entry.sequenceID)
                        }
                        Color.clear.frame(height: 1).id(BottomAnchor.id)
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }
                .onChange(of: viewModel.entries.count) { _, _ in
                    // Follow new entries only while the user is at (or near)
                    // the bottom — never yank them back while reading history.
                    guard viewModel.isNearBottom else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(BottomAnchor.id, anchor: .bottom)
                    }
                }
                .overlay(alignment: .bottom) {
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: BottomPreferenceKey.self,
                            value: geo.frame(in: .named("scroll")).minY
                        )
                    }
                    .frame(height: 0)
                    .onPreferenceChange(BottomPreferenceKey.self) { minY in
                        viewModel.updateScrollPosition(minY: minY)
                    }
                }
            }
            controls
        }
        .refreshable { await viewModel.refreshInstallState() } // deliberate no-op pull; keeps state fresh
    }

    // MARK: - Header

    private var statusHeader: some View {
        VStack(spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("GigaAM-v3 e2e_rnnt")
                        .font(.subheadline.weight(.semibold))
                    Text(viewModel.backendDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusChip(
                    text: viewModel.state.phase.localizedLabel,
                    tint: viewModel.state.phase.chipColor
                )
            }
            WaveformView(levels: viewModel.audioLevels)
                .frame(height: 28)
            HStack(spacing: 12) {
                Label(Format.clock(viewModel.state.elapsed), systemImage: "clock")
                    .monospacedDigit()
                Label(viewModel.micRoute, systemImage: "mic")
                    .lineLimit(1)
                Spacer()
                if let latency = viewModel.state.lastASRLatency {
                    Text("ASR \(Format.seconds(latency))")
                }
                if let latency = viewModel.state.lastTranslationLatency {
                    Text("译 \(Format.seconds(latency))")
                }
                if let rtf = viewModel.state.lastRTF {
                    Text("RTF \(String(format: "%.2f", rtf))")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(.bar)
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let message = viewModel.errorBannerText {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(message)
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if viewModel.showsSwitchToOtherBackend {
                    Button(String(localized: "Switch to other installed backend")) {
                        Task { await viewModel.switchToOtherInstalledBackend() }
                    }
                    .font(.footnote.bold())
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(10)
            .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal)
            .padding(.top, 4)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 16) {
            switch viewModel.controlMode {
            case .start:
                Button {
                    Task { await viewModel.start() }
                } label: {
                    Label(String(localized: "Start"), systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canStart)
            case .running:
                Button {
                    viewModel.pause()
                } label: {
                    Label(String(localized: "Pause"), systemImage: "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button(role: .destructive) {
                    Task { await viewModel.stop() }
                } label: {
                    Label(String(localized: "End"), systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            case .paused:
                Button {
                    Task { await viewModel.resume() }
                } label: {
                    Label(String(localized: "Resume"), systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button(role: .destructive) {
                    Task { await viewModel.stop() }
                } label: {
                    Label(String(localized: "End"), systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .controlSize(.large)
        .padding()
        .background(.bar)
    }
}

/// Anchor identity for auto-scroll.
private enum BottomAnchor {
    static let id = "subtitle-list-bottom"
}

private struct BottomPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// First-launch model selection shown when no backend is installed.
struct OnboardingView: View {
    let coreMLBytes: Int
    let sherpaBytes: Int
    let onInstall: (ASRBackendKind) -> Void
    let onLater: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                    .padding(.top, 24)
                Text("GigaAM-v3 e2e_rnnt")
                    .font(.title2.bold())
                Text(String(localized: "One Russian speech recognition model, two local inference backends. Download at least one to begin. Recognition works fully offline."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                backendCard(
                    kind: .coreMLFP16,
                    bytes: coreMLBytes,
                    fallback: "≈ 446 MB",
                    note: String(localized: "Precision first · recommended for iPhone 17 Pro Max")
                )
                backendCard(
                    kind: .sherpaONNXInt8,
                    bytes: sherpaBytes,
                    fallback: "≈ 216 MB",
                    note: String(localized: "Size first · CPU inference")
                )

                Button(String(localized: "Download both")) {
                    onInstall(.coreMLFP16)
                    onInstall(.sherpaONNXInt8)
                }
                .buttonStyle(.bordered)

                Button(String(localized: "Decide later")) { onLater() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 24)
            }
            .padding(.horizontal)
        }
    }

    private func backendCard(kind: ASRBackendKind, bytes: Int, fallback: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(kind.displayName).font(.headline)
            Text("\(String(localized: "Download")) \(bytes > 0 ? Format.bytes(bytes) : fallback)")
                .font(.subheadline)
            Text(note).font(.caption).foregroundStyle(.secondary)
            Button(String(localized: "Download")) { onInstall(kind) }
                .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }
}
