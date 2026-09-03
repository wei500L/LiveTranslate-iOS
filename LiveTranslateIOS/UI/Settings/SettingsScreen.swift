import SwiftUI

/// Settings tab (我的): backend selection, VAD, translation API, data,
/// privacy, licenses, benchmark entry. When pushed from the home screen,
/// pass `embedsInStack: false` so it doesn't nest its own NavigationStack.
struct SettingsScreen: View {
    @Environment(AppEnvironment.self) private var environment

    var embedsInStack = true

    @State private var apiKeyInput = ""
    @State private var connectionTestResult: String?
    @State private var isTestingConnection = false
    @State private var storageBytes = 0
    @State private var showDeleteAllConfirm = false
    @State private var showDeleteAllRecordingsConfirm = false
    @State private var showPrivacy = false
    @State private var showLicenses = false
    @State private var recordingCount = 0
    @State private var incompleteRecordingCount = 0
    @State private var recordingBytes: Int64 = 0

    var body: some View {
        Group {
            if embedsInStack {
                NavigationStack { settingsContent }
            } else {
                settingsContent
            }
        }
        .task {
            storageBytes = environment.repository.storageBytes()
            refreshAttachmentStorage()
            refreshRecordingStorage()
            apiKeyInput = (try? environment.keychain.get(forKey: AppEnvironment.apiKeychainKey)) ?? ""
        }
        // Keep the live translator in sync with edited settings.
        .onChange(of: environment.settings.apiBase) { _, _ in environment.refreshTranslationService() }
        .onChange(of: environment.settings.translationModel) { _, _ in environment.refreshTranslationService() }
        .onChange(of: environment.settings.streaming) { _, _ in environment.refreshTranslationService() }
        .onChange(of: environment.settings.contextTurns) { _, _ in environment.refreshTranslationService() }
        .onChange(of: environment.settings.temperature) { _, _ in environment.refreshTranslationService() }
        .onChange(of: environment.settings.maxTokens) { _, _ in environment.refreshTranslationService() }
        .onChange(of: environment.settings.timeout) { _, _ in environment.refreshTranslationService() }
        .onChange(of: environment.settings.thinkingStyle) { _, _ in environment.refreshTranslationService() }
        .onChange(of: environment.settings.customSystemPrompt) { _, _ in environment.refreshTranslationService() }
        .onChange(of: environment.settings.studyReviewModel) { _, _ in environment.refreshTranslationService() }
        .onChange(of: environment.settings.attachmentAnalysisModel) { _, _ in environment.refreshTranslationService() }
    }

