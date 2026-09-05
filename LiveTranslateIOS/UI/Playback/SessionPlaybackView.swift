import SwiftUI

/// Full classroom-recording playback page (pushed from the detail's
/// bottom player). Real waveform, current-entry highlight with
/// auto-follow, timeline markers for notes/images/bookmarks, and the
/// standard transport (seek / ±15 s / speed). Correction entries hang off
/// each row's context menu.
struct SessionPlaybackView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewModel = PlaybackViewModel()
    @State private var correctionEditor: CorrectionEditorContext?
    let sessionID: UUID
    /// Entry to start from (a jump landed here from elsewhere).
    var initialEntryID: UUID?

    struct CorrectionEditorContext: Identifiable {
        let entry: TranscriptEntry
        var id: UUID { entry.id }
    }

    var body: some View {
        LTPage {
            Group {
                if viewModel.isLoaded, viewModel.session == nil {
                    LTEmptyState(
                        symbol: "questionmark.folder",
                        title: "课堂不存在",
                        message: "这条记录可能已被删除"
                    )
                } else if viewModel.isLoaded, viewModel.recording == nil
                    || viewModel.recording?.isDeleted == true {
                    LTEmptyState(
                        symbol: "waveform.slash",
                        title: "本堂课没有录音",
                        message: "文字记录、笔记和图片不受影响"
                    )
                } else if viewModel.isLoaded {
                    content
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("课堂回放")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            viewModel.attach(environment)
            viewModel.load(sessionID: sessionID)
            viewModel.loadRecording()
            if let initialEntryID,
               let entry = viewModel.entries.first(where: { $0.id == initialEntryID }) {
                // One layout pass, then position before playing.
                try? await Task.sleep(for: .milliseconds(150))
                _ = viewModel.playFrom(entry: entry)
            }
        }
        .onDisappear {
            // Leaving the page keeps the audio playing only when the user
            // explicitly asked (mini player). Here we keep state; the mini
            // player on the detail page continues the same engine.
        }
        .sheet(item: $correctionEditor) { context in
            TranscriptCorrectionView(sessionID: sessionID, entry: context.entry)
                .environment(environment)
                .onDisappear { viewModel.reload() }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: LTSpacing.l) {
                        waveformCard
                        transportCard
                        markerLegend
                        transcriptList
                    }
                    .padding(.horizontal, LTSpacing.screenPadding)
                    .padding(.top, LTSpacing.s)
                    .padding(.bottom, 90)
                }
                .onChange(of: viewModel.currentEntry?.sequenceID) { _, target in
                    guard viewModel.shouldAutoFollow, let target else { return }
                    if reduceMotion {
                        proxy.scrollTo(target, anchor: .center)
                    } else {
                        withAnimation(LTMotion.quick) {
                            proxy.scrollTo(target, anchor: .center)
                        }
                    }
                }
                .onChange(of: viewModel.pendingScrollTarget) { _, target in
                    guard let target else { return }
                    withAnimation(LTMotion.resolved(reduceMotion)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                    viewModel.pendingScrollTarget = nil
                }
                .simultaneousGesture(
                    DragGesture().onChanged { value in
                        // Any deliberate scroll suspends auto-follow.
                        if abs(value.translation.height) > 12 {
                            viewModel.isFollowSuspended = true
                        }
                    }
                )
            }
        }
    }

    // MARK: - Waveform

    /// Real precomputed peaks when available; otherwise the plain
    /// progress bar remains the source of truth and an honest hint shows.
    @ViewBuilder
    private var waveformCard: some View {
        if let playback = viewModel.playback, playback.phase != .idle {
            VStack(alignment: .leading, spacing: LTSpacing.xs) {
                HStack {
                    Text("录音")
                        .font(LTTypography.cardTitle)
                        .foregroundStyle(LTColors.textPrimary)
                    if playback.isLoadedFileIncomplete {
                        StatusChip(text: "录音不完整", tint: LTColors.warning)
                    }
                    Spacer()
                    Text("\(TranscriptExporter.mmss(playback.currentTime)) / \(TranscriptExporter.mmss(playback.totalDuration))")
                        .font(LTTypography.timestamp)
                        .foregroundStyle(LTColors.textSecondary)
                }
                if case .failed(let message) = playback.phase {
                    Text(message)
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.warning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    WaveformStrip(
                        buckets: viewModel.waveform,
                        progress: playback.totalDuration > 0
                            ? playback.currentTime / playback.totalDuration : 0,
                        onScrub: { fraction in
                            playback.seek(to: fraction * playback.totalDuration)
                        }
                    )
                    if viewModel.waveform.isEmpty {
                        Text(environment.waveformStore.isGenerating
                            ? "正在准备波形…" : "无波形 · 仍可正常播放")
                            .font(LTTypography.caption)
                            .foregroundStyle(LTColors.textTertiary)
                    }
                }
            }
            .ltCard()
        }
    }

    // MARK: - Transport

    @ViewBuilder
    private var transportCard: some View {
        if let playback = viewModel.playback {
            VStack(spacing: LTSpacing.s) {
                HStack(spacing: LTSpacing.l) {
                    Button {
                        playback.skip(by: -15)
                        LTHaptics.tap()
                    } label: {
                        Image(systemName: "gobackward.15")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(LTColors.textPrimary)
                            .frame(width: LTSpacing.minTouchTarget, height: LTSpacing.minTouchTarget)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(Text("后退 15 秒"))

                    Button {
                        playback.togglePlayPause()
                        LTHaptics.tap()
                    } label: {
                        Image(systemName: playback.phase == .playing
                            ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 44, weight: .regular))
                            .foregroundStyle(LTColors.accentGreen)
                            .frame(width: LTSpacing.minTouchTarget, height: LTSpacing.minTouchTarget)
                            .contentShape(Rectangle())
                    }
                    .disabled(playback.phase != .playing && playback.phase != .paused
                        && playback.phase != .interrupted)
                    .accessibilityLabel(Text(playback.phase == .playing ? "暂停" : "播放"))

                    Button {
                        playback.skip(by: 15)
                        LTHaptics.tap()
                    } label: {
                        Image(systemName: "goforward.15")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(LTColors.textPrimary)
                            .frame(width: LTSpacing.minTouchTarget, height: LTSpacing.minTouchTarget)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(Text("前进 15 秒"))

                    Spacer()

                    Menu {
                        ForEach(PlaybackSpeed.allCases) { speed in
                            Button(speed.label) {
                                playback.setSpeed(speed)
                            }
                        }
                    } label: {
                        Text(playback.speed.label)
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(LTColors.accentBlue)
                            .padding(.horizontal, LTSpacing.s)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(LTColors.accentBlue.opacity(0.12))
                            )
                            .overlay(Capsule().strokeBorder(LTColors.accentBlue.opacity(0.3), lineWidth: 0.5))
                    }
                    .accessibilityLabel(Text("播放速度"))
                }
                if viewModel.isFollowSuspended {
                    Button {
                        viewModel.resumeFollowing()
                    } label: {
                        Label("回到当前内容", systemImage: "location")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(LTColors.accentCyan)
                    }
                }
            }
            .ltCard()
        }
    }

    private var markerLegend: some View {
        VStack(alignment: .leading, spacing: LTSpacing.xs) {
            // The marker strip: note/image/bookmark positions along the
            // recording's duration. Tapping a marker jumps (and plays)
            // there; markers < 2 s apart aggregate into one.
            TimelineMarkerStrip(
                markers: viewModel.timelineMarkers,
                duration: viewModel.playback?.totalDuration ?? 0,
                onTapMarker: { marker in
                    guard let playback = viewModel.playback else { return }
                    playback.seek(to: max(0, marker.offset - 1.0))
                    playback.play()
                    if let sequence = marker.entrySequenceID {
                        viewModel.pendingScrollTarget = sequence
                    }
                }
            )
            HStack(spacing: LTSpacing.m) {
                legendItem(symbol: "pencil.line", color: LTColors.warning, label: "笔记")
                legendItem(symbol: "photo", color: LTColors.accentBlue, label: "图片")
                legendItem(symbol: "bookmark.fill", color: LTColors.accentGreen, label: "书签")
                Spacer()
            }
            .font(LTTypography.caption)
        }
    }

    private func legendItem(symbol: String, color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.caption2)
            Text(label)
        }
        .foregroundStyle(color.opacity(0.9))
    }

    // MARK: - Transcript

    private var transcriptList: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            HStack {
                LTSectionHeader(title: "对照转录")
                if let current = viewModel.currentEntry {
                    Text(TranscriptExporter.mmss(current.startOffset))
                        .font(LTTypography.timestamp)
                        .foregroundStyle(LTColors.textTertiary)
                }
                Spacer()
            }
            LazyVStack(alignment: .leading, spacing: LTSpacing.s) {
                ForEach(viewModel.entries, id: \.sequenceID) { entry in
                    PlaybackEntryRow(
                        entry: entry,
                        isCurrent: viewModel.currentEntry?.id == entry.id,
                        isCorrected: viewModel.isCorrected(entry),
                        chinese: viewModel.effectiveChinese(entry),
                        russian: viewModel.effectiveRussian(entry),
                        onPlayFrom: { _ = viewModel.playFrom(entry: entry) },
                        onCorrect: { correctionEditor = CorrectionEditorContext(entry: entry) }
                    )
                    .id(entry.sequenceID)
                }
            }
        }
    }
}

