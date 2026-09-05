import SwiftUI
import PhotosUI
import UIKit

/// The classroom image capture entry: a restrained sheet offering camera
/// and photo-library import. Deliberately NOT an editor — the class keeps
/// running, images land anchored to the current transcript entry, and the
/// user can rotate/crop/re-classify afterwards in the session detail.
struct AttachmentCaptureSheet: View {
    @Environment(AppEnvironment.self) private var environment
    /// Target session (live classroom or a past class in the detail view).
    let sessionID: UUID
    /// Default anchor for new images (the live classroom's current entry;
    /// nil for post-class imports).
    var defaultAnchorEntryID: UUID? = nil
    /// Whether to show the in-class anchoring hint.
    var showsAnchorHint: Bool = false
    /// Fired after a successful import so callers can refresh.
    var onImported: () -> Void = {}
    @Binding var isPresented: Bool

    @State private var showCamera = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var importFeedback: String?
    @State private var showDuplicatesNotice = false

    var body: some View {
        NavigationStack {
            VStack(spacing: LTSpacing.l) {
                if showsAnchorHint {
                    Text("图片将关联当前课堂，默认锚定正在显示的转录段落")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textTertiary)
                }

                Button {
                    guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                        importFeedback = String(localized: "此设备没有可用相机")
                        return
                    }
                    showCamera = true
                } label: {
                    captureButtonLabel(
                        symbol: "camera.fill",
                        title: "拍摄黑板",
                        subtitle: "使用相机拍摄当前板书"
                    )
                }
                .buttonStyle(.plain)

                PhotosPicker(
                    selection: $photoSelection,
                    maxSelectionCount: 10,
                    matching: .images
                ) {
                    captureButtonLabel(
                        symbol: "photo.on.rectangle.angled",
                        title: "从相册导入",
                        subtitle: "板书、课件或手写笔记（可多选）"
                    )
                }
                .buttonStyle(.plain)

                if let importFeedback {
                    Label(importFeedback, systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(LTColors.accentGreen)
                        .padding(.top, LTSpacing.xs)
                }
                if showDuplicatesNotice {
                    Label("相册中的部分图片已在本课堂中，已跳过", systemImage: "arrow.triangle.2.circlepath")
                        .font(.footnote)
                        .foregroundStyle(LTColors.warning)
                }
                if environment.attachmentImporter.isImporting {
                    ProgressView("正在保存图片…")
                        .font(.footnote)
                }
                Spacer()
            }
            .padding(LTSpacing.screenPadding)
            .navigationTitle("添加课堂图片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { isPresented = false }
                }
            }
            .sheet(isPresented: $showCamera) {
                CameraCaptureSheet { image in
                    showCamera = false
                    if let image {
                        Task { await importCaptured(image) }
                    }
                }
            }
            .onChange(of: photoSelection) { _, items in
                guard !items.isEmpty else { return }
                let picked = items
                photoSelection = []
                Task { await importPicked(picked) }
            }
        }
        .preferredColorScheme(.dark)
    }

    // nonisolated: the PhotosPicker label closure is nonisolated (the
    // button label above it too); this view touches no instance state.
    nonisolated private func captureButtonLabel(symbol: String, title: String, subtitle: String) -> some View {
        HStack(spacing: LTSpacing.m) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(LTColors.accentGreen)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LTColors.textPrimary)
                Text(subtitle)
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textTertiary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote)
                .foregroundStyle(LTColors.textTertiary)
        }
        .padding(LTSpacing.m)
        .background(
            RoundedRectangle(cornerRadius: LTRadius.medium)
                .fill(LTColors.surfacePrimary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LTRadius.medium)
                .strokeBorder(LTColors.border, lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: LTRadius.medium))
    }

    /// The entry a new image anchors to (the same notion of "current" as
    /// the notes composer uses).
    private var anchorEntryID: UUID? {
        defaultAnchorEntryID
    }

    private func importCaptured(_ image: UIImage) async {
        guard let data = image.jpegData(compressionQuality: 0.9) else {
            importFeedback = String(localized: "图片保存失败")
            return
        }
        await runImport([
            AttachmentImagePayload(
                data: data, capturedAt: .now,
                suggestedTitle: String(localized: "黑板"), suggestedKind: .blackboard
            )
        ], sessionID: sessionID)
    }

    private func importPicked(_ items: [PhotosPickerItem]) async {
        var payloads: [AttachmentImagePayload] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            // PHPicker exposes no creation date without full library
            // permission — imported photos use the import time as their
            // timeline position.
            payloads.append(AttachmentImagePayload(data: data, capturedAt: .now))
        }
        guard !payloads.isEmpty else {
            importFeedback = String(localized: "无法读取所选图片")
            return
        }
        await runImport(payloads, sessionID: sessionID)
    }

    private func runImport(_ payloads: [AttachmentImagePayload], sessionID: UUID) async {
        let outcome = await environment.attachmentImporter.importImages(
            payloads, sessionID: sessionID,
            defaultKind: .blackboard, anchorEntryID: anchorEntryID
        )
        if outcome.imported.isEmpty && !outcome.failures.isEmpty {
            importFeedback = outcome.failures.first
        } else {
            importFeedback = String(localized: "已保存 \(outcome.imported.count) 张图片")
            LTHaptics.success()
        }
        showDuplicatesNotice = !outcome.duplicates.isEmpty
        onImported()
    }
}

/// UIImagePickerController wrapper for in-class camera capture. Photos are
/// returned as UIImage (JPEG-encoded by the caller); no library write —
/// the image belongs to the classroom, not the camera roll.
struct CameraCaptureSheet: UIViewControllerRepresentable {
    let onCapture: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage?) -> Void

        init(onCapture: @escaping (UIImage?) -> Void) {
            self.onCapture = onCapture
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            let image = info[.originalImage] as? UIImage
            onCapture(image)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCapture(nil)
        }
    }
}
