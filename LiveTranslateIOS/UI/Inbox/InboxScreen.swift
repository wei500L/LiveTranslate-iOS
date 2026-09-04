import SwiftUI
import ImageIO
import UIKit

/// 智能收件箱 — the organizing surface for everything shared into the
/// app from other apps. Unprocessed items first, honest status per item,
/// date-grouped; batch actions for the common cases; complex decisions
/// live in the detail view. NOT a new tab: reached from home / the
/// material library.
struct InboxScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var selectionMode = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var pushItemID: UUID?
    /// Batch course assignment (批量归入课程) for selected FILE items.
    @State private var showBatchCoursePicker = false
    @State private var batchCourseID: UUID?

    /// A route may point at one item (e.g. the review center's 今天
    /// segment) — consumed once on appear by pushing its detail.
    var initialItemID: UUID? = nil

    var body: some View {
        LTPage {
            Group {
                if environment.inbox.storeUnavailable {
                    LTEmptyState(
                        symbol: "tray",
                        title: "收件箱不可用",
                        message: "共享存储未能打开。请重新安装应用后重试。"
                    )
                } else if environment.inbox.isLoaded, environment.inbox.items.isEmpty {
                    LTEmptyState(
                        symbol: "tray",
                        title: "收件箱是空的",
                        message: "在其他应用里选择文件、图片、链接或文字，通过系统分享菜单发送到 LiveTranslate，它们会出现在这里等你整理。"
                    )
                } else if environment.inbox.isLoaded {
                    inboxList
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("收件箱")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !environment.inbox.items.isEmpty {
                    Button(selectionMode ? "完成" : "选择") {
                        selectionMode.toggle()
                        if !selectionMode { selectedIDs.removeAll() }
                    }
                }
            }
        }
        .task {
            environment.inbox.reconcile()
            // Route target: open the pointed-at item's detail once.
            if let initialItemID, environment.inbox.item(id: initialItemID) != nil {
                pushItemID = initialItemID
            }
        }
        .onAppear {
            environment.inbox.reload()
        }
        .navigationDestination(isPresented: Binding(
            get: { pushItemID != nil },
            set: { presented in if !presented { pushItemID = nil } }
        )) {
            if let itemID = pushItemID {
                InboxItemDetailView(itemID: itemID)
                    .environment(environment)
            }
        }
        // Post-confirm jumps from an item detail to the formal entity's
        // own screen.
        .navigationDestination(for: InboxLedgerRoute.self) { route in
            InboxLedgerRoute.destination(for: route)
                .environment(environment)
        }
        .sheet(isPresented: $showBatchCoursePicker) {
            batchCoursePicker
        }
    }

    // MARK: - List

    private var inboxList: some View {
        List {
            let grouped = Self.groupByDay(environment.inbox.items)
            ForEach(grouped, id: \.day) { group in
                Section {
                    ForEach(group.items) { item in
                        row(item)
                    }
                } header: {
                    HStack {
                        Text(Self.dayLabel(group.day))
                        Spacer()
                        Text(group.day == grouped.first?.day
                             ? "\(environment.inbox.pendingCount) 项待整理" : "")
                            .foregroundStyle(LTColors.accentCyan)
                    }
                }
            }
            if environment.inbox.items.contains(where: { $0.status == .completed }) {
                Section {
                    Button(role: .destructive) {
                        environment.inbox.clearCompleted()
                    } label: {
                        Label("清理已处理记录", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .overlay(alignment: .bottom) {
            if selectionMode { batchBar }
        }
    }

    private func row(_ item: SharedInboxItem) -> some View {
        Button {
            if selectionMode {
                if selectedIDs.contains(item.id) {
                    selectedIDs.remove(item.id)
                } else {
                    selectedIDs.insert(item.id)
                }
            } else {
                pushItemID = item.id
            }
        } label: {
            HStack(spacing: LTSpacing.m) {
                if selectionMode {
                    Image(systemName: selectedIDs.contains(item.id)
                        ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(
                            selectedIDs.contains(item.id)
                                ? LTColors.accentGreen : LTColors.textTertiary
                        )
                }
                InboxItemRowLeading(item: item)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(LTColors.textPrimary)
                        .lineLimit(2)
                    Text(InboxScreen.rowSubtitle(item))
                        .font(LTTypography.caption)
                        .foregroundStyle(LTColors.textTertiary)
                        .lineLimit(1)
                    if let local = environment.inbox.suggestions(for: item)?.local {
                        HStack(spacing: LTSpacing.xxs) {
                            StatusChip(text: local.kind.displayName, tint: LTColors.accentBlue)
                            if let name = local.matchedCourseName {
                                StatusChip(text: name, tint: LTColors.accentCyan)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
                StatusChip(
                    text: item.status.displayName,
                    tint: Self.statusTint(item.status)
                )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(item.title)，\(item.status.displayName)"))
    }

    // MARK: - Batch bar

    private var batchBar: some View {
        HStack(spacing: LTSpacing.m) {
            Button {
                // Select every still-pending item.
                selectedIDs = Set(environment.inbox.pendingItems.map(\.id))
            } label: {
                Text("全选待处理")
                    .font(.footnote)
            }
            .buttonStyle(LTSecondaryButtonStyle())
            Spacer()
            if !batchableFileItems.isEmpty {
                Button {
                    batchCourseID = nil
                    showBatchCoursePicker = true
                } label: {
                    Label("归入课程", systemImage: "folder")
                        .font(.footnote.weight(.medium))
                }
                .buttonStyle(LTSecondaryButtonStyle())
            }
            Button(role: .destructive) {
                environment.inbox.deleteItems(ids: Array(selectedIDs))
                selectedIDs.removeAll()
            } label: {
                Label("删除", systemImage: "trash")
                    .font(.footnote.weight(.medium))
            }
            .buttonStyle(LTSecondaryButtonStyle(tint: LTColors.destructive))
            .disabled(selectedIDs.isEmpty)
        }
        .padding(.horizontal, LTSpacing.l)
        .padding(.vertical, LTSpacing.s)
        .background(.ultraThinMaterial)
    }

    /// Selected items a batch course assignment can honestly process
    /// (files — text/url items need their own per-item decisions).
    private var batchableFileItems: [SharedInboxItem] {
        selectedIDs.compactMap { id in
            environment.inbox.item(id: id)
        }
        .filter { $0.payloadKind == .file && $0.status.isPending }
    }

    /// 批量归入课程: every selected FILE item imports as a course
    /// material into the picked course through the SAME executor pipeline
    /// (per-item ledger, partial failures listed honestly).
    private var batchCoursePicker: some View {
        NavigationStack {
            Form {
                Picker("所属课程", selection: $batchCourseID) {
                    Text("未归类").tag(UUID?.none)
                    ForEach((try? environment.repository.courses()) ?? []) { course in
                        Text(course.name).tag(UUID?.some(course.id))
                    }
                }
                Section {
                    Text("将 \(batchableFileItems.count) 个文件保存为课程资料。文本和链接分享仍需逐项整理。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("归入课程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showBatchCoursePicker = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { runBatchAssignment() }
                        .disabled(batchableFileItems.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func runBatchAssignment() {
        guard let executor = environment.inboxExecutor else {
            showBatchCoursePicker = false
            return
        }
        let context = InboxActionExecutor.Context(
            courseID: batchCourseID,
            sessionID: nil,
            duplicateResolution: .keepCopy
        )
        let targets = batchableFileItems
        showBatchCoursePicker = false
        Task {
            for item in targets {
                var action = InboxSuggestedAction(
                    kind: .saveAsMaterial, title: "批量归入课程资料"
                )
                action.materialKindRaw = MaterialKind.other.rawValue
                _ = await executor.perform(
                    itemID: item.id,
                    context: context,
                    selected: [],
                    manualAction: action
                )
            }
            environment.inbox.reload()
            selectedIDs.removeAll()
        }
    }

    // MARK: - Formatting

    static func groupByDay(_ items: [SharedInboxItem]) -> [(day: Date, items: [SharedInboxItem])] {
        let calendar = Calendar.current
        var buckets: [Date: [SharedInboxItem]] = [:]
        for item in items {
            buckets[calendar.startOfDay(for: item.receivedAt), default: []].append(item)
        }
        return buckets.keys.sorted(by: >).map { day in
            (day, buckets[day]!.sorted { $0.receivedAt > $1.receivedAt })
        }
    }

    static func dayLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "今天" }
        if calendar.isDateInYesterday(day) { return "昨天" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEEE"
        return formatter.string(from: day)
    }

    static func rowSubtitle(_ item: SharedInboxItem) -> String {
        var parts: [String] = []
        switch item.payloadKind {
        case .file:
            parts.append(item.fileHints.family == .image ? "图片" : "文件")
            if item.fileSize > 0 { parts.append(Format.bytes(Int(item.fileSize))) }
        case .text: parts.append("文本")
        case .url: parts.append("链接")
        }
        let time = item.receivedAt.formatted(date: .omitted, time: .shortened)
        parts.append(time)
        return parts.joined(separator: " · ")
    }

    static func statusTint(_ status: SharedInboxItemStatus) -> Color {
        switch status {
        case .received, .inspecting, .needsConfirmation: return LTColors.accentCyan
        case .processing: return LTColors.accentBlue
        case .partiallyProcessed: return LTColors.warning
        case .completed: return LTColors.accentGreen
        case .failed: return LTColors.destructive
        }
    }
}

// MARK: - Row leading icon (real thumbnail where one exists)

struct InboxItemRowLeading: View {
    @Environment(AppEnvironment.self) private var environment
    let item: SharedInboxItem
    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: LTRadius.small))
            } else {
                LTIconBadge(symbol: symbol, tint: tint, size: 40)
            }
        }
        .task(id: item.id) { loadThumbnail() }
    }

    private var symbol: String {
        switch item.payloadKind {
        case .file:
            switch item.fileHints.family {
            case .pdf: return "doc.richtext"
            case .image: return "photo"
            case .text, .markdown: return "doc.plaintext"
            case .other: return "doc"
            }
        case .text: return "text.quote"
        case .url: return "link"
        }
    }

    private var tint: Color {
        switch item.payloadKind {
        case .url: return LTColors.accentCyan
        default: return LTColors.accentBlue
        }
    }

    /// Real thumbnails for image payloads (downsampled, never re-encoded
    /// on disk); everything else keeps the format glyph.
    private func loadThumbnail() {
        guard item.payloadKind == .file, item.fileHints.family == .image,
              let data = environment.inbox.payloadData(for: item)
        else { return }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 96,
        ]
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            thumbnail = UIImage(cgImage: cgImage)
        }
    }
}
