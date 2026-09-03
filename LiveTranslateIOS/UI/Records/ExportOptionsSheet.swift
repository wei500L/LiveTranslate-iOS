import SwiftUI

/// Export options: what to include (scope) and in which format. Kept as
/// one compact sheet — the scope limits which formats make sense (a study
/// review has no SRT form; subtitles stay pure transcript).
struct ExportOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var scope: ExportScope = .fullMaterial
    @State private var format: ExportFormat = .markdown

    /// Whether the classroom has a study review (gates the review scopes).
    private let hasReview: Bool
    private let onExport: (ExportScope, ExportFormat) -> Void

    init(
        hasReview: Bool,
        onExport: @escaping (ExportScope, ExportFormat) -> Void
    ) {
        self.hasReview = hasReview
        self.onExport = onExport
    }

    /// Formats that can carry the selected scope. Single-language TXT and
    /// SRT keep their pure-transcript semantics — review content is never
    /// forced into them.
    private var availableFormats: [ExportFormat] {
        switch scope {
        case .reviewOnly:
            return [.markdown, .json]
        case .transcriptOnly:
            return [.markdown, .bilingualTXT, .russianTXT, .chineseTXT, .json, .srt]
        case .transcriptAndNotes, .fullMaterial:
            return [.markdown, .bilingualTXT, .json]
        }
    }

    private var availableScopes: [ExportScope] {
        if hasReview {
            return ExportScope.allCases
        }
        return [.transcriptOnly, .transcriptAndNotes]
    }

    var body: some View {
        NavigationStack {
            LTPage {
                VStack(alignment: .leading, spacing: LTSpacing.l) {
                    section(title: "内容范围") {
                        VStack(spacing: LTSpacing.xs) {
                            ForEach(availableScopes) { candidate in
                                scopeRow(candidate)
                            }
                        }
                    }
                    section(title: "格式") {
                        VStack(spacing: LTSpacing.xs) {
                            ForEach(availableFormats) { candidate in
                                formatRow(candidate)
                            }
                        }
                    }
                    Button {
                        onExport(scope, format)
                        dismiss()
                    } label: {
                        Label("导出", systemImage: "square.and.arrow.up")
                            .font(LTTypography.button)
                            .foregroundStyle(Color.black.opacity(0.85))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, LTSpacing.s + 2)
                            .background(Capsule().fill(LTColors.accentGreen))
                    }
                    .padding(.top, LTSpacing.s)
                    Spacer()
                }
                .padding(.horizontal, LTSpacing.screenPadding)
                .padding(.vertical, LTSpacing.l)
            }
            .navigationTitle("导出课堂资料")
            .navigationBarTitleDisplayMode(.inline)
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
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            // Start on the richest scope that actually exists.
            scope = hasReview ? .fullMaterial : .transcriptAndNotes
            format = .markdown
        }
        .onChange(of: scope) { _, _ in
            if !availableFormats.contains(format) {
                format = availableFormats.first ?? .markdown
            }
        }
    }

    private func section(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.xs) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(LTColors.textSecondary)
            content()
        }
    }

    private func scopeRow(_ candidate: ExportScope) -> some View {
        let isSelected = candidate == scope
        return Button {
            scope = candidate
            LTHaptics.tap()
        } label: {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? LTColors.accentGreen : LTColors.textTertiary)
                Text(candidate.displayName)
                    .font(.subheadline)
                    .foregroundStyle(LTColors.textPrimary)
                Spacer()
            }
            .padding(LTSpacing.m)
            .background(
                RoundedRectangle(cornerRadius: LTRadius.small)
                    .fill(LTColors.surfacePrimary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LTRadius.small)
                    .strokeBorder(
                        isSelected ? LTColors.accentGreen.opacity(0.4) : LTColors.border,
                        lineWidth: 0.6
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func formatRow(_ candidate: ExportFormat) -> some View {
        let isSelected = candidate == format
        return Button {
            format = candidate
            LTHaptics.tap()
        } label: {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? LTColors.accentGreen : LTColors.textTertiary)
                Text(candidate.displayName)
                    .font(.subheadline)
                    .foregroundStyle(LTColors.textPrimary)
                Spacer()
            }
            .padding(LTSpacing.m)
            .background(
                RoundedRectangle(cornerRadius: LTRadius.small)
                    .fill(LTColors.surfacePrimary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LTRadius.small)
                    .strokeBorder(
                        isSelected ? LTColors.accentGreen.opacity(0.4) : LTColors.border,
                        lineWidth: 0.6
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
