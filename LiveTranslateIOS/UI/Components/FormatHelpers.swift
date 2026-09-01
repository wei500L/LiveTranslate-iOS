import Foundation

/// Shared formatting helpers for all screens.
enum Format {
    static func bytes(_ value: Int) -> String {
        guard value > 0 else { return "0 MB" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(value))
    }

    /// mm:ss, or h:mm:ss past the hour mark.
    static func clock(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    static func seconds(_ interval: TimeInterval) -> String {
        String(format: "%.2f s", interval)
    }

    static func percent(_ fraction: Double) -> String {
        Int((fraction * 100).rounded()).description + "%"
    }

    static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
