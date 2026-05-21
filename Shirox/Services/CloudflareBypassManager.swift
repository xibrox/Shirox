import WebKit

enum CloudflareBypassError: Error {
    case timeout
}

@MainActor
final class CloudflareBypassManager {
    static let shared = CloudflareBypassManager()
    private init() {}

    private struct CachedBypass {
        let value: String
        let expires: Date
    }

    private var cache: [String: CachedBypass] = [:]

    func cookie(for host: String) -> String? {
        guard let entry = cache[host], entry.expires > Date() else {
            cache.removeValue(forKey: host)
            return nil
        }
        return entry.value
    }

    func store(cookie: String, for host: String) {
        cache[host] = CachedBypass(value: cookie, expires: Date().addingTimeInterval(3600))
    }

    /// Loads `url` in a hidden WKWebView and waits up to 15 s for `cf_clearance` to appear.
    /// The WKWebView uses `WKWebsiteDataStore.default()` so it shares cookies with NetworkFetchMonitor.
    func triggerBypass(for url: URL) async throws {
        guard let host = url.host else { return }

        // Reuse cached cookie if still valid
        if cookie(for: host) != nil { return }

        let webView = makeHiddenWebView()
        webView.load(URLRequest(url: url))

        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            if let value = await cfClearanceCookie(for: host, in: webView) {
                store(cookie: value, for: host)
                return
            }
        }
        throw CloudflareBypassError.timeout
    }

    // MARK: - Private

    private func makeHiddenWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        // WKWebViewConfiguration uses WKWebsiteDataStore.default() by default — shared with NetworkFetchMonitor
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        return wv
    }

    private func cfClearanceCookie(for host: String, in webView: WKWebView) async -> String? {
        return await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let value = cookies.first(where: { $0.name == "cf_clearance" && $0.domain.contains(host) })?.value
                continuation.resume(returning: value)
            }
        }
    }
}
