import SwiftUI
import UIKit

// MARK: - Image rendering helpers

/// In-memory rendering of the non-destructive display transform (crop →
/// rotate). The STORED files are never re-encoded — this exists purely so
/// lists, viewers and exports show the user's intended framing.
enum AttachmentRender {
    /// Applies the transform to a display image. Returns the input when
    /// the transform is identity or rendering fails (a bad transform must
    /// never hide the original).
    static func applyTransform(_ image: UIImage, transform: AttachmentTransform) -> UIImage {
        guard !transform.isIdentity else { return image }
        // 1) Crop (normalized rect on the source pixels).
        var cropped = image
        let pixelW = image.size.width * image.scale
        let pixelH = image.size.height * image.scale
        let rect = CGRect(
            x: transform.cropX * pixelW,
            y: transform.cropY * pixelH,
            width: transform.cropWidth * pixelW,
            height: transform.cropHeight * pixelH
        ).integral
        if rect.width > 2, rect.height > 2, rect.minX >= 0, rect.minY >= 0,
           rect.maxX <= pixelW, rect.maxY <= pixelH,
           let cg = image.cgImage?.cropping(to: rect) {
            cropped = UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
        }
        // 2) Rotate by quarter turns (clockwise).
        guard transform.quarterTurns > 0 else { return cropped }
        let rotatedSize = transform.quarterTurns % 2 == 1
            ? CGSize(width: cropped.size.height, height: cropped.size.width)
            : cropped.size
        return cropped.rotatedClockwise(
            quarterTurns: transform.quarterTurns, fitting: rotatedSize
        )
    }
}

private extension UIImage {
    /// Clockwise quarter-turn rendering into `size` (the rotated bounds).
    func rotatedClockwise(quarterTurns: Int, fitting size: CGSize) -> UIImage {
        let radians = -CGFloat(quarterTurns) * .pi / 2
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            ctx.cgContext.translateBy(x: size.width / 2, y: size.height / 2)
            ctx.cgContext.rotate(by: radians)
            draw(in: CGRect(
                x: -self.size.width / 2, y: -self.size.height / 2,
                width: self.size.width, height: self.size.height
            ))
        }
    }
}

// MARK: - Shared preview image

/// Async preview image (list/grid sizes). Loads the stored preview bytes,
/// falling back to the original; applies the non-destructive transform at
/// render time. Loads off the main actor; shows a quiet placeholder until
/// the image lands.
struct AttachmentPreviewImage: View {
    let attachmentID: UUID
    let sessionID: UUID
    var transformJSON: String = ""
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Rectangle().fill(LTColors.surfaceElevated.opacity(0.6))
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                } else {
                    Image(systemName: "photo")
                        .font(.title3)
                        .foregroundStyle(LTColors.textTertiary)
                }
            }
        }
        .task(id: "\(attachmentID.uuidString)|\(transformJSON)") {
            let id = attachmentID
            let sid = sessionID
            let tJSON = transformJSON
            let rendered = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let store = AttachmentFileStoreShared.store,
                      let data = store.previewOrOriginalData(for: id, sessionID: sid),
                      let base = UIImage(data: data) else { return nil }
                let transform = AttachmentTransform.decode(tJSON) ?? .identity
                return AttachmentRender.applyTransform(base, transform: transform)
            }.value
            guard !Task.isCancelled else { return }
            image = rendered
        }
    }
}

// MARK: - Live classroom thumbnail

/// Compact in-class thumbnail with a delete affordance (context menu).
struct LiveAttachmentThumbnail: View {
    let attachment: SessionAttachment
    let onDelete: () -> Void

    var body: some View {
        AttachmentPreviewImage(
            attachmentID: attachment.id,
            sessionID: attachment.sessionID,
            transformJSON: attachment.transformJSON
        )
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: LTRadius.small))
        .overlay(alignment: .bottomLeading) {
            Text(attachment.kind.displayName)
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(3)
        }
        .contextMenu {
            Button("删除这张图片", role: .destructive, action: onDelete)
        }
        .accessibilityLabel(Text("\(attachment.kind.displayName)图片"))
    }
}

// MARK: - Session detail section (板书与图片)

