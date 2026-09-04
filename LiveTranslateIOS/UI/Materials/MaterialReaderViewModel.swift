import SwiftUI
import Observation
import UIKit

/// Reader presentation state: the material, its pages, current page,
/// in-material search, file availability (local / downloading / missing
/// are DIFFERENT states), and the page-note/bookmark layer.
@MainActor
@Observable
final class MaterialReaderViewModel {
    enum FileAvailability: Equatable {
        case local
        case downloading
        case missing
    }

    private(set) var material: CourseMaterial?
    private(set) var pages: [MaterialPage] = []
    private(set) var annotations: [MaterialAnnotation] = []
    private(set) var isLoaded = false
    private(set) var fileAvailability: FileAvailability = .local
    var currentPage: Int = 1
    var searchText: String = ""

    private weak var environmentBox: AppEnvironment?
    private var materialID: UUID?

    func attach(_ environment: AppEnvironment) {
        environmentBox = environment
    }

    func load(materialID: UUID) {
        load(materialID: materialID, initialPage: nil)
    }

    /// `initialPage` (an evidence-chip jump target) wins over the synced
    /// reading position — the user asked about THAT page.
    func load(materialID: UUID, initialPage: Int?) {
        self.materialID = materialID
        reload()
        isLoaded = true
        // Reading continues where it left off (synced position).
        if let initialPage, initialPage >= 1,
           initialPage <= max(material?.pageCount ?? 1, 1) {
            currentPage = initialPage
        } else if let material, material.lastReadPage > 0,
           material.lastReadPage <= max(material.pageCount, 1) {
            currentPage = material.lastReadPage
        }
        touchRead()
    }

    func reload() {
        guard let environment = environmentBox, let materialID else { return }
        material = try? environment.repository.material(id: materialID)
        pages = (try? environment.repository.materialPages(materialID: materialID)) ?? []
        annotations = (try? environment.repository.materialAnnotations(materialID: materialID)) ?? []
        refreshFileAvailability()
    }

    /// Distinct honest file states — never one blended 处理中.
    private func refreshFileAvailability() {
        guard let material else { return }
        guard material.ownsFile else {
            // Borrows a classroom attachment's files: its availability is
            // the attachment's (rendered via the attachment store).
            fileAvailability = .local
            return
        }
        guard let store = MaterialFileStoreShared.store else {
            fileAvailability = .missing
            return
        }
        let ext = MaterialFileStore.fileExtension(
            fileName: material.originalFileName, mime: material.mimeType
        )
        fileAvailability = store.originalExists(materialID: material.id, fileExtension: ext)
            ? .local
            : .missing
    }

    var canDownloadFromCloud: Bool {
        guard let environment = environmentBox, let material else { return false }
        return environment.cloudSync?.isSignedIn == true
            && material.ownsFile
            && !material.contentHash.isEmpty
    }

    func downloadFile(environment: AppEnvironment) async {
        guard let material, let cloudSync = environment.cloudSync else { return }
        fileAvailability = .downloading
        let ok = await cloudSync.downloadMaterialFile(material)
        fileAvailability = ok ? .local : .missing
    }

    // MARK: - Derived state

    var currentPageRow: MaterialPage? {
        pages.first { $0.pageNumber == currentPage }
    }

