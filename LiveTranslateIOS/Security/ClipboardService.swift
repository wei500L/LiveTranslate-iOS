import Foundation
import SwiftUI
import UIKit
import OSLog

/// The single path every copy takes (round 17). Views never touch
/// UIPasteboard directly.
///
/// Policy:
///   - ALL copies are local-only (no Cross-Device Handoff of copied
///     content — it stays on this iPhone);
///   - SENSITIVE copies (translations, Russian replies, OCR/document
///     text, full transcripts) expire from the clipboard after 2
///     minutes — via the system's own expirationDate, NOT a timer that
///     could clobber whatever the user copied next;
///   - PLAIN copies (non-sensitive phrases) stay local-only with no
///     expiry — an explicit, documented difference;
///   - copies are never logged, never analyzed, never synced;
///   - the clipboard is never READ (paste is the system's business).
///
/// Active clearing (used by the privacy center's manual action and
/// available to tests) is changeCount-guarded: it only clears when the
/// current clipboard contents are still OURS — a later copy by the user
/// or another app is never wiped by us.
@MainActor
@Observable
final class ClipboardService {
    static let shared = ClipboardService()

    private static let logger = Logger(
        subsystem: "com.livetranslate.ios", category: "clipboard"
    )

    /// How long a sensitive copy stays on the clipboard.
    static let sensitiveExpiration: TimeInterval = 2 * 60

    /// What the copy sites show (root-level toast) — the honest
    /// "kept briefly on THIS device" hint.
    private(set) var notice: String?
    private var noticeTask: Task<Void, Never>?

    /// The changeCount of the last copy THIS service made (nil = none).
    private var lastCopyChangeCount: Int?

    private init() {}

    enum Policy: Equatable, Sendable {
        /// Translations / Russian replies / OCR / document text /
        /// full transcripts: expires after 2 minutes.
        case sensitive
        /// Non-sensitive phrases: local-only, no expiration.
        case plain
    }

    /// Copies text under the given policy. Returns the user-facing hint
    /// text (also published to `notice` for the root toast).
    ///
    /// API note: the `localOnly` / `expirationDate` PROPERTIES were
    /// removed from the iOS 26 SDK — `setObjects(_:localOnly:
    /// expirationDate:)` is the (only) supported way to write with those
    /// options. String bridges to NSString (NSItemProviderWriting), so
    /// plain text rides it directly and `pasteboard.string` still reads
    /// back.
    @discardableResult
    func copy(_ text: String, policy: Policy) -> String? {
        let trimmed = text
        guard !trimmed.isEmpty else { return nil }
        let pasteboard = UIPasteboard.general
        let expiration: Date?
        if case .sensitive = policy {
            expiration = Date().addingTimeInterval(Self.sensitiveExpiration)
        } else {
            // A plain copy explicitly outlives the sensitive window.
            expiration = nil
        }
        pasteboard.setObjects(
            [trimmed], localOnly: true, expirationDate: expiration
        )
        lastCopyChangeCount = pasteboard.changeCount

        switch policy {
        case .sensitive:
            let hint = String(localized: "已复制，将在本机剪贴板中短暂保留（2 分钟）")
            publishNotice(hint)
            return hint
        case .plain:
            let hint = String(localized: "已复制（仅本机）")
            publishNotice(hint)
            return hint
        }
    }

    /// Convenience for the classic one-liner call sites.
    @discardableResult
    func copySensitive(_ text: String) -> String? {
        copy(text, policy: .sensitive)
    }

    /// Manual clear (privacy-center action): wipes the clipboard ONLY
    /// when its current contents are still the ones WE wrote — a newer
    /// copy from the user or another app is never touched.
    @discardableResult
    func clearIfStillOurs() -> Bool {
        let pasteboard = UIPasteboard.general
        guard let lastCopyChangeCount,
              pasteboard.changeCount == lastCopyChangeCount else {
            return false
        }
        pasteboard.string = nil
        self.lastCopyChangeCount = nil
        Self.logger.info("clipboard cleared (still ours)")
        return true
    }

    /// Whether the current clipboard contents are still ours (changeCount
    /// unchanged since our last copy). Read-only probe — no content read.
    var clipboardStillOurs: Bool {
        guard let lastCopyChangeCount else { return false }
        return UIPasteboard.general.changeCount == lastCopyChangeCount
    }

    private func publishNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}

// MARK: - Copy-notice toast (root + live-classroom layers)

/// Shows the honest copy hint ("已复制，将在本机剪贴板中短暂保留").
/// Applied per presentation layer (root view + live-classroom cover) —
/// the same pattern as the privacy shield.
struct ClipboardToastModifier: ViewModifier {
    @State private var service = ClipboardService.shared

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let notice = service.notice {
                Text(notice)
                    .font(LTTypography.caption)
                    .foregroundStyle(LTColors.textPrimary)
                    .padding(.horizontal, LTSpacing.m)
                    .padding(.vertical, LTSpacing.s)
                    .background(
                        Capsule().fill(LTColors.surfaceElevated)
                    )
                    .overlay(
                        Capsule().stroke(LTColors.separator, lineWidth: 1)
                    )
                    .padding(.bottom, LTSpacing.xl)
                    .transition(.opacity)
                    .accessibilityLabel(notice)
            }
        }
        .animation(.easeOut(duration: 0.2), value: service.notice)
    }
}

extension View {
    /// Copy-notice toast — attach to every top-level presentation layer.
    func clipboardToast() -> some View {
        modifier(ClipboardToastModifier())
    }
}
