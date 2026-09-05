import SwiftUI
import VisionKit

/// VisionKit document-scanner wrapper for 随身翻译's 现场文件 entry.
/// Multi-page scans return JPEG page data in order; a cancelled scan
/// returns nil — the caller creates NO document for a cancelled scan
/// (回到原会话，不产生空文档).
///
/// The scanner stops TTS before presenting (the audio-mutex protocol:
/// the same rule that stops TTS before the microphone starts).
struct DocumentScannerSheet: UIViewControllerRepresentable {
    let onResult: ([Data]?) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(
        _ uiViewController: VNDocumentCameraViewController, context: Context
    ) {}

    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onResult: ([Data]?) -> Void

        init(onResult: @escaping ([Data]?) -> Void) {
            self.onResult = onResult
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            // Pages in scan order; JPEG-encoded (the scanner returns
            // UIImage pages).
            var pages: [Data] = []
            for index in 0..<scan.pageCount {
                if let data = scan.imageOfPage(at: index).jpegData(compressionQuality: 0.85) {
                    pages.append(data)
                }
            }
            onResult(pages.isEmpty ? nil : pages)
        }

        func documentCameraViewControllerDidCancel(
            _ controller: VNDocumentCameraViewController
        ) {
            onResult(nil) // cancelled: no document
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            onResult(nil) // failed: honest failure path, no document
        }
    }
}
