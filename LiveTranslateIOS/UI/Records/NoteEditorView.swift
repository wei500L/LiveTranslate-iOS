import SwiftUI

/// Sheet editor for one classroom note (create or edit). Saves through the
/// repository so the note persists and the cloud-sync layer learns about
/// it — never view-only state.
struct NoteEditorView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    /// The session the note belongs to.
    private let session: ClassroomSession
    /// The note being edited; nil = creating a new one.
    private let note: SessionNote?
    /// Entry the new note is anchored to (nil = unanchored). Ignored when
    /// editing an existing note — an existing anchor is only cleared from
    /// the transcript row's context menu.
    private let anchorEntry: TranscriptEntry?

    @State private var text = ""
    @State private var errorText: String?
    @FocusState private var editorFocused: Bool

    init(
        session: ClassroomSession,
        note: SessionNote? = nil,
        anchorEntry: TranscriptEntry? = nil
    ) {
        self.session = session
        self.note = note
        self.anchorEntry = anchorEntry
    }

    var body: some View {
        NavigationStack {
            LTPage {
                VStack(alignment: .leading, spacing: LTSpacing.m) {
                    if let errorText {
                        Text(errorText)
                            .font(LTTypography.caption)
                            .foregroundStyle(LTColors.destructive)
                    }
                    anchorBanner
                    TextEditor(text: $text)
                        .font(.body)
                        .foregroundStyle(LTColors.textPrimary)
                        .scrollContentBackground(.hidden)
                        .padding(LTSpacing.s)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .background(
                            RoundedRectangle(cornerRadius: LTRadius.small)
                                .fill(LTColors.surfacePrimary)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: LTRadius.small)
                                .strokeBorder(LTColors.border, lineWidth: 0.5)
                        )
                        .focused($editorFocused)
                }
                .padding(.horizontal, LTSpacing.screenPadding)
                .padding(.vertical, LTSpacing.m)
            }
            .navigationTitle(note == nil ? "添加笔记" : "编辑笔记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .foregroundStyle(LTColors.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(LTColors.accentGreen)
                        .disabled(trimmedText.isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if let note, text.isEmpty {
                text = note.text
            }
            editorFocused = true
        }
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Shows what the note is anchored to (the transcript line it refers
    /// to). Purely informational — the anchor was chosen at creation.
    @ViewBuilder
    private var anchorBanner: some View {
        if let entry = effectiveAnchor {
            VStack(alignment: .leading, spacing: 3) {
                Label("锚定段落 · \(TranscriptExporter.mmss(entry.startOffset))", systemImage: "text.bubble")
                    .font(LTTypography.caption.weight(.semibold))
                    .foregroundStyle(LTColors.warning)
                Text(entry.translatedText ?? entry.originalText)
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textSecondary)
                    .lineLimit(2)
            }
            .padding(LTSpacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: LTRadius.small)
                    .fill(LTColors.warning.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: LTRadius.small)
                    .strokeBorder(LTColors.warning.opacity(0.25), lineWidth: 0.5)
            )
        }
    }

    private var effectiveAnchor: TranscriptEntry? {
        if let note {
            // Existing note: show its anchor when one exists.
            guard let anchorID = note.anchorEntryID else { return nil }
            let entries = (try? environment.repository.entries(for: session)) ?? []
            return entries.first { $0.id == anchorID }
        }
        return anchorEntry
    }

    // MARK: - Actions

    private func save() {
        let trimmed = trimmedText
        guard !trimmed.isEmpty else { return }
        do {
            if let note {
                try environment.repository.updateNote(note, text: trimmed)
            } else {
                _ = try environment.repository.addNote(
                    NoteDraft(text: trimmed, anchorEntryID: anchorEntry?.id),
                    toSessionID: session.id
                )
            }
            LTHaptics.success()
            dismiss()
        } catch {
            errorText = "保存失败，请重试"
            LTHaptics.warning()
        }
    }
}
