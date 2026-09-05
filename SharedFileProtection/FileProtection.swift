import Foundation
import OSLog

// Shared file-protection kit — compiled into the main app AND the Share
// Extension (both write App Group inbox files; the extension stages
// payloads in-process and must apply protection at write time, not wait
// for the app's reconcile). Foundation + OSLog only: no SwiftData, no
// UIKit, no networking — extension-safe.
//
// On-disk data protection — the single source of truth for what
// protection class and backup behavior every persistent location gets.
//
// Three protection tiers drive the mapping (see docs/PRIVACY.md):
//
//   Secrets            → the Keychain (KeychainStore), never plain files;
//   Sensitive content  → `.complete` (unreadable while the device is
//                        locked): interpreter documents (证件/PDF/OCR),
//                        the shared inbox, regenerable caches, temporary
//                        exports;
//   Working data       → `.completeUntilFirstUserAuthentication`: the
//                        SwiftData store + WAL/SHM, the sync outbox,
//                        classroom recordings and the ASR model files —
//                        all of them MUST stay writable/readable while a
//                        classroom keeps running in the locked background
//                        (background audio + the 45 s sync loop + on-demand
//                        model loading), and synced originals may be
//                        re-downloaded by a background sync pass.
//
// The mapping is deliberately NOT one global level: a single `.complete`
// everywhere would break the locked-background classroom (writes to the
// store/outbox/raw.wav and reads of model files would fail), and a single
// "until first unlock" everywhere would leave passport scans readable on
// a locked device. Both failure modes are real, so the matrix is explicit.
//
// Backup policy: regenerable caches (thumbnails, preview/analysis copies,
// waveforms, model downloads, the shared-inbox tmp dir and temporary
// exports) are excluded from device/iCloud backup; so are interpreter
// document originals — they are device-local BY DESIGN (never synced,
// never uploaded) and the retention policy treats them as ephemeral.
// Formal user records (the SwiftData store, attachments, materials,
// recordings, inbox items) stay in backups: they are the only copy on a
// guest device and the safety net for every account.
//
// What this file does NOT claim: data protection is not encryption at
// rest against an unlocked device, and it is not end-to-end encryption
// toward the sync server. It only binds file access to the device lock
// state.

/// One protection class the app applies to a file or directory.
enum DataProtectionClass: String, Sendable, CaseIterable {
    /// SwiftData store, WAL/SHM, sync outbox, classroom raw recordings —
    /// written while a classroom runs in the locked background.
    case classroomWorking
    /// Attachment/material originals: imported in the foreground, but a
    /// background sync pass may re-download them while locked.
    case syncedUserContent
    /// Interpreter (随身翻译) document originals, extraction sidecars and
    /// page thumbnails — read/written only on explicit foreground user
    /// actions, and never backed up (device-local by design).
    case sensitiveLocalDocument
    /// Regenerable caches: thumbnails, preview/analysis JPEGs, waveforms,
    /// compiled-model caches, the shared-inbox tmp dir.
    case regenerableCache
    /// ASR model files (downloads + compiled Core ML): regenerable, but
    /// READ by a background classroom while the device is locked.
    case modelFile
    /// Temporary exports staged for the system share sheet: deleted
    /// shortly after the share completes.
    case temporaryExport
    /// App Group system-surface files (widget snapshot, command/route
    /// queues): READ by the WidgetKit extension while the device is
    /// locked (lock-screen widgets), regenerable — excluded from backup.
    case systemSurface
    /// Shared-inbox manifest + committed item payloads: written by the
    /// Share Extension (device necessarily unlocked), read by foreground
    /// UI only. tmp/ under the same root uses `regenerableCache`.
    case sharedInboxItem

    /// The NSFileProtection level. Nil is never returned today — the
    /// switch is exhaustive so a future class must decide.
    var fileProtection: FileProtectionType {
        switch self {
        case .classroomWorking, .syncedUserContent, .modelFile,
             .systemSurface:
            return .completeUntilFirstUserAuthentication
        case .sensitiveLocalDocument, .regenerableCache,
             .temporaryExport, .sharedInboxItem:
            return .complete
        }
    }

    /// Whether locations of this class are excluded from device/iCloud
    /// backup.
    var excludesFromBackup: Bool {
        switch self {
        case .classroomWorking, .syncedUserContent, .sharedInboxItem:
            return false
        case .sensitiveLocalDocument, .regenerableCache, .modelFile,
             .temporaryExport, .systemSurface:
            return true
        }
    }
}

