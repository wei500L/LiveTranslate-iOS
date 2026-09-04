import Foundation

/// Resolves `VisualEvidence` against the live local stores (main actor).
/// One resolver shared by the ask pipeline, the answer cards and the
/// evidence pickers — every path agrees on what an evidence row points
/// at and whether it still exists. Deleted sources NEVER block history:
/// `sourceExists` answers false and the UI renders 原图片已不存在.
@MainActor
enum VisualAskEvidenceLoader {
    // MARK: - Existence

    /// Whether the evidence's source row still exists locally (the files
    /// may still be missing after a reclaim — image loading reports that
    /// separately).
    static func sourceExists(
        _ evidence: VisualEvidence,
        repository: any ClassroomRepositoryProtocol
    ) -> Bool {
        switch evidence.kind {
        case .sessionAttachment, .ocr, .analysis:
            return ((try? repository.attachment(id: evidence.sourceID)) ?? nil) != nil
        case .materialImage, .materialPage:
            return ((try? repository.material(id: evidence.materialID ?? evidence.sourceID)) ?? nil) != nil
        case .transcript:
            let sessions = (try? repository.sessions(matching: "")) ?? []
            return sessions.contains { $0.id == evidence.sourceID }
        case .note:
            return noteTitle(for: evidence, repository: repository) != nil
        }
    }

    // MARK: - Image loading (for model requests)

    /// Loads the raw image source for one image-kind evidence. Prefers
    /// the attachment's analysis rendition (EXIF already baked), falls
    /// back to the material's own bytes or the cached page thumbnail.
    /// Returns nil when the source is gone or unreadable.
    static func imageSource(
        for evidence: VisualEvidence,
        repository: any ClassroomRepositoryProtocol
    ) -> VisualAskImagePipeline.PrepareSource? {
        switch evidence.kind {
        case .sessionAttachment:
            guard let attachment = ((try? repository.attachment(id: evidence.sourceID)) ?? nil) else {
                return nil
            }
            let store = AttachmentFileStoreShared.store
            let data = store?.analysisData(for: attachment.id, sessionID: attachment.sessionID)
                ?? store?.previewOrOriginalData(
                    for: attachment.id, sessionID: attachment.sessionID
                )
            guard let data else { return nil }
            return VisualAskImagePipeline.PrepareSource(
                source: .imageData(data),
                transform: attachment.transform,
                crop: evidence.cropRect
            )
        case .materialImage:
            let materialID = evidence.materialID ?? evidence.sourceID
            guard let material = ((try? repository.material(id: materialID)) ?? nil) else {
                return nil
            }
            // Borrowed classroom image → the attachment's renditions.
            if let attachmentID = material.sourceAttachmentID,
               let attachment = ((try? repository.attachment(id: attachmentID)) ?? nil) {
                let store = AttachmentFileStoreShared.store
                let data = store?.analysisData(for: attachment.id, sessionID: attachment.sessionID)
                    ?? store?.previewOrOriginalData(
                        for: attachment.id, sessionID: attachment.sessionID
                    )
                guard let data else { return nil }
                return VisualAskImagePipeline.PrepareSource(
                    source: .imageData(data),
                    transform: attachment.transform,
                    crop: evidence.cropRect
                )
            }
            let store = MaterialFileStoreShared.store
            let ext = MaterialFileStore.fileExtension(
                fileName: material.originalFileName, mime: material.mimeType
            )
            if let data = store?.originalData(materialID: materialID, fileExtension: ext) {
                return VisualAskImagePipeline.PrepareSource(
                    source: .imageData(data), crop: evidence.cropRect
                )
            }
            // Own-file image materials keep no page thumbnail cache.
            return nil
        case .materialPage:
            let materialID = evidence.materialID ?? evidence.sourceID
            guard let material = ((try? repository.material(id: materialID)) ?? nil),
                  let pageNumber = evidence.pageNumber else { return nil }
            let store = MaterialFileStoreShared.store
            let ext = MaterialFileStore.fileExtension(
                fileName: material.originalFileName, mime: material.mimeType
            )
            if let store, store.originalExists(materialID: materialID, fileExtension: ext),
               let url = store.originalURL(materialID: materialID, fileExtension: ext) {
                return VisualAskImagePipeline.PrepareSource(
                    source: .pdfPage(url: url, pageNumber: pageNumber),
                    crop: evidence.cropRect
                )
            }
            // Original reclaimed/missing: the cached page thumbnail is
            // still a real local image (lower resolution, honestly used).
            if let data = store?.pageThumbnailData(materialID: materialID, pageNumber: pageNumber) {
                return VisualAskImagePipeline.PrepareSource(
                    source: .imageData(data), crop: evidence.cropRect
                )
            }
            return nil
        case .transcript, .note, .ocr, .analysis:
            return nil
        }
    }

