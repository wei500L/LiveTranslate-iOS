import SwiftUI
import PDFKit
import PhotosUI

/// 随身翻译的文件上下文面板：导入入口（相机/扫描/相册/文件/收件箱）、
/// 已加载文档的真实状态、页面选择、原文/OCR 文本切换、重新提取/删除/
/// 仅本机保留设置，以及"解释文件 / 字段助手 / 按文件提问"入口。
///
/// 互斥：收音中不启动相机或扫描（先结束当前句或停止收音 —— 按钮禁用
/// 并说明原因）；打开相机/扫描前停止 TTS。查看文件与文本不受麦克风
/// 权限影响。
struct InterpreterDocumentPanel: View {
    @Environment(AppEnvironment.self) private var environment
    let viewModel: InterpreterViewModel
    @Binding var isPresented: Bool
    /// 从问题输入进入时预填的问题（按文件提问流）。
    var pendingQuestion: String = ""

    @State private var showCamera = false
    @State private var showScanner = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var showFileImporter = false
    @State private var showInboxPicker = false
    @State private var showSendPreview = false
    @State private var analysisQuestion = ""

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var documentModel: InterpreterDocumentContextModel? {
        viewModel.documentContext
    }

    private var conversationID: UUID? {
        viewModel.conversation?.id
    }

