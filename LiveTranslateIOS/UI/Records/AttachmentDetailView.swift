import SwiftUI
import UIKit

/// Full attachment viewer: the image (original on demand), the structured
/// analysis with clear source separation (可见内容 / AI 解释 / 不确定),
/// the nearby transcript context, metadata editing, non-destructive
/// rotate/crop, re-analysis and delete.
struct AttachmentDetailView: View {
    @Environment(AppEnvironment.self) private var environment
    let session: ClassroomSession
    let attachmentID: UUID
    let onChanged: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var attachment: SessionAttachment?
    @State private var showEditor = false
    @State private var showCropper = false
    @State private var showDeleteConfirmation = false
    @State private var analysisMode: AttachmentAnalysisGenerator.Mode?
    @State private var originalLoaded = false
    @State private var downloadingOriginal = false

    var body: some View {
        NavigationStack {
            Group {
                if let attachment {
                    content(attachment)
                } else {
                    LTEmptyState(
                        symbol: "photo",
                        title: "图片不存在",
                        message: "这张图片可能已被删除"
                    )
                }
            }
            .navigationTitle(attachment?.title.isEmpty == false ? attachment!.title : "课堂图片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("编辑信息") { showEditor = true }
                        Button("旋转 90°") { rotate(attachment) }
                        Button("裁切") { showCropper = true }
                        Menu("分析") {
                            ForEach(AttachmentAnalysisGenerator.Mode.allCases) { mode in
                                Button(mode.displayName) { analysisMode = mode }
                            }
                        }
                        Button("重新分析") { analysisMode = .withClassContext }
                        Divider()
                        Button("删除图片", role: .destructive) {
                            showDeleteConfirmation = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .onAppear { reload() }
        .sheet(item: $termDraftBox) { box in
            TermSaveSheet(draft: box.draft)
        }
        .sheet(item: $cardDraftBox) { box in
            CardSaveSheet(draft: box.draft)
        }
        .sheet(item: $taskDraftBox) { box in
            TaskSaveSheet(draft: box.draft, editingTask: nil)
        }
        .sheet(isPresented: $showEditor) {
            if let attachment {
                AttachmentEditSheet(attachment: attachment, session: session) {
                    reload()
                    onChanged()
                }
            }
        }
        .sheet(isPresented: $showCropper) {
            if let attachment {
                AttachmentCropSheet(attachment: attachment) { transform in
                    try? environment.repository.updateAttachmentTransform(
                        attachment, transform: transform
                    )
                    reload()
                    onChanged()
                }
            }
        }
        .sheet(item: Binding(
            get: { analysisMode.map { AnalysisModeBox2(mode: $0) } },
            set: { analysisMode = $0?.mode }
        )) { box in
            if let attachment {
                AttachmentBatchAnalysisSheet(
                    session: session,
                    attachments: [attachment],
                    mode: box.mode,
                    onComplete: {
                        reload()
                        onChanged()
                    }
                )
            }
        }
        .confirmationDialog("删除这张图片？", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let attachment {
                    try? environment.repository.deleteAttachment(attachment)
                }
                onChanged()
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("原图、缩略图和分析结果会一起删除，已同步到云端的副本也会删除。")
        }
    }

    // MARK: - Content

    private func content(_ attachment: SessionAttachment) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LTSpacing.m) {
                imageView(attachment)

                HStack(spacing: LTSpacing.xs) {
                    Text(attachment.kind.displayName)
                        .font(LTTypography.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(LTColors.surfaceElevated))
                    Text(captureLabel(attachment))
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textTertiary)
                    if !attachment.caption.isEmpty {
                        Text(attachment.caption)
                            .font(LTTypography.caption)
                            .foregroundStyle(LTColors.textSecondary)
                            .lineLimit(2)
                    }
                    Spacer()
                }
                .padding(.horizontal, LTSpacing.screenPadding)

                analysisSection(attachment)
                transcriptContextSection(attachment)
                ocrSection(attachment)
                syncSection(attachment)
            }
            .padding(.vertical, LTSpacing.s)
        }
    }

    /// The image. Uses the preview by default; the original loads on
    /// demand (locally, or downloaded from the user's server when it was
    /// reclaimed).
    private func imageView(_ attachment: SessionAttachment) -> some View {
        ZStack {
            AttachmentPreviewImage(
                attachmentID: attachment.id,
                sessionID: attachment.sessionID,
                transformJSON: attachment.transformJSON,
                contentMode: .fit
            )
            .frame(height: 300)
            if downloadingOriginal {
                ProgressView("正在下载原图…")
                    .padding(LTSpacing.m)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: LTRadius.small))
            }
        }
        .padding(.horizontal, LTSpacing.screenPadding)
        .onTapGesture { Task { await loadOriginal(attachment) } }
        .accessibilityLabel(Text("课堂图片，点按查看原图"))
    }

    private func captureLabel(_ attachment: SessionAttachment) -> String {
        let offset = attachment.capturedAt.timeIntervalSince(session.startTime)
        if offset >= 0, offset <= max(session.duration, 0) + 60 {
            return String(localized: "课堂上 \(TranscriptExporter.mmss(offset))")
        }
        return Format.time(attachment.capturedAt)
    }

    // MARK: - Analysis

    @ViewBuilder
    private func analysisSection(_ attachment: SessionAttachment) -> some View {
        let progress = environment.attachmentAnalysisGenerator.progressByID[attachment.id]
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            Label("图片理解", systemImage: "sparkles")
                .font(LTTypography.cardTitle)
                .foregroundStyle(LTColors.textPrimary)

            switch attachment.analysisStatus {
            case .pending:
                Text("尚未分析。可以在上方菜单里选择分析方式。")
                    .font(.footnote)
                    .foregroundStyle(LTColors.textTertiary)
            case .analyzing:
                HStack(spacing: LTSpacing.xs) {
                    ProgressView().controlSize(.small)
                    Text("正在分析这张图片…")
                        .font(.footnote)
                        .foregroundStyle(LTColors.textSecondary)
                }
            case .failed:
                VStack(alignment: .leading, spacing: LTSpacing.xs) {
                    Text(failureText(progress))
                        .font(.footnote)
                        .foregroundStyle(LTColors.destructive)
                    Button("重新分析") { analysisMode = .withClassContext }
                        .font(.footnote.bold())
                        .buttonStyle(LTSecondaryButtonStyle(tint: LTColors.accentBlue))
                }
            case .completed, .partial:
                if let result = AttachmentAnalysisResult.decode(attachment.analysisJSON) {
                    AnalysisResultView(
                        result: result,
                        session: session,
                        isPartial: attachment.analysisStatus == .partial
                    )
                } else {
                    Text("分析结果无法读取。")
                        .font(.footnote)
                        .foregroundStyle(LTColors.textTertiary)
                }
            }
        }
        .padding(LTSpacing.m)
        .background(
            RoundedRectangle(cornerRadius: LTRadius.medium)
                .fill(LTColors.surfacePrimary.opacity(0.5))
        )
        .padding(.horizontal, LTSpacing.screenPadding)
    }

    private func failureText(_ progress: AttachmentAnalysisGenerator.ProgressState?) -> String {
        if case .failed(let message)? = progress { return message }
        return String(localized: "分析失败，可以重试。图片和本地文字识别不受影响。")
    }

    // MARK: - Nearby transcript

    @ViewBuilder
    private func transcriptContextSection(_ attachment: SessionAttachment) -> some View {
        let nearby = nearbyEntries(attachment)
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            Label("附近转录", systemImage: "text.bubble")
                .font(LTTypography.cardTitle)
                .foregroundStyle(LTColors.textPrimary)
            if nearby.isEmpty {
                Text("图片拍摄时附近没有转录内容。")
                    .font(.footnote)
                    .foregroundStyle(LTColors.textTertiary)
            } else {
                ForEach(nearby, id: \.id) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: LTSpacing.xs) {
                            Text(TranscriptExporter.mmss(entry.startOffset))
                                .font(LTTypography.timestamp)
                                .foregroundStyle(LTColors.textTertiary)
                            if entry.id == attachment.anchorEntryID {
                                Text("锚定段落")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(LTColors.warning)
                            }
                        }
                        Text(entry.originalText)
                            .font(.footnote)
                            .foregroundStyle(LTColors.textPrimary)
                        if let chinese = entry.translatedText {
                            Text(chinese)
                                .font(.footnote)
                                .foregroundStyle(LTColors.textSecondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(LTSpacing.m)
        .background(
            RoundedRectangle(cornerRadius: LTRadius.medium)
                .fill(LTColors.surfacePrimary.opacity(0.5))
        )
        .padding(.horizontal, LTSpacing.screenPadding)
    }

    /// Transcript entries around the capture point (the anchored entry's
    /// neighborhood), bounded for reading.
    private func nearbyEntries(_ attachment: SessionAttachment) -> [TranscriptEntry] {
        let entries = (try? environment.repository.entries(for: session)) ?? []
        guard !entries.isEmpty else { return [] }
        let center: TimeInterval
        if let anchorID = attachment.anchorEntryID,
           let anchored = entries.first(where: { $0.id == anchorID }) {
            center = anchored.startOffset
        } else {
            let elapsed = attachment.capturedAt.timeIntervalSince(session.startTime)
            center = max(0, elapsed)
        }
        return entries
            .filter { abs($0.startOffset - center) <= 120 }
            .prefix(10)
            .sorted { $0.startOffset < $1.startOffset }
    }

    // MARK: - Local OCR

    @ViewBuilder
    private func ocrSection(_ attachment: SessionAttachment) -> some View {
        if !attachment.ocrText.isEmpty {
            VStack(alignment: .leading, spacing: LTSpacing.s) {
                Label("本地文字识别", systemImage: "doc.text.viewfinder")
                    .font(LTTypography.cardTitle)
                    .foregroundStyle(LTColors.textPrimary)
                Text(attachment.ocrText)
                    .font(.footnote)
                    .foregroundStyle(LTColors.textSecondary)
                    .textSelection(.enabled)
                Text("系统本地识别，可能有误；与图片理解结果分开保存。可在编辑信息中修改。")
                    .font(.system(size: 11))
                    .foregroundStyle(LTColors.textTertiary)
            }
            .padding(LTSpacing.m)
            .background(
                RoundedRectangle(cornerRadius: LTRadius.medium)
                    .fill(LTColors.surfacePrimary.opacity(0.5))
            )
            .padding(.horizontal, LTSpacing.screenPadding)
        }
    }

    // MARK: - Sync state

    @ViewBuilder
    private func syncSection(_ attachment: SessionAttachment) -> some View {
        if let sync = environment.cloudSync, sync.isSignedIn {
            let uploaded = sync.allAttachmentFilesUploaded || attachment.serverVersion == 0
            Label(
                attachment.serverVersion == 0
                    ? "等待同步到云端"
                    : (uploaded ? "已同步" : "正在上传图片文件"),
                systemImage: attachment.serverVersion == 0 || !uploaded
                    ? "arrow.triangle.2.circlepath" : "checkmark.icloud"
            )
            .font(LTTypography.caption)
            .foregroundStyle(LTColors.textTertiary)
            .padding(.horizontal, LTSpacing.screenPadding)
        }
    }

    // MARK: - Actions

    private func reload() {
        attachment = try? environment.repository.attachment(id: attachmentID)
    }

    private func rotate(_ attachment: SessionAttachment) {
        let next = attachment.transform.rotatedRight()
        try? environment.repository.updateAttachmentTransform(attachment, transform: next)
        reload()
        onChanged()
    }

    private func loadOriginal(_ attachment: SessionAttachment) async {
        guard let store = AttachmentFileStoreShared.store,
              !store.fileExists(
                  for: attachment.id, sessionID: attachment.sessionID, variant: .original
              ) else { return }
        guard let sync = environment.cloudSync else { return }
        downloadingOriginal = true
        defer { downloadingOriginal = false }
        _ = await sync.downloadAttachmentFile(attachment, variant: .original)
        reload()
    }
}

private struct AnalysisModeBox2: Identifiable {
    let mode: AttachmentAnalysisGenerator.Mode
    var id: String { mode.rawValue }
}

// MARK: - Analysis result display

/// The structured analysis with explicit source separation:
/// 可见内容 (image-visible), AI 解释 (interpretation), 不确定 (hedges).
struct AnalysisResultView: View {
    @Environment(AppEnvironment.self) private var environment
    let result: AttachmentAnalysisResult
    let session: ClassroomSession
    var isPartial: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: LTSpacing.m) {
            if isPartial {
                Label("结果不完整（部分内容解析失败），可重新分析补全", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(LTColors.warning)
            }

            if let title = result.title, !title.isEmpty {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LTColors.textPrimary)
            }

            section("图片中可见的内容", systemImage: "eye", items: result.visibleText)
            codeSection("识别出的公式", systemImage: "function", items: result.formulas)
            codeSection("识别出的代码", systemImage: "chevron.left.forwardslash.chevron.right", items: result.codeBlocks)
            section("要点", systemImage: "list.bullet", items: result.keyPoints)

            if let explanation = result.explanation, !explanation.isEmpty {
                VStack(alignment: .leading, spacing: LTSpacing.xs) {
                    Label("AI 解释（结合课堂上下文）", systemImage: "brain")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(LTColors.textSecondary)
                    Text(explanation)
                        .font(.footnote)
                        .foregroundStyle(LTColors.textPrimary)
                        .textSelection(.enabled)
                }
            }

            section("不确定的内容", systemImage: "questionmark.circle", items: result.uncertainties)

            if let references = result.transcriptReferences, !references.isEmpty {
                referenceRow(references)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, systemImage: String, items: [String]?) -> some View {
        if let items, !items.isEmpty {
            VStack(alignment: .leading, spacing: LTSpacing.xs) {
                Label(title, systemImage: systemImage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(LTColors.textSecondary)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text(item)
                        .font(.footnote)
                        .foregroundStyle(LTColors.textPrimary)
                        .textSelection(.enabled)
                        .contextMenu {
                            Button {
                                termDraftBox = TermDraftBox(draft: TermDraft(
                                    russian: item,
                                    courseID: session.courseID,
                                    sessionID: session.id,
                                    sourceAttachmentID: attachmentID
                                ))
                            } label: {
                                Label("保存为术语", systemImage: "character.book.closed")
                            }
                            Button {
                                cardDraftBox = CardDraftBox(draft: CardDraft(
                                    front: item, back: "",
                                    courseID: session.courseID,
                                    sessionID: session.id,
                                    sourceAttachmentID: attachmentID
                                ))
                            } label: {
                                Label("制作学习卡片", systemImage: "rectangle.on.rectangle")
                            }
                            Button {
                                taskDraftBox = TaskDraftBox(draft: TaskDraft(
                                    title: String(item.prefix(120)),
                                    status: .pendingConfirm,
                                    origin: .ai,
                                    uncertainty: "从图片分析识别的作业候选，确认后生效",
                                    courseID: session.courseID,
                                    sessionID: session.id,
                                    sourceAttachmentID: attachmentID
                                ))
                            } label: {
                                Label("转为任务（待确认）", systemImage: "checklist")
                            }
                        }
                }
            }
        }
    }

    /// Formulas and code render in monospace to preserve structure.
    @ViewBuilder
    private func codeSection(_ title: String, systemImage: String, items: [String]?) -> some View {
        if let items, !items.isEmpty {
            VStack(alignment: .leading, spacing: LTSpacing.xs) {
                Label(title, systemImage: systemImage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(LTColors.textSecondary)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(item)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(LTColors.textPrimary)
                            .textSelection(.enabled)
                    }
                    .contextMenu {
                        Button {
                            cardDraftBox = CardDraftBox(draft: CardDraft(
                                front: item, back: "",
                                type: title.contains("公式") ? .formula : .code,
                                courseID: session.courseID,
                                sessionID: session.id,
                                sourceAttachmentID: attachmentID
                            ))
                        } label: {
                            Label("制作学习卡片", systemImage: "rectangle.on.rectangle")
                        }
                    }
                }
            }
        }
    }

    /// Referenced transcript lines — validated against the session's real
    /// entries before display (dangling ids are dropped, never rendered).
    @ViewBuilder
    private func referenceRow(_ references: [UUID]) -> some View {
        let entries = (try? environment.repository.entries(for: session)) ?? []
        let resolved = references.compactMap { id in entries.first { $0.id == id } }
        if !resolved.isEmpty {
            VStack(alignment: .leading, spacing: LTSpacing.xs) {
                Label("关联的转录内容", systemImage: "link")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(LTColors.textSecondary)
                ForEach(resolved, id: \.id) { entry in
                    Text("\(TranscriptExporter.mmss(entry.startOffset)) · \(entry.originalText)")
                        .font(.footnote)
                        .foregroundStyle(LTColors.textSecondary)
                        .lineLimit(2)
                }
            }
        }
    }
}

