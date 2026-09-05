import Foundation
import OSLog

/// Launch-time reconcile of file-protection attributes over every
/// persistent root of the ACTIVE profile (plus the shared App Group
/// surfaces). Idempotent and non-destructive: files whose attributes
/// already match are untouched, mismatches are upgraded in place, and an
/// attribute failure NEVER deletes or moves the file — it is counted and
/// logged (stable code only, never content).
///
/// Why a reconcile pass at all: the write-time protection (round 17)
/// covers new files, but files written by earlier builds of the app carry
/// the system default. This pass upgrades them once per launch, off the
/// main actor (the walks can be large — models, thumbnails).
///
/// Scope: the ACTIVE profile's roots only. Other accounts' directories
/// are upgraded when their profile next becomes active; their files are
/// meanwhile protected by nothing less than what the previous app version
/// gave them (system default), which is the honest pre-round-17 baseline.
enum DataProtectionReconciler {
    private static let logger = Logger(
        subsystem: "com.livetranslate.ios", category: "file-protection"
    )

    /// Runs the full pass for one profile. Callers hand in the roots
    /// derived from AccountScope (single source of truth) so tests can
    /// pass throwaway directories.
    struct Roots {
        /// Directory holding the SwiftData store + outbox (account dir,
        /// or Application Support itself for the guest profile's global
        /// files).
        var storeRoot: URL
        var attachmentsRoot: URL
        var materialsRoot: URL
        var interpreterDocumentsRoot: URL
        var sessionsRoot: URL
        var modelsRoot: URL?

        static func forActiveProfile(accountID: UUID?) -> Roots {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!
            // The account directory holds the store/outbox directly; the
            // guest keeps its global files loose in Application Support.
            let storeRoot = accountID.map {
                AccountScope.accountDirectory(accountID: $0)
            } ?? support
            return Roots(
                storeRoot: storeRoot,
                attachmentsRoot: AccountScope.attachmentsRoot(accountID: accountID),
                materialsRoot: AccountScope.materialsRoot(accountID: accountID),
                interpreterDocumentsRoot: AccountScope.interpreterDocumentsRoot(
                    accountID: accountID
                ),
                sessionsRoot: SessionRecordings.rootDirectory,
                modelsRoot: try? ModelPaths.modelsRoot()
            )
        }
    }

    /// One reconcile run's outcome (surfaced in diagnostics only — the
    /// pass itself never blocks app startup).
    struct Outcome: Sendable {
        var upgradedFiles: Int = 0
        var failures: Int = 0
    }

    static func reconcile(_ roots: Roots) -> Outcome {
        var outcome = Outcome()

        func run(
            _ root: URL, _ cls: DataProtectionClass,
            matching: ((URL) -> Bool)? = nil,
            label: String
        ) {
            // Store-root special case: the whole account directory gets
            // the working class, but its Attachments/Materials/
            // InterpreterDocuments subdirectories carry their own classes
            // (reconciled separately below) — skip them here so the
            // weaker class never lands first.
            let result = FileProtection.reconcile(
                root: root, class: cls, matching: matching
            )
            outcome.upgradedFiles += result.upgraded
            outcome.failures += result.failed.count
            if !result.failed.isEmpty {
                logger.error(
                    "protection reconcile failures on \(label, privacy: .public): \(result.failed.count)"
                )
            }
        }

        // 1. Store + outbox (classroomWorking): everything directly in the
        //    store root, EXCEPT the subdirectories with their own classes.
        let ownSubtrees: Set<String> = [
            AccountScope.attachmentsDirectoryName,
            AccountScope.materialsDirectoryName,
            AccountScope.interpreterDocumentsDirectoryName,
        ]
        run(roots.storeRoot, .classroomWorking, label: "store") { url in
            guard url == roots.storeRoot else {
                return !ownSubtrees.contains(url.lastPathComponent)
            }
            return true
        }

        // 2. Attachments: originals keep working-class (synced content);
        //    preview/analysis JPEGs are regenerable caches.
        run(roots.attachmentsRoot, .syncedUserContent, label: "attachments") { url in
            url.lastPathComponent.hasPrefix("original.")
        }
        run(roots.attachmentsRoot, .regenerableCache, label: "attachments-cache") { url in
            let name = url.lastPathComponent
            return name == "preview.jpg" || name == "analysis.jpg"
        }

        // 3. Materials: same split (original.* vs page-*.jpg).
        run(roots.materialsRoot, .syncedUserContent, label: "materials") { url in
            url.lastPathComponent.hasPrefix("original.")
        }
        run(roots.materialsRoot, .regenerableCache, label: "materials-cache") { url in
            url.lastPathComponent.hasPrefix("page-")
        }

        // 4. Interpreter documents: the most sensitive tree — everything
        //    `.complete` + excluded from backup.
        run(roots.interpreterDocumentsRoot, .sensitiveLocalDocument, label: "interpreter-documents")

        // 5. Recordings: raw audio keeps working-class (written while the
        //    classroom runs locked); waveform caches are regenerable.
        run(roots.sessionsRoot, .classroomWorking, label: "sessions") { url in
            !url.lastPathComponent.hasSuffix(".\(RecordingWaveformStore.waveformFileExtension)")
        }
        run(roots.sessionsRoot, .regenerableCache, label: "sessions-waveform") { url in
            url.lastPathComponent.hasSuffix(".\(RecordingWaveformStore.waveformFileExtension)")
        }

        // 6. Model files (read by locked-background classrooms,
        //    re-downloadable).
        if let modelsRoot = roots.modelsRoot {
            run(modelsRoot, .modelFile, label: "models")
        }

        // 7. App Group system surfaces (snapshot, commands, routes) —
        //    read by the widget extension while locked, regenerable.
        if let groupRoot = SystemSnapshotStore.containerURL {
            run(groupRoot, .systemSurface, label: "system-surfaces") { url in
                let name = url.lastPathComponent
                return url == groupRoot
                    || name.hasPrefix("SystemSnapshot")
                    || name.hasPrefix("SystemCommands")
                    || name.hasPrefix("SystemRoutes")
            }

            // 8. Shared inbox: committed items + manifest `.complete`;
            //    the tmp staging area is a regenerable cache.
            let inboxRoot = groupRoot.appendingPathComponent("SharedInbox", isDirectory: true)
            let inboxTmp = inboxRoot.appendingPathComponent("tmp", isDirectory: true)
                .standardizedFileURL.path
            run(inboxRoot, .sharedInboxItem, label: "inbox") { url in
                !url.standardizedFileURL.path.hasPrefix(inboxTmp)
            }
            run(inboxRoot, .regenerableCache, label: "inbox-tmp") { url in
                url.standardizedFileURL.path.hasPrefix(inboxTmp)
            }
        }

        if outcome.upgradedFiles > 0 {
            logger.info(
                "protection reconcile upgraded \(outcome.upgradedFiles) entries"
            )
        }
        return outcome
    }

    /// Convenience for the app launch path: reconciles the active
    /// profile's roots off the main actor.
    @MainActor
    static func reconcileActiveProfile(accountID: UUID?) {
        let roots = Roots.forActiveProfile(accountID: accountID)
        Task.detached(priority: .utility) {
            _ = reconcile(roots)
        }
    }
}
