import SwiftUI

/// Detail view for one classroom session: bilingual entries, stats,
/// retranslation of failed items, and export.
struct SessionDetailView: View {
    @Environment(AppEnvironment.self) private var environment

    let session: ClassroomSession

    @State private var title: String = ""
    @State private var entries: [TranscriptEntry] = []
    @State private var isRetranslating = false
    @State private var shareItem: SharedFile?

    @State private var titleEditing = false

    var body: some View {
        List {
            Section {
                if titleEditing {
                    TextField(String(localized: "Title"), text: $title, onCommit: commitTitle)
                        .textFieldStyle(.roundedBorder)
                } else {
                    Button {
                        title = session.title
                        titleEditing = true
                    } label: {
                        HStack {
                            Text(session.title).font(.headline).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "pencil")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityHint(Text("Double tap to rename"))
                }
            }

            statsSection

            Section(String(localized: "Transcript")) {
                ForEach(displayEntries) { entry in
                    TranscriptRow(entry: entry)
                }
            }
        }
        .navigationTitle(String(localized: "Session"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    Task { await retranslateFailed() }
                } label: {
                    if isRetranslating {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(failedCount == 0 || isRetranslating)
                .accessibilityLabel(Text("Retry failed translations"))

                Menu {
                    ForEach(ExportFormat.allCases) { format in
                        Button(format.displayName) { export(format) }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel(Text("Export"))
            }
        }
        .task { reload() }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
    }

    // MARK: - Sections

    private var displayEntries: [TranscriptEntry] {
        entries.sorted { $0.sequenceID < $1.sequenceID }
    }

    private var failedCount: Int {
        entries.filter { $0.status == .failed || $0.status == .notConfigured }.count
    }

    private var statsSection: some View {
        Section(String(localized: "Session info")) {
            LabeledRow(label: String(localized: "Started"), value: Format.date(session.startTime))
            if let end = session.endTime {
                LabeledRow(label: String(localized: "Ended"), value: Format.date(end))
            }
            LabeledRow(label: String(localized: "Duration"), value: Format.clock(session.duration))
            LabeledRow(label: String(localized: "Model"), value: "\(session.asrModel) \(session.asrRevision)")
            if let backend = ASRBackendKind(rawValue: session.asrBackend) {
                LabeledRow(label: String(localized: "Backend"), value: backend.displayName)
            }
            if !session.computePreference.isEmpty {
                LabeledRow(label: String(localized: "Compute"), value: session.computePreference)
            }
            if !session.translationModel.isEmpty {
                LabeledRow(label: String(localized: "Translation model"), value: session.translationModel)
            }
            if !entries.isEmpty {
                LabeledRow(label: String(localized: "Entries"), value: "\(entries.count)")
                LabeledRow(label: String(localized: "Avg ASR latency"), value: Format.seconds(avg(\.asrLatency)))
                LabeledRow(label: String(localized: "Avg RTF"), value: String(format: "%.2f", avg(\.asrRTF)))
                let completed = entries.filter { $0.status == .completed }.count
                LabeledRow(label: String(localized: "Translated"), value: Format.percent(Double(completed) / Double(entries.count)))
            }
        }
    }

    private func avg(_ keyPath: KeyPath<TranscriptEntry, Double>) -> Double {
        let values = entries.map { $0[keyPath: keyPath] }.filter { $0 > 0 }
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    // MARK: - Actions

    private func reload() {
        title = session.title
        entries = (try? environment.repository.entries(for: session)) ?? []
    }

    private func commitTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            session.title = trimmed
            session.updatedAt = .now
        }
        titleEditing = false
    }

    private func retranslateFailed() async {
        isRetranslating = true
        defer { isRetranslating = false }
        guard let pending = try? environment.repository.entriesNeedingRetry(for: session) else { return }
        let history = completedHistory()
        for entry in pending {
            let request = TranslationRequest(
                id: entry.sequenceID,
                sequenceID: entry.sequenceID,
                text: entry.originalText,
                sourceLanguage: session.sourceLanguage,
                targetLanguage: session.targetLanguage,
                history: history
            )
            let outcome = await environment.translationService.translate(request)
            if let text = outcome.text, !text.isEmpty {
                try? environment.repository.updateTranslation(
                    entryID: entry.id, text: text,
                    latency: outcome.latency, status: .completed
                )
            } else {
                try? environment.repository.updateTranslation(
                    entryID: entry.id, text: "",
                    latency: outcome.latency, status: .failed
                )
            }
        }
        reload()
    }

    /// Recent (source, translation) pairs in utterance order, for context.
    private func completedHistory() -> [(source: String, translation: String)] {
        displayEntries
            .filter { $0.status == .completed }
            .suffix(environment.settings.contextTurns)
            .map { ($0.originalText, $0.translatedText ?? "") }
    }

    private func export(_ format: ExportFormat) {
        let ordered = displayEntries
        let backend = ASRBackendKind(rawValue: session.asrBackend) ?? environment.settings.preferredBackend
        let data = TranscriptExportData(
            title: session.title,
            startTime: session.startTime,
            endTime: session.endTime,
            duration: session.duration,
            backend: backend,
            modelVersion: session.modelVersion,
            computeDescription: session.computePreference,
            translationModel: session.translationModel,
            entries: ordered.map { entry in
                ExportEntry(
                    sequenceID: entry.sequenceID,
                    startOffset: entry.startOffset,
                    endOffset: entry.endOffset,
                    originalText: entry.originalText,
                    translatedText: entry.translatedText,
                    createdAt: entry.createdAt
                )
            }
        )
        let text = TranscriptExporter.export(data, format: format)
        let safeTitle = session.title.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeTitle).\(format.fileExtension)")
        do {
            try text.data(using: .utf8)?.write(to: url, options: .atomic)
            shareItem = SharedFile(url: url)
        } catch {
            // Surface rather than silently dropping the export.
            shareItem = nil
        }
    }
}

/// Read-only bilingual row (lighter than the live subtitle card).
private struct TranscriptRow: View {
    let entry: TranscriptEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(offset)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer()
                if entry.status == .failed {
                    StatusChip(text: String(localized: "Translation failed"), tint: .red)
                } else if entry.status == .pending {
                    StatusChip(text: String(localized: "Pending"), tint: .secondary)
                }
            }
            Text(entry.originalText)
                .font(.body)
                .textSelection(.enabled)
            if let translated = entry.translatedText, !translated.isEmpty {
                Text(translated)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }

    private var offset: String {
        Format.clock(entry.startOffset)
    }
}

struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .font(.subheadline)
    }
}

/// URL wrapper so `.sheet(item:)` can present the share sheet.
/// File-scope (not nested) so BenchmarkScreen can use it too.
struct SharedFile: Identifiable {
    let id = UUID()
    let url: URL
}
