import SwiftUI
import UniformTypeIdentifiers

/// The material import flow:
///
///     选择来源（「文件」/ 课堂图片）
///     → 挑文件（真实类型，不伪装扩展名）
///     → 相同文件已在库中时如实提示（查看已有 / 建立新关联 / 保留副本）
///     → 填标题、类型、课程、课堂、课表关联（全部可选 → 支持先导入后整理）
///     → 导入（流式哈希+拷贝；行最后落库）
struct MaterialImportSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    /// Pre-scoped course (entered from a course detail).
    let defaultCourseID: UUID?

    @State private var source: MaterialImportSource = .files
    @State private var showFilePicker = false
    @State private var showAttachmentPicker = false
    /// The picked file.
    @State private var pickedURL: URL?
    @State private var classification: MaterialImportService.Classification?
    /// The picked classroom image (source = .attachment).
    @State private var pickedAttachment: SessionAttachment?
    /// Same-bytes materials already in the library.
    @State private var duplicates: [CourseMaterial] = []
    @State private var isCheckingDuplicates = false
    @State private var isImporting = false
    @State private var importError: String?

    // Metadata form.
    @State private var title = ""
    @State private var kind: MaterialKind = .lecture
    @State private var courseID: UUID?
    @State private var sessionID: UUID?
    @State private var occurrenceKey: String?

    @State private var courses: [Course] = []
    @State private var sessions: [ClassroomSession] = []
    @State private var occurrences: [ScheduleCalculator.Occurrence] = []

    var body: some View {
        Form {
            Section {
                Picker("导入来源", selection: $source) {
                    ForEach(MaterialImportSource.allCases) { source in
                        Label(source.displayName, systemImage: source.symbol)
                            .tag(source)
                    }
                }
                .pickerStyle(.segmented)

                switch source {
                case .files:
                    Button {
                        showFilePicker = true
                    } label: {
                        Label(
                            pickedURL?.lastPathComponent ?? "选择文件",
                            systemImage: pickedURL == nil ? "folder" : "doc.fill"
                        )
                    }
                    if let classification {
                        LabeledRow(
                            label: "内容提取",
                            value: classification.canExtract
                                ? "支持（\(classification.format.displayName)）"
                                : "暂不支持内容提取（仅保存与预览）"
                        )
                    }
                case .attachment:
                    Button {
                        showAttachmentPicker = true
                    } label: {
                        Label(
                            pickedAttachment.map { attachmentTitle($0) } ?? "选择课堂图片",
                            systemImage: "photo"
                        )
                    }
                }
            } header: {
                Text("来源")
            } footer: {
                Text("支持 PDF、TXT、Markdown 与 JPEG/PNG/HEIC 的内容提取；DOCX、PPTX 等格式将如实保存并支持预览，但暂不支持内容提取。")
            }

            if hasPick {
                Section("资料信息") {
                    TextField("标题", text: $title)
                    Picker("资料类型", selection: $kind) {
                        ForEach(MaterialKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
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
                                Text(occurrenceLabel(occurrence))
                                    .tag(String?.some(occurrence.occurrenceKey))
                            }
                        }
                    }
                }

                if !duplicates.isEmpty {
                    Section {
                        ForEach(duplicates) { duplicate in
                                            VStack(alignment: .leading, spacing: LTSpacing.xxs) {
                            Text(duplicate.title)
                                .font(LTTypography.cardTitle)
                            Text("库中已有相同文件的资料")
                                .font(LTTypography.caption)
                                .foregroundStyle(LTColors.warning)
                        }
                        }
                        Button("为已有资料建立新关联") {
                            relinkExisting()
                        }
                        .disabled(isImporting)
                    } header: {
                        Text("发现相同文件")
                    } footer: {
                        Text("同一文件已在资料库中。可以更新那份资料的课程与课堂关联，或仍保留一份独立副本。")
                    }
                }
            }
        }
        .navigationTitle("导入资料")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(isImporting ? "导入中…" : "导入") {
                    Task { await performImport() }
                }
                .disabled(!canImport || isImporting)
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            handleFileResult(result)
        }
        .sheet(isPresented: $showAttachmentPicker) {
            AttachmentPickerSheet(
                courseID: courseID ?? defaultCourseID
            ) { attachment in
                pickedAttachment = attachment
                title = attachmentTitle(attachment)
                checkAttachmentDuplicates(attachment)
            }
            .environment(environment)
        }
        .task {
            courseID = defaultCourseID
            courses = (try? environment.repository.courses()) ?? []
            reloadLinkTargets()
        }
        .onChange(of: courseID) {
            sessionID = nil
            occurrenceKey = nil
            reloadLinkTargets()
        }
        .alert("导入失败", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    // MARK: - Derived state

    private var hasPick: Bool {
        pickedURL != nil || pickedAttachment != nil
    }

    private var canImport: Bool {
        if source == .attachment { return pickedAttachment != nil }
        return pickedURL != nil
    }

    // MARK: - Actions

    private func handleFileResult(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        pickedAttachment = nil
        pickedURL = url
        classification = MaterialImportService.classify(fileName: url.lastPathComponent)
        if title.isEmpty {
            title = (url.lastPathComponent as NSString).deletingPathExtension
        }
        duplicates = []
        isCheckingDuplicates = true
        Task {
            let found = await environment.materialImporter.existingDuplicates(for: url)
            duplicates = found
            isCheckingDuplicates = false
        }
    }

    private func checkAttachmentDuplicates(_ attachment: SessionAttachment) {
        duplicates = (try? environment.repository.materials(
            contentHash: attachment.contentHash
        )) ?? []
    }

    private func reloadLinkTargets() {
        let repository = environment.repository
        let allSessions = (try? repository.sessions(matching: "")) ?? []
        sessions = courseID == nil
            ? allSessions
            : allSessions.filter { $0.courseID == courseID }
        // Upcoming occurrences (next 14 days) of the selected course's
        // schedules — the 课前资料 association target.
        let schedules = (try? repository.schedules(courseID: courseID)) ?? []
        let exceptions = (try? repository.allExceptions()) ?? []
        var upcoming: [ScheduleCalculator.Occurrence] = []
        let window = Calendar.current.date(
            byAdding: .day, value: 14, to: .now
        ) ?? .now
        for schedule in schedules {
            upcoming.append(contentsOf: ScheduleCalculator.occurrences(
                of: schedule, from: .now, to: window, exceptions: exceptions
            ))
        }
        occurrences = upcoming
            .filter { !$0.isCancelled }
            .sorted { $0.start < $1.start }
    }

    private func performImport() async {
        isImporting = true
        defer { isImporting = false }
        let metadata = MaterialImportService.Metadata(
            title: title,
            kind: kind,
            courseID: courseID,
            sessionID: sessionID,
            occurrenceKey: occurrenceKey
        )
        do {
            if source == .attachment, let attachment = pickedAttachment {
                _ = try environment.materialImporter.importFromAttachment(
                    attachment, metadata: metadata
                )
                dismiss()
                return
            }
            guard let url = pickedURL else { return }
            let keepCopy = !duplicates.isEmpty
            _ = try await environment.materialImporter.importFile(
                at: url, metadata: metadata, keepDuplicateCopy: keepCopy
            )
            dismiss()
        } catch {
            importError = (error as? LocalizedError)?.errorDescription
                ?? String(localized: "导入失败，请重试。")
        }
    }

    /// 建立新关联: the duplicate KEEPS its identity (and its files) —
    /// only its course/session/occurrence links are updated, then the
    /// import is done (no second copy).
    private func relinkExisting() {
        guard let existing = duplicates.first else { return }
        do {
            let draft = MaterialDraft(
                title: existing.title.isEmpty ? title : existing.title,
                originalFileName: existing.originalFileName,
                mimeType: existing.mimeType,
                kind: kind,
                format: existing.format,
                fileSize: existing.fileSize,
                contentHash: existing.contentHash,
                pageCount: existing.pageCount,
                courseID: courseID,
                sessionID: sessionID,
                occurrenceKey: occurrenceKey,
                sourceAttachmentID: existing.sourceAttachmentID,
                extractionStatus: existing.extractionStatus
            )
            try environment.repository.updateMaterial(existing, with: draft)
            dismiss()
        } catch {
            importError = String(localized: "更新资料关联失败。")
        }
    }

    // MARK: - Formatting

    private func attachmentTitle(_ attachment: SessionAttachment) -> String {
        attachment.title.isEmpty ? "课堂图片 · \(attachment.kind.displayName)" : attachment.title
    }

    private func occurrenceLabel(_ occurrence: ScheduleCalculator.Occurrence) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 EEE"
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: occurrence.start)
    }
}

