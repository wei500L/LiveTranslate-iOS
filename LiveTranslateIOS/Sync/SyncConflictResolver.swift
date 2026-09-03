import Foundation

/// Conflict rules mirrored from the server's protocol v1
/// (services/conflict_resolver.py). The same rules must hold on both
/// sides; a future Web client reuses the server's copy.
enum SyncConflictResolver {
    /// Merges a push item with the server record returned by a `conflict`
    /// result and produces the re-submission payload. Rules:
    ///
    /// - Russian original: server wins unless server's is empty (the
    ///   original is immutable after first write).
    /// - Everything else: the local (newer-intent) payload wins.
    /// - `deleted` server records never resurrect: the caller drops the
    ///   local entity instead.
    static func mergedPayload(
        entityType: SyncEntityType, local: SyncPushPayloadDTO,
        server: SyncServerRecordDTO
    ) -> SyncPushPayloadDTO? {
        guard !server.deleted else { return nil }

        var merged = local
        switch entityType {
        case .entry:
            if let serverRussian = server.russianText, !serverRussian.isEmpty {
                merged.russianText = serverRussian
            }
            // The server's chinese may be newer than ours when it lost a
            // race; prefer ours only when non-empty, else keep server's.
            if (merged.chineseText ?? "").isEmpty, let serverChinese = server.chineseText {
                merged.chineseText = serverChinese
            }
        case .session:
            if (merged.title ?? "").isEmpty, let serverTitle = server.title {
                merged.title = serverTitle
            }
        case .bookmark, .favorite:
            break // boolean states: local intent wins on equal versions
        case .course:
            // Course fields are small user-edited strings; local intent
            // wins, with an empty local name falling back to the server's.
            if (merged.title ?? "").isEmpty, let serverName = server.title {
                merged.title = serverName
            }
        case .note:
            // Note text merges like chineseText: local wins when non-empty.
            if (merged.noteText ?? "").isEmpty, let serverText = server.noteText {
                merged.noteText = serverText
            }
        case .studyReview:
            // The local payload carries the user's current reading state
            // (possibly edited). Local content wins when non-empty; the
            // generated original falls back to the server's when the local
            // run produced none (e.g. a failed first generation adopting an
            // existing remote review).
            if (merged.reviewContent ?? "").isEmpty, let serverContent = server.reviewContent,
               !serverContent.isEmpty {
                merged.reviewContent = serverContent
                merged.reviewGeneratedContent = server.reviewGeneratedContent
                merged.reviewStatus = server.reviewStatus
                merged.reviewModel = server.reviewModel
                merged.reviewGeneratedAt = server.reviewGeneratedAt
                merged.reviewSourceUpdatedAt = server.reviewSourceUpdatedAt
            }
        case .attachment:
            // Identity fields (hash, size, dimensions, mime) are immutable
            // server-side; re-asserting the local copies is harmless. Local
            // user intent (title, caption, kind, anchor, sort) wins when
            // non-empty; the analysis result falls back to the server's
            // when the local run produced none (a failed re-analysis keeps
            // the remote result instead of blanking it).
            if (merged.title ?? "").isEmpty, let serverTitle = server.title {
                merged.title = serverTitle
            }
            if (merged.attachmentCaption ?? "").isEmpty,
               let serverCaption = server.attachmentCaption, !serverCaption.isEmpty {
                merged.attachmentCaption = serverCaption
            }
            if (merged.attachmentOcrText ?? "").isEmpty,
               let serverOCR = server.attachmentOcrText, !serverOCR.isEmpty {
                merged.attachmentOcrText = serverOCR
            }
            if (merged.attachmentAnalysis ?? "").isEmpty,
               let serverAnalysis = server.attachmentAnalysis, !serverAnalysis.isEmpty {
                merged.attachmentAnalysis = serverAnalysis
                merged.attachmentAnalysisStatus = server.attachmentAnalysisStatus
            }
        }
        return merged
    }

    /// Decides whether a remote change should overwrite the local row.
    /// Returns false when the local row is newer (higher serverVersion) —
    /// the pull apply loop uses this to skip no-op writes.
    static func shouldApplyRemote(
        localServerVersion: Int, remoteServerVersion: Int
    ) -> Bool {
        remoteServerVersion > localServerVersion
    }
}
