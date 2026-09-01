import SwiftUI
import UIKit

/// System share sheet wrapper. Callers export to a temporary file with
/// `TranscriptExporter.writeTemporaryFile` and share the URL.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
