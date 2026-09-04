import SwiftUI
import UIKit
import PDFKit

/// The visual-ask composer (询问图片): gathers evidence images (with an
/// optional normalized region selection), the question, quick templates
/// and the context toggles, shows exactly what will be sent, then hands
/// the turn to the SAME assistant thread system — the sheet swaps to the
/// thread's chat view, so follow-ups continue in place (never a second
/// chat app).
struct VisualAskSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let scope: CourseAssistantService.Scope
    let courseID: UUID?
    var initialEvidence: [VisualEvidence] = []
    var initialQuestion: String = ""
    /// A short label naming where the ask came from (thread title seed).
    var contextTitle: String = "图片提问"

    @State private var evidence: [VisualEvidence] = []
    @State private var question = ""
    @State private var options = CourseAssistantService.VisualAskOptions.all
    @State private var sentThread: CourseAssistantThread?
    @State private var showPicker = false
    @State private var regionSelecting = false
    @State private var regionRect = NormalizedRect.full
    @State private var editorImage: UIImage?
    @State private var showPrivacyNotice = false
    @State private var loaded = false

    /// One-time 发送范围 confirmation (not a per-ask blocker).
    @AppStorage("visualAsk.privacyNoticeShown.v1") private var privacyNoticeShown = false

    private var imageEvidence: [VisualEvidence] {
        evidence.filter { $0.kind.isImageKind }
    }

    var body: some View {
        Group {
            if let thread = sentThread {
                NavigationStack {
                    AssistantChatView(
                        thread: thread,
                        fixedScope: scope,
                        initialQuestion: question,
                        initialEvidence: evidence,
                        initialOptions: options
                    )
                }
                .environment(environment)
            } else {
                composer
            }
        }
        .presentationDetents([.large])
        .task {
            guard !loaded else { return }
            loaded = true
            evidence = initialEvidence
            question = initialQuestion
            options = initialOptions(for: scope)
        }
    }

    // MARK: - Composer

    private var composer: some View {
        NavigationStack {
            LTPage {
                ScrollView {
                    VStack(alignment: .leading, spacing: LTSpacing.l) {
                        if regionSelecting, let editorImage {
                            regionEditor(editorImage)
                        } else {
                            evidenceCard
                            questionCard
                            contextCard
                            sendSummary
                        }
                    }
                    .padding(.horizontal, LTSpacing.screenPadding)
                    .padding(.bottom, LTSpacing.tabBarReserve)
                }
            }
            .navigationTitle("询问图片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("提问") { send() }
                    .font(LTTypography.button.bold())
                    .disabled(!canSend)
                }
            }
            .sheet(isPresented: $showPicker) {
                VisualEvidencePickerSheet(
                    courseID: courseID,
                    focusSessionID: scope.sessionIDValue,
                    focusMaterialID: scope.materialIDValue,
                    existing: imageEvidence
                ) { picked in
                    evidence = picked
                    if picked.count > 1 { clearRegion() }
                }
                .environment(environment)
            }
            .alert("发送范围确认", isPresented: $showPrivacyNotice) {
                Button("取消", role: .cancel) {}
                Button("发送") {
                    privacyNoticeShown = true
                    performSend()
                }
            } message: {
                Text(sendSummaryText)
            }
        }
    }

    // MARK: - Evidence card

    private var evidenceCard: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            HStack {
                Label("图片", systemImage: "photo.stack")
                    .font(LTTypography.cardTitle)
                    .foregroundStyle(LTColors.textPrimary)
                Spacer()
                Button {
                    showPicker = true
                } label: {
                    Label("添加", systemImage: "plus")
                        .font(LTTypography.button)
                }
                .disabled(imageEvidence.count >= VisualAskImagePipeline.maxEvidenceCount)
            }

            if imageEvidence.isEmpty {
                Text("还没有选择图片。可以添加课堂图片、资料图片或 PDF 页面。")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textTertiary)
            } else {
                VStack(alignment: .leading, spacing: LTSpacing.xs) {
                    ForEach(Array(imageEvidence.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: LTSpacing.xs) {
                            VisualEvidenceChip(evidence: item, order: index, compact: true)
                            Spacer(minLength: 0)
                            // Reorder (up/down) — the order is the 图片 n
                            // numbering the answer references.
                            VStack(spacing: 2) {
                                Button {
                                    moveEvidence(at: index, delta: -1)
                                } label: {
                                    Image(systemName: "chevron.up")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .disabled(index == 0)
                                Button {
                                    moveEvidence(at: index, delta: 1)
                                } label: {
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .disabled(index == imageEvidence.count - 1)
                            }
                            .foregroundStyle(LTColors.textSecondary)
                            Button {
                                removeEvidence(at: index)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 15))
                                    .foregroundStyle(LTColors.textTertiary)
                            }
                            .accessibilityLabel(Text("移除 \(item.title)"))
                        }
                    }
                }

                if imageEvidence.count == 1 {
                    regionControls(for: imageEvidence[0])
                }
            }
        }
        .ltCard()
    }

    /// Region selection for a single image: browse (zoom) ⇆ select
    /// (draw/adjust). The rect is normalized in the upright image space.
    @ViewBuilder
    private func regionControls(for item: VisualEvidence) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.xs) {
            if let cropRect = item.cropRect, !cropRect.isFull {
                HStack(spacing: LTSpacing.s) {
                    Label("已圈选区域（只询问选中部分）", systemImage: "crop")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.accentGreen)
                    Spacer()
                    Button("清除") { clearRegion() }
                        .font(LTTypography.button)
                }
            }
            Button {
                beginRegionSelect()
            } label: {
                Label(
                    item.cropRect.map { !$0.isFull } == true ? "重新圈选" : "圈选区域",
                    systemImage: "crop"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(LTSecondaryButtonStyle())
        }
    }

    private func regionEditor(_ image: UIImage) -> some View {
        VStack(spacing: LTSpacing.s) {
            Text("拖动画出矩形区域，可拖动四角调整；未选满整张图时只询问选中区域。")
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.textTertiary)
            NormalizedRectEditor(
                uiImage: image,
                rect: $regionRect,
                isSelecting: true
            )
            .frame(maxHeight: 420)
            .background(LTColors.surfacePrimary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: LTRadius.small))

            HStack(spacing: LTSpacing.m) {
                Button {
                    regionSelecting = false
                } label: {
                    Text("取消选择")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(LTSecondaryButtonStyle())
                Button {
                    applyRegion()
                } label: {
                    Text("使用选中区域")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(LTPrimaryButtonStyle())
                .disabled(regionRect.width < 0.05 || regionRect.height < 0.05)
            }
        }
        .ltCard()
    }

    // MARK: - Question card

    private var questionCard: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            Label("问题", systemImage: "text.bubble")
                .font(LTTypography.cardTitle)
                .foregroundStyle(LTColors.textPrimary)
            TextField("问点什么…（如：这个公式是什么意思）", text: $question, axis: .vertical)
                .font(Font.subheadline)
                .lineLimit(1...4)
                .padding(LTSpacing.s)
                .background(LTColors.surfacePrimary.opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: LTRadius.small))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: LTSpacing.xs) {
                    ForEach(quickPrompts, id: \.self) { prompt in
                        Button(prompt) {
                            question = prompt
                        }
                        .font(LTTypography.button)
                        .padding(.horizontal, LTSpacing.m)
                        .padding(.vertical, LTSpacing.xxs)
                        .background(LTColors.accentGreen.opacity(0.12))
                        .clipShape(Capsule())
                    }
                }
            }
        }
        .ltCard()
    }

    /// Real quick-question templates — they prefill the input, nothing
    /// more (no canned answers).
    private var quickPrompts: [String] {
        if imageEvidence.count > 1 {
            return [
                "比较这几张图片的异同",
                "综合解释这几页的内容",
                "找出它们之间的推导关系",
                "把它们按讲课顺序整理成笔记",
            ]
        }
        return [
            "解释这部分内容",
            "翻译图片中的文字",
            "识别并解释公式",
            "分析这个图表",
            "总结这页笔记的要点",
            "结合老师讲解说明这一步",
            "检查我的解题步骤",
        ]
    }

    // MARK: - Context card

    private var contextCard: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            Label("回答时结合", systemImage: "books.vertical")
                .font(LTTypography.cardTitle)
                .foregroundStyle(LTColors.textPrimary)
            contextToggle("当前课堂讲解（转录）", value: $options.includeTranscript)
            contextToggle("本堂课笔记", value: $options.includeNotes)
            contextToggle("课程资料检索", value: $options.includeRetrieval)
            Text("不勾选时只按图片本身回答；发送前可以在下方看到本次发送范围。")
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.textTertiary)
        }
        .ltCard()
    }

    private func contextToggle(_ title: String, value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            Text(title)
                .font(Font.subheadline)
                .foregroundStyle(LTColors.textPrimary)
        }
        .toggleStyle(.switch)
    }

    // MARK: - Send

    private var sendSummary: some View {
        VStack(alignment: .leading, spacing: LTSpacing.xxs) {
            Text(sendSummaryText)
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.textSecondary)
            if !environment.isImageModelConfigured {
                Label(
                    "图片理解模型未配置——设置里的「图片理解」模型用于图片问答，历史问答和 OCR 不受影响。",
                    systemImage: "exclamationmark.triangle"
                )
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.warning)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sendSummaryText: String {
        var parts: [String] = ["将发送 \(max(imageEvidence.count, 0)) 张图片"]
        if options.includeTranscript { parts.append("课堂讲解") }
        if options.includeNotes { parts.append("课堂笔记") }
        if options.includeRetrieval { parts.append("资料检索") }
        return parts.joined(separator: " + ") + "；图片会发送到你在设置中配置的模型服务。"
    }

    private var canSend: Bool {
        environment.isImageModelConfigured
            && !imageEvidence.isEmpty
            && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend else { return }
        if !privacyNoticeShown {
            showPrivacyNotice = true
            return
        }
        performSend()
    }

    private func performSend() {
        let title = threadTitle()
        guard let thread = try? environment.repository.addAssistantThread(
            courseID: courseID, title: title
        ) else { return }
        sentThread = thread
    }

    /// The new thread's title: the question (short) or the context label.
    private func threadTitle() -> String {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 16 { return trimmed.isEmpty ? contextTitle : trimmed }
        return String(trimmed.prefix(16)) + "…"
    }

    // MARK: - Evidence management

    private func moveEvidence(at index: Int, delta: Int) {
        let target = index + delta
        guard imageEvidence.indices.contains(index),
              imageEvidence.indices.contains(target) else { return }
        // Keep text-context evidence pinned at the end; reorder the image
        // list (the 图片 n numbering).
        var images = evidence.filter { $0.kind.isImageKind }
        let moved = images.remove(at: index)
        images.insert(moved, at: target)
        let texts = evidence.filter { !$0.kind.isImageKind }
        evidence = images + texts
    }

    private func removeEvidence(at index: Int) {
        guard imageEvidence.indices.contains(index) else { return }
        let target = imageEvidence[index]
        evidence.removeAll { $0.id == target.id }
        if evidence.filter { $0.kind.isImageKind }.count != 1 { clearRegion() }
    }

    private func clearRegion() {
        for index in evidence.indices {
            evidence[index].cropRect = nil
        }
        regionRect = .full
    }

    private func beginRegionSelect() {
        regionRect = imageEvidence.first?.cropRect ?? .full
        loadEditorImage()
        regionSelecting = true
    }

    private func applyRegion() {
        let clamped = regionRect.clamped()
        guard imageEvidence.indices.contains(0) else { return }
        if let index = evidence.firstIndex(where: { $0.id == imageEvidence[0].id }) {
            evidence[index].cropRect = clamped.isFull ? nil : clamped
        }
        regionSelecting = false
    }

    /// Loads the upright image for the region editor (EXIF + transform
    /// applied — the same geometry the pipeline sends).
    private func loadEditorImage() {
        guard let item = imageEvidence.first else { return }
        guard let source = VisualAskEvidenceLoader.imageSource(
            for: item, repository: environment.repository
        ) else {
            editorImage = nil
            return
        }
        Task {
            let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                switch source.source {
                case .imageData(let data):
                    guard let base = UIImage(data: data) else { return nil }
                    return AttachmentRender.applyTransform(base, transform: source.transform)
                case .pdfPage(let url, let pageNumber):
                    guard let document = PDFDocument(url: url),
                          pageNumber >= 1, pageNumber <= document.pageCount,
                          let page = document.page(at: pageNumber - 1) else { return nil }
                    let box = page.bounds(for: .mediaBox)
                    let scale = min(1_600 / max(box.width, box.height), 4)
                    return page.thumbnail(
                        of: CGSize(width: box.width * scale, height: box.height * scale),
                        for: .mediaBox
                    )
                }
            }.value
            editorImage = image
        }
    }

    /// Session-scoped asks default to transcript+notes+retrieval; page
    /// scope to retrieval; pure image asks to images only when the
    /// caller passed `.imagesOnly`-style options (initialQuestion flows).
    private func initialOptions(for scope: CourseAssistantService.Scope) -> CourseAssistantService.VisualAskOptions {
        var options = CourseAssistantService.VisualAskOptions.all
        if case .page = scope {
            options.includeTranscript = false
            options.includeNotes = false
        }
        return options
    }
}

// MARK: - Scope helpers

extension CourseAssistantService.Scope {
    var sessionIDValue: UUID? {
        if case .session(let id) = self { return id }
        return nil
    }

    var materialIDValue: UUID? {
        if case .material(let id) = self { return id }
        if case .page(let id, _) = self { return id }
        return nil
    }
}