// MARK: - Metadata editor

/// Title / caption / kind / anchor / OCR text editing.
struct AttachmentEditSheet: View {
    @Environment(AppEnvironment.self) private var environment
    let attachment: SessionAttachment
    let session: ClassroomSession
    let onChanged: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var caption = ""
    @State private var kind: AttachmentKind = .other
    @State private var anchorEntryID: UUID?
    @State private var ocrText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("标题与说明") {
                    TextField("标题", text: $title)
                    TextField("说明（自己的备注）", text: $caption, axis: .vertical)
                        .lineLimit(1...3)
                }
                Section("分类") {
                    Picker("分类", selection: $kind) {
                        ForEach(AttachmentKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                }
                Section("锚定段落") {
                    Picker("锚定到", selection: $anchorEntryID) {
                        Text("不锚定").tag(UUID?.none)
                        ForEach(anchorCandidates, id: \.id) { entry in
                            Text("\(TranscriptExporter.mmss(entry.startOffset)) · \(entry.originalText)")
                                .lineLimit(1)
                                .tag(UUID?.some(entry.id))
                        }
                    }
                }
                if !attachment.ocrText.isEmpty || !ocrText.isEmpty {
                    Section("本地文字识别（可修改）") {
                        TextEditor(text: $ocrText)
                            .font(.footnote)
                            .frame(minHeight: 80)
                    }
                }
            }
            .navigationTitle("编辑图片信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
            .onAppear {
                title = attachment.title
                caption = attachment.caption
                kind = attachment.kind
                anchorEntryID = attachment.anchorEntryID
                ocrText = attachment.ocrText
            }
        }
    }

