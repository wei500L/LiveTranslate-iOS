import SwiftUI

/// Manual correction editor for one transcript entry. Shows the model's
/// original Russian + translation (read-only, always visible), the two
/// editable correction fields, and:
/// - 从该段播放 (jump to sound when a recording exists);
/// - 保存 (only touched fields persist — a blank Russian falls back to
///   the original, an untouched Chinese stays nil so model output shows);
/// - 恢复原始内容 (deletes the correction row);
/// - an optional re-translation of the corrected Russian (user-triggered
///   only; a failure keeps the Russian correction).
///
/// The user never sees revision/serverVersion/overlay vocabulary — the UI
/// speaks in 识别原文 / 你的修正 / 模型翻译.
struct TranscriptCorrectionView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let sessionID: UUID
    let entry: TranscriptEntry

    @State private var russianDraft: String = ""
    @State private var chineseDraft: String = ""
    /// nil = the user never touched Chinese (keep model output / no
    /// correction); true after any edit.
    @State private var chineseTouched = false
    @State private var showOriginalOnly = false
    @State private var isRetranslating = false
    @State private var retranslationFailed = false
    @State private var conflictNotice: CorrectionConflictCopy?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            LTPage {
                ScrollView {
                    VStack(alignment: .leading, spacing: LTSpacing.l) {
                        originalSection
                        correctedSection
                        conflictSection
                        actionsSection
                    }
                    .padding(.horizontal, LTSpacing.screenPadding)
                    .padding(.top, LTSpacing.s)
                    .padding(.bottom, LTSpacing.xl)
                }
            }
            .navigationTitle("校正转录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { save() }
                        .disabled(!canSave)
                }
            }
            .task { loadDrafts() }
            .alert("重新翻译失败", isPresented: $retranslationFailed) {
                Button("好", role: .cancel) {}
            } message: {
                Text("俄语修正已保存，翻译保持原样，可稍后重试。")
            }
        }
    }

    // MARK: - Original (model output, immutable)

    private var originalSection: some View {
        VStack(alignment: .leading, spacing: LTSpacing.xs) {
            LTSectionHeader(title: "识别原文")
            VStack(alignment: .leading, spacing: LTSpacing.s) {
                Text(entry.originalText)
                    .font(.footnote)
                    .foregroundStyle(LTColors.textSecondary)
                    .textSelection(.enabled)
                if let translated = entry.translatedText, !translated.isEmpty {
                    Divider()
                    Text(translated)
                        .font(.footnote)
                        .foregroundStyle(LTColors.textSecondary)
                        .textSelection(.enabled)
                }
            }
            .padding(LTSpacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: LTRadius.small)
                    .fill(LTColors.surfacePrimary.opacity(0.5))
            )
        }
    }

    // MARK: - Corrections

    private var correctedSection: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            LTSectionHeader(title: "你的修正")
            VStack(alignment: .leading, spacing: 2) {
                Text("俄语（留空则保留识别原文）")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textTertiary)
                TextField("俄语原文", text: $russianDraft, axis: .vertical)
                    .font(.subheadline)
                    .lineLimit(2...5)
                    .padding(LTSpacing.s)
                    .background(
                        RoundedRectangle(cornerRadius: LTRadius.small)
                            .fill(LTColors.surfacePrimary)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: LTRadius.small)
                            .strokeBorder(LTColors.border, lineWidth: 0.5)
                    )
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("中文（不填则保留模型翻译）")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textTertiary)
                TextField("中文翻译", text: chineseBinding, axis: .vertical)
                    .font(.subheadline)
                    .lineLimit(2...5)
                    .padding(LTSpacing.s)
                    .background(
                        RoundedRectangle(cornerRadius: LTRadius.small)
                            .fill(LTColors.surfacePrimary)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: LTRadius.small)
                            .strokeBorder(LTColors.border, lineWidth: 0.5)
                    )
            }
        }
    }

    /// Chinese editing is tri-state: untouched (nil correction) vs edited
    /// (a real string, possibly deliberately blank).
    private var chineseBinding: Binding<String> {
        Binding(
            get: { chineseDraft },
            set: { chineseDraft = $0; chineseTouched = true }
        )
    }

    // MARK: - Conflict copy

    /// A remote edit lost the newer-modifiedAt race: offer adoption
    /// explicitly — nothing is silently discarded.
    @ViewBuilder
    private var conflictSection: some View {
        if let conflict = conflictNotice {
            VStack(alignment: .leading, spacing: LTSpacing.xs) {
                HStack {
                    Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(LTColors.warning)
                    Text("其他设备也修改了这段")
                        .font(LTTypography.caption.weight(.semibold))
                        .foregroundStyle(LTColors.warning)
                }
                if !conflict.russianText.isEmpty {
                    Text("俄语：\(conflict.russianText)")
                        .font(.footnote)
                        .foregroundStyle(LTColors.textSecondary)
                }
                if let chinese = conflict.chineseText, !chinese.isEmpty {
                    Text("中文：\(chinese)")
                        .font(.footnote)
                        .foregroundStyle(LTColors.textSecondary)
                }
                HStack {
                    Button("采用这份修改") {
                        russianDraft = conflict.russianText
                        if let chinese = conflict.chineseText {
                            chineseDraft = chinese
                            chineseTouched = true
                        }
                        clearConflict()
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(LTColors.accentBlue)
                    Spacer()
                    Button("保留我的版本") { clearConflict() }
                        .font(.footnote)
                        .foregroundStyle(LTColors.textTertiary)
                }
            }
            .padding(LTSpacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: LTRadius.small)
                    .fill(LTColors.warning.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: LTRadius.small)
                    .strokeBorder(LTColors.warning.opacity(0.2), lineWidth: 0.5)
            )
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(spacing: LTSpacing.s) {
            if hasRecording {
                Button {
                    playFromEntry()
                } label: {
                    Label("从这段播放录音", systemImage: "play.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            Button {
                Task { await retranslate() }
            } label: {
                HStack {
                    Label("用修正后的俄语重新翻译", systemImage: "arrow.triangle.2.circlepath")
                    if isRetranslating { ProgressView().controlSize(.small) }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isRetranslating || effectiveRussianForRetranslation.isEmpty)

            if correctionExists {
                Button(role: .destructive) {
                    restoreOriginal()
                } label: {
                    Label("恢复识别原文", systemImage: "arrow.uturn.backward")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Data

    private var correctionExists: Bool {
        (try? environment.repository.corrections(forSessionID: sessionID))?
            .contains { $0.id == entry.id } ?? false
    }

    private var hasRecording: Bool {
        guard let recording = try? environment.repository.recording(sessionID: sessionID) else {
            return false
        }
        return !recording.isDeleted && SessionRecordings.recordingFileExists(sessionID: sessionID)
    }

    private func loadDrafts() {
        guard !loaded else { return }
        loaded = true
        let corrections = (try? environment.repository.corrections(forSessionID: sessionID)) ?? []
        if let correction = corrections.first(where: { $0.id == entry.id }) {
            russianDraft = correction.russianText
            chineseDraft = correction.chineseText ?? ""
            chineseTouched = correction.chineseText != nil
            conflictNotice = CorrectionConflictCopy.decode(correction.conflictJSON)
        } else {
            russianDraft = ""
            chineseDraft = ""
        }
    }

    private var canSave: Bool {
        let russianChanged = russianDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            != (try? environment.repository.corrections(forSessionID: sessionID))?
            .first { $0.id == entry.id }?.russianText ?? ""
        return russianChanged || chineseTouched
    }

    private func save() {
        // 保存语义:
        // - 俄语: trimmed text; blank = fall back to the model original.
        // - 中文: untouched = nil (model output stays effective); touched =
        //   the string as typed (blank is a deliberate empty translation).
        let russian = russianDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let chinese: String? = chineseTouched
            ? chineseDraft.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        _ = try? environment.repository.saveCorrection(
            sessionID: sessionID,
            entryID: entry.id,
            russian: russian,
            chinese: chinese,
            needsRetranslation: false
        )
        clearConflict()
        dismiss()
    }

    private func restoreOriginal() {
        try? environment.repository.deleteCorrection(entryID: entry.id)
        dismiss()
    }

    private func clearConflict() {
        conflictNotice = nil
        // The conflict copy is consumed — drop it from the row too so it
        // does not reappear after the next sync.
        let corrections = (try? environment.repository.corrections(forSessionID: sessionID)) ?? []
        if let correction = corrections.first(where: { $0.id == entry.id }),
           correction.conflictJSON != nil {
            _ = try? environment.repository.saveCorrection(
                sessionID: sessionID,
                entryID: entry.id,
                russian: correction.russianText,
                chinese: correction.chineseText,
                needsRetranslation: correction.needsRetranslation
            )
        }
    }

    private var effectiveRussianForRetranslation: String {
        let trimmed = russianDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? entry.originalText : trimmed
    }

    /// Re-translate the CORRECTED Russian on explicit user action. The
    /// result updates the MODEL translation field (translatedText); any
    /// Chinese correction stays effective (the user's edit wins at read
    /// time) and the UI says so.
    private func retranslate() async {
        guard let session = (try? environment.repository.sessions(matching: ""))?
            .first(where: { $0.id == sessionID }) else { return }
        isRetranslating = true
        defer { isRetranslating = false }
        let request = TranslationRequest(
            id: entry.sequenceID,
            sequenceID: entry.sequenceID,
            text: effectiveRussianForRetranslation,
            sourceLanguage: session.sourceLanguage,
            targetLanguage: session.targetLanguage,
            history: []
        )
        let outcome = await environment.translationService.translate(request)
        if let text = outcome.text, !text.isEmpty {
            try? environment.repository.updateTranslation(
                entryID: entry.id, text: text,
                latency: outcome.latency, status: .completed
            )
            // The model translation changed; persist the correction
            // (Russian + Chinese intent) so the model-field update and the
            // correction layer stay consistent, then close.
            save()
        } else {
            // The Russian correction must survive — save it, keep the
            // model translation as-is, surface the failure.
            save()
            retranslationFailed = true
        }
    }

    private func playFromEntry() {
        guard let recording = try? environment.repository.recording(sessionID: sessionID),
              !recording.isDeleted else { return }
        environment.playback.load(recording: recording)
        environment.playback.seek(to: max(0, entry.startOffset - 1.5))
        environment.playback.play()
    }
}
