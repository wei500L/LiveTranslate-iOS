import SwiftUI

/// Global search tab: one field searching classroom titles plus Chinese and
/// Russian transcript text through the existing repository query, with a
/// per-session match snippet. Debounced, since entry-text search is the
/// expensive path.
struct SearchScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var query = ""
    @State private var appliedQuery = ""
    @State private var results: [SessionHit] = []
    @State private var isLoaded = false
    @State private var isSearching = false
    @State private var debounceTask: Task<Void, Never>?

    /// One matched session with its best snippet.
    struct SessionHit: Identifiable {
        let session: ClassroomSession
        let snippet: String

        var id: UUID { session.id }
    }

    var body: some View {
        NavigationStack {
            LTPage {
                ScrollView {
                    VStack(alignment: .leading, spacing: LTSpacing.l) {
                        searchField
                        if !appliedQuery.isEmpty && isLoaded {
                            resultHeader
                            resultList
                        } else if isLoaded {
                            LTEmptyState(
                                symbol: "magnifyingglass",
                                title: "搜索全部课堂",
                                message: "支持课堂名称、中文翻译与俄语原文"
                            )
                        }
                    }
                    .padding(.horizontal, LTSpacing.screenPadding)
                    .padding(.top, LTSpacing.s)
                    .padding(.bottom, LTSpacing.xl)
                }
            }
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            isLoaded = true
        }
        .onChange(of: query) { _, newValue in
            searchDidChange(newValue)
        }
    }

    private var searchField: some View {
        HStack(spacing: LTSpacing.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(LTColors.textTertiary)
            TextField("课堂名称 / 中文翻译 / 俄语原文", text: $query)
                .font(.subheadline)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if isSearching {
                ProgressView()
                    .controlSize(.small)
            } else if !query.isEmpty {
                Button {
                    query = ""
                    appliedQuery = ""
                    results = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(LTColors.textTertiary)
                }
                .accessibilityLabel(Text("清除搜索"))
            }
        }
        .padding(LTSpacing.m)
        .background(RoundedRectangle(cornerRadius: LTRadius.medium).fill(LTColors.surfacePrimary))
        .overlay(RoundedRectangle(cornerRadius: LTRadius.medium).strokeBorder(LTColors.border, lineWidth: 0.5))
    }

    private var resultHeader: some View {
        Text(results.isEmpty ? "没有匹配的课堂" : "共 \(results.count) 堂课匹配")
            .font(LTTypography.caption)
            .foregroundStyle(LTColors.textTertiary)
    }

    @ViewBuilder
    private var resultList: some View {
        if results.isEmpty {
            LTEmptyState(
                symbol: "questionmark.circle",
                title: "换个关键词试试",
                message: "搜索会覆盖课堂名称与全部双语文本"
            )
        } else {
            VStack(spacing: LTSpacing.s) {
                ForEach(results) { hit in
                    NavigationLink {
                        SessionDetailView(sessionID: hit.session.id)
                    } label: {
                        searchResultRow(hit)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func searchResultRow(_ hit: SessionHit) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: LTSpacing.s) {
                LTIconBadge(
                    symbol: LTIconography.symbol(for: hit.session.title),
                    tint: LTIconography.tint(for: hit.session.title),
                    size: 34
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(hit.session.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LTColors.textPrimary)
                        .lineLimit(1)
                    Text("\(Format.date(hit.session.startTime)) · \(Format.clock(hit.session.duration))")
                        .font(LTTypography.timestamp)
                        .foregroundStyle(LTColors.textTertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(LTColors.textTertiary)
            }
            Text(hit.snippet)
                .font(.footnote)
                .foregroundStyle(LTColors.textSecondary)
                .lineLimit(2)
                .padding(.leading, 46)
        }
        .ltCard()
        .accessibilityElement(children: .combine)
    }

    // MARK: - Search logic

    private func searchDidChange(_ newValue: String) {
        debounceTask?.cancel()
        let trimmed = newValue.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            appliedQuery = ""
            results = []
            return
        }
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await runSearch(trimmed)
        }
    }

    private func runSearch(_ query: String) async {
        isSearching = true
        defer { isSearching = false }
        // The repository query already searches titles + both texts.
        let sessions = (try? environment.repository.sessions(matching: query)) ?? []
        results = sessions.map { session in
            SessionHit(session: session, snippet: snippet(for: session, query: query))
        }
        appliedQuery = query
    }

    /// First matching entry's text as a snippet.
    private func snippet(for session: ClassroomSession, query: String) -> String {
        let entries = (try? environment.repository.entries(for: session)) ?? []
        let hit = entries.first {
            $0.originalText.localizedCaseInsensitiveContains(query)
                || ($0.translatedText ?? "").localizedCaseInsensitiveContains(query)
        }
        if let hit {
            let translated = (hit.translatedText ?? "").isEmpty ? "" : "\(hit.translatedText!) · "
            return "\(translated)\(hit.originalText)"
        }
        return session.title
    }
}
