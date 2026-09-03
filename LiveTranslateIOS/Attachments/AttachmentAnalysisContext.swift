import Foundation

/// Builds the bounded classroom context for one attachment's analysis:
/// course name, session title, the transcript window around the capture
/// time (the anchored entry plus its neighbors), and the user's notes.
/// Deliberately BOUNDED — never the whole two-hour transcript, never all
/// attachments; each analysis is one image plus a few lines.
enum AttachmentAnalysisContext {
    /// Window half-width around the anchor/capture point (seconds).
    static let windowSeconds: TimeInterval = 120
    /// Hard cap on cited entries per analysis.
    static let maxEntries = 20
    /// Hard cap on included notes.
    static let maxNotes = 5

    /// The provider handed to the generator. Closes over the repository
    /// and session; called on the main actor.
    @MainActor
    static func provider(
        repository: any ClassroomRepositoryProtocol, session: ClassroomSession
    ) -> AttachmentAnalysisContextProvider {
        { attachment, includeClassContext in
            build(
                repository: repository, session: session,
                attachment: attachment, includeClassContext: includeClassContext
            )
        }
    }

    @MainActor
    static func build(
        repository: any ClassroomRepositoryProtocol, session: ClassroomSession,
        attachment: SessionAttachment, includeClassContext: Bool
    ) -> AttachmentAnalysisPromptContextBundle {
        let courseName: String?
        if let courseID = session.courseID,
           let course = (try? repository.course(id: courseID)) ?? nil {
            courseName = course.name
        } else {
            courseName = nil
        }

        guard includeClassContext else {
            return AttachmentAnalysisPromptContextBundle(
                promptContext: AttachmentAnalysisPrompt.Context(
                    courseName: nil,
                    sessionTitle: session.title,
                    attachmentTitle: attachment.title,
                    userCaption: attachment.caption,
                    transcriptLines: [],
                    anchoredLines: [],
                    noteTexts: [],
                    citationCount: 0
                ),
                citationIDs: []
            )
        }

        let entries = (try? repository.entries(for: session)) ?? []
        let notes = (try? repository.notes(forSessionID: session.id)) ?? []

        // Anchor point: the anchored entry's offset, else the offset the
        // capture time maps to within the session timeline.
        var anchorOffset: TimeInterval?
        if let anchorID = attachment.anchorEntryID,
           let anchored = entries.first(where: { $0.id == anchorID }) {
            anchorOffset = anchored.startOffset
        } else {
            let elapsed = attachment.capturedAt.timeIntervalSince(session.startTime)
            if elapsed >= 0 { anchorOffset = elapsed }
        }

        // Bounded window around the anchor point (or the newest entries
        // when the image is unanchored and predates the session).
        var window: [TranscriptEntry] = []
        if let center = anchorOffset {
            window = entries.filter {
                abs($0.startOffset - center) <= windowSeconds
            }
        }
        if window.isEmpty {
            window = Array(entries.suffix(maxEntries))
        } else if window.count > maxEntries {
            // Keep the entries nearest the center.
            let sorted = window.sorted {
                abs($0.startOffset - center!) < abs($1.startOffset - center!)
            }
            let picked = Array(sorted.prefix(maxEntries))
            window = picked.sorted { $0.startOffset < $1.startOffset }
        }

        let citationIDs = window.map(\.id)
        var lines: [String] = []
        var anchoredLines: [String] = []
        for (index, entry) in window.enumerated() {
            let line = "[\(index + 1)] \(TranscriptExporter.mmss(entry.startOffset)) \(entry.originalText)"
            let chinese = entry.translatedText.map { "    中文：\($0)" } ?? ""
            if entry.id == attachment.anchorEntryID {
                anchoredLines.append(line)
                if !chinese.isEmpty { anchoredLines.append(chinese) }
            } else {
                lines.append(line)
                if !chinese.isEmpty { lines.append(chinese) }
            }
        }

        // Notes anchored inside the window first, else the latest ones.
        var windowNoteIDs = Set(window.map(\.id))
        let windowNotes = notes.filter {
            $0.anchorEntryID.map { windowNoteIDs.contains($0) } ?? false
        }
        var selectedNotes = windowNotes
        if selectedNotes.count < maxNotes {
            for note in notes.reversed() where !selectedNotes.contains(where: { $0.id == note.id }) {
                selectedNotes.append(note)
                if selectedNotes.count >= maxNotes { break }
            }
        }

        return AttachmentAnalysisPromptContextBundle(
            promptContext: AttachmentAnalysisPrompt.Context(
                courseName: courseName,
                sessionTitle: session.title,
                attachmentTitle: attachment.title,
                userCaption: attachment.caption,
                transcriptLines: lines,
                anchoredLines: anchoredLines,
                noteTexts: selectedNotes.map(\.text),
                citationCount: citationIDs.count
            ),
            citationIDs: citationIDs
        )
    }
}
