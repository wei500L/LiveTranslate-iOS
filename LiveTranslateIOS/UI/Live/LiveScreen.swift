import SwiftUI

/// Full-screen live classroom (reference image 3): lyric-style bilingual
/// feed where the *current Chinese translation* is the focus, the waveform
/// mirrors real microphone levels, and all controls drive the real
/// pipeline coordinator. The global tab bar is hidden while this screen is
/// presented.
struct LiveScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewModel = LiveViewModel()
    @State private var showEndConfirmation = false

    var body: some View {
        ZStack {
            LTBackground()
            VStack(spacing: 0) {
                topBar
                waveformStrip
                errorBanner
                translationConfigBanner
                content
                tabBar
                controlsBar
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(viewModel.isRunning)
        .task { viewModel.attach(environment) }
        .confirmationDialog(
            "结束这堂课？",
            isPresented: $showEndConfirmation,
            titleVisibility: .visible
        ) {
            Button("结束课堂", role: .destructive) {
                Task { await endSession() }
            }
            Button("继续听课", role: .cancel) {}
        } message: {
            Text("剩余语音会完成识别与翻译后保存，可稍后在课堂记录中查看。")
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: LTSpacing.s) {
            Button {
                // Collapse: a running session keeps running behind the home
                // tab (which shows an ongoing banner); after the classroom
                // ends this simply returns home.
                environment.flow.collapseLive()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LTColors.textSecondary)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(LTColors.surfacePrimary))
                    .overlay(Circle().strokeBorder(LTColors.border, lineWidth: 0.5))
                    .frame(width: LTSpacing.minTouchTarget, height: LTSpacing.minTouchTarget)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text(viewModel.isRunning ? "收起课堂，课堂继续进行" : "返回"))
            VStack(alignment: .leading, spacing: 1) {
                Text(viewModel.sessionTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LTColors.textPrimary)
                    .lineLimit(1)
                HStack(spacing: LTSpacing.xs) {
                    LTActivityDot(active: viewModel.isRunning && !viewModel.isPaused)
                    Text(Format.clock(viewModel.state.elapsed))
                        .font(LTTypography.timestamp.monospacedDigit())
                        .foregroundStyle(LTColors.textSecondary)
                }
            }
            Spacer()
            StatusChip(
                text: viewModel.state.phase.localizedLabel,
                tint: viewModel.state.phase.chipColor
            )
        }
        .padding(.horizontal, LTSpacing.screenPadding)
        .padding(.top, LTSpacing.s)
        .padding(.bottom, LTSpacing.xs)
    }

    /// Real microphone level history pushed by the capture service (~10 Hz
    /// while live). No timeline animation: it only redraws when new audio
    /// data arrives, so a paused or interrupted mic freezes the bars.
    private var waveformStrip: some View {
        WaveformView(levels: viewModel.audioLevels)
            .frame(height: 26)
            .padding(.horizontal, LTSpacing.screenPadding)
            .padding(.bottom, LTSpacing.xs)
            .opacity(viewModel.isPaused ? 0.35 : 1)
            .animation(LTMotion.quick, value: viewModel.isPaused)
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let message = viewModel.errorBannerText {
            HStack(spacing: LTSpacing.s) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(LTColors.warning)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(LTColors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if viewModel.showsSwitchToOtherBackend {
                    Button("切换到另一后端") {
                        Task { await viewModel.switchToOtherInstalledBackend() }
                    }
                    .font(.footnote.bold())
                    .buttonStyle(LTSecondaryButtonStyle(tint: LTColors.accentBlue))
                }
            }
            .padding(LTSpacing.s)
            .background(LTColors.destructive.opacity(0.12), in: RoundedRectangle(cornerRadius: LTRadius.small))
            .overlay(
                RoundedRectangle(cornerRadius: LTRadius.small)
                    .strokeBorder(LTColors.destructive.opacity(0.3), lineWidth: 0.5)
            )
            .padding(.horizontal, LTSpacing.screenPadding)
            .padding(.bottom, LTSpacing.xs)
        }
    }

    // MARK: - Content

    /// Shown only when the user *wants* translation but no service is
    /// configured. (Translation deliberately turned off shows nothing —
    /// that is an intent, not a problem to fix.)
    @ViewBuilder
    private var translationConfigBanner: some View {
        if viewModel.isTranslationWanted && !viewModel.isTranslationConfigured {
            HStack(spacing: LTSpacing.s) {
                Image(systemName: "gearshape.badge.questionmark")
                    .foregroundStyle(LTColors.warning)
                Text("翻译服务未配置 · 俄语原文仍会保存")
                    .font(.footnote)
                    .foregroundStyle(LTColors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("前往设置") {
                    // Collapses the classroom (it keeps running) and lands
                    // on the 我的 tab, where translation settings live.
                    environment.flow.collapseLive(to: .profile)
                }
                .font(.footnote.bold())
                .buttonStyle(LTSecondaryButtonStyle(tint: LTColors.accentBlue))
            }
            .padding(LTSpacing.s)
            .background(LTColors.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: LTRadius.small))
            .overlay(
                RoundedRectangle(cornerRadius: LTRadius.small)
                    .strokeBorder(LTColors.warning.opacity(0.28), lineWidth: 0.5)
            )
            .padding(.horizontal, LTSpacing.screenPadding)
            .padding(.bottom, LTSpacing.xs)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.selectedTab {
        case .transcript: TranscriptFeed(viewModel: viewModel, reduceMotion: reduceMotion)
        case .notes: LiveNotesTab(viewModel: viewModel)
        case .bookmarks: LiveBookmarksTab(viewModel: viewModel)
        case .search: LiveSearchTab(viewModel: viewModel)
        }
    }

    // MARK: - In-class toolbar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(LiveViewModel.LiveTab.allCases) { tab in
                Button {
                    withAnimation(LTMotion.resolved(reduceMotion)) {
                        viewModel.selectedTab = tab
                    }
                    LTHaptics.tap()
                } label: {
                    Text(tab.title)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(
                            viewModel.selectedTab == tab ? LTColors.accentGreen : LTColors.textSecondary
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, LTSpacing.xs + 2)
                        .background {
                            if viewModel.selectedTab == tab {
                                Capsule().fill(LTColors.accentGreen.opacity(0.15))
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(viewModel.selectedTab == tab ? [.isSelected] : [])
            }
        }
        .padding(LTSpacing.xxs + 1)
        .background(Capsule().fill(LTColors.surfacePrimary.opacity(0.9)))
        .overlay(Capsule().strokeBorder(LTColors.border, lineWidth: 0.5))
        .padding(.horizontal, LTSpacing.screenPadding)
        .padding(.top, LTSpacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("课堂工具栏"))
    }

    // MARK: - Session controls

    private var controlsBar: some View {
        HStack(spacing: LTSpacing.l) {
            // 书签: mark the current entry as a key point.
            Button {
                if viewModel.bookmarkCurrent() {
                    LTHaptics.success()
                } else {
                    LTHaptics.warning()
                }
            } label: {
                Image(systemName: "bookmark")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(LTColors.textSecondary)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(LTColors.surfacePrimary))
                    .overlay(Circle().strokeBorder(LTColors.border, lineWidth: 0.5))
            }
            .accessibilityLabel(Text("标记当前内容为书签"))

            controlSpacer

            switch viewModel.state.phase {
            case .finished:
                finishedControls
            case .idle:
                idleControls
            case .backendError:
                // start() admits the backendError phase, so a real retry
                // with the same backend is possible here.
                errorControls
            case .modelNotInstalled:
                // start() does not admit this phase — retrying would be a
                // silent no-op. The way out is the banner's 切换到另一后端
                // (when the other runtime is installed) or going back and
                // installing the resources.
                idleControls
            default:
                if viewModel.isPaused {
                    pausedControls
                } else {
                    runningControls
                }
            }

            controlSpacer

            // End classroom (destructive, with confirmation).
            Button {
                showEndConfirmation = true
                LTHaptics.warning()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(LTColors.destructive)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(LTColors.destructive.opacity(0.14)))
                    .overlay(Circle().strokeBorder(LTColors.destructive.opacity(0.35), lineWidth: 0.5))
            }
            .disabled(!viewModel.isRunning)
            .opacity(viewModel.isRunning ? 1 : 0.35)
            .accessibilityLabel(Text("结束课堂"))
        }
        .padding(.horizontal, LTSpacing.screenPadding)
        .padding(.vertical, LTSpacing.s)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
    }

    private var controlSpacer: some View {
        Spacer().frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var runningControls: some View {
        Button {
            viewModel.pause()
            LTHaptics.tap()
        } label: {
            HStack(spacing: LTSpacing.xs) {
                Image(systemName: "pause.fill")
                Text("暂停")
            }
            .font(LTTypography.button)
            .foregroundStyle(LTColors.textPrimary)
            .padding(.horizontal, LTSpacing.xl)
            .padding(.vertical, LTSpacing.xs + 4)
            .background(Capsule().fill(LTColors.surfaceElevated))
            .overlay(Capsule().strokeBorder(LTColors.border, lineWidth: 0.5))
        }
        .accessibilityLabel(Text("暂停课堂"))
    }

    @ViewBuilder
    private var pausedControls: some View {
        Button {
            viewModel.resume()
            LTHaptics.tap()
        } label: {
            HStack(spacing: LTSpacing.xs) {
                Image(systemName: "play.fill")
                Text("继续")
            }
            .font(LTTypography.button)
            .foregroundStyle(Color.black.opacity(0.85))
            .padding(.horizontal, LTSpacing.xl)
            .padding(.vertical, LTSpacing.xs + 4)
            .background(Capsule().fill(LTColors.accentGreen))
            .shadow(color: LTColors.accentGreen.opacity(0.35), radius: 8, y: 2)
        }
        .accessibilityLabel(Text("继续课堂"))
    }

    /// Shown once the classroom has ended: a summary + return home.
    @ViewBuilder
    private var finishedControls: some View {
        Button {
            environment.flow.collapseLive()
        } label: {
            HStack(spacing: LTSpacing.xs) {
                Image(systemName: "checkmark.circle.fill")
                Text("课堂已结束 · 返回首页")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.black.opacity(0.85))
            .padding(.horizontal, LTSpacing.l)
            .padding(.vertical, LTSpacing.xs + 4)
            .background(Capsule().fill(LTColors.accentGreen))
        }
        .accessibilityLabel(Text("课堂已结束，返回首页"))
    }

    /// Edge state: the classroom view opened with no session (e.g. an
    /// aborted start). Nothing to control — just go home.
    @ViewBuilder
    private var idleControls: some View {
        Button {
            environment.flow.collapseLive()
        } label: {
            HStack(spacing: LTSpacing.xs) {
                Image(systemName: "arrow.down.circle")
                Text("尚未开始 · 返回")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(LTColors.textPrimary)
            .padding(.horizontal, LTSpacing.l)
            .padding(.vertical, LTSpacing.xs + 4)
            .background(Capsule().fill(LTColors.surfaceElevated))
            .overlay(Capsule().strokeBorder(LTColors.border, lineWidth: 0.5))
        }
        .accessibilityLabel(Text("课堂尚未开始，返回"))
    }

    /// The engine failed while listening: an explicit retry bound to the
    /// real coordinator start (never a silent backend switch).
    @ViewBuilder
    private var errorControls: some View {
        Button {
            Task { await viewModel.restartSession() }
        } label: {
            HStack(spacing: LTSpacing.xs) {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("重试启动")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.black.opacity(0.85))
            .padding(.horizontal, LTSpacing.l)
            .padding(.vertical, LTSpacing.xs + 4)
            .background(Capsule().fill(LTColors.warning.opacity(0.85)))
        }
        .accessibilityLabel(Text("重试启动课堂"))
    }

    // MARK: - Actions

    private func endSession() async {
        await viewModel.stop()
        LTHaptics.success()
    }
}
