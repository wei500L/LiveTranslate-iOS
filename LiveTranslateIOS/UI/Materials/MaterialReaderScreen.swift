import SwiftUI
import PDFKit
import QuickLook
import UIKit
import Observation

/// The material reader: page-level reading for PDFs (PDFKit), plain
/// text for TXT/Markdown, the image itself for image materials, and an
/// honest save-only preview for unsupported formats (Quick Look — the
/// extension is never renamed, the content never claimed).
///
/// States are distinct and honestly labeled: 页面加载 / 文本提取 / OCR /
/// 文件下载 are never one blended 处理中. Page notes and bookmarks are
/// user-layer rows (AI output lives in the digest). Reading never
/// touches the live classroom — opening a material can coexist with a
/// running recording.
struct MaterialReaderScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = MaterialReaderViewModel()
    @State private var showDigest = false
    @State private var showNotes = false
    @State private var showAssistant = false
    @State private var showMetadataEditor = false
    @State private var showDeleteConfirm = false
    @State private var shareItem: SharedFile?
    @State private var showQuickLook = false
    @State private var showSearch = false

    let materialID: UUID

    var body: some View {
        LTPage {
            Group {
                if viewModel.isLoaded, viewModel.material == nil {
                    LTEmptyState(
                        symbol: "questionmark.folder",
                        title: "资料不存在",
                        message: "这份资料可能已被删除"
                    )
                } else if viewModel.isLoaded, let material = viewModel.material {
                    readerContent(material)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle(viewModel.material?.title.isEmpty == false
            ? viewModel.material!.title : "资料")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: LTSpacing.m) {
                    Button {
                        showSearch.toggle()
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(LTColors.textSecondary)
                    }
                    .accessibilityLabel(Text("在资料中搜索"))
                    Menu {
                        Button {
                            showMetadataEditor = true
                        } label: {
                            Label("编辑资料信息", systemImage: "square.and.pencil")
                        }
                        Button {
                            shareItem = viewModel.shareFile()
                        } label: {
                            Label("分享原文件", systemImage: "square.and.arrow.up")
                        }
                        .disabled(viewModel.shareFile() == nil)
                        if viewModel.material?.format == .other {
                            Button {
                                showQuickLook = true
                            } label: {
                                Label("预览文件", systemImage: "eye")
                            }
                            .disabled(viewModel.shareFile() == nil)
                        }
                        if viewModel.currentPageNeedsOCR {
                            Button {
                                viewModel.runOCR(environment: environment)
                            } label: {
                                Label("识别本页文字", systemImage: "text.viewfinder")
                            }
                        }
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label("删除资料", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(LTColors.textSecondary)
                    }
                    .accessibilityLabel(Text("更多操作"))
                }
            }
        }
        .task {
            viewModel.attach(environment)
            viewModel.load(materialID: materialID)
        }
        .onAppear {
            if viewModel.isLoaded {
                viewModel.reload()
            }
        }
        .sheet(isPresented: $showDigest) {
            NavigationStack {
                MaterialDigestScreen(materialID: materialID)
                    .environment(environment)
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showNotes) {
            NavigationStack {
                MaterialNotesScreen(
                    viewModel: viewModel
                )
                .environment(environment)
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showAssistant) {
            NavigationStack {
                CourseAssistantScreen(
                    courseID: viewModel.material?.courseID,
                    fixedMaterialID: materialID,
                    fixedPageNumber: viewModel.currentPage
                )
                .environment(environment)
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showMetadataEditor) {
            NavigationStack {
                MaterialMetadataEditor(viewModel: viewModel)
                    .environment(environment)
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .sheet(isPresented: $showQuickLook) {
            if let url = viewModel.shareFile() {
                QuickLookPreview(url: url)
            }
        }
        .confirmationDialog(
            "删除这份资料？", isPresented: $showDeleteConfirm, titleVisibility: .visible
        ) {
            Button("删除资料", role: .destructive) {
                viewModel.delete(environment: environment)
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将同时删除其页面文字、笔记、书签与导读，并清理本机文件。")
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func readerContent(_ material: CourseMaterial) -> some View {
        ScrollView {
            VStack(spacing: LTSpacing.l) {
                headerCard(material)
                digestCard(material)
                if showSearch {
                    searchCard(material)
                }
                pageCard(material)
                annotationsCard(material)
            }
            .padding(.horizontal, LTSpacing.screenPadding)
            .padding(.bottom, LTSpacing.tabBarReserve)
        }
    }

    private func headerCard(_ material: CourseMaterial) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.xs) {
            HStack(spacing: LTSpacing.m) {
                LTIconBadge(
                    symbol: material.format.symbol,
                    tint: material.ownsFile ? LTColors.accentBlue : LTColors.accentCyan,
                    size: 40
                )
                VStack(alignment: .leading, spacing: LTSpacing.xxs) {
                    Text(material.title)
                        .font(LTTypography.cardTitle)
                        .foregroundStyle(LTColors.textPrimary)
                    Text(headerMetaLine(material))
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textTertiary)
                }
                Spacer()
            }
            if let chip = material.extractionStatus.statusChip {
                StatusChip(text: chip.text, tint: chip.tint)
            }
            if viewModel.isExtractionRunning {
                HStack(spacing: LTSpacing.xs) {
                    ProgressView().controlSize(.small)
                    Text(viewModel.extractionProgressLabel)
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textSecondary)
                }
            }
            if viewModel.isOCRRunning {
                HStack(spacing: LTSpacing.xs) {
                    ProgressView().controlSize(.small)
                    Text(viewModel.ocrProgressLabel)
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textSecondary)
                }
            }
        }
        .ltCard()
    }

    private func headerMetaLine(_ material: CourseMaterial) -> String {
        var parts: [String] = [material.kind.displayName]
        if material.pageCount > 0 {
            parts.append(material.pageCount == 1 ? "1 页" : "\(material.pageCount) 页")
        }
        if !material.ownsFile {
            parts.append("来自课堂图片")
        }
        parts.append(Format.bytes(material.fileSize))
        return parts.joined(separator: " · ")
    }

    /// 导读 card: shows the digest when it exists (with a 重新整理 hint
    /// when the material changed), offers generation when the model is
    /// configured, and says honestly when it is not.
    @ViewBuilder
    private func digestCard(_ material: CourseMaterial) -> some View {
        Button {
            showDigest = true
        } label: {
            HStack(spacing: LTSpacing.m) {
                LTIconBadge(symbol: "sparkles", tint: LTColors.accentGreen, size: 38)
                VStack(alignment: .leading, spacing: LTSpacing.xxs) {
                    Text("资料导读")
                        .font(LTTypography.cardTitle)
                        .foregroundStyle(LTColors.textPrimary)
                    Text(digestDetailLine(material))
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textTertiary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LTColors.textTertiary)
            }
        }
        .buttonStyle(.plain)
        .ltCard()
        .accessibilityHint(Text("查看或生成资料导读"))
    }

    private func digestDetailLine(_ material: CourseMaterial) -> String {
        if viewModel.isDigestRunning {
            return viewModel.digestProgressLabel
        }
        if let digest = material.digest {
            if viewModel.isDigestStale {
                return "资料内容已更新，可重新整理"
            }
            return "已生成 · 概述、术语、公式与重点页码"
        }
        switch material.digestStatus {
        case .failed: return "上次整理失败，可重试"
        case .partial: return "整理未完成，可继续"
        default: return environment.isTranslationConfigured
            ? "生成概述、目录、术语与重点页码"
            : "需要先在设置中配置兼容模型"
        }
    }

    /// In-material search: real page-text matching (extracted + OCR);
    /// hits jump to the page (scanned pages work once OCR ran).
    private func searchCard(_ material: CourseMaterial) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            HStack(spacing: LTSpacing.s) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(LTColors.textTertiary)
                TextField("搜索这份资料", text: $viewModel.searchText)
                    .font(Font.subheadline)
                    .autocorrectionDisabled()
            }
            if viewModel.searchText.isEmpty == false {
                if viewModel.searchHits.isEmpty {
                    Text("没有匹配的页面")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textTertiary)
                } else {
                    Text("命中第 \(viewModel.searchHits.map(String.init).joined(separator: "、")) 页")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textSecondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: LTSpacing.xs) {
                            ForEach(viewModel.searchHits, id: \.self) { pageNumber in
                                Button("第 \(pageNumber) 页") {
                                    viewModel.currentPage = pageNumber
                                    viewModel.touchRead(environment: environment)
                                }
                                .font(LTTypography.button)
                                .padding(.horizontal, LTSpacing.m)
                                .padding(.vertical, LTSpacing.xxs)
                                .background(LTColors.accentGreen.opacity(0.15))
                                .clipShape(Capsule())
                            }
                        }
                    }
                }
            }
        }
        .ltCard()
    }

    /// The page content: PDF via PDFKit (page by page — never the whole
    /// document at once), text as plain scroll, image as image,
    /// unsupported formats as an honest save-only card.
    @ViewBuilder
    private func pageCard(_ material: CourseMaterial) -> some View {
        VStack(spacing: LTSpacing.s) {
            switch viewModel.fileAvailability {
            case .local:
                switch material.format {
                case .pdf:
                    if let page = viewModel.currentPageRow, !page.effectiveText.isEmpty {
                        pageTextView(page)
                    } else {
                        pdfPageView(material)
                    }
                case .text, .markdown:
                    if let page = viewModel.pages.first {
                        pageTextView(page, fullText: true)
                    }
                case .image:
                    imagePageView(material)
                case .other:
                    unsupportedCard(material)
                }
            case .downloading:
                VStack(spacing: LTSpacing.s) {
                    ProgressView()
                    Text("正在从云端下载原文件…")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, LTSpacing.xl)
            case .missing:
                VStack(spacing: LTSpacing.s) {
                    Text("原文件不在本机")
                        .font(LTTypography.cardTitle)
                        .foregroundStyle(LTColors.textPrimary)
                    Text(fileMissingMessage)
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textTertiary)
                        .multilineTextAlignment(.center)
                    if viewModel.canDownloadFromCloud {
                        Button("从云端下载") {
                            Task { await viewModel.downloadFile(environment: environment) }
                        }
                        .buttonStyle(LTSecondaryButtonStyle())
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, LTSpacing.xl)
            }
        }
        .ltCard()
    }

    /// Page text (extracted layer first; OCR shown as its own block —
    /// the two layers are never blended into one "content").
    private func pageTextView(_ page: MaterialPage, fullText: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            if !fullText {
                HStack {
                    Text("第 \(page.pageNumber) 页")
                        .font(LTTypography.cardTitle)
                        .foregroundStyle(LTColors.textPrimary)
                    Spacer()
                }
            }
            if !page.extractedText.isEmpty {
                Text(page.extractedText)
                    .font(Font.subheadline)
                    .foregroundStyle(LTColors.textSecondary)
                    .textSelection(.enabled)
                    .lineSpacing(4)
            }
            if !page.ocrText.isEmpty {
                VStack(alignment: .leading, spacing: LTSpacing.xxs) {
                    Text("识别文字（自动识别，可能有误）")
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textTertiary)
                    Text(page.ocrText)
                        .font(Font.subheadline)
                        .foregroundStyle(LTColors.textSecondary)
                        .textSelection(.enabled)
                }
            }
            if page.effectiveText.isEmpty {
                Text("本页没有可显示的文字（可能是扫描图片，可尝试识别文字）")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textTertiary)
            }
        }
    }

    /// PDFKit page rendering (single page; the whole document is never
    /// rasterized).
    private func pdfPageView(_ material: CourseMaterial) -> some View {
        VStack(spacing: LTSpacing.s) {
            if let url = viewModel.localFileURL() {
                PDFSinglePageView(url: url, pageNumber: viewModel.currentPage)
                    .frame(minHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: LTRadius.small))
            }
            HStack(spacing: LTSpacing.m) {
                Button {
                    viewModel.turnPage(-1)
                    viewModel.touchRead(environment: environment)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .medium))
                        .frame(minWidth: LTSpacing.minTouchTarget, minHeight: LTSpacing.minTouchTarget)
                }
                .disabled(viewModel.currentPage <= 1)
                .accessibilityLabel(Text("上一页"))
                Text("第 \(viewModel.currentPage) / \(max(material.pageCount, viewModel.pages.count)) 页")
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textSecondary)
                Button {
                    viewModel.turnPage(1)
                    viewModel.touchRead(environment: environment)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .medium))
                        .frame(minWidth: LTSpacing.minTouchTarget, minHeight: LTSpacing.minTouchTarget)
                }
                .disabled(viewModel.currentPage >= max(material.pageCount, viewModel.pages.count))
                .accessibilityLabel(Text("下一页"))
            }
        }
    }

    private func imagePageView(_ material: CourseMaterial) -> some View {
        VStack(spacing: LTSpacing.s) {
            if let data = viewModel.imageData() {
                if let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: LTRadius.small))
                }
            }
        }
    }

    private func unsupportedCard(_ material: CourseMaterial) -> some View {
        VStack(spacing: LTSpacing.s) {
            LTIconBadge(symbol: "doc", tint: LTColors.textTertiary, size: 44)
            Text("该格式暂不支持内容提取")
                .font(LTTypography.cardTitle)
                .foregroundStyle(LTColors.textPrimary)
            Text("文件已完整保存，可以预览或分享；读取其中的内容会在后续版本支持。")
                .font(LTTypography.caption)
                .foregroundStyle(LTColors.textTertiary)
                .multilineTextAlignment(.center)
            HStack(spacing: LTSpacing.s) {
                Button {
                    showQuickLook = true
                } label: {
                    Label("预览", systemImage: "eye")
                }
                .buttonStyle(LTSecondaryButtonStyle())
                Button {
                    shareItem = viewModel.shareFile()
                } label: {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(LTSecondaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, LTSpacing.l)
    }

    /// Current-page actions: bookmark toggle, note, ask about this page.
    private func annotationsCard(_ material: CourseMaterial) -> some View {
        VStack(spacing: LTSpacing.s) {
            HStack(spacing: LTSpacing.m) {
                Button {
                    viewModel.toggleBookmark(environment: environment)
                } label: {
                    Label(
                        viewModel.isCurrentPageBookmarked ? "已收藏本页" : "收藏本页",
                        systemImage: viewModel.isCurrentPageBookmarked
                            ? "bookmark.fill" : "bookmark"
                    )
                    .foregroundStyle(
                        viewModel.isCurrentPageBookmarked
                            ? LTColors.accentGreen
                            : LTColors.textSecondary
                    )
                }
                .buttonStyle(LTSecondaryButtonStyle())
                Button {
                    showNotes = true
                } label: {
                    Label("本页笔记", systemImage: "square.and.pencil")
                }
                .buttonStyle(LTSecondaryButtonStyle())
            }
            if environment.isTranslationConfigured {
                Button {
                    showAssistant = true
                } label: {
                    Label("就本页提问", systemImage: "bubble.left.and.text.bubble.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(LTPrimaryButtonStyle())
            }
            if !viewModel.annotations.isEmpty {
                VStack(alignment: .leading, spacing: LTSpacing.xs) {
                    ForEach(viewModel.annotations.prefix(3)) { annotation in
                        HStack(alignment: .top, spacing: LTSpacing.xs) {
                            Image(systemName: annotation.kind == .bookmark ? "bookmark.fill" : "note.text")
                                .font(.system(size: 12))
                                .foregroundStyle(LTColors.accentCyan)
                            Text("第 \(annotation.pageNumber) 页 · \(annotation.text)")
                                .font(LTTypography.caption)
                                .foregroundStyle(LTColors.textSecondary)
                                .lineLimit(2)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .ltCard()
    }

    private var fileMissingMessage: String {
        viewModel.canDownloadFromCloud
            ? "云端可能保留了这份文件，可以尝试下载。"
            : "这份文件只保存在导入它的设备上，或尚未上传到云端。"
    }
}

// MARK: - PDF single-page view

/// Renders ONE PDF page via PDFKit (bounded memory; the whole document
/// is never rasterized).
struct PDFSinglePageView: UIViewRepresentable {
    let url: URL
    let pageNumber: Int

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePage
        view.displayDirection = .horizontal
        view.backgroundColor = .clear
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        guard let document = view.document else { return }
        guard pageNumber >= 1, pageNumber <= document.pageCount,
              let page = document.page(at: pageNumber - 1) else { return }
        if view.currentPage != page {
            view.go(to: page)
        }
    }
}

// MARK: - Quick Look (unsupported formats' honest preview)

struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(
            _ controller: QLPreviewController, previewItemAt index: Int
        ) -> QLPreviewItem {
            url as NSURL
        }
    }
}
