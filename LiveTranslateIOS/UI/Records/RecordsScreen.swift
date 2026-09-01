import SwiftUI

/// Classroom records tab: searchable session history.
struct RecordsScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var sessions: [ClassroomSession] = []
    @State private var query = ""

    var body: some View {
        NavigationStack {
            Group {
                if filteredSessions.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(filteredSessions, id: \.id) { session in
                            NavigationLink {
                                SessionDetailView(session: session)
                            } label: {
                                SessionRowView(session: session)
                            }
                        }
                        .onDelete { indexSet in
                            delete(at: indexSet)
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "Records"))
            .searchable(text: $query, prompt: String(localized: "Search titles and transcripts"))
            .task { reload() }
            .refreshable { reload() }
        }
    }

    private var filteredSessions: [ClassroomSession] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return sessions }
        return sessions.filter { session in
            session.title.localizedCaseInsensitiveContains(trimmed)
                || (session.entries?.contains {
                    $0.originalText.localizedCaseInsensitiveContains(trimmed)
                        || ($0.translatedText ?? "").localizedCaseInsensitiveContains(trimmed)
                } ?? false)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(String(localized: "No classroom records"), systemImage: "list.bullet.rectangle")
        } description: {
            Text(query.isEmpty
                 ? String(localized: "Start a live session and your classroom transcripts will appear here.")
                 : String(localized: "No records match your search."))
        }
    }

    private func reload() {
        sessions = (try? environment.repository.sessions(matching: "")) ?? []
    }

    private func delete(at indexSet: IndexSet) {
        let doomed = indexSet.map { filteredSessions[$0] }
        for session in doomed {
            try? environment.repository.deleteSession(session)
        }
        reload()
    }
}

struct SessionRowView: View {
    let session: ClassroomSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if session.abnormalTermination {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                        .accessibilityLabel(Text("Ended abnormally"))
                }
                Spacer()
                if let backend = ASRBackendKind(rawValue: session.asrBackend) {
                    StatusChip(text: backend.shortLabel, tint: .blue)
                }
            }
            Text("\(Format.date(session.startTime)) · \(Format.clock(session.duration)) · \(session.entryCount) \(String(localized: "entries"))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