/// Applies protection attributes to real file-system URLs. All methods
/// are honest about failure: a failed attribute application is returned
/// (and logged by the caller that cares) — the file itself is NEVER
/// deleted or moved to "fix" a protection problem.
///
/// Concurrency: stateless; safe to call from any thread. Every operation
/// is idempotent so the launch reconcile can re-run freely.
enum FileProtection {
    /// Applies protection + backup exclusion to one file or directory.
    /// For directories the exclusion flag covers the subtree (Apple
    /// semantics); file protection still has to be set per file — new
    /// files inside a protected directory do NOT inherit it.
    /// Returns nil on success, or the error that occurred.
    @discardableResult
    static func apply(
        _ cls: DataProtectionClass, to url: URL
    ) -> Error? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            // Not an error: reconcile walks roots that may legitimately
            // not exist yet (a fresh account with no attachments).
            return nil
        }
        do {
            let attributes: [FileAttributeKey: Any] = [
                .protectionKey: cls.fileProtection
            ]
            try fm.setAttributes(attributes, ofItemAtPath: url.path)
            if cls.excludesFromBackup {
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                var target = url
                try target.setResourceValues(values)
            }
            return nil
        } catch {
            return error
        }
    }

    /// Convenience for store write paths: create (or reuse) a directory
    /// and immediately protect it. Creation failures propagate to the
    /// caller (a store that cannot create its root must say so, not
    /// silently degrade); attribute failures are reported, not thrown —
    /// the data itself is intact, only the lock-state binding is weaker.
    @discardableResult
    static func ensureDirectory(
        _ url: URL, class cls: DataProtectionClass
    ) throws -> Error? {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true
        )
        return apply(cls, to: url)
    }

    /// Writes data to `url` atomically WITH the protection applied to the
    /// final file in one step (the `.completeFileProtection` write option
    /// covers the temp file too, so the plaintext never exists at a
    /// weaker level). Backup exclusion is applied afterwards.
    static func write(
        _ data: Data, to url: URL, class cls: DataProtectionClass
    ) throws {
        var options: Data.WritingOptions = [.atomic]
        switch cls.fileProtection {
        case .complete:
            options.insert(.completeFileProtection)
        case .completeUntilFirstUserAuthentication:
            options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        default:
            break
        }
        try data.write(to: url, options: options)
        if let failure = apply(cls, to: url) {
            // The write itself succeeded; the attribute application is
            // reported through the same channel as reconcile failures
            // (never silently swallowed, never destructive).
            ProtectionFailureLog.record(failure, url: url)
        }
    }

    /// Launch-time reconcile: upgrade existing files under `root` to the
    /// class's attributes. Idempotent — files already carrying the right
    /// attributes are left untouched (no metadata churn), mismatches are
    /// upgraded, and failures NEVER delete or move the file. `matching`
    /// (optional) restricts the pass to files it accepts — one root can
    /// carry mixed renditions (originals vs caches) via separate passes.
    /// Returns the number of files whose attributes were actually changed
    /// and the failures that must be surfaced (diagnostics only).
    static func reconcile(
        root: URL, class cls: DataProtectionClass,
        matching: ((URL) -> Bool)? = nil,
        fileManager: FileManager = .default
    ) -> (upgraded: Int, failed: [(url: URL, error: Error)]) {
        guard
            let enumerator = fileManager.enumerator(
                at: root, includingPropertiesForKeys: [
                    .isDirectoryKey, .isRegularFileKey,
                    .fileProtectionKey, .isExcludedFromBackupKey,
                ]
            )
        else { return (0, []) }
        var upgraded = 0
        var failed: [(url: URL, error: Error)] = []
        while let next = enumerator.nextObject() {
            guard let url = next as? URL else { continue }
            guard
                let values = try? url.resourceValues(
                    forKeys: [.isDirectoryKey, .isRegularFileKey,
                              .isExcludedFromBackupKey]
                )
            else { continue }
            if let matching, !matching(url) {
                // The enumerator still descends into rejected
                // directories — files below may match a later pass.
                continue
            }
            // File protection is READ via FileManager attributes
            // (URLResourceValues exposes no property for it).
            let currentProtection = (try? fileManager.attributesOfItem(
                atPath: url.path
            )?[.protectionKey]) as? FileProtectionType
            let currentExcluded = values.isExcludedFromBackup ?? false
            let protectionMatches =
                currentProtection == cls.fileProtection
            let exclusionMatches = currentExcluded == cls.excludesFromBackup
            if protectionMatches && exclusionMatches { continue }
            if let error = apply(cls, to: url) {
                failed.append((url, error))
            } else {
                upgraded += 1
            }
        }
        return (upgraded, failed)
    }
}

/// Where attribute-application failures land. OSLog with a stable code —
/// never the file's contents, never user data (paths of app-container
/// locations only).
enum ProtectionFailureLog {
    private static let logger = Logger(
        subsystem: "com.livetranslate.ios", category: "file-protection"
    )

    static func record(_ error: Error, url: URL) {
        logger.error(
            "protection attribute failed: \(error.localizedDescription, privacy: .public)"
        )
    }
}
