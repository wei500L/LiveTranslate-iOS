import Foundation
import UIKit
import PDFKit
import CoreGraphics

/// Image preparation for visual-ask requests. ONE bounded pipeline for
/// every multimodal request (single image, crop region, multi-image
/// comparison, PDF page):
///
///     upright image (EXIF applied + attachment transform applied)
///     → optional normalized crop
///     → long-edge downscale
///     → JPEG re-encode (HEIC/PNG inputs become JPEG — the format
///       model endpoints accept universally)
///     → total-budget enforcement (quality/dimension fallback, then an
///       explicit error — never a silently-failing oversized request)
///
/// Nothing is written to disk: crop copies live for the request
/// lifecycle only; the original files are never touched.
enum VisualAskImagePipeline {
    /// How many images may ride one request (images AND pdf pages).
    static let maxEvidenceCount = 4
    /// Preferred long edge per image (matches the analysis.jpg budget —
    /// keeps formulas and small handwriting readable).
    static let preferredLongEdge: CGFloat = 2048
    /// Fallback long edge when the total budget is exceeded.
    static let fallbackLongEdge: CGFloat = 1600
    static let preferredQuality: CGFloat = 0.72
    static let fallbackQuality: CGFloat = 0.6
    /// Soft total budget for the base64 payloads (~9 MB of JPEG bytes).
    static let totalByteBudget: Int = 9_000_000
    /// Hard ceiling — beyond this the ask is refused with an explicit
    /// error instead of a doomed request.
    static let hardByteLimit: Int = 12_000_000

