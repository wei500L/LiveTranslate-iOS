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
        case .term:
            // Text fields: local (newer user intent) wins when non-empty;
            // fall back to the server's so a rebase never blanks a field.
            if (merged.termChinese ?? "").isEmpty, let serverChinese = server.termChinese {
                merged.termChinese = serverChinese
            }
            if (merged.termExplanation ?? "").isEmpty,
               let serverExplanation = server.termExplanation {
                merged.termExplanation = serverExplanation
            }
            if (merged.termUserNote ?? "").isEmpty, let serverNote = server.termUserNote {
                merged.termUserNote = serverNote
            }
        case .studyCard:
            // Content fields: local wins, server fallback for empties.
            if (merged.cardFront ?? "").isEmpty, let serverFront = server.cardFront {
                merged.cardFront = serverFront
            }
            if (merged.cardBack ?? "").isEmpty, let serverBack = server.cardBack {
                merged.cardBack = serverBack
            }
            // Review state: newest lastReviewedAt wins — the OTHER
            // device may have reviewed this card after we last did, and
            // its schedule must survive our content edit (mirrors the
            // server-side merge rule in applyStudyCard).
            let localReviewed = merged.cardLastReviewedAt ?? .distantPast
            let serverReviewed = server.cardLastReviewedAt ?? .distantPast
            if serverReviewed > localReviewed {
                merged.cardStage = server.cardStage
                merged.cardReviewCount = server.cardReviewCount
                merged.cardIntervalHours = server.cardIntervalHours
                merged.cardDueAt = server.cardDueAt
                merged.cardLastReviewedAt = server.cardLastReviewedAt
                merged.cardLastGrade = server.cardLastGrade
            }
        case .studyTask:
            if (merged.title ?? "").isEmpty, let serverTitle = server.title {
                merged.title = serverTitle
            }
            if (merged.taskDetail ?? "").isEmpty, let serverDetail = server.taskDetail {
                merged.taskDetail = serverDetail
            }
            if (merged.taskUserNote ?? "").isEmpty, let serverNote = server.taskUserNote {
                merged.taskUserNote = serverNote
            }
            // Done is sticky: once the server says the task is completed,
            // a stale non-done local push never reopens it.
            if server.taskStatus == StudyTaskStatus.done.rawValue {
                merged.taskStatus = StudyTaskStatus.done.rawValue
                if let completedAt = server.taskCompletedAt {
                    merged.taskCompletedAt = completedAt
                }
            }
        case .transcriptCorrection:
            // The user's newer intent (clientUpdatedAt on the push) wins;
            // the conflict-copy semantics live in the repository's pull
            // apply (newer modifiedAt wins, loser preserved locally).
            // Rebase keeps the local texts; only a completely empty local
            // correction falls back to the server's so a rebase never
            // blanks the user's edit layer.
            if (merged.correctionRussian ?? "").isEmpty,
               let serverRussian = server.correctionRussian {
                merged.correctionRussian = serverRussian
            }
            if merged.correctionChinese == nil, let serverChinese = server.correctionChinese {
                merged.correctionChinese = serverChinese
            }
            if merged.correctionModifiedAt == nil, let serverModified = server.correctionModifiedAt {
                merged.correctionModifiedAt = serverModified
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