// MARK: - Waveform strip

/// Real waveform: one bar per bucket from the precomputed peaks; tapping
/// or dragging scrubs. Without buckets it degrades to a plain progress
/// bar (the surrounding card says so).
struct WaveformStrip: View {
    let buckets: [Float]
    let progress: Double
    let onScrub: (Double) -> Void

    @State private var isScrubbing = false
    /// The strip's width, captured via GeometryReader (the gesture closure
    /// cannot see the geometry value directly).
    @State private var stripWidth: CGFloat = 1

    var body: some View {
        GeometryReader { geometry in
            Group {
                if buckets.isEmpty {
                    progressBar
                } else {
                    bars
                }
            }
            .onAppear { stripWidth = max(1, geometry.size.width) }
            .onChange(of: geometry.size.width) { _, width in
                stripWidth = max(1, width)
            }
        }
        .frame(height: 48)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    isScrubbing = true
                    let fraction = min(max(0, value.location.x / stripWidth), 1)
                    onScrub(fraction)
                }
                .onEnded { _ in isScrubbing = false }
        )
        .accessibilityLabel(Text("播放进度"))
        .accessibilityValue(Text("\(Int(progress * 100)) percent"))
    }

    @ViewBuilder
    private var bars: some View {
        let count = max(1, buckets.count)
        let barWidth = max(1.5, (stripWidth - CGFloat(count - 1)) / CGFloat(count))
        let headIndex = Int(progress * Double(count))
        HStack(alignment: .center, spacing: 1) {
            ForEach(0..<count, id: \.self) { index in
                let height = max(3, CGFloat(buckets[index]) * 44)
                RoundedRectangle(cornerRadius: 1)
                    .fill(index <= headIndex
                        ? LTColors.accentGreen.opacity(0.85)
                        : LTColors.textTertiary.opacity(0.35))
                    .frame(width: barWidth, height: height)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var progressBar: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(LTColors.textTertiary.opacity(0.25))
            Capsule()
                .fill(LTColors.accentGreen.opacity(0.8))
                .frame(width: max(6, stripWidth * progress))
        }
    }
}