    enum PrepareError: LocalizedError, Equatable {
        case tooManyImages(Int)
        case emptyImage
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .tooManyImages(let limit):
                return "一次最多选择 \(limit) 张图片或页面。"
            case .emptyImage:
                return "图片无法读取，可能文件已损坏或被清理。"
            case .tooLarge:
                return "图片内容过大，请减少图片数量或缩小圈选范围后重试。"
            }
        }
    }

    /// One prepared request image.
    struct PreparedImage: Sendable, Equatable {
        let data: Data
        let label: String

        var payload: ModelImagePayload {
            ModelImagePayload(data: data, mimeType: "image/jpeg", label: label)
        }
    }

    /// One input to the pipeline: the raw image source plus the geometry
    /// to apply. `transform` is the attachment's non-destructive
    /// rotate/crop (identity for PDF pages and own-file materials);
    /// `crop` is the user's question-time selection, normalized in the
    /// DISPLAYED (upright) space — the same space the region editor and
    /// the stored evidence use.
    struct PrepareSource: Sendable {
        var source: VisualEvidenceImageSource
        var transform: AttachmentTransform = .identity
        var crop: NormalizedRect? = nil

        init(
            source: VisualEvidenceImageSource,
            transform: AttachmentTransform = .identity,
            crop: NormalizedRect? = nil
        ) {
            self.source = source
            self.transform = transform
            self.crop = crop
        }
    }

    // MARK: - Upright rendering

    /// Decodes bytes into an upright UIImage (UIImage respects EXIF
    /// orientation on decode).
    private static func decode(_ data: Data) -> UIImage? {
        UIImage(data: data)
    }

    /// Applies the user's selection crop (normalized, upright space).
    private static func applyCrop(_ image: UIImage, crop: NormalizedRect?) -> UIImage {
        guard let crop, !crop.isFull else { return image }
        let clamped = crop.clamped()
        guard clamped.width > 0.01, clamped.height > 0.01 else { return image }
        guard let cgImage = image.cgImage else {
            // Alpha/EXIF-backed images without a direct CGImage go through
            // a renderer first.
            let renderer = UIGraphicsImageRenderer(size: image.size)
            let flat = renderer.image { _ in image.draw(at: .zero) }
            guard let flatCG = flat.cgImage else { return image }
            let px = flatCG.width, py = flatCG.height
            let rect = CGRect(
                x: clamped.x * CGFloat(px),
                y: clamped.y * CGFloat(py),
                width: clamped.width * CGFloat(px),
                height: clamped.height * CGFloat(py)
            ).integral.intersection(CGRect(x: 0, y: 0, width: px, height: py))
            guard rect.width > 4, rect.height > 4,
                  let cropped = flatCG.cropping(to: rect) else { return image }
            return UIImage(cgImage: cropped)
        }
        let px = cgImage.width, py = cgImage.height
        let rect = CGRect(
            x: clamped.x * CGFloat(px),
            y: clamped.y * CGFloat(py),
            width: clamped.width * CGFloat(px),
            height: clamped.height * CGFloat(py)
        ).integral.intersection(CGRect(x: 0, y: 0, width: px, height: py))
        guard rect.width > 4, rect.height > 4,
              let cropped = cgImage.cropping(to: rect) else { return image }
        return UIImage(cgImage: cropped)
    }

    /// Downscales so the long edge fits `maxEdge` (never upscales).
    private static func downscale(_ image: UIImage, maxEdge: CGFloat) -> UIImage {
        let longEdge = max(image.size.width, image.size.height)
        guard longEdge > maxEdge, longEdge > 0 else { return image }
        let scale = maxEdge / longEdge
        let target = CGSize(
            width: (image.size.width * scale).rounded(.down),
            height: (image.size.height * scale).rounded(.down)
        )
        guard target.width > 4, target.height > 4 else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// Rasterizes ONE PDF page (never the whole document) at the model
    /// budget.
    private static func renderPDFPage(url: URL, pageNumber: Int) -> UIImage? {
        guard let document = PDFDocument(url: url),
              pageNumber >= 1, pageNumber <= document.pageCount,
              let page = document.page(at: pageNumber - 1) else { return nil }
        let box = page.bounds(for: .mediaBox)
        let longEdge = max(box.width, box.height)
        guard longEdge > 0 else { return nil }
        let scale = preferredLongEdge / longEdge
        return page.thumbnail(
            of: CGSize(width: box.width * scale, height: box.height * scale),
            for: .mediaBox
        )
    }

    // MARK: - Entry points

    /// Prepares the ordered evidence list into bounded, labeled request
    /// images ("图片 1"…). Throws `tooManyImages`/`emptyImage`/`tooLarge`
    /// — callers surface the error; nothing is silently dropped.
    static func prepare(_ sources: [PrepareSource]) throws -> [PreparedImage] {
        guard sources.count <= maxEvidenceCount else {
            throw PrepareError.tooManyImages(maxEvidenceCount)
        }
        guard !sources.isEmpty else { return [] }

        // 1. Upright (EXIF + transform) + selection crop (per image;
        //    releases as we go).
        var uprights: [UIImage] = []
        for entry in sources {
            let image: UIImage?
            switch entry.source {
            case .imageData(let data):
                image = decode(data)
            case .pdfPage(let url, let pageNumber):
                image = renderPDFPage(url: url, pageNumber: pageNumber)
            }
            guard let image else { throw PrepareError.emptyImage }
            let transformed = AttachmentRender.applyTransform(
                image, transform: entry.transform
            )
            uprights.append(applyCrop(transformed, crop: entry.crop))
        }

        // 2. Encode with the preferred budget; fall back to smaller
        //    images when the TOTAL exceeds the soft budget; refuse past
        //    the hard ceiling.
        func encodeAll(maxEdge: CGFloat, quality: CGFloat) -> [Data] {
            var encoded: [Data] = []
            for image in uprights {
                let scaled = downscale(image, maxEdge: maxEdge)
                guard let jpeg = scaled.jpegData(compressionQuality: quality) else {
                    continue
                }
                encoded.append(jpeg)
            }
            return encoded
        }

        var encoded = encodeAll(maxEdge: preferredLongEdge, quality: preferredQuality)
        if encoded.count == uprights.count, encoded.reduce(0) { $0 + $1.count } > totalByteBudget {
            encoded = encodeAll(maxEdge: fallbackLongEdge, quality: fallbackQuality)
        }
        guard encoded.count == uprights.count else { throw PrepareError.emptyImage }
        let total = encoded.reduce(0) { $0 + $1.count }
        guard total <= hardByteLimit else { throw PrepareError.tooLarge }

        return encoded.enumerated().map { index, data in
            PreparedImage(data: data, label: "图片 \(index + 1)")
        }
    }
}
