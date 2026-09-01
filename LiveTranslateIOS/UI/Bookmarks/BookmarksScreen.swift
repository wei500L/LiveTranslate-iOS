import SwiftUI

/// Bookmarks tab: entry bookmarks across all classrooms, resolved against
/// the real repository by stable entry ID — so re-translated entries and
/// renamed sessions always show their latest content, and deleted
/// sessions/entries disappear automatically. Tapping a bookmark opens the
/// classroom detail (its transcript is searchable there).
struct BookmarksScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var groups: [BookmarkGroup] = []
    @State private var isLoaded = false

    /// One session's bookmarks with their resolved entry content.
    private struct BookmarkGroup: Identifiable {
        let sessionID: UUID
        let title: String
        let rows: [Row]

        var id: UUID { sessionID }

        struct Row: Identifiable {
            let bookmark: BookmarkStore.EntryBookmark
            let startOffset: TimeInterval
            let translatedText: String?
            let originalText: String

            var id: UUID { bookmark.id }
        }
    }

    var body: some View {
        NavigationStack {
            LTPage {
                ScrollView {
                    VStack(alignment: .leading, spacing: LTSpacing.l) {
                        if isLoaded && groups.isEmpty {
                            LTEmptyState(
                                symbol: "bookmark",
                                title: "还没有书签",
                                message: "实时课堂中点击书签按钮，或在课堂详情里标记重点内容"
                            )
                        } else if isLoaded {
                            bookmarkGroups
                        } else {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.top, LTSpacing.xl)
                        }
                    }
                    .padding(.horizontal, LTSpacing.screenPadding)
                    .padding(.top, LTSpacing.s)
                    .padding(.bottom, LTSpacing.xl)
                }
            }
            .navigationTitle("书签")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { reload() }
        .onAppear { reload() }
    }

    private var bookmarkGroups: some View {
        ForEach(groups) { group in
            bookmarkGroup(group)
        }
    }

    private func bookmarkGroup(_ group: BookmarkGroup) -> some View {
        VStack(alignment: .leading, spacing: LTSpacing.s) {
            HStack(spacing: LTSpacing.s) {
                LTIconBadge(
                    symbol: LTIconography.symbol(for: group.title),
                    tint: LTIconography.tint(for: group.title),
                    size: 34
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LTColors.textPrimary)
                        .lineLimit(1)
                    Text("\(group.rows.count) 条书签")
                        .font(LTTypography.timestamp)
                        .foregroundStyle(LTColors.textTertiary)
                }
                Spacer()
                NavigationLink {
                    SessionDetailView(sessionID: group.sessionID)
                } label: {
                    Text("打开课堂")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(LTColors.accentBlue)
                }
                .buttonStyle(.plain)
            }
            VStack(spacing: LTSpacing.xs) {
                ForEach(group.rows) { row in
                    BookmarkRow(
                        startOffset: row.startOffset,
                        createdAt: row.bookmark.createdAt,
                        translatedText: row.translatedText,
                        originalText: row.originalText
                    )
                }
            }
        }
    }

    /// Resolve every bookmark against the repository (newest title/text),
    /// pruning session-level and entry-level orphans along the way.
    private func reload() {
        let sessions = (try? environment.repository.sessions(matching: "")) ?? []
        environment.bookmarks.pruneSessions(Set(sessions.map(\.id)))

        let sessionsByID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var resolved: [BookmarkGroup] = []
        for (sessionID, bookmarks) in Dictionary(grouping: environment.bookmarks.entryBookmarks, by: \.sessionID) {
            guard let session = sessionsByID[sessionID] else { continue }
            let entries = (try? environment.repository.entries(for: session)) ?? []
            let entriesByID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

            var rows: [BookmarkGroup.Row] = []
            for bookmark in bookmarks {
                guard let entry = entriesByID[bookmark.entryID] else { continue }
                rows.append(BookmarkGroup.Row(
                    bookmark: bookmark,
                    startOffset: entry.startOffset,
                    translatedText: entry.translatedText,
                    originalText: entry.originalText
                ))
            }
            // Entries deleted upstream drop their bookmarks (orphan IDs).
            environment.bookmarks.pruneEntries(
                in: sessionID, existingEntryIDs: Set(entries.map(\.id))
            )
            guard !rows.isEmpty else { continue }
            rows.sort { $0.bookmark.createdAt > $1.bookmark.createdAt }
            resolved.append(BookmarkGroup(sessionID: sessionID, title: session.title, rows: rows))
        }
        // Newest session first (by its most recent bookmark).
        resolved.sort { $0.rows.first?.bookmark.createdAt ?? .distantPast > $1.rows.first?.bookmark.createdAt ?? .distantPast }
        groups = resolved
        isLoaded = true
    }
}

private struct BookmarkRow: View {
    let startOffset: TimeInterval
    let createdAt: Date
    let translatedText: String?
    let originalText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: LTSpacing.xs) {
                Image(systemName: "bookmark.fill")
                    .font(.caption2)
                    .foregroundStyle(LTColors.accentGreen)
                Text(TranscriptExporter.mmss(startOffset))
                    .font(LTTypography.timestamp)
                    .foregroundStyle(LTColors.textTertiary)
                Spacer()
                Text(createdAt.formatted(date: .omitted, time: .shortened))
                    .font(LTTypography.timestamp)
                    .foregroundStyle(LTColors.textTertiary)
            }
            if let translated = translatedText, !translated.isEmpty {
                Text(translated)
                    .font(.subheadline)
                    .foregroundStyle(LTColors.textPrimary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Text(originalText)
                .font(.footnote)
                .foregroundStyle(LTColors.textSecondary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .padding(LTSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: LTRadius.small).fill(LTColors.surfacePrimary.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: LTRadius.small).strokeBorder(LTColors.border, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}