    var body: some View {
        NavigationStack {
            LTPage {
                ScrollView {
                    VStack(spacing: LTSpacing.s) {
                        importSection
                        if let documentModel {
                            documentsList(documentModel)
                        }
                        if let error = documentModel?.lastImportError {
                            errorRow(error)
                        }
                        privacyFootnote
                    }
                    .padding(.horizontal, LTSpacing.screenPadding)
                    .padding(.vertical, LTSpacing.s)
                }
            }
            .navigationTitle("文件上下文")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { isPresented = false }
                }
            }
            .sheet(isPresented: $showCamera) {
                CameraCaptureSheet { image in
                    showCamera = false
                    if let image, let data = image.jpegData(compressionQuality: 0.9),
                       let conversationID {
                        let model = documentModel
                        Task { await model?.importCapturedImage(data, conversationID: conversationID) }
                    }
                }
            }
            .sheet(isPresented: $showScanner) {
                DocumentScannerSheet { pages in
                    showScanner = false
                    guard let pages, let conversationID else { return }
                    let model = documentModel
                    Task { await model?.importScannedPages(pages, conversationID: conversationID) }
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first,
                      let conversationID else { return }
                let model = documentModel
                Task { await model?.importFileURL(url, conversationID: conversationID) }
            }
            .sheet(isPresented: $showInboxPicker) {
                InterpreterInboxDocumentPicker { item in
                    showInboxPicker = false
                    guard let item, let conversationID,
                          let payloadURL = environment.inbox.payloadURL(for: item) else { return }
                    let model = documentModel
                    Task {
                        await model?.importInboxItem(
                            payloadURL: payloadURL,
                            fileName: item.title.isEmpty ? "收件箱文件" : item.title,
                            conversationID: conversationID
                        )
                    }
                }
                .environment(environment)
            }
            .onChange(of: photoSelection) { _, items in
                guard !items.isEmpty else { return }
                let picked = items
                photoSelection = []
                Task {
                    var datas: [Data] = []
                    for item in picked {
                        if let data = try? await item.loadTransferable(type: Data.self) {
                            datas.append(data)
                        }
                    }
                    if let conversationID, !datas.isEmpty {
                        await documentModel?.importPickedPhotos(datas, conversationID: conversationID)
                    }
                }
            }
            .sheet(isPresented: $showSendPreview) {
                if let documentModel {
                    InterpreterSendPreviewSheet(
                        viewModel: viewModel,
                        documentModel: documentModel,
                        question: analysisQuestion
                    )
                }
            }
        }
        .onAppear {
            documentModel?.reload(conversationID: conversationID)
        }
    }

    // MARK: - Import section

    private var importSection: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            Label("添加现场文件", systemImage: "plus.viewfinder")
                .font(LTTypography.cardTitle)
                .foregroundStyle(LTColors.textPrimary)
            Text("拍摄或扫描工作人员递来的表格、通知、回执；文字在本机提取，发送给 AI 前需要你确认。")
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.textSecondary)

            let listening = viewModel.listeningPhase == .listening
                || viewModel.listeningPhase == .transcribing
            let canCapture = documentModel?.canStartCapture(isListening: listening) ?? true

            HStack(spacing: LTSpacing.s) {
                importButton(symbol: "camera.fill", title: "拍摄") {
                    // 互斥：打开相机前停止 TTS；收音中先不启动。
                    viewModel.stopSpeaking()
                    showCamera = true
                }
                .disabled(!canCapture)
                importButton(symbol: "doc.viewfinder", title: "扫描多页") {
                    viewModel.stopSpeaking()
                    showScanner = true
                }
                .disabled(!canCapture)
            }
            HStack(spacing: LTSpacing.s) {
                PhotosPicker(selection: $photoSelection, maxSelectionCount: 5, matching: .images) {
                    importButtonLabel(symbol: "photo.on.rectangle.angled", title: "相册")
                }
                .buttonStyle(.plain)
                importButton(symbol: "folder", title: "文件") {
                    showFileImporter = true
                }
                importButton(symbol: "tray.and.arrow.down", title: "收件箱") {
                    showInboxPicker = true
                }
            }
            if !canCapture {
                Text("正在收音——请先结束这句或停止收音，再使用相机/扫描")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.warning)
            }
            if documentModel?.isImporting == true {
                HStack(spacing: LTSpacing.xs) {
                    ProgressView().controlSize(.small)
                    Text("正在导入…")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textSecondary)
                }
            }
        }
        .ltCard()
    }

    private func importButton(
        symbol: String, title: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            importButtonLabel(symbol: symbol, title: title)
        }
        .buttonStyle(.plain)
    }

    private func importButtonLabel(symbol: String, title: String) -> some View {
        VStack(spacing: LTSpacing.xxs) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(LTColors.accentCyan)
            Text(title)
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, LTSpacing.s)
        .background(
            RoundedRectangle(cornerRadius: LTRadius.medium)
                .fill(LTColors.surfaceElevated.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: LTRadius.medium)
                .strokeBorder(LTColors.border, lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: LTRadius.medium))
    }

    // MARK: - Documents list

    @ViewBuilder
    private func documentsList(_ model: InterpreterDocumentContextModel) -> some View {
        if model.documents.isEmpty {
            LTEmptyState(
                symbol: "doc.text.magnifyingglass",
                title: "还没有文件上下文",
                message: "添加文件后，可以在提问时引用其中的内容。"
            )
        } else {
            ForEach(model.documents, id: \.id) { document in
                InterpreterDocumentCard(
                    viewModel: viewModel,
                    documentModel: model,
                    document: document
                )
            }
            aiActions(model)
        }
    }

    private func aiActions(_ model: InterpreterDocumentContextModel) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            Label("用这些文件做什么", systemImage: "sparkles")
                .font(LTTypography.cardTitle)
                .foregroundStyle(LTColors.textPrimary)

            TextField("想问什么（例如：这份文件要我做什么？）", text: $analysisQuestion, axis: .vertical)
                .lineLimit(1...3)
                .font(LTTypography.body)
                .padding(LTSpacing.s)
                .background(
                    RoundedRectangle(cornerRadius: LTRadius.medium)
                        .fill(LTColors.surfaceElevated.opacity(0.6))
                )

            HStack(spacing: LTSpacing.s) {
                actionButton("解释文件") {
                    analysisQuestion = ""
                    if model.buildPreview(question: "", action: .analyze) {
                        showSendPreview = true
                    }
                }
                actionButton("按文件提问") {
                    if model.buildPreview(question: analysisQuestion, action: .ask) {
                        showSendPreview = true
                    }
                }
            }
            if model.lastAIError != nil {
                Text(model.lastAIError ?? "")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.warning)
            }
            if model.readyDocumentCount == 0 {
                Text("先等文件完成文字提取（或对扫描页运行识别）才能提问")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textTertiary)
            }
        }
        .ltCard()
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(LTTypography.button)
                .foregroundStyle(Color.black.opacity(0.85))
                .frame(maxWidth: .infinity)
                .padding(.vertical, LTSpacing.s)
                .background(
                    Capsule().fill(LTColors.accentCyan.opacity(0.9))
                )
        }
        .buttonStyle(LTPrimaryButtonStyle(tint: LTColors.accentCyan))
    }

    private func errorRow(_ message: String) -> some View {
        HStack(spacing: LTSpacing.xs) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(LTColors.warning)
            Text(message)
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.warning)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, LTSpacing.screenPadding)
    }

    private var privacyFootnote: some View {
        Text("原始文件、完整识别文本和页面缩略图只保存在这台设备上，不会同步到云端；仅你确认发送的文字会用于提问。")
            .font(LTTypography.caption)
            .foregroundStyle(LTColors.textTertiary)
            .padding(.horizontal, LTSpacing.screenPadding)
            .padding(.bottom, LTSpacing.s)
    }
}

