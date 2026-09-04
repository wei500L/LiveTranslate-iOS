import SwiftUI
import UIKit

// Share Extension principal view controller.
//
// Scope (deliberately tiny): read the system share, stage it into the
// App Group inbox, show real progress, hand control back. NO SwiftData,
// no model/AI/OCR, no network, no course picker — the main app's inbox
// screen does the organizing.
//
// Reliability policy: staging starts as soon as the extension appears
// (content the user already chose to share must not be lost), each item
// commits independently, and 取消 only skips items that have not finished
// receiving — committed items stay in the inbox (they are already safe
// on disk).

@objc(ShareViewController)
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.05, green: 0.06, blue: 0.07, alpha: 1)

        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        let host = UIHostingController(
            rootView: ShareReceiveView(
                items: items,
                onFinish: { [weak self] in
                    self?.finish()
                },
                onCancel: { [weak self] in
                    self?.finish()
                }
            )
        )
        addChild(host)
        host.view.backgroundColor = .clear
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}

// MARK: - Receive UI (self-contained; never imports the main app)

private struct ShareReceiveView: View {
    @State private var receiver = ShareInboxReceiver(store: SharedInboxStore())
    @State private var outcome: ShareInboxReceiver.Outcome?

    let items: [NSExtensionItem]
    let onFinish: () -> Void
    let onCancel: () -> Void

    private var isReceiving: Bool { outcome == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            if isReceiving, receiver.progress.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(.white.opacity(0.7))
                    Text("正在读取分享内容…")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.75))
                }
            }

            // Per-item rows with REAL states (receiving / done / failed).
            ForEach(Array(receiver.progress.enumerated()), id: \.offset) { _, item in
                row(item)
            }

            if let outcome {
                summary(outcome)
            }

            Spacer(minLength: 0)

            buttons
        }
        .padding(24)
        .frame(width: 420, height: 420, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(red: 0.11, green: 0.12, blue: 0.14))
                .shadow(radius: 24)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // Receiving (staging + manifest commit) starts immediately —
            // real progress drives the rows above.
            outcome = await receiver.receive(items: items)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(Color(red: 0.30, green: 0.85, blue: 0.55))
            VStack(alignment: .leading, spacing: 2) {
                Text("LiveTranslate")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(isReceiving ? "正在接收分享内容" : "已存入收件箱")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
            }
            Spacer()
        }
    }

    private func row(_ item: ShareInboxReceiver.ItemProgress) -> some View {
        HStack(spacing: 10) {
            switch item.state {
            case .receiving:
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.7))
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color(red: 0.30, green: 0.85, blue: 0.55))
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.yellow)
            }
            Text(item.label)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if case .failed(let reason) = item.state {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.yellow.opacity(0.9))
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func summary(_ outcome: ShareInboxReceiver.Outcome) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("已接收 \(outcome.received) 项，稍后在 LiveTranslate 中整理")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
            if !outcome.failed.isEmpty {
                Text("\(outcome.failed.count) 项接收失败")
                    .font(.caption)
                    .foregroundStyle(.yellow)
            }
            if outcome.skipped > 0 {
                Text("单次最多 \(SharedInboxStore.maxItemsPerShare) 项，已跳过 \(outcome.skipped) 项")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.06))
        )
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            Button(action: onCancel) {
                Text("取消")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Capsule().fill(Color.white.opacity(0.10)))
            }
            Button(action: onFinish) {
                Text(isReceiving ? "收下并完成" : "完成")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.black.opacity(0.85))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(
                        Capsule().fill(Color(red: 0.30, green: 0.85, blue: 0.55))
                    )
            }
        }
    }
}