// MARK: - Playback entry row

private struct PlaybackEntryRow: View {
    let entry: TranscriptEntry
    let isCurrent: Bool
    let isCorrected: Bool
    let chinese: String?
    let russian: String
    var onPlayFrom: () -> Void = {}
    var onCorrect: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: LTSpacing.m) {
            Button(action: onPlayFrom) {
                Text(TranscriptExporter.mmss(entry.startOffset))
                    .font(LTTypography.timestamp.monospacedDigit())
                    .foregroundStyle(isCurrent ? LTColors.accentGreen : LTColors.accentCyan)
                    .frame(width: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("从 \(TranscriptExporter.mmss(entry.startOffset)) 播放"))

            VStack(alignment: .leading, spacing: LTSpacing.xxs) {
                if let chinese, !chinese.isEmpty {
                    Text(chinese)
                        .font(.subheadline)
                        .foregroundStyle(LTColors.textPrimary)
                        .textSelection(.enabled)
                }
                Text(russian)
                    .font(.footnote)
                    .foregroundStyle(LTColors.textSecondary)
                    .textSelection(.enabled)
                if isCorrected {
                    Text("已修正")
                        .font(LTTypography.timestamp)
                        .foregroundStyle(LTColors.accentCyan.opacity(0.9))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(LTSpacing.s)
        .background(
            RoundedRectangle(cornerRadius: LTRadius.small)
                .fill(isCurrent ? LTColors.accentGreen.opacity(0.07) : LTColors.surfacePrimary.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: LTRadius.small)
                .strokeBorder(
                    isCurrent ? LTColors.accentGreen.opacity(0.4) : LTColors.border,
                    lineWidth: isCurrent ? 1 : 0.5
                )
        )
        .contentShape(Rectangle())
        .onTapGesture { onPlayFrom() }
        .contextMenu {
            Button(action: onPlayFrom) {
                Label("从这里播放", systemImage: "play")
            }
            Button(action: onCorrect) {
                Label("校正这段文字", systemImage: "pencil.line")
            }
            Button {
                ClipboardService.shared.copySensitive(russian)
            } label: {
                Label("复制俄语", systemImage: "doc.on.doc")
            }
            if let chinese, !chinese.isEmpty {
                Button {
                    ClipboardService.shared.copySensitive(chinese)
                } label: {
                    Label("复制中文", systemImage: "doc.on.doc")
                }
            }
        }
    }
}

// MARK: - Mini player (session detail bottom bar)

/// Compact playback bar for the classroom detail page: play/pause, times,
/// progress, ±15 s and the expand affordance. Hidden entirely when the
/// session has no recording — never a disabled stub.
struct SessionMiniPlayerView: View {
    @Environment(AppEnvironment.self) private var environment
    let sessionID: UUID
    var onExpand: () -> Void

    var body: some View {
        let playback = environment.playback
        let isFailed: Bool = {
            if case .failed = playback.phase { return true }
            return false
        }()
        VStack(spacing: LTSpacing.xxs) {
            HStack(spacing: LTSpacing.m) {
                Button {
                    playback.togglePlayPause()
                    LTHaptics.tap()
                } label: {
                    Image(systemName: playback.phase == .playing
                        ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(
                            isFailed ? LTColors.textTertiary : LTColors.accentGreen
                        )
                        .frame(width: LTSpacing.minTouchTarget, height: LTSpacing.minTouchTarget)
                        .contentShape(Rectangle())
                }
                .disabled(playback.phase != .playing && playback.phase != .paused
                    && playback.phase != .interrupted)
                .accessibilityLabel(Text(playback.phase == .playing ? "暂停录音" : "播放录音"))

                VStack(alignment: .leading, spacing: 2) {
                    if case .failed(let message) = playback.phase {
                        Text(message)
                            .font(LTTypography.caption)
                            .foregroundStyle(LTColors.warning)
                            .lineLimit(2)
                    } else {
                        Text("\(TranscriptExporter.mmss(playback.currentTime)) / \(TranscriptExporter.mmss(playback.totalDuration))")
                            .font(LTTypography.timestamp.monospacedDigit())
                            .foregroundStyle(LTColors.textSecondary)
                        if playback.isLoadedFileIncomplete {
                            Text("录音不完整 · 可能中断于课堂结束")
                                .font(LTTypography.timestamp)
                                .foregroundStyle(LTColors.textTertiary)
                        }
                    }
                }

                Spacer()

                Button {
                    playback.skip(by: -15)
                } label: {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(LTColors.textSecondary)
                        .frame(width: LTSpacing.minTouchTarget, height: LTSpacing.minTouchTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text("后退 15 秒"))

                Button {
                    playback.skip(by: 15)
                } label: {
                    Image(systemName: "goforward.15")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(LTColors.textSecondary)
                        .frame(width: LTSpacing.minTouchTarget, height: LTSpacing.minTouchTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text("前进 15 秒"))

                Button(action: onExpand) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(LTColors.accentCyan)
                        .frame(width: LTSpacing.minTouchTarget, height: LTSpacing.minTouchTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text("展开完整回放"))
            }
            // Slim real progress line (no waveform in the mini bar).
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(LTColors.textTertiary.opacity(0.25))
                    Capsule()
                        .fill(LTColors.accentGreen.opacity(0.7))
                        .frame(width: playback.totalDuration > 0
                            ? max(4, geometry.size.width * playback.currentTime / playback.totalDuration)
                            : 0)
                }
            }
            .frame(height: 3)
        }
        .padding(.horizontal, LTSpacing.m)
        .padding(.vertical, LTSpacing.xs + 2)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Timeline marker strip

/// Lightweight time markers (notes / images / bookmarks) along the
/// recording. Deliberately restrained: small dots on a hairline, no
/// labels (the transcript list above disambiguates), aggregation handled
/// upstream. Tapping a marker seeks and plays.
struct TimelineMarkerStrip: View {
    let markers: [PlaybackViewModel.TimelineMarker]
    let duration: TimeInterval
    var onTapMarker: (PlaybackViewModel.TimelineMarker) -> Void

    var body: some View {
        if duration > 0, !markers.isEmpty {
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(LTColors.separator)
                        .frame(height: 1)
                        .frame(maxWidth: .infinity)
                    ForEach(markers) { marker in
                        let x = min(max(0, marker.offset / duration), 1) * width
                        Circle()
                            .fill(color(for: marker.kind))
                            .frame(width: 7, height: 7)
                            .position(x: x, y: geometry.size.height / 2)
                            .onTapGesture {
                                onTapMarker(marker)
                                LTHaptics.tap()
                            }
                    }
                }
            }
            .frame(height: 18)
            .accessibilityLabel(Text("时间轴标记"))
            .accessibilityValue(Text("\(markers.count) 个标记"))
        }
    }

    private func color(for kind: PlaybackViewModel.TimelineMarker.Kind) -> Color {
        switch kind {
        case .note: return LTColors.warning.opacity(0.9)
        case .attachment: return LTColors.accentBlue.opacity(0.9)
        case .bookmark: return LTColors.accentGreen.opacity(0.9)
        }
    }
}
