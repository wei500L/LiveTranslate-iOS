import SwiftUI
import Observation

/// Course-material library: one flat, filterable list — no new tab, no
/// shell navigation. Entered from a course (scoped), from a session
/// (linked materials) or globally (全部资料 incl. 未归类). Filters hide
/// when their category is empty (no dead navigation); the import entry
/// is always real (Files picker or classroom images).
struct CourseMaterialLibraryScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var viewModel = MaterialLibraryViewModel()
    @State private var showImporter = false
    @State private var pushingInbox = false

    /// Course scope (nil = the whole library). Set when entered from a
    /// course; the global entry passes nil.
    let courseID: UUID?

    var body: some View {
        LTPage {
            Group {
                if viewModel.isLoaded && viewModel.materials.isEmpty {
                    LTEmptyState(
                        symbol: "books.vertical",
                        title: "还没有课程资料",
                        message: courseID == nil
                            ? "导入讲义、习题或阅读材料后，可以阅读、搜索并向课程助手提问"
                            : "导入这份讲义、习题或阅读材料，课前课后都能用"
                    )
                } else if viewModel.isLoaded {
                    materialList
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("课程资料")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 收件箱 entry: only real when unprocessed shared items exist
            // (no dead badge on an empty inbox).
            if environment.inbox.pendingCount > 0 {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        pushingInbox = true
                    } label: {
                        Image(systemName: "tray.full")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(LTColors.textSecondary)
                            .overlay(alignment: .topTrailing) {
                                Text("\(environment.inbox.pendingCount)")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(Color.black.opacity(0.85))
                                    .padding(.horizontal, 3)
                                    .background(Capsule().fill(LTColors.accentCyan))
                                    .offset(x: 7, y: -6)
                            }
                    }
                    .accessibilityLabel(Text("收件箱，\(environment.inbox.pendingCount) 项待整理"))
                    .navigationDestination(isPresented: $pushingInbox) {
                        InboxScreen()
                            .environment(environment)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showImporter = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(LTColors.textSecondary)
                }
                .accessibilityLabel(Text("导入资料"))
            }
        }
        .task {
            viewModel.attach(environment)
            viewModel.load(courseID: courseID)
            environment.inbox.reload()
        }
        .onAppear {
            if viewModel.isLoaded {
                viewModel.reload()
            }
            environment.inbox.reload()
        }
        .sheet(isPresented: $showImporter) {
            NavigationStack {
                MaterialImportSheet(defaultCourseID: courseID)
                    .environment(environment)
            }
            .presentationDetents([.large])
        }
    }

    private var materialList: some View {
        ScrollView {
            VStack(spacing: LTSpacing.l) {
                filterBar
                LazyVStack(spacing: LTSpacing.s) {
                    ForEach(viewModel.filteredMaterials) { material in
                        NavigationLink {
                            MaterialReaderScreen(materialID: material.id)
                                .environment(environment)
                        } label: {
                            MaterialRow(
                                material: material,
                                showsCourse: courseID == nil,
                                courseName: viewModel.courseNames[material.courseID ?? UUID()]
                            )
                        }
                        .buttonStyle(.plain)
                        .ltCard(padding: LTSpacing.m)
                    }
                }
            }
            .padding(.horizontal, LTSpacing.screenPadding)
            .padding(.bottom, LTSpacing.tabBarReserve)
        }
        .refreshable { viewModel.reload() }
    }

    /// Filter chips: only categories with real content are shown (an
    /// empty category is a dead end, never a dead button).
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: LTSpacing.xs) {
                ForEach(viewModel.availableFilters) { filter in
                    Button {
                        viewModel.selectedFilter = filter
                    } label: {
                        Text(filter.title)
                            .font(LTTypography.button)
                            .padding(.horizontal, LTSpacing.m)
                            .padding(.vertical, LTSpacing.xs)
                            .background(
                                viewModel.selectedFilter == filter
                                    ? LTColors.accentGreen.opacity(0.22)
                                    : LTColors.surfacePrimary.opacity(0.6)
                            )
                            .clipShape(Capsule())
                            .overlay(
                                Capsule().stroke(
                                    viewModel.selectedFilter == filter
                                        ? LTColors.accentGreen.opacity(0.6)
                                        : LTColors.border,
                                    lineWidth: 1
                                )
                            )
                    }
                    .foregroundStyle(
                        viewModel.selectedFilter == filter
                            ? LTColors.textPrimary
                            : LTColors.textSecondary
                    )
                    .accessibilityLabel(Text("筛选：\(filter.title)"))
                }
            }
        }
    }
}