// MARK: - Document card

/// One loaded document's row: real status, per-page progress, page
/// selection, original/OCR text toggle, actions.
struct InterpreterDocumentCard: View {
    let viewModel: InterpreterViewModel
    let documentModel: InterpreterDocumentContextModel
    let document: InterpreterDocument

    @State private var isExpanded = false
    @State private var showText = false
    @State private var extraction: InterpreterDocumentExtraction?

    private var progress: InterpreterDocumentService.Progress? {
        documentModel.extractionProgress(for: document.id)
    }

    private var statusIcon: String {
        switch document.status {
        case .importing: return "arrow.down.circle"
        case .imported: return "checkmark.circle"
        case .extracting: return "arrow.2.circlepath.circle"
        case .ready: return "checkmark.seal"
        case .partiallyExtracted: return "exclamationmark.arrow.triangle.2.circlepath"
        case .failed: return "xmark.octagon"
        }
    }

    private var statusColor: Color {
        switch document.status {
        case .failed: return LTColors.warning
        case .partiallyExtracted: return LTColors.warning
        default: return LTColors.accentGreen
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            header
            if let progress {
                progressRow(progress)
            }
            if !document.errorSummary.isEmpty {
                Text(document.errorSummary)
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.warning)
                    .multilineTextAlignment(.leading)
            }
            if isExpanded {
                expandedContent
            }
            actionRow
        }
        .ltCard(padding: LTSpacing.m)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(reduceMotion ? nil : LTMotion.quick) {
                isExpanded.toggle()
            }
            if isExpanded {
                extraction = documentModel.extraction(for: document)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "文件 \(document.originalFileName)，\(document.status.displayName)，\(document.pageCount) 页"
        )
    }

    private var header: some View {
        HStack(spacing: LTSpacing.s) {
            Image(systemName: document.format == .pdf ? "doc.richtext" : "doc.text")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(LTColors.accentCyan)
            VStack(alignment: .leading, spacing: 2) {
                Text(document.originalFileName)
                    .font(LTTypography.body)
                    .foregroundStyle(LTColors.textPrimary)
                    .lineLimit(2)
                HStack(spacing: LTSpacing.xs) {
                    Text("\(document.format.displayName) · \(document.pageCount) 页 · \(ByteCountFormatter.string(fromByteCount: document.fileSize, countStyle: .file))")
                    Text("·")
                    Label(document.status.displayName, systemImage: statusIcon)
                        .foregroundStyle(statusColor)
                }
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.textSecondary)
            }
            Spacer()
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.caption2)
                .foregroundStyle(LTColors.textTertiary)
        }
    }

    private func progressRow(_ progress: InterpreterDocumentService.Progress) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.xxs) {
            Text(progress.label)
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.textSecondary)
            if progress.total > 0 {
                ProgressView(value: Double(progress.done), total: Double(progress.total))
            }
            Button("取消") {
                documentModel.cancelExtraction(document)
            }
            .font(LTTypography.caption)
            .foregroundStyle(LTColors.textSecondary)
        }
    }

    @ViewBuilder
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            Divider().overlay(LTColors.separator)

            // 页面选择（默认全选；大文档引导用户选择范围）。
            if let extraction, document.pageCount > 1 {
                pageSelection(extraction)
            }

            // 部分提取：成功页/失败页（不只靠颜色区分 —— 文字标签）。
            let failedPages = documentModel.failedPages(for: document)
            let lowConfidence = documentModel.lowConfidencePages(for: document)
            if !failedPages.isEmpty {
                Label(
                    "第 \(failedPages.map(String.init).joined(separator: "、")) 页识别失败，可单独重试",
                    systemImage: "exclamationmark.triangle"
                )
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.warning)
            }
            if !lowConfidence.isEmpty {
                Label(
                    "第 \(lowConfidence.map(String.init).joined(separator: "、")) 页识别置信度较低，请人工核对",
                    systemImage: "eye.trianglebadge.exclamationmark"
                )
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.warning)
            }

            // 原文/识别文本切换。
            if let extraction {
                textToggle(extraction)
            }

            // 字段助手。
            if let fields = extractionFields, !fields.isEmpty {
                fieldAssistant(fields)
            }
        }
    }

    private func pageSelection(_ extraction: InterpreterDocumentExtraction) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.xs) {
            Text("选择要用于提问的页面")
                .font(LTTypography.statusChip)
                .foregroundStyle(LTColors.textTertiary)
            let selected = documentModel.selectedPages[document.id] ?? Set(extraction.pages.map(\.pageNumber))
            FlowLayoutishRows(items: extraction.pages.map(\.pageNumber)) { page in
                Button {
                    var current = documentModel.selectedPages[document.id] ?? Set(extraction.pages.map(\.pageNumber))
                    if current.contains(page) {
                        current.remove(page)
                    } else {
                        current.insert(page)
                    }
                    documentModel.selectedPages[document.id] = current
                } label: {
                    Text("第\(page)页")
                        .font(LTTypography.caption)
                        .foregroundStyle(selected.contains(page) ? LTColors.accentCyan : LTColors.textTertiary)
                        .padding(.horizontal, LTSpacing.s)
                        .padding(.vertical, LTSpacing.xs + 2)
                        .background(
                            Capsule().fill(
                                selected.contains(page)
                                    ? LTColors.accentCyan.opacity(0.14)
                                    : LTColors.surfaceElevated.opacity(0.5)
                            )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("第\(page)页\(selected.contains(page) ? "，已选中" : "，未选中")")
            }
            if document.pageCount > InterpreterDocumentService.largeDocumentPageThreshold {
                Text("这份文件页数较多——默认全部选中会占用更多提问额度，建议只选需要的页")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textTertiary)
            }
        }
    }

    private func textToggle(_ extraction: InterpreterDocumentExtraction) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.xs) {
            Picker("显示", selection: $showText) {
                Text("识别文本").tag(false)
                Text("原文/文字层").tag(true)
            }
            .pickerStyle(.segmented)
            let text: String = {
                guard let page = extraction.pages.first else { return "" }
                return showText ? page.extractedText : page.effectiveText
            }()
            ScrollView {
                Text(text.isEmpty ? "（无内容——扫描页可运行识别）" : text)
                    .font(LTTypography.body)
                    .foregroundStyle(LTColors.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
        }
    }

    private var extractionFields: [InterpreterFormField]? {
        // 字段列表来自最近一次文件分析结果（存储于 turn details 的
        // suggestedReplies/keywords 之外——本轮字段助手从分析 JSON
        // 载入）。简化：字段助手入口由解释文件流程写入。
        nil
    }

    @ViewBuilder
    private func fieldAssistant(_ fields: [InterpreterFormField]) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            Text("字段助手")
                .font(LTTypography.statusChip)
                .foregroundStyle(LTColors.textTertiary)
            ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                InterpreterFieldAssistantRow(
                    field: field,
                    onSubmit: { value in
                        Task {
                            await viewModel.submitFieldCheck(field: field, value: value)
                        }
                    }
                )
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: LTSpacing.l) {
            if document.status == .imported || document.status == .failed {
                Button {
                    documentModel.retryExtraction(document)
                } label: {
                    Label("提取文字", systemImage: "text.viewfinder")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.accentBlue)
                }
                .buttonStyle(.plain)
            }
            if let extraction = extraction, extraction.pages.contains(where: {
                $0.ocrStatusRaw == InterpreterPageOCRStatus.none.rawValue
                    && $0.extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) {
                Button {
                    documentModel.runOCR(document: document)
                } label: {
                    Label("识别页面文字", systemImage: "character.textbox")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.accentBlue)
                }
                .buttonStyle(.plain)
            }
            Toggle(isOn: Binding(
                get: { document.allowsModelUse },
                set: { documentModel.setAllowsModelUse(document, $0) }
            )) {
                Text("允许用于提问")
                    .font(LTTypography.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            Button(role: .destructive) {
                documentModel.deleteDocument(document, conversationID: viewModel.conversation?.id)
            } label: {
                Label("删除", systemImage: "trash")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.destructive)
            }
            .buttonStyle(.plain)
        }
    }
}