    // MARK: - Existing text layers (prompt context)

    /// The existing local text layers (OCR + structured analysis) of the
    /// turn's attachment evidence — bounded, clearly labeled as
    /// machine-generated, may-be-wrong context.
    static func imageContextLines(
        for evidence: [VisualEvidence],
        repository: any ClassroomRepositoryProtocol
    ) -> [VisualAskPrompt.ImageContextLine] {
        var lines: [VisualAskPrompt.ImageContextLine] = []
        var imageNumber = 0
        for item in evidence where item.kind.isImageKind {
            imageNumber += 1
            guard let attachment = attachmentFor(item, repository: repository) else { continue }
            var parts: [String] = []
            if !attachment.ocrText.isEmpty {
                parts.append("OCR：" + String(attachment.ocrText.prefix(1_200)))
            }
            if let analysis = AttachmentAnalysisResult.decode(attachment.analysisJSON) {
                let analysisText = analysis.searchableText
                if !analysisText.isEmpty {
                    parts.append("图片理解：" + String(analysisText.prefix(1_200)))
                }
            }
            guard !parts.isEmpty else { continue }
            lines.append(VisualAskPrompt.ImageContextLine(
                imageNumber: imageNumber,
                title: attachment.title.isEmpty ? attachment.kind.displayName : attachment.title,
                text: parts.joined(separator: "\n")
            ))
        }
        return lines
    }

    /// The attachment behind an evidence row (direct attachment evidence
    /// or a material borrowing one).
    static func attachmentFor(
        _ evidence: VisualEvidence,
        repository: any ClassroomRepositoryProtocol
    ) -> SessionAttachment? {
        switch evidence.kind {
        case .sessionAttachment, .ocr, .analysis:
            return (try? repository.attachment(id: evidence.sourceID)) ?? nil
        case .materialImage:
            let materialID = evidence.materialID ?? evidence.sourceID
            guard let material = ((try? repository.material(id: materialID)) ?? nil),
                  let attachmentID = material.sourceAttachmentID else { return nil }
            return (try? repository.attachment(id: attachmentID)) ?? nil
        default:
            return nil
        }
    }

    // MARK: - Evidence builders (entry points)

    static func attachmentEvidence(_ attachment: SessionAttachment) -> VisualEvidence {
        let title = attachment.title.isEmpty
            ? "\(attachment.kind.displayName)"
            : attachment.title
        return VisualEvidence(
            kind: .sessionAttachment,
            sourceID: attachment.id,
            sessionID: attachment.sessionID,
            courseID: attachment.courseID,
            title: title
        )
    }

    static func materialImageEvidence(_ material: CourseMaterial) -> VisualEvidence {
        VisualEvidence(
            kind: .materialImage,
            sourceID: material.id,
            courseID: material.courseID,
            materialID: material.id,
            title: material.title.isEmpty ? material.originalFileName : material.title
        )
    }

    static func materialPageEvidence(
        _ material: CourseMaterial, pageNumber: Int
    ) -> VisualEvidence {
        VisualEvidence(
            kind: .materialPage,
            sourceID: material.id,
            courseID: material.courseID,
            materialID: material.id,
            pageNumber: pageNumber,
            title: material.title.isEmpty ? material.originalFileName : material.title
        )
    }

    // MARK: - Display helpers

    /// Live title for a text-context evidence (transcript/note).
    static func noteTitle(
        for evidence: VisualEvidence,
        repository: any ClassroomRepositoryProtocol
    ) -> String? {
        guard evidence.kind == .note, let sessionID = evidence.sessionID else { return nil }
        let notes = (try? repository.notes(forSessionID: sessionID)) ?? []
        return notes.first { $0.id == evidence.sourceID }?.text
    }

    /// Live session title (for transcript evidence / jump labels).
    static func sessionTitle(
        for evidence: VisualEvidence,
        repository: any ClassroomRepositoryProtocol
    ) -> String? {
        let sessions = (try? repository.sessions(matching: "")) ?? []
        return sessions.first { $0.id == evidence.sourceID }?.title
    }
}
