import Foundation

/// Server endpoint configuration. The base URL comes from the
/// `CloudSyncServerURL` Info.plist key, which the build injects per
/// configuration (Debug → local/LAN server, Release → HTTPS domain) via
/// the `CLOUD_SYNC_SERVER_URL` xcconfig variable.
///
/// Release builds only accept `https://` base URLs. Plain-HTTP is a
/// Debug-only convenience for LAN development servers (ATS already
/// restricts plain HTTP to local networking in this app).
enum ServerConfiguration {
    static let infoPlistKey = "CloudSyncServerURL"

    /// Resolved base URL (e.g. `https://sync.example.com/v1`) or nil when
    /// the build provides none.
    static var baseURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String else {
            return nil
        }
        return normalized(raw)
    }

    /// True when a server is configured for this build.
    static var isConfigured: Bool { baseURL != nil }

    static func normalized(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "$(CLOUD_SYNC_SERVER_URL)" else { return nil }
        guard var components = URLComponents(string: trimmed) else { return nil }
        if components.scheme == nil {
            components.scheme = "https"
        }
        guard let url = components.url else { return nil }
        #if DEBUG
        return url
        #else
        guard url.scheme?.lowercased() == "https" else {
            assertionFailure("Release builds must use an HTTPS sync server")
            return nil
        }
        return url
        #endif
    }

    /// Stable per-install device identifier for the devices table. Stored
    /// in UserDefaults (it is not a secret; the Keychain is for tokens).
    static func clientDeviceId() -> String {
        let key = "cloudsync.clientDeviceId"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    static var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (s?, b?): return "\(s) (\(b))"
        case let (s?, nil): return s
        default: return "unknown"
        }
    }

    static var deviceDisplayName: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(String(UnicodeScalar(UInt8(value))))
        }
    }
}