    /// Entries near the capture point — anchoring candidates.
    private var anchorCandidates: [TranscriptEntry] {
        let entries = (try? environment.repository.entries(for: session)) ?? []
        let center = max(0, attachment.capturedAt.timeIntervalSince(session.startTime))
        let near = entries.filter { abs($0.startOffset - center) <= 300 }
        return near.isEmpty ? Array(entries.suffix(20)) : Array(near.suffix(20))
    }

    private func save() {
        try? environment.repository.updateAttachmentTitle(attachment, title: title)
        try? environment.repository.updateAttachmentCaption(attachment, caption: caption)
        if attachment.kind != kind {
            try? environment.repository.updateAttachmentKind(attachment, kind: kind)
        }
        if attachment.anchorEntryID != anchorEntryID {
            try? environment.repository.updateAttachmentAnchor(
                attachment, anchorEntryID: anchorEntryID
            )
        }
        if attachment.ocrText != ocrText {
            try? environment.repository.updateAttachmentOCRText(attachment, text: ocrText)
        }
        dismiss()
        onChanged()
    }
}

// MARK: - Crop sheet

/// Interactive normalized-crop editor over the preview image. Produces a
/// new AttachmentTransform (rotation preserved); the original bytes are
/// never touched.
struct AttachmentCropSheet: View {
    let attachment: SessionAttachment
    let onApply: (AttachmentTransform) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var cropRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var dragStart: CGRect?
    @State private var imageSize: CGSize = CGSize(width: 1, height: 1)

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let display = fittedSize(in: proxy.size)
                ZStack {
                    AttachmentPreviewImage(
                        attachmentID: attachment.id,
                        sessionID: attachment.sessionID,
                        transformJSON: rotationOnlyJSON,
                        contentMode: .fit
                    )
                    .frame(width: display.width, height: display.height)
                    .position(
                        x: proxy.size.width / 2,
                        y: proxy.size.height / 2
                    )
                    .background(GeometryReader { inner in
                        Color.clear.onAppear { imageSize = inner.size }
                    })

                    // Dimmed-out area + visible crop window.
                    CropOverlay(rect: cropRect, in: display)
                        .strokeBorder(LTColors.accentGreen, lineWidth: 1.5)
                        .gesture(cropDrag(in: display))
                }
            }
            .padding(LTSpacing.screenPadding)
            .navigationTitle("裁切")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") {
                        var next = attachment.transform
                        next.cropX = cropRect.minX
                        next.cropY = cropRect.minY
                        next.cropWidth = cropRect.width
                        next.cropHeight = cropRect.height
                        onApply(next)
                        dismiss()
                    }
                }
            }
            .onAppear {
                let t = attachment.transform
                cropRect = CGRect(
                    x: t.cropX, y: t.cropY, width: t.cropWidth, height: t.cropHeight
                )
            }
        }
    }

    /// Rotation-only transform for the underlying image (the crop rect is
    /// edited in the ROTATED space, matching the stored transform).
    private var rotationOnlyJSON: String {
        var t = attachment.transform
        t.cropX = 0; t.cropY = 0; t.cropWidth = 1; t.cropHeight = 1
        return t.encodedJSON() ?? ""
    }

    private func fittedSize(in container: CGSize) -> CGSize {
        let aspect = CGFloat(max(attachment.pixelWidth, 1)) / CGFloat(max(attachment.pixelHeight, 1))
        // Rotation swaps the aspect.
        let effective = attachment.transform.quarterTurns % 2 == 1 ? 1 / aspect : aspect
        var width = container.width
        var height = width / effective
        if height > container.height {
            height = container.height
            width = height * effective
        }
        return CGSize(width: width, height: height)
    }

    /// One-finger drag: move the crop window (the canonical simple crop).
    private func cropDrag(in display: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStart == nil { dragStart = cropRect }
                guard let start = dragStart else { return }
                let dx = value.translation.width / max(display.width, 1)
                let dy = value.translation.height / max(display.height, 1)
                var next = start
                next.origin.x = min(max(0, start.minX + dx), 1 - start.width)
                next.origin.y = min(max(0, start.minY + dy), 1 - start.height)
                cropRect = next
            }
            .onEnded { _ in dragStart = nil }
    }
}

/// Overlay dimming everything outside the crop window.
struct CropOverlay: View {
    let rect: CGRect
    let in size: CGSize

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .reverseMask {
                    Rectangle()
                        .path(in: CGRect(
                            x: rect.minX * size.width,
                            y: rect.minY * size.height,
                            width: rect.width * size.width,
                            height: rect.height * size.height
                        ))
                        .fill(style: FillStyle(eoFill: true))
                }
        }
        .allowsHitTesting(false)
    }
}

private extension View {
    /// Cuts `mask` out of the receiver (the inverse of .mask).
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask {
            Rectangle()
                .overlay(alignment: .center) {
                    mask().blendMode(.destinationOut)
                }
                .compositingGroup()
        }
    }
}