    var searchHits: [Int] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return pages
            .filter { $0.searchableText.localizedCaseInsensitiveContains(trimmed) }
            .map(\.pageNumber)
    }

    var isCurrentPageBookmarked: Bool {
        annotations.contains {
            $0.kind == .bookmark && $0.pageNumber == currentPage
        }
    }

    var currentPageNeedsOCR: Bool {
        currentPageRow?.needsOCR == true
    }

    var isExtractionRunning: Bool {
        guard let material else { return false }
        return environmentBox?.materialExtractionRunner.isActive(material.id) ?? false
    }

    var extractionProgressLabel: String {
        guard let material else { return "" }
        return environmentBox?.materialExtractionRunner.progress(for: material.id)?.label
            ?? "正在读取资料内容…"
    }

    var isOCRRunning: Bool {
        guard let material else { return false }
        return environmentBox?.materialExtractionRunner.isActive(material.id) == true
            && environmentBox?.materialExtractionRunner.progress(for: material.id)?.stage == .ocr
    }

    var ocrProgressLabel: String {
        guard let material else { return "" }
        return environmentBox?.materialExtractionRunner.progress(for: material.id)?.label
            ?? "正在识别页面文字…"
    }

    var isDigestRunning: Bool {
        guard let material else { return false }
        return environmentBox?.materialDigestGenerator.isActive(material.id) ?? false
    }

    var digestProgressLabel: String {
        guard let material else { return "" }
        return environmentBox?.materialDigestGenerator.progress(for: material.id)?.label
            ?? "正在整理资料内容…"
    }

    var isDigestStale: Bool {
        guard let material else { return false }
        return environmentBox?.materialDigestGenerator.isDigestStale(material) ?? false
    }

    // MARK: - Page actions

    func turnPage(_ delta: Int) {
        guard let material else { return }
        let total = max(material.pageCount, pages.count, 1)
        currentPage = min(max(currentPage + delta, 1), total)
        touchRead()
    }

    /// Persists the reading position (syncs so it follows the user).
    func touchRead(environment: AppEnvironment? = nil) {
        guard let material else { return }
        if let environment {
            try? environment.repository.touchMaterialRead(material, page: currentPage)
        } else {
            try? environmentBox?.repository.touchMaterialRead(material, page: currentPage)
        }
    }

    func toggleBookmark(environment: AppEnvironment) {
        guard let material else { return }
        if let existing = annotations.first(where: {
            $0.kind == .bookmark && $0.pageNumber == currentPage
        }) {
            try? environment.repository.deleteMaterialAnnotation(existing)
        } else {
            _ = try? environment.repository.addMaterialAnnotation(
                MaterialAnnotationDraft(
                    materialID: material.id, pageNumber: currentPage, kind: .bookmark
                )
            )
        }
        reload()
    }

    func addNote(_ text: String, environment: AppEnvironment) {
        guard let material else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = try? environment.repository.addMaterialAnnotation(
            MaterialAnnotationDraft(
                materialID: material.id, pageNumber: currentPage,
                kind: .note, text: trimmed
            )
        )
        reload()
    }

    func deleteAnnotation(_ annotation: MaterialAnnotation, environment: AppEnvironment) {
        try? environment.repository.deleteMaterialAnnotation(annotation)
        reload()
    }

    func runOCR(environment: AppEnvironment) {
        guard let material else { return }
        environment.materialExtractionRunner.runOCR(
            material: material, pages: [currentPage]
        )
    }

    // MARK: - File plumbing (store-mediated; the view never builds paths)

    func localFileURL() -> URL? {
        guard let material, let store = MaterialFileStoreShared.store else { return nil }
        let ext = MaterialFileStore.fileExtension(
            fileName: material.originalFileName, mime: material.mimeType
        )
        guard store.originalExists(materialID: material.id, fileExtension: ext) else {
            return nil
        }
        return store.originalURL(materialID: material.id, fileExtension: ext)
    }

    func imageData() -> Data? {
        guard let material else { return nil }
        // A borrowed classroom image renders through the attachment
        // store (the same renditions everywhere — no duplicate copy).
        if let attachmentID = material.sourceAttachmentID,
           let attachment = try? environmentBox?.repository.attachment(id: attachmentID),
           let store = AttachmentFileStoreShared.store {
            return store.previewOrOriginalData(
                for: attachment.id, sessionID: attachment.sessionID
            )
        }
        guard let store = MaterialFileStoreShared.store else { return nil }
        let ext = MaterialFileStore.fileExtension(
            fileName: material.originalFileName, mime: material.mimeType
        )
        return store.originalData(materialID: material.id, fileExtension: ext)
    }

    /// The original file URL for share / Quick Look.
    func shareFile() -> URL? {
        localFileURL()
    }

    func delete(environment: AppEnvironment) {
        guard let material else { return }
        try? environment.repository.deleteMaterial(material)
    }
}

// MARK: - Page notes screen

/// The material's page notes (all pages; the current page is the
/// default add target).
struct MaterialNotesScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: MaterialReaderViewModel
    @State private var noteText = ""

    var body: some View {
        LTPage {
            ScrollView {
                VStack(spacing: LTSpacing.l) {
                    VStack(alignment: .leading, spacing: LTSpacing.s) {
                        HStack {
                            Text("记在第 \(viewModel.currentPage) 页")
                                .font(LTTypography.cardTitle)
                                .foregroundStyle(LTColors.textPrimary)
                            Spacer()
                        }
                        TextField("写点什么…", text: $noteText, axis: .vertical)
                            .font(Font.subheadline)
                            .lineLimit(2...5)
                            .padding(LTSpacing.s)
                            .background(LTColors.surfacePrimary.opacity(0.7))
                            .clipShape(RoundedRectangle(cornerRadius: LTRadius.small))
                        Button {
                            viewModel.addNote(noteText, environment: environment)
                            noteText = ""
                        } label: {
                            Label("保存笔记", systemImage: "plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(LTPrimaryButtonStyle())
                        .disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .ltCard()

                    if viewModel.annotations.isEmpty {
                        Text("还没有笔记或书签")
                            .font(LTTypography.caption)
                            .foregroundStyle(LTColors.textTertiary)
                    } else {
                        LazyVStack(spacing: LTSpacing.s) {
                            ForEach(viewModel.annotations) { annotation in
                                HStack(alignment: .top, spacing: LTSpacing.m) {
                                    LTIconBadge(
                                        symbol: annotation.kind == .bookmark
                                            ? "bookmark.fill" : "note.text",
                                        tint: LTColors.accentCyan,
                                        size: 32
                                    )
                                    VStack(alignment: .leading, spacing: LTSpacing.xxs) {
                                        Text("第 \(annotation.pageNumber) 页 · \(annotation.kind.displayName)")
                                            .font(LTTypography.caption)
                                            .foregroundStyle(LTColors.textTertiary)
                                        if !annotation.text.isEmpty {
                                            Text(annotation.text)
                                                .font(Font.subheadline)
                                                .foregroundStyle(LTColors.textPrimary)
                                                .textSelection(.enabled)
                                        }
                                    }
                                    Spacer()
                                    Button {
                                        viewModel.deleteAnnotation(annotation, environment: environment)
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: 13))
                                            .foregroundStyle(LTColors.destructive)
                                    }
                                    .accessibilityLabel(Text("删除"))
                                }
                                .ltCard(padding: LTSpacing.m)
                            }
                        }
                    }
                }
                .padding(.horizontal, LTSpacing.screenPadding)
                .padding(.bottom, LTSpacing.tabBarReserve)
            }
        }
        .navigationTitle("笔记与书签")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("完成") { dismiss() }
            }
        }
    }
}