/// 简单的流式换行行（页码 chips）。
private struct FlowLayoutishRows<Item: Hashable, Content: View>: View {
    let items: [Item]
    let content: (Item) -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: LTSpacing.xs) {
            HStack(spacing: LTSpacing.s) {
                ForEach(items, id: \.self) { item in
                    content(item)
                }
            }
        }
    }
}

// MARK: - Field assistant row

/// 一个表格字段的解释与值核对（字段助手）。只展示理解与建议 ——
/// 不自动填写；用户手动输入自己的值后可让 AI 检查格式。
struct InterpreterFieldAssistantRow: View {
    let field: InterpreterFormField
    var onSubmit: (String) -> Void

    @State private var value = ""
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: LTSpacing.xs) {
            Button {
                withAnimation(LTMotion.quick) { expanded.toggle() }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(field.russianLabel)
                        .font(LTTypography.body)
                        .foregroundStyle(LTColors.textPrimary)
                    HStack(spacing: LTSpacing.s) {
                        Text(field.chineseMeaning)
                        if let type = field.expectedType, !type.isEmpty {
                            Text("· \(type)")
                        }
                        if let page = field.pageNumber {
                            Text("· 第\(page)页")
                        }
                    }
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textSecondary)
                }
            }
            .buttonStyle(.plain)

            if expanded {
                if let existing = field.existingValue, !existing.isEmpty {
                    detailLine("文件中的值", existing)
                }
                if let hint = field.preparationHint, !hint.isEmpty {
                    detailLine("需要准备", hint)
                }
                if let example = field.exampleFormat, !example.isEmpty {
                    detailLine("示例格式（不是你的真实信息）", example)
                }
                if let risk = field.riskNote, !risk.isEmpty {
                    Label(risk, systemImage: "exclamationmark.triangle")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.warning)
                }
                HStack(spacing: LTSpacing.s) {
                    TextField("输入你的值（可选）", text: $value)
                        .font(LTTypography.body)
                        .textFieldStyle(.roundedBorder)
                    Button("检查格式") {
                        onSubmit(value.trimmingCharacters(in: .whitespaces))
                    }
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.accentBlue)
                    .disabled(value.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("输入的值只用于本次格式检查，不会自动填进文件")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textTertiary)
            }
        }
        .padding(.vertical, LTSpacing.xxs)
    }

    private func detailLine(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(LTTypography.statusChip)
                .foregroundStyle(LTColors.textTertiary)
            Text(value)
                .font(LTTypography.body)
                .foregroundStyle(LTColors.textSecondary)
                .textSelection(.enabled)
        }
    }
}
