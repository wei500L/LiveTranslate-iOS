import Foundation
import OSLog

/// Controlled temporary-export lifecycle (round 17): every file staged
/// for the system share sheet lives HERE — a dedicated directory with a
/// manifest, protected and reaped. No exporter writes loose files into
/// tmp/ anymore.
///
/// Lifecycle contract:
///   - created in `tmp/LiveTranslateExports/` (system-purgeable
///     territory, isolated from user data directories);
///   - `.complete` file protection + excluded from backup (share
///     payloads are transcript/document content);
///   - file names NEVER carry emails, account UUIDs or passport numbers
///     (the exporters' suggestedFileName rules already sanitize);
///   - the system share sheet gives NO reliable completion callback —
///     the manifest records an expiry (24 h) and the reap pass (every
///     launch + every staging) deletes what expired. Files still within
///     their window are NEVER deleted while a share may be open;
///   - nothing is ever deleted outside this directory — formal user
///     files (materials, attachments, recordings) are untouched;
///   - the manifest carries file names + timestamps + byte counts only —
///     no content, no absolute paths in logs.
struct TemporaryExportStore: Sendable {
    private static let logger = Logger(
        subsystem: "com.livetranslate.ios", category: "temporary-exports"
    )

    /// Exports older than this are reaped (a share sheet left open
    /// overnight is over; the system's own tmp purge is the backstop).
    static let retention: TimeInterval = 24 * 3600

    /// Directory name inside the app's tmp/.
    static let directoryName = "LiveTranslateExports"

    let root: URL

    /// The production store (the app's tmp directory).
    init() {
        self.root = FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.directoryName, isDirectory: true)
        Self.prepare(root: root)
    }

    /// Test/demo store with a throwaway root.
    init(root: URL) {
        self.root = root
        Self.prepare(root: root)
    }

    // MARK: - Manifest

    struct Entry: Codable, Sendable, Equatable {
        var id: UUID
        /// File name INSIDE the store (never an absolute path).
        var fileName: String
        var createdAt: Date
        var expiresAt: Date
        var byteCount: Int64
    }

    private var manifestURL: URL {
        root.appendingPathComponent("manifest.json")
    }

    private func loadManifest() -> [Entry] {
        guard let data = try? Data(contentsOf: manifestURL),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return entries
    }

    private func saveManifest(_ entries: [Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        let tmp = manifestURL.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: manifestURL.path) {
                _ = try FileManager.default.replaceItemAt(manifestURL, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: manifestURL)
            }
            FileProtection.apply(.temporaryExport, to: manifestURL)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            // Non-fatal: a lost manifest row means the file reaps on the
            // next full sweep instead of at its expiry.
        }
    }

    private static func prepare(root: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        FileProtection.apply(.temporaryExport, to: root)
    }

    // MARK: - Staging

    /// Writes one export file and records it. Returns the URL to hand to
    /// the share sheet (the file is NOT deleted before its expiry — a
    /// share in flight keeps working).
    func stage(fileName: String, data: Data) throws -> URL {
        try stage(fileName: fileName) { url in
            try data.write(to: url, options: [.atomic, .completeFileProtection])
        }
    }

    /// Creates one export DIRECTORY (multi-file shares: document +
    /// image copies) and records it. `populate` writes inside it.
    func stageDirectory(
        fileName: String, populate: (URL) throws -> Void
    ) throws -> URL {
        try stage(fileName: fileName, populate: populate)
    }

    private func stage(
        fileName: String, populate: (URL) throws -> Void
    ) throws -> URL {
        reap()
        // Unique name: a repeated export of the same session within a
        // minute must not silently replace a file still open in a share
        // sheet (the SessionExport convention).
        var url = root.appendingPathComponent(fileName)
        var counter = 2
        let stem = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        while FileManager.default.fileExists(atPath: url.path) {
            let suffix = ext.isEmpty ? "\(counter)" : "\(counter).\(ext)"
            url = root.appendingPathComponent("\(stem)-\(suffix)")
            counter += 1
        }
        try populate(url)
        FileProtection.apply(.temporaryExport, to: url)

        var entries = loadManifest()
        let byteCount: Int64 = {
            guard let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
            ) else { return 0 }
            var total: Int64 = 0
            for case let file as URL in enumerator {
                guard let values = try? file.resourceValues(
                    forKeys: [.fileSizeKey, .isRegularFileKey]
                ), values.isRegularFile == true, let size = values.fileSize else {
                    continue
                }
                total += Int64(size)
            }
            return total
        }()
        entries.append(Entry(
            id: UUID(),
            fileName: url.lastPathComponent,
            createdAt: .now,
            expiresAt: Date().addingTimeInterval(Self.retention),
            byteCount: byteCount
        ))
        saveManifest(entries)
        return url
    }

    // MARK: - Reaping

    /// Deletes EXPIRED entries (files + manifest rows). Idempotent; a
    /// failed file deletion keeps the row so the next pass retries — a
    /// reaped-but-alive file is reported, never silently leaked.
    @discardableResult
    func reap(asOf now: Date = .now) -> Int {
        var entries = loadManifest()
        var removed = 0
        var kept: [Entry] = []
        let fm = FileManager.default
        for entry in entries {
            guard entry.expiresAt <= now else {
                kept.append(entry)
                continue
            }
            let url = root.appendingPathComponent(entry.fileName)
            if fm.fileExists(atPath: url.path) {
                do {
                    try fm.removeItem(at: url)
                    removed += 1
                } catch {
                    // Deletion failed (file busy?) — keep the row, retry
                    // on the next pass. NEVER ignore-and-drop.
                    kept.append(entry)
                    Self.logger.error(
                        "export reap failed: \(entry.fileName, privacy: .public)"
                    )
                }
            } else {
                // Already gone (system tmp purge) — drop the row.
                removed += 1
            }
        }
        if kept.count != entries.count {
            entries = kept
            saveManifest(entries)
        }
        return removed
    }

    /// One-time legacy cleanup: exports written by pre-round-17 builds
    /// sit LOOSE in tmp/ (some with the LiveTranslate- prefix, some —
    /// learning/benchmark exports — with no prefix at all). Only the
    /// identifiable prefix pattern is reaped; the store directory itself
    /// is excluded (it has its own manifest).
    @discardableResult
    static func reapLegacyLooseFiles(
        olderThan cutoff: Date = Date().addingTimeInterval(-retention)
    ) -> Int {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        guard let contents = try? fm.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return 0 }
        var removed = 0
        for url in contents {
            guard url.lastPathComponent.hasPrefix("LiveTranslate-"),
                  url.lastPathComponent != directoryName else { continue }
            guard let modified = try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate, modified < cutoff else { continue }
            if (try? fm.removeItem(at: url)) != nil {
                removed += 1
            }
        }
        return removed
    }

    /// Manual "clear now" (privacy center): reaps EVERYTHING in the
    /// store regardless of expiry. The user asked; files outside this
    /// directory are untouched.
    @discardableResult
    func reapAll() -> Int {
        let fm = FileManager.default
        let entries = loadManifest()
        var removed = 0
        for entry in entries {
            let url = root.appendingPathComponent(entry.fileName)
            if fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: url)
                removed += 1
            }
        }
        saveManifest([])
        return removed
    }

    // MARK: - Storage stats (privacy center)

    /// Total bytes under the store (files only).
    func totalBytes() -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            ), values.isRegularFile == true, let size = values.fileSize else {
                continue
            }
            total += Int64(size)
        }
        return total
    }

    var entryCount: Int {
        loadManifest().count
    }
}