// MARK: - View model

/// Library presentation state: materials, the course-name map, filters
/// derived from REAL content, and a stable reload path.
@MainActor
@Observable
final class MaterialLibraryViewModel {
    enum Filter: String, CaseIterable, Identifiable {
        case all
        case unclassified
        case pdf
        case image
        case text
        case link
        case pendingExtraction
        case digested
        case recent

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "全部"
            case .unclassified: return "未归类"
            case .pdf: return "PDF"
            case .image: return "图片"
            case .text: return "文本"
            case .link: return "链接"
            case .pendingExtraction: return "尚未提取"
            case .digested: return "已整理"
            case .recent: return "最近使用"
            }
        }
    }

    private(set) var materials: [CourseMaterial] = []
    private(set) var courseNames: [UUID: String] = [:]
    private(set) var isLoaded = false
    var selectedFilter: Filter = .all
    private weak var environmentBox: AppEnvironment?
    private var courseID: UUID?

    func attach(_ environment: AppEnvironment) {
        environmentBox = environment
    }

    func load(courseID: UUID?) {
        self.courseID = courseID
        reload()
        isLoaded = true
    }

    func reload() {
        guard let environment = environmentBox else { return }
        materials = (try? environment.repository.materials(courseID: courseID)) ?? []
        let courses = (try? environment.repository.courses()) ?? []
        var names: [UUID: String] = [:]
        for course in courses { names[course.id] = course.name }
        courseNames = names
        // A filter whose category emptied out falls back to 全部.
        if !availableFilters.contains(selectedFilter) {
            selectedFilter = .all
        }
    }

    /// Filters with content (or the always-present 全部) — an empty
    /// category is never offered as navigation.
    var availableFilters: [Filter] {
        Filter.allCases.filter { filter in
            switch filter {
            case .all: return true
            case .unclassified:
                return materials.contains { $0.courseID == nil }
            case .pdf:
                return materials.contains { $0.format == .pdf }
            case .image:
                return materials.contains { $0.format == .image }
            case .text:
                return materials.contains { $0.format == .text || $0.format == .markdown }
            case .link:
                return materials.contains { $0.format == .link }
            case .pendingExtraction:
                return materials.contains {
                    $0.extractionStatus == .pending || $0.extractionStatus == .failed
                }
            case .digested:
                return materials.contains { !$0.digestJSON.isEmpty }
            case .recent:
                return materials.contains { $0.lastOpenedAt != nil }
            }
        }
    }

    var filteredMaterials: [CourseMaterial] {
        let base: [CourseMaterial]
        switch selectedFilter {
        case .all: base = materials
        case .unclassified: base = materials.filter { $0.courseID == nil }
        case .pdf: base = materials.filter { $0.format == .pdf }
        case .image: base = materials.filter { $0.format == .image }
        case .text: base = materials.filter { $0.format == .text || $0.format == .markdown }
        case .pendingExtraction:
            base = materials.filter {
                $0.extractionStatus == .pending || $0.extractionStatus == .failed
            }
        case .digested: base = materials.filter { !$0.digestJSON.isEmpty }
        case .recent:
            base = materials
                .filter { $0.lastOpenedAt != nil }
                .sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
        }
        return base
    }
}
