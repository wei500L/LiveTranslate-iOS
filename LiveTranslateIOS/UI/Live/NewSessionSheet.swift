import SwiftUI
import AVFoundation

/// New-classroom form (reference image 2). Presented as a sheet from the
/// home start card; on 开始课堂 it validates, starts the real pipeline
/// coordinator and hands over to the full-screen classroom.
struct NewSessionSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var isStarting = false
    @State private var nameError: String?
    /// Start-chain validation / launch failure (distinct from nameError so
    /// the two never fight over the same slot).
    @State private var startError: String?
    @State private var micAuthorized = true
    @State private var preferredBackendInstalled = true
    @State private var isRequestingPermission = false
    @State private var showModelManagement = false
    /// Set only after a successful coordinator start; the classroom is
    /// presented from onDisappear, once this sheet has fully animated out.
    @State private var shouldOpenLive = false
    @FocusState private var nameFieldFocused: Bool

    private let nameLimit = 60

    var body: some View {
        NavigationStack {
            LTPage {
                ScrollView {
                    VStack(alignment: .leading, spacing: LTSpacing.l) {
                        titleBlock
                        nameSection
                        directionSection
                        liveSettingsSection
                        storageSection
                        micSection
                        startButton
                    }
                    .padding(.horizontal, LTSpacing.screenPadding)
                    .padding(.vertical, LTSpacing.l)
                }
            }
            .navigationTitle("新建课堂")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showModelManagement) {
                ModelManagementScreen()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(LTColors.textSecondary)
                    }
                    .accessibilityLabel(Text("关闭"))
                    .disabled(isStarting || isRequestingPermission)
                }
                ToolbarItem(placement: .keyboard) {
                    HStack {
                        Spacer()
                        Button("收起键盘") { nameFieldFocused = false }
                            .font(.footnote)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        // No dismissal path — interactive or otherwise — while a start (or
        // the system permission dialog) is in flight, so no task can end up
        // writing @State after the sheet is gone.
        .interactiveDismissDisabled(isStarting || isRequestingPermission)
        .onDisappear {
            // Present the classroom only after the sheet has fully
            // dismissed: requesting the full-screen cover mid-dismissal can
            // be dropped by UIKit ("attempt to present while a presentation
            // is in progress"). shouldOpenLive is set only by a successful
            // start(), so a cancelled sheet (xmark, swipe-down, or a push
            // inside this stack) never triggers this.
            if shouldOpenLive {
                environment.flow.openLive()
            }
        }
        .task {
            micAuthorized = AVAudioApplication.shared.recordPermission == .granted
            preferredBackendInstalled = await environment.engineManager.isInstalled(
                environment.settings.preferredBackend
            )
        }
    }

    // MARK: - Header

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("为新课堂命名")
                .font(.title3.weight(.bold))
                .foregroundStyle(LTColors.textPrimary)
            Text("俄语授课将被实时转写并翻译成中文，全程自动保存")
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.textSecondary)
        }
    }

    // MARK: - Name

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: LTSpacing.xs) {
            Text("课堂名称")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(LTColors.textSecondary)
            TextField("例如：高等数学 · 第三章", text: $name)
                .font(.body)
                .focused($nameFieldFocused)
                .submitLabel(.done)
                .onSubmit { nameFieldFocused = false }
                .onChange(of: name) { _, newValue in
                    if newValue.count > nameLimit {
                        name = String(newValue.prefix(nameLimit))
                    }
                    if nameError != nil {
                        nameError = nil
                    }
                }
                .padding(LTSpacing.m)
                .background(
                    RoundedRectangle(cornerRadius: LTRadius.small)
                        .fill(LTColors.surfacePrimary)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: LTRadius.small)
                        .strokeBorder(
                            nameError != nil ? LTColors.destructive.opacity(0.7) : LTColors.border,
                            lineWidth: 0.8
                        )
                )
            HStack {
                if let nameError {
                    Text(nameError)
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.destructive)
                }
                Spacer()
                Text("\(name.count)/\(nameLimit)")
                    .font(LTTypography.timestamp)
                    .foregroundStyle(LTColors.textTertiary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - Direction

    private var directionSection: some View {
        VStack(alignment: .leading, spacing: LTSpacing.xs) {
            Text("翻译方向")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(LTColors.textSecondary)
            HStack(spacing: LTSpacing.s) {
                directionBadge(text: "俄语", symbol: "globe.europe.africa.fill")
                Image(systemName: "arrow.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(LTColors.accentGreen)
                directionBadge(text: "简体中文", symbol: "character.book.closed.fill")
                Spacer()
                Text("当前版本固定")
                    .font(LTTypography.timestamp)
                    .foregroundStyle(LTColors.textTertiary)
            }
            .padding(LTSpacing.m)
            .background(
                RoundedRectangle(cornerRadius: LTRadius.small)
                    .fill(LTColors.surfacePrimary)
            )
            .overlay(RoundedRectangle(cornerRadius: LTRadius.small).strokeBorder(LTColors.border, lineWidth: 0.5))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("翻译方向固定为俄语到简体中文"))
    }

    private func directionBadge(text: String, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.caption)
            Text(text)
                .font(.subheadline.weight(.medium))
        }
        .foregroundStyle(LTColors.textPrimary)
    }

    // MARK: - Core settings

    private var liveSettingsSection: some View {
        VStack(spacing: 0) {
            Toggle(isOn: liveTranslationBinding) {
                settingLabel(
                    title: "实时翻译",
                    detail: "关闭后仅转写并保存俄语原文；重新开启只对新段落生效",
                    symbol: "translate"
                )
            }
            .tint(LTColors.accentGreen)
            .padding(LTSpacing.m)
            Divider().overlay(LTColors.separator)
            settingRow(
                title: "自动保存",
                detail: "俄语原文识别后立即保存在本地，无法关闭",
                symbol: "externaldrive.badge.checkmark",
                trailing: StatusChip(text: "已开启", tint: LTColors.accentGreen)
            )
            Divider().overlay(LTColors.separator)
            localASRRow
        }
        .background(RoundedRectangle(cornerRadius: LTRadius.small).fill(LTColors.surfacePrimary))
        .overlay(RoundedRectangle(cornerRadius: LTRadius.small).strokeBorder(LTColors.border, lineWidth: 0.5))
    }

    /// 本地转写 state is bound to the real install state; tapping when not
    /// ready routes to model management.
    @ViewBuilder
    private var localASRRow: some View {
        HStack(spacing: LTSpacing.s) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 15))
                .foregroundStyle(LTColors.accentCyan)
            VStack(alignment: .leading, spacing: 1) {
                Text("本地转写")
                    .font(.subheadline)
                    .foregroundStyle(LTColors.textPrimary)
                Text(preferredBackendInstalled ? "本地模式 · 已就绪" : "语言资源未准备好")
                    .font(LTTypography.caption)
                    .foregroundStyle(preferredBackendInstalled ? LTColors.textSecondary : LTColors.warning)
            }
            Spacer()
            if preferredBackendInstalled {
                StatusChip(text: "本地转写可用", tint: LTColors.accentGreen)
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(LTColors.textTertiary)
            }
        }
        .padding(LTSpacing.m)
        .contentShape(Rectangle())
        .onTapGesture {
            if !preferredBackendInstalled {
                showModelManagement = true
            }
        }
        .accessibilityHint(preferredBackendInstalled ? Text("") : Text("语言资源未安装，双击前往语言资源管理"))
    }

    // MARK: - Mic

    private var storageSection: some View {
        HStack(spacing: LTSpacing.s) {
            Image(systemName: "mic.badge.plus")
                .font(.system(size: 15))
                .foregroundStyle(micAuthorized ? LTColors.accentGreen : LTColors.warning)
            VStack(alignment: .leading, spacing: 1) {
                Text("麦克风来源")
                    .font(.subheadline)
                    .foregroundStyle(LTColors.textPrimary)
                Text(micAuthorized ? currentMicRoute : "未授权 · 请先在系统设置中允许麦克风")
                    .font(LTTypography.caption)
                    .foregroundStyle(micAuthorized ? LTColors.textSecondary : LTColors.warning)
            }
            Spacer()
            if !micAuthorized {
                Button("前往授权") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(LTColors.accentBlue)
            }
        }
        .padding(LTSpacing.m)
        .background(RoundedRectangle(cornerRadius: LTRadius.small).fill(LTColors.surfacePrimary))
        .overlay(RoundedRectangle(cornerRadius: LTRadius.small).strokeBorder(LTColors.border, lineWidth: 0.5))
    }

    private var currentMicRoute: String {
        let inputs = AVAudioSession.sharedInstance().currentRoute.inputs
        if let input = inputs.first {
            return input.portType == .builtInMic ? "iPhone 麦克风" : input.portName
        }
        return "iPhone 麦克风"
    }

    // MARK: - Start

    private var startButton: some View {
        VStack(spacing: LTSpacing.s) {
            if let startError {
                Text(startError)
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.destructive)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                Task { await start() }
            } label: {
                HStack(spacing: LTSpacing.s) {
                    if isStarting || isRequestingPermission {
                        ProgressView()
                            .tint(Color.black.opacity(0.7))
                    } else {
                        Image(systemName: "play.fill")
                    }
                    Text(isStarting ? "正在进入课堂…" : "开始课堂")
                }
            }
            .buttonStyle(LTPrimaryButtonStyle())
            .disabled(isStarting || isRequestingPermission)
        }
        .padding(.top, LTSpacing.s)
    }

    // MARK: - Actions

    private var liveTranslationBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.liveTranslationEnabled },
            set: { environment.settings.liveTranslationEnabled = $0 }
        )
    }

    private func settingLabel(title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: LTSpacing.s) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(LTColors.accentCyan)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(LTColors.textPrimary)
                Text(detail)
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textSecondary)
            }
        }
    }

    private func settingRow(title: String, detail: String, symbol: String, trailing: some View) -> some View {
        HStack(spacing: LTSpacing.s) {
            settingLabel(title: title, detail: detail, symbol: symbol)
            Spacer()
            trailing
        }
        .padding(LTSpacing.m)
    }

    /// The full validation chain from the spec: name → active-session guard
    /// → mic permission → local resources → start. Re-entrancy guarded so
    /// rapid double-taps can never create two sessions or two starts.
    private func start() async {
        guard !isStarting && !isRequestingPermission else { return }
        nameFieldFocused = false
        startError = nil

        // 1. Name.
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            nameError = "请填写课堂名称"
            LTHaptics.warning()
            return
        }

        // 2. Active-session guard (double start / re-entry). A collapsed
        // classroom keeps running behind the home tab, so starting a second
        // one must be refused explicitly.
        guard !environment.coordinator.isRunning else {
            startError = "已有一堂课正在进行，请先结束当前课堂"
            LTHaptics.warning()
            return
        }

        // 3. Microphone permission (request if undetermined).
        if AVAudioApplication.shared.recordPermission == .undetermined {
            isRequestingPermission = true
            let granted = await AudioCaptureService.recordPermission()
            isRequestingPermission = false
            micAuthorized = granted
        } else {
            micAuthorized = AVAudioApplication.shared.recordPermission == .granted
        }
        guard micAuthorized else {
            startError = "需要麦克风权限才能录制课堂，请在系统设置中开启"
            LTHaptics.warning()
            return
        }

        // 4. Local language resources.
        guard preferredBackendInstalled || await environment.engineManager.isInstalled(
            environment.settings.preferredBackend
        ) else {
            startError = "语言资源尚未安装，请在“我的 → 语言资源管理”中完成下载"
            LTHaptics.warning()
            return
        }

        // 5. Start the real pipeline. Failure is detected via the
        // coordinator's resulting state (engine load / VAD / mic capture
        // all surface as non-running phases): on failure the sheet stays
        // up with a retryable error — the button is never left dead.
        isStarting = true
        LTHaptics.success()
        await environment.coordinator.start(title: trimmedName)
        isStarting = false

        if environment.coordinator.isRunning {
            // Classroom created and the coordinator is live. The classroom
            // screen is presented from onDisappear, once this sheet has
            // fully animated out (see above).
            shouldOpenLive = true
            dismiss()
        } else {
            startError = "课堂启动失败，请重试；若反复失败，请在“我的 → 语言资源管理”中检查语言资源。"
            LTHaptics.warning()
        }
    }
}