    private var settingsContent: some View {
        Form {
            profileSection
            recognitionSection
            vadSection
            translationSection
            studyReviewSection
            attachmentAnalysisSection
            dataSection
            cloudSection
            aboutSection
        }
        .navigationTitle(String(localized: "我的"))
        .scrollContentBackground(.hidden)
        .background(LTBackground())
        .sheet(isPresented: $showPrivacy) { PrivacySheet() }
        .sheet(isPresented: $showLicenses) { LicensesSheet() }
        .confirmationDialog(
            String(localized: "Delete all classroom records?"),
            isPresented: $showDeleteAllConfirm,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete all"), role: .destructive) {
                try? environment.repository.deleteAllSessions()
                storageBytes = environment.repository.storageBytes()
                refreshAttachmentStorage()
                refreshRecordingStorage()
            }
        }
        .confirmationDialog(
            String(localized: "删除全部课堂录音？"),
            isPresented: $showDeleteAllRecordingsConfirm,
            titleVisibility: .visible
        ) {
            Button(String(localized: "仅删除录音"), role: .destructive) {
                deleteAllRecordings()
            }
            Button(String(localized: "取消"), role: .cancel) {}
        } message: {
            Text(String(localized: "将释放约 \(Format.bytes(Int(recordingBytes)))。转录、笔记、图片和学习整理全部保留；仅删除本机的声音文件。"))
        }
    }

    // MARK: - Recording storage management

    /// Counts + sizes from the metadata rows against the real files.
    private func refreshRecordingStorage() {
        let recordings = (try? environment.repository.allRecordings()) ?? []
        recordingCount = recordings.filter { !$0.isDeleted }.count
        incompleteRecordingCount = recordings.filter { !$0.isDeleted && !$0.isComplete }.count
        recordingBytes = recordings
            .filter { !$0.isDeleted }
            .reduce(Int64(0)) { total, recording in
                let url = SessionRecordings.fileURL(for: recording)
                let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0
                return total + size
            }
    }

    /// Deletes every recording FILE, keeping all text and study material
    /// (the rows stay with isDeleted — time metadata survives).
    private func deleteAllRecordings() {
        environment.playback.stop()
        let recordings = (try? environment.repository.allRecordings()) ?? []
        for recording in recordings where !recording.isDeleted {
            _ = try? environment.repository.deleteRecordingFile(recording)
        }
        refreshRecordingStorage()
    }

    // MARK: - Profile

    /// Simple identity header for the 我的 tab: app name + real local-mode
    /// state (installed backends), no fabricated account.
    private var profileSection: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(LTColors.accentGreen)
                VStack(alignment: .leading, spacing: 2) {
                    Text("LiveTranslate")
                        .font(.headline)
                    Text("课堂俄语转写 · 本地识别 · 中文翻译")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusChip(
                    text: environment.engineManager.loaded != nil
                        ? "本地转写可用" : "本地模式",
                    tint: LTColors.accentGreen
                )
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Recognition

    private var recognitionSection: some View {
        Section {
            LabeledRow(label: String(localized: "本地语音识别"), value: String(localized: "俄语 · 全程在本机运行"))

            Picker(String(localized: "识别模式"), selection: backendBinding) {
                ForEach(ASRBackendKind.allCases) { kind in
                    Text(kind.userTitle).tag(kind)
                }
            }
            .pickerStyle(.inline)
            .disabled(environment.engineManager.sessionActive)

            Text(environment.settings.preferredBackend.userSubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            if environment.engineManager.sessionActive {
                Text(String(localized: "课堂进行中暂不能切换识别模式。"))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Picker(String(localized: "准确度优先的计算方式"), selection: computeBinding) {
                ForEach(CoreMLComputePreference.allCases) { pref in
                    Text(pref.displayName).tag(pref)
                }
            }
            .disabled(environment.settings.preferredBackend != .coreMLFP16)

            if environment.settings.coreMLCompute == .neuralEngineExperimental {
                Text(String(localized: "实验特性：结果可能有细微差异，首次准备更慢。切换后会重新准备资源。"))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Picker(String(localized: "速度优先的线程数"), selection: threadsBinding) {
                Text("2").tag(2)
                Text("4").tag(4)
            }
            .disabled(environment.settings.preferredBackend != .sherpaONNXInt8)

            NavigationLink(String(localized: "语言资源管理…")) {
                ModelManagementScreen()
            }
        } header: {
            Text(String(localized: "Speech recognition"))
        } footer: {
            Text(String(localized: "两种识别模式使用同一个本地模型，仅运行方式不同。"))
        }
    }

    private var backendBinding: Binding<ASRBackendKind> {
        Binding(
            get: { environment.settings.preferredBackend },
            set: { environment.settings.preferredBackend = $0 }
        )
    }

    private var computeBinding: Binding<CoreMLComputePreference> {
        Binding(
            get: { environment.settings.coreMLCompute },
            set: { environment.settings.coreMLCompute = $0 }
        )
    }

    private var threadsBinding: Binding<Int> {
        Binding(
            get: { environment.settings.onnxThreads },
            set: { environment.settings.onnxThreads = $0 }
        )
    }

    // MARK: - VAD

    private var vadSection: some View {
        Section(String(localized: "Voice activity detection")) {
            VStack(alignment: .leading) {
                LabeledRow(
                    label: String(localized: "Threshold"),
                    value: String(format: "%.2f", environment.settings.vadThreshold)
                )
                Slider(
                    value: Binding(
                        get: { environment.settings.vadThreshold },
                        set: { environment.settings.vadThreshold = $0 }
                    ),
                    in: 0.3...0.7,
                    step: 0.05
                )
                .accessibilityLabel(Text("VAD threshold"))
            }
            Stepper(
                value: Binding(
                    get: { environment.settings.vadMinSpeechMs },
                    set: { environment.settings.vadMinSpeechMs = $0 }
                ),
                in: 100...1000,
                step: 50
            ) {
                LabeledRow(label: String(localized: "Min speech"), value: "\(environment.settings.vadMinSpeechMs) ms")
            }
            Stepper(
                value: Binding(
                    get: { environment.settings.vadSilenceEndMs },
                    set: { environment.settings.vadSilenceEndMs = $0 }
                ),
                in: 300...1500,
                step: 100
            ) {
                LabeledRow(label: String(localized: "Silence ends segment"), value: "\(environment.settings.vadSilenceEndMs) ms")
            }
        }
    }

    // MARK: - Translation

    private var translationSection: some View {
        Section {
            TextField(String(localized: "API Base (e.g. https://api.deepseek.com)"), text: apiBaseBinding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField(String(localized: "Model name"), text: modelBinding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField(String(localized: "API Key (stored in Keychain)"), text: $apiKeyInput, onCommit: saveAPIKey)
                .textInputAutocapitalization(.never)
            Toggle(String(localized: "Streaming (SSE)"), isOn: streamBinding)
            Stepper(value: contextBinding, in: 0...10) {
                LabeledRow(label: String(localized: "Context turns"), value: "\(environment.settings.contextTurns)")
            }
            HStack {
                LabeledRow(label: "Temperature", value: String(format: "%.1f", environment.settings.temperature))
                Spacer()
                Slider(value: tempBinding, in: 0...1, step: 0.1)
                    .frame(maxWidth: 180)
            }
            Stepper(value: maxTokensBinding, in: 64...1024, step: 64) {
                LabeledRow(label: String(localized: "Max tokens"), value: "\(environment.settings.maxTokens)")
            }
            Stepper(value: timeoutBinding, in: 10...120, step: 5) {
                LabeledRow(label: String(localized: "Timeout"), value: "\(Int(environment.settings.timeout)) s")
            }
            Picker(String(localized: "Disable thinking"), selection: thinkingBinding) {
                ForEach(ThinkingStyle.allCases) { style in
                    Text(style.displayName).tag(style.rawValue)
                }
            }
            VStack(alignment: .leading) {
                Text(String(localized: "Custom system prompt (optional)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: promptBinding)
                    .frame(minHeight: 70)
                    .font(.caption)
            }
            Button {
                Task { await testConnection() }
            } label: {
                if isTestingConnection {
                    HStack { ProgressView().padding(.trailing, 6); Text(String(localized: "Testing…")) }
                } else {
                    Text(String(localized: "Test connection"))
                }
            }
            .disabled(isTestingConnection || environment.settings.apiBase.isEmpty)
            if let result = connectionTestResult {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(result.hasPrefix("✓") ? Color.green : Color.red)
            }
        } header: {
            Text(String(localized: "Translation API"))
        } footer: {
            Text("Only recognized Russian text is sent to this endpoint. API keys stay in the Keychain.")
        }
    }

    /// 课后整理 uses the translation API's base + key; only the model can
    /// differ. No request parameters are exposed here.
    private var studyReviewSection: some View {
        Section {
            TextField(
                String(localized: "Model (empty = same as translation)"),
                text: studyModelBinding
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            LabeledRow(label: String(localized: "Language"), value: String(localized: "简体中文（保留俄语术语原文）"))
        } header: {
            Text(String(localized: "Post-class review"))
        } footer: {
            Text("把课堂整理为复习资料时，会将你选择的那堂课的文字（转录、翻译、笔记）发送到上方配置的模型服务；整理由你主动点击开始。")
        }
    }

    /// 图片理解 (multimodal): inherits the translation API base + key; the
    /// model falls back to the study-review model, then the translation
    /// model. The footer is honest about capability: whether a model
    /// actually accepts images is decided by the server at request time —
    /// we never claim support we cannot verify.
    private var attachmentAnalysisSection: some View {
        Section {
            TextField(
                String(localized: "Model (empty = same as review)"),
                text: attachmentModelBinding
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        } header: {
            Text(String(localized: "Image understanding"))
        } footer: {
            Text("分析课堂图片（板书、课件、手写笔记）时，会将压缩后的图片发送到上方配置的模型服务。请填写支持图片输入的模型；如果不确定，模型会在请求时告诉我们是否支持。")
        }
    }

    private var attachmentModelBinding: Binding<String> {
        Binding(
            get: { environment.settings.attachmentAnalysisModel },
            set: { environment.settings.attachmentAnalysisModel = $0 }
        )
    }

    private var studyModelBinding: Binding<String> {
        Binding(
            get: { environment.settings.studyReviewModel },
            set: { environment.settings.studyReviewModel = $0 }
        )
    }

    private var apiBaseBinding: Binding<String> {
        Binding(
            get: { environment.settings.apiBase },
            set: { environment.settings.apiBase = $0 }
        )
    }
    private var modelBinding: Binding<String> {
        Binding(
            get: { environment.settings.translationModel },
            set: { environment.settings.translationModel = $0 }
        )
    }
    private var streamBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.streaming },
            set: { environment.settings.streaming = $0 }
        )
    }
    private var contextBinding: Binding<Int> {
        Binding(
            get: { environment.settings.contextTurns },
            set: { environment.settings.contextTurns = $0 }
        )
    }
    private var tempBinding: Binding<Double> {
        Binding(
            get: { environment.settings.temperature },
            set: { environment.settings.temperature = $0 }
        )
    }
    private var maxTokensBinding: Binding<Int> {
        Binding(
            get: { environment.settings.maxTokens },
            set: { environment.settings.maxTokens = $0 }
        )
    }
    private var timeoutBinding: Binding<Double> {
        Binding(
            get: { environment.settings.timeout },
            set: { environment.settings.timeout = $0 }
        )
    }
    private var thinkingBinding: Binding<String> {
        Binding(
            get: { environment.settings.thinkingStyle },
            set: { environment.settings.thinkingStyle = $0 }
        )
    }
    private var promptBinding: Binding<String> {
        Binding(
            get: { environment.settings.customSystemPrompt },
            set: { environment.settings.customSystemPrompt = $0 }
        )
    }

    private func saveAPIKey() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespaces)
        try? environment.keychain.set(key, forKey: AppEnvironment.apiKeychainKey)
        // The translator snapshots the key at construction, so a fresh
        // service must be built the moment the stored key changes —
        // otherwise "Test connection" (and live translation) would keep
        // probing with the previous, possibly nil, key.
        environment.refreshTranslationService()
    }

    private func testConnection() async {
        saveAPIKey()
        isTestingConnection = true
        defer { isTestingConnection = false }
        let result = await environment.translationService.testConnection()
        switch result {
        case .success(let message):
            connectionTestResult = "✓ \(message)"
        case .failure(let error):
            connectionTestResult = "✗ \(error.localizedDescription)"
        }
    }

    // MARK: - Data

    private var dataSection: some View {
        Section(String(localized: "Data")) {
            Toggle(isOn: saveAudioBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "课堂录音"))
                    Text(String(localized: "不保存录音（默认）· 保留原始质量 · ≈1.9 MB 每分钟 · 存储在本机，不随文字记录同步"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            LabeledRow(label: String(localized: "Records storage"), value: Format.bytes(storageBytes))
            LabeledRow(
                label: String(localized: "Classroom images"),
                value: Format.bytes(Int(attachmentBytes))
            )
            if attachmentBytes > 0 {
                Button {
                    reclaimSyncedAttachmentOriginals()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "Free up synced image space"))
                        Text(String(localized: "Removes local ORIGINALS of images already uploaded to your server; thumbnails stay and originals re-download on demand."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(syncedAttachmentIDs.isEmpty)
            }
            recordingStorageSection
            Button(String(localized: "Delete all records"), role: .destructive) {
                showDeleteAllConfirm = true
            }
        }
    }

    /// Real recording statistics (row + actual file sizes) and the
    /// text-preserving deletion actions. Deleting audio keeps every
    /// transcript, note, image and review; only the sound goes.
    @ViewBuilder
    private var recordingStorageSection: some View {
        if recordingCount > 0 {
            LabeledRow(
                label: String(localized: "课堂录音"),
                value: "\(recordingCount) 段 · \(Format.bytes(Int(recordingBytes)))"
            )
            if incompleteRecordingCount > 0 {
                LabeledRow(
                    label: String(localized: "不完整录音"),
                    value: "\(incompleteRecordingCount) 段（可播放，可能中断于课堂结束）"
                )
            }
            Button(role: .destructive) {
                showDeleteAllRecordingsConfirm = true
            } label: {
                Text(String(localized: "删除全部课堂录音"))
            }
        } else {
            LabeledRow(
                label: String(localized: "课堂录音"),
                value: String(localized: "暂无")
            )
        }
    }

    @State private var attachmentBytes: Int64 = 0
    @State private var syncedAttachmentIDs: [UUID] = []
    @State private var sessionIDsByAttachment: [UUID: UUID] = [:]

    /// 删除本地已同步原图 (local reclaim only — the cloud copy is a
    /// separate, explicit action in 云端同步).
    private func reclaimSyncedAttachmentOriginals() {
        guard let store = environment.attachmentStore else { return }
        _ = store.reclaimOriginals(
            attachmentIDs: syncedAttachmentIDs, sessionIDs: sessionIDsByAttachment
        )
        refreshAttachmentStorage()
    }

    private func refreshAttachmentStorage() {
        attachmentBytes = environment.attachmentStore.totalBytes()
        let all = (try? environment.repository.allAttachments()) ?? []
        sessionIDsByAttachment = Dictionary(
            all.map { ($0.id, $0.sessionID) }, uniquingKeysWith: { first, _ in first }
        )
        syncedAttachmentIDs = all
            .filter { $0.serverVersion > 0 }
            .map(\.id)
    }

    private var saveAudioBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.saveRawAudio },
            set: { environment.settings.saveRawAudio = $0 }
        )
    }

    // MARK: - Cloud sync

    /// 云端同步 entry: real status chip from the live service (nil service
    /// → 仅保存在本机). The detail page holds sign-in and the sync controls.
    private var cloudSection: some View {
        Section {
            NavigationLink {
                CloudSyncSettingsView()
            } label: {
                HStack {
                    Text(String(localized: "云端同步"))
                    Spacer()
                    if let sync = environment.cloudSync {
                        StatusChip(text: sync.phase.statusText, tint: sync.phase.tint)
                    } else {
                        Text(String(localized: "仅保存在本机"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text(String(localized: "Cloud sync"))
        } footer: {
            Text(String(localized: "通过你自己的云端服务器在设备间同步课堂记录；不使用 iCloud。语音音频永不离开本机。"))
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            NavigationLink(String(localized: "识别性能测试")) {
                BenchmarkScreen()
            }
            Button(String(localized: "Privacy details")) { showPrivacy = true }
            Button(String(localized: "Third-party licenses")) { showLicenses = true }
        } header: {
            Text(String(localized: "About"))
        } footer: {
            Text("LiveTranslate · 语音识别完全在本机完成。")
        }
    }
}

/// Privacy summary sheet.
struct PrivacySheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    privacyPoint(String(localized: "Microphone audio is recognized on this iPhone by the local recognition model. Audio never leaves the device."))
                    privacyPoint(String(localized: "Raw audio is not saved by default; when enabled in Settings it stays in the app sandbox."))
                    privacyPoint(String(localized: "Only the recognized Russian text is sent to your configured translation API."))
                    privacyPoint(String(localized: "The API key is stored only in the iOS Keychain and never exported."))
                    privacyPoint(String(localized: "You can delete individual sessions or all records at any time."))
                    privacyPoint(String(localized: "A normal iOS app cannot capture audio playing inside other apps — input is the microphone only."))
                    privacyPoint(String(localized: "The microphone is never started automatically in the background; you start every session explicitly."))
                }
                .padding()
            }
            .navigationTitle(String(localized: "Privacy"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
    }

    private func privacyPoint(_ text: String) -> some View {
        Label { Text(text).font(.subheadline) } icon: {
            Image(systemName: "checkmark.shield").foregroundStyle(.green)
        }
    }
}

/// Third-party license summary sheet.
struct LicensesSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let licenses: [(name: String, detail: String)] = [
        ("GigaAM-v3 (ai-sage)", "MIT · base model, Russian ASR"),
        ("Core ML FP16 conversion (smkrv)", "MIT · GigaAM-v3 e2e_rnnt Core ML packages"),
        ("sherpa-onnx INT8 conversion (Alexxerm)", "MIT · GigaAM-v3 e2e_rnnt ONNX quantized"),
        ("sherpa-onnx runtime", "Apache-2.0 · v1.13.7 incl. ONNX Runtime"),
        ("Silero VAD", "MIT · voice activity detection"),
    ]

    var body: some View {
        NavigationStack {
            List {
                ForEach(licenses, id: \.name) { license in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(license.name).font(.subheadline.weight(.medium))
                        Text(license.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(String(localized: "Third-party licenses"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
    }
}