/// Picks one classroom image (source of an image material — the
/// original is BORROWED, never copied).
private struct AttachmentPickerSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let courseID: UUID?
    let onSelect: (SessionAttachment) -> Void

    @State private var attachments: [(attachment: SessionAttachment, sessionTitle: String)] = []

    var body: some View {
        NavigationStack {
            LTPage {
                Group {
                    if attachments.isEmpty {
                        LTEmptyState(
                            symbol: "photo.on.rectangle",
                            title: "没有可选取的课堂图片",
                            message: "在课堂上拍摄或导入图片后，可以在这里把它们整理成课程资料"
                        )
                    } else {
                        ScrollView {
                            LazyVStack(spacing: LTSpacing.s) {
                                ForEach(attachments, id: \.attachment.id) { item in
                                    Button {
                                        onSelect(item.attachment)
                                        dismiss()
                                    } label: {
                                        HStack(spacing: LTSpacing.m) {
                                            LTIconBadge(
                                                symbol: "photo",
                                                tint: LTColors.accentCyan,
                                                size: 38
                                            )
                                            VStack(alignment: .leading, spacing: LTSpacing.xxs) {
                                                Text(item.attachment.title.isEmpty
                                                    ? item.attachment.kind.displayName
                                                    : item.attachment.title)
                                                    .font(LTTypography.cardTitle)
                                                    .foregroundStyle(LTColors.textPrimary)
                                                Text(item.sessionTitle)
                                                    .font(LTTypography.caption)
                                                    .foregroundStyle(LTColors.textTertiary)
                                            }
                                            Spacer()
                                            Image(systemName: "checkmark.circle")
                                                .foregroundStyle(LTColors.accentGreen)
                                                .opacity(0)
                                        }
                                        .ltCard(padding: LTSpacing.m)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, LTSpacing.screenPadding)
                        }
                    }
                }
            }
            .navigationTitle("选择课堂图片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
            .task {
                let sessions = (try? environment.repository.sessions(matching: "")) ?? []
                let scoped = courseID == nil
                    ? sessions
                    : sessions.filter { $0.courseID == courseID }
                var result: [(SessionAttachment, String)] = []
                for session in scoped {
                    let items = (try? environment.repository.attachments(
                        forSessionID: session.id
                    )) ?? []
                    for attachment in items {
                        result.append((attachment, session.title))
                    }
                }
                attachments = result
            }
        }
    }
}
