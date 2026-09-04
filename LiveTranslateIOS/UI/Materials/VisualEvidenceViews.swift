import SwiftUI
import UIKit

/// Async thumbnail for one image-kind evidence (attachment renditions,
/// material page caches). Pure display — no files are created. WHICH
/// bytes to read resolves on the main actor (cheap row reads); the
/// decode runs off the main actor.
struct VisualEvidenceThumbnail: View {
    let evidence: VisualEvidence
    @Environment(AppEnvironment.self) private var environment
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(LTColors.surfaceElevated.opacity(0.6))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: evidence.kind.symbol)
                    .font(.caption)
                    .foregroundStyle(LTColors.textTertiary)
            }
        }
        .task(id: evidence.id) {
            let data = resolveThumbnailData()
            guard let data else { return }
            let rendered = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                UIImage(data: data)
            }.value
            guard !Task.isCancelled else { return }
            image = rendered
        }
    }

    @MainActor
    private func resolveThumbnailData() -> Data? {
        switch evidence.kind {
        case .sessionAttachment, .ocr, .analysis:
            guard let attachment = ((try? environment.repository.attachment(id: evidence.sourceID)) ?? nil) else {
                return nil
            }
            return AttachmentFileStoreShared.store?.previewOrOriginalData(
                for: attachment.id, sessionID: attachment.sessionID
            )
        case .materialImage:
            let materialID = evidence.materialID ?? evidence.sourceID
            guard let material = ((try? environment.repository.material(id: materialID)) ?? nil) else {
                return nil
            }
            // Borrowed classroom image → the attachment's preview.
            if let attachmentID = material.sourceAttachmentID,
               let attachment = ((try? environment.repository.attachment(id: attachmentID)) ?? nil) {
                return AttachmentFileStoreShared.store?.previewOrOriginalData(
                    for: attachment.id, sessionID: attachment.sessionID
                )
            }
            let ext = MaterialFileStore.fileExtension(
                fileName: material.originalFileName, mime: material.mimeType
            )
            return MaterialFileStoreShared.store?.originalData(
                materialID: materialID, fileExtension: ext
            )
        case .materialPage:
            guard let materialID = evidence.materialID ?? Optional(evidence.sourceID),
                  let pageNumber = evidence.pageNumber else { return nil }
            return MaterialFileStoreShared.store?.pageThumbnailData(
                materialID: materialID, pageNumber: pageNumber
            )
        case .transcript, .note:
            return nil
        }
    }
}

/// One evidence chip: thumbnail (image kinds) or icon (text kinds),
/// title + page/crop detail, and an honest existence state — a deleted
/// source renders 原图片已不存在 and jumps nowhere; another image is
/// never substituted.
struct VisualEvidenceChip: View {
    @Environment(AppEnvironment.self) private var environment
    let evidence: VisualEvidence
    /// 0-based order in the turn (drives the 图片 n badge).
    var order: Int? = nil
    var compact: Bool = false

    @State private var exists: Bool = true

    var body: some View {
        Group {
            if exists {
                jumpLink
            } else {
                label.disabled(true).opacity(0.7)
            }
        }
        .task(id: evidence.id) {
            exists = VisualAskEvidenceLoader.sourceExists(
                evidence, repository: environment.repository
            )
        }
    }

    @ViewBuilder
    private var jumpLink: some View {
        switch evidence.kind {
        case .sessionAttachment, .ocr, .analysis:
            if let sessionID = evidence.sessionID,
               let session = liveSession(for: sessionID) {
                NavigationLink {
                    AttachmentDetailView(
                        session: session,
                        attachmentID: evidence.sourceID,
                        onChanged: {}
                    )
                    .environment(environment)
                } label: {
                    label
                }
                .buttonStyle(.plain)
            } else {
                label
            }
        case .materialImage:
            NavigationLink {
                MaterialReaderScreen(materialID: evidence.materialID ?? evidence.sourceID)
                    .environment(environment)
            } label: {
                label
            }
            .buttonStyle(.plain)
        case .materialPage:
            if let materialID = evidence.materialID {
                NavigationLink {
                    MaterialReaderScreen(materialID: materialID, initialPage: evidence.pageNumber)
                        .environment(environment)
                } label: {
                    label
                }
                .buttonStyle(.plain)
            } else {
                label
            }
        case .transcript, .note:
            if let sessionID = evidence.sessionID {
                NavigationLink {
                    SessionDetailView(sessionID: sessionID)
                        .environment(environment)
                } label: {
                    label
                }
                .buttonStyle(.plain)
            } else {
                label
            }
        }
    }

    private var label: some View {
        HStack(spacing: LTSpacing.xs) {
            if evidence.kind.isImageKind {
                VisualEvidenceThumbnail(evidence: evidence)
                    .frame(width: compact ? 34 : 44, height: compact ? 34 : 44)
                    .clipShape(RoundedRectangle(cornerRadius: LTRadius.small))
            } else {
                LTIconBadge(
                    symbol: evidence.kind.symbol,
                    tint: LTColors.accentCyan,
                    size: compact ? 26 : 32
                )
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: LTSpacing.xxs) {
                    if let order {
                        Text("图片 \(order + 1)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(LTColors.accentGreen)
                    }
                    Text(evidence.title)
                        .font(LTTypography.button)
                        .foregroundStyle(exists ? LTColors.accentCyan : LTColors.textTertiary)
                        .lineLimit(1)
                }
                Text(subtitle)
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, LTSpacing.s)
        .padding(.vertical, LTSpacing.xxs)
        .background(LTColors.surfaceElevated.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: LTRadius.small))
        .overlay(
            RoundedRectangle(cornerRadius: LTRadius.small)
                .strokeBorder(LTColors.border, lineWidth: 0.5)
        )
        .accessibilityLabel(Text(
            exists ? "\(evidence.kind.displayName) \(evidence.title)" : "原图片已不存在"
        ))
    }

    private var subtitle: String {
        if !exists { return "原图片已不存在" }
        var parts: [String] = [evidence.kind.displayName]
        if let detail = evidence.detailLabel { parts.append(detail) }
        if let snippet = evidence.snippet, !snippet.isEmpty, !evidence.kind.isImageKind {
            parts.append(String(snippet.prefix(30)))
        }
        return parts.joined(separator: " · ")
    }

    @MainActor
    private func liveSession(for sessionID: UUID) -> ClassroomSession? {
        let sessions = (try? environment.repository.sessions(matching: "")) ?? []
        return sessions.first { $0.id == sessionID }
    }
}
