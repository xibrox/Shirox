import Foundation

/// App-scoped blocklist of adult hosts. Enforced at every request chokepoint the app
/// controls (fetchv2 bridges, WKWebView scrapers, Cloudflare bypass, player). This is a
/// deliberate alternative to a system hosts file / DNS reconfiguration, which would be
/// system-wide.
final class HostBlocklist {
    nonisolated(unsafe) static let shared = HostBlocklist()

    private var hosts: Set<String> = []
    private(set) var isLoaded = false

    private init() {}

    // MARK: - Pure decision logic (testable)

    /// Parses a hosts-file (`0.0.0.0 host` / `127.0.0.1 host`) or bare-host list into a
    /// normalized lowercase set. Skips comments, blank lines, `localhost`, and tokens
    /// without a dot.
    static func parse(_ contents: String) -> Set<String> {
        var result = Set<String>()
        contents.enumerateLines { line, _ in
            var s = line
            if let hash = s.firstIndex(of: "#") { s = String(s[..<hash]) }
            s = s.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { return }
            let parts = s.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            let host = (parts.last ?? "").lowercased()
            guard !host.isEmpty, host != "localhost", host.contains(".") else { return }
            result.insert(host)
        }
        return result
    }

    /// True if `host` exactly matches, or is a subdomain of, any entry in `set`.
    /// Only checks suffixes with ≥2 labels so a stray bare-TLD entry can't over-block.
    static func isHostBlocked(_ host: String, in set: Set<String>) -> Bool {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return set.contains(host.lowercased()) }
        var i = 0
        while labels.count - i >= 2 {
            let candidate = labels[i...].joined(separator: ".")
            if set.contains(candidate) { return true }
            i += 1
        }
        return false
    }

    // MARK: - Instance API

    func isBlocked(_ url: URL) -> Bool {
        guard let host = url.host else { return false }
        return Self.isHostBlocked(host, in: hosts)
    }

    /// Loads the bundled snapshot once, off the main thread. Safe to call at launch.
    func loadIfNeeded() {
        guard !isLoaded else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let url = Bundle.main.url(forResource: "adult_hosts", withExtension: "txt"),
                  let contents = try? String(contentsOf: url, encoding: .utf8) else {
                DispatchQueue.main.async { self?.isLoaded = true }   // fail-open if missing
                return
            }
            let parsed = Self.parse(contents)
            DispatchQueue.main.async {
                self?.hosts = parsed
                self?.isLoaded = true
            }
        }
    }

    /// Test seam: injects a host set synchronously.
    static func loadForTesting(_ set: Set<String>) {
        shared.hosts = set
        shared.isLoaded = true
    }
}