/// The 板书与图片 section of the session detail: a chronological grid of
/// the class's images with per-image analysis states and batch actions.
/// Editing (metadata, crop, analysis results) lives in the detail viewer.
struct AttachmentSectionView: View {
    @Environment(AppEnvironment.self) private var environment
    let session: ClassroomSession
    let attachments: [SessionAttachment]
    /// Fires when attachments were added/edited/re-analyzed so the detail
    /// can offer 课堂资料已更新 (study review staleness).
    var onAttachmentSetChanged: () -> Void

    @State private var selectedAttachmentID: UUID?
    @State private var showCapture = false
    @State private var analysisMode: AttachmentAnalysisGenerator.Mode?

    var body: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            HStack(spacing: LTSpacing.xs) {
                Label("板书与图片", systemImage: "photo.on.rectangle.angled")
                    .font(LTTypography.cardTitle)
                    .foregroundStyle(LTColors.textPrimary)
                if !attachments.isEmpty {
                    Text("\(attachments.count)")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textTertiary)
                }
                Spacer()
                if !attachments.isEmpty {
                    Menu {
                        ForEach(AttachmentAnalysisGenerator.Mode.allCases) { mode in
                            Button(mode.displayName) {
                                analysisMode = mode
                            }
                        }
                    } label: {
                        Label(
                            pendingAnalysisCount > 0
                                ? "分析图片（\(pendingAnalysisCount)）"
                                : "分析图片",
                            systemImage: "sparkles"
                        )
                        .font(.footnote)
                    }
                    .disabled(pendingAnalysisCount == 0 && failedCount == 0)
                }
                Button {
                    showCapture = true
                } label: {
                    Image(systemName: "plus")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(LTColors.textSecondary)
                }
                .accessibilityLabel(Text("添加课堂图片"))
            }

            if attachments.isEmpty {
                Text("课堂中没有拍摄或导入的图片。上课时可以在课堂里拍摄黑板、导入手写笔记或课件。")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textTertiary)
                    .padding(.vertical, LTSpacing.xs)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: LTSpacing.s)], spacing: LTSpacing.s) {
                    ForEach(attachments, id: \.id) { attachment in
                        AttachmentGridCell(
                            attachment: attachment,
                            progress: environment.attachmentAnalysisGenerator.progressByID[attachment.id]
                        )
                        .onTapGesture { selectedAttachmentID = attachment.id }
                    }
                }
                if let summary = analysisSummary {
                    Text(summary)
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textTertiary)
                }
            }
        }
        .padding(LTSpacing.m)
        .background(
            RoundedRectangle(cornerRadius: LTRadius.medium)
                .fill(LTColors.surfacePrimary.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: LTRadius.medium)
                .strokeBorder(LTColors.border, lineWidth: 0.5)
        )
        .sheet(isPresented: $showCapture) {
            AttachmentCaptureSheet(
                sessionID: session.id,
                isPresented: $showCapture,
                onImported: { onAttachmentSetChanged() }
            )
        }
        .sheet(item: Binding(
            get: { analysisMode.map { AnalysisModeBox(mode: $0) } },
            set: { analysisMode = $0?.mode }
        )) { box in
            AttachmentBatchAnalysisSheet(
                session: session,
                attachments: attachments,
                mode: box.mode,
                onComplete: { onAttachmentSetChanged() }
            )
        }
        .sheet(item: Binding(
            get: { selectedAttachmentID.flatMap { id in attachments.first { $0.id == id } } },
            set: { selectedAttachmentID = $0?.id }
        )) { attachment in
            AttachmentDetailView(
                session: session,
                attachmentID: attachment.id,
                onChanged: onAttachmentSetChanged
            )
        }
    }

    private var pendingAnalysisCount: Int {
        attachments.filter {
            $0.analysisStatus == .pending || $0.analysisStatus == .analyzing
        }.count
    }

    private var failedCount: Int {
        attachments.filter { $0.analysisStatus == .failed }.count
    }

    private var analysisSummary: String? {
        let completed = attachments.filter {
            $0.analysisStatus == .completed || $0.analysisStatus == .partial
        }.count
        let failed = failedCount
        guard completed > 0 || failed > 0 else { return nil }
        if failed > 0 {
            return String(localized: "已分析 \(completed) 张 · \(failed) 张失败，可单独重试")
        }
        return String(localized: "已分析 \(completed) 张")
    }
}