// MARK: - Metadata editor

/// Edits a material's metadata (title, kind, course/session/occurrence
/// links — the 先导入后整理 path).
struct MaterialMetadataEditor: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: MaterialReaderViewModel

    @State private var title = ""
    @State private var kind: MaterialKind = .other
    /// Link materials: the text shared alongside the URL (editable).
    @State private var sharedText = ""
    @State private var courseID: UUID?
    @State private var sessionID: UUID?
    @State private var occurrenceKey: String?
    @State private var courses: [Course] = []
    @State private var sessions: [ClassroomSession] = []
    @State private var occurrences: [ScheduleCalculator.Occurrence] = []

    var body: some View {
        Form {
            Section("资料信息") {
                TextField("标题", text: $title)
                Picker("资料类型", selection: $kind) {
                    ForEach(MaterialKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                if viewModel.material?.format == .link {
                    TextField("分享时的文字（可编辑）", text: $sharedText, axis: .vertical)
                        .lineLimit(2...6)
                }
            }
            Section("归属") {
                Picker("所属课程", selection: $courseID) {
                    Text("未归类").tag(UUID?.none)
                    ForEach(courses) { course in
                        Text(course.name).tag(UUID?.some(course.id))
                    }
                }
                if !sessions.isEmpty {
                    Picker("关联课堂", selection: $sessionID) {
                        Text("不关联").tag(UUID?.none)
                        ForEach(sessions) { session in
                            Text(session.title).tag(UUID?.some(session.id))
                        }
                    }
                }
                if !occurrences.isEmpty {
                    Picker("课前资料（课表）", selection: $occurrenceKey) {
                        Text("不关联").tag(String?.none)
                        ForEach(occurrences) { occurrence in
                            Text(Self.occurrenceLabel(occurrence))
                                .tag(String?.some(occurrence.occurrenceKey))
                        }
                    }
                }
            }
        }
        .navigationTitle("编辑资料信息")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") { save() }
            }
        }
        .task {
            guard let material = viewModel.material else { return }
            title = material.title
            kind = material.kind
            sharedText = material.sharedText
            courseID = material.courseID
            sessionID = material.sessionID
            occurrenceKey = material.occurrenceKey
            courses = (try? environment.repository.courses()) ?? []
            reloadLinkTargets()
        }
        .onChange(of: courseID) {
            sessionID = nil
            occurrenceKey = nil
            reloadLinkTargets()
        }
    }

    private func reloadLinkTargets() {
        let allSessions = (try? environment.repository.sessions(matching: "")) ?? []
        sessions = courseID == nil
            ? allSessions
            : allSessions.filter { $0.courseID == courseID }
        let schedules = (try? environment.repository.schedules(courseID: courseID)) ?? []
        let exceptions = (try? environment.repository.allExceptions()) ?? []
        var upcoming: [ScheduleCalculator.Occurrence] = []
        let window = Calendar.current.date(byAdding: .day, value: 14, to: .now) ?? .now
        for schedule in schedules {
            upcoming.append(contentsOf: ScheduleCalculator.occurrences(
                of: schedule, from: .now, to: window, exceptions: exceptions
            ))
        }
        occurrences = upcoming.filter { !$0.isCancelled }.sorted { $0.start < $1.start }
    }

    private func save() {
        guard let material = viewModel.material else { return }
        let draft = MaterialDraft(
            title: title.isEmpty ? material.title : title,
            originalFileName: material.originalFileName,
            mimeType: material.mimeType,
            kind: kind,
            format: material.format,
            fileSize: material.fileSize,
            contentHash: material.contentHash,
            pageCount: material.pageCount,
            courseID: courseID,
            sessionID: sessionID,
            occurrenceKey: occurrenceKey,
            sourceAttachmentID: material.sourceAttachmentID,
            sourceURL: material.sourceURL,
            sharedText: material.isLink ? sharedText : material.sharedText,
            extractionStatus: material.extractionStatus
        )
        try? environment.repository.updateMaterial(material, with: draft)
        viewModel.reload()
        dismiss()
    }

    static func occurrenceLabel(_ occurrence: ScheduleCalculator.Occurrence) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 EEE"
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: occurrence.start)
    }
}