/// Identifiable wrapper for the analysis-mode sheet.
private struct AnalysisModeBox: Identifiable {
    let mode: AttachmentAnalysisGenerator.Mode
    var id: String { mode.rawValue }
}

/// Grid cell: preview + analysis state mark.
struct AttachmentGridCell: View {
    let attachment: SessionAttachment
    let progress: AttachmentAnalysisGenerator.ProgressState?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            AttachmentPreviewImage(
                attachmentID: attachment.id,
                sessionID: attachment.sessionID,
                transformJSON: attachment.transformJSON
            )
            .frame(height: 88)
            .clipShape(RoundedRectangle(cornerRadius: LTRadius.small))
            .overlay(
                RoundedRectangle(cornerRadius: LTRadius.small)
                    .strokeBorder(LTColors.border, lineWidth: 0.5)
            )
            stateBadge
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(attachment.kind.displayName)，\(stateLabel)"))
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch attachment.analysisStatus {
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(LTColors.accentGreen)
                .padding(4)
        case .partial:
            Image(systemName: "checkmark.circle.trianglebadge.exclamationmark")
                .font(.system(size: 13))
                .foregroundStyle(LTColors.warning)
                .padding(4)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(LTColors.destructive)
                .padding(4)
        case .analyzing:
            ProgressView()
                .controlSize(.small)
                .padding(4)
                .background(.ultraThinMaterial, in: Circle())
        default:
            EmptyView()
        }
    }

    private var stateLabel: String {
        if let progress {
            switch progress {
            case .waiting: return String(localized: "排队中")
            case .analyzing: return String(localized: "分析中")
            case .completed: return String(localized: "已分析")
            case .partial: return String(localized: "部分完成")
            case .failed: return String(localized: "分析失败")
            case .cancelled: return String(localized: "已取消")
            }
        }
        switch attachment.analysisStatus {
        case .pending: return String(localized: "未分析")
        case .analyzing: return String(localized: "分析中")
        case .completed: return String(localized: "已分析")
        case .partial: return String(localized: "部分完成")
        case .failed: return String(localized: "分析失败")
        }
    }
}

// MARK: - Batch analysis sheet

/// Presents the two user-facing analysis modes, then kicks the generator
/// off. Progress is the generator's REAL per-image state — no fake
/// percentages.
struct AttachmentBatchAnalysisSheet: View {
    @Environment(AppEnvironment.self) private var environment
    let session: ClassroomSession
    let attachments: [SessionAttachment]
    let mode: AttachmentAnalysisGenerator.Mode
    let onComplete: () -> Void
    @Environment(\.dismiss) private var dismiss

    /// Only images that still need work run; completed ones stay.
    private var targets: [SessionAttachment] {
        attachments.filter {
            $0.analysisStatus == .pending || $0.analysisStatus == .failed
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: LTSpacing.l) {
                Label(mode.explanation, systemImage: "sparkles")
                    .font(.footnote)
                    .foregroundStyle(LTColors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if targets.isEmpty {
                    Text("所有图片都已有分析结果。可在单张图片里重新分析。")
                        .font(.footnote)
                        .foregroundStyle(LTColors.textTertiary)
                } else {
                    Text("将分析 \(targets.count) 张图片，逐张进行。某张失败不影响其他图片，可以单独重试。")
                        .font(.footnote)
                        .foregroundStyle(LTColors.textTertiary)
                }

                if !environment.attachmentAnalysisService.isConfiguredNow {
                    Label("图片理解模型未配置，请先在设置中填写", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(LTColors.warning)
                }

                Spacer()

                Button {
                    start()
                } label: {
                    Text(mode.displayName)
                        .font(LTTypography.button)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(LTPrimaryButtonStyle())
                .disabled(targets.isEmpty || !environment.attachmentAnalysisService.isConfiguredNow)
            }
            .padding(LTSpacing.screenPadding)
            .navigationTitle("图片分析")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func start() {
        let provider = AttachmentAnalysisContext.provider(
            repository: environment.repository, session: session
        )
        environment.attachmentAnalysisGenerator.analyze(targets, mode: mode, context: provider)
        dismiss()
        onComplete()
    }
}
