import Combine
import Foundation

#if os(tvOS)
    import FakeWebKit
#else
    import WebKit
#endif

enum CloudflareBypassError: Error {
    case timeout
}

@MainActor
final class CloudflareBypassManager: ObservableObject {
    static let shared = CloudflareBypassManager()
    private init() {}

    /// Non-nil while a Turnstile challenge is in progress — drives the bypass sheet.
    @Published var activeBypassWebView: WKWebView? = nil

    private struct CachedBypass {
        let value: String
        let cookieHeader: String
        let expires: Date
    }

    private var cache: [String: CachedBypass] = [:]

    // Kept alive after solving so we can extract cookies + UA for the URLSession retry.
    private var bypassWebViews: [String: WKWebView] = [:]

    func cookie(for host: String) -> String? {
        guard let entry = cache[host], entry.expires > Date() else {
            cache.removeValue(forKey: host)
            return nil
        }
        return entry.value
    }

    /// Returns the full cookie header (all bypass session cookies) cached at solve time.
    func fullCookieHeader(for host: String) -> String? {
        guard let entry = cache[host], entry.expires > Date() else { return nil }
        return entry.cookieHeader
    }

    func store(cookie: String, cookieHeader: String, for host: String) {
        cache[host] = CachedBypass(value: cookie, cookieHeader: cookieHeader, expires: Date().addingTimeInterval(3600))
    }

    /// Returns all cookies for `host` from the bypass store as a Cookie header string,
    /// plus the actual User-Agent the bypass WKWebView used when it solved the challenge.
    /// Used by fetchv2 to retry CF-protected requests with the correct session identity.
    func bypassSessionInfo(for host: String) async -> (cookieHeader: String, userAgent: String)? {
        guard let webView = bypassWebViews[host] else { return nil }

        let allCookies: [HTTPCookie] = await withCheckedContinuation { cont in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                cont.resume(returning: cookies)
            }
        }

        let hostCookies = allCookies.filter {
            let domain = $0.domain.hasPrefix(".") ? String($0.domain.dropFirst()) : $0.domain
            return host == domain || host.hasSuffix("." + domain)
        }
        let cookieHeader = hostCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")

        let ua = (try? await webView.evaluateJavaScript("navigator.userAgent") as? String) ?? ""

        guard !cookieHeader.isEmpty else { return nil }
        return (cookieHeader, ua)
    }

    /// Presents a WKWebView sheet so the user can complete the Turnstile challenge.
    /// Polls up to 30 s for `cf_clearance` to appear, then throws `.timeout`.
    func triggerBypass(for url: URL) async throws {
        guard let host = url.host else { return }
        if cookie(for: host) != nil { return }

        let webView = makeBypassWebView()
        let rootUrl = URL(string: "\(url.scheme ?? "https")://\(host)/") ?? url
        Logger.shared.log("[CFBypass] Loading \(rootUrl) for host \(host)", type: "Debug")
        webView.load(URLRequest(url: rootUrl))

        activeBypassWebView = webView
        defer { activeBypassWebView = nil }

        // 60 polls × 500 ms = 30 s
        for i in 0..<60 {
            try await Task.sleep(nanoseconds: 500_000_000)
            guard activeBypassWebView != nil else { return }  // user cancelled
            if let value = await cfClearanceCookie(for: host, in: webView) {
                let fullHeader = await allCookiesHeader(for: host, in: webView)
                Logger.shared.log("[CFBypass] Got cf_clearance for \(host) after \(i + 1) polls, cookies=\(fullHeader.prefix(120))", type: "Debug")
                store(cookie: value, cookieHeader: fullHeader, for: host)
                bypassWebViews[host] = webView
                return
            }
        }
        Logger.shared.log("[CFBypass] Timeout waiting for cf_clearance for \(host)", type: "Error")
        throw CloudflareBypassError.timeout
    }

    func cancelActiveBypass() {
        activeBypassWebView = nil
    }

    // MARK: - Private

    private func makeBypassWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        // Isolated store so cookies from other WKWebViews don't contaminate the cf_clearance poll.
        config.websiteDataStore = .nonPersistent()

        // No anti-bot script and no custom UA — Turnstile fingerprints the real browser to
        // verify it's legitimate. Modifying navigator/screen/window properties causes CF to
        // reject the challenge even after the user taps, because the fingerprint looks spoofed.

        // Frame is set by the caller (full-screen on iOS, zero on macOS)
        let wv = WKWebView(frame: .zero, configuration: config)
        return wv
    }

    private func allCookiesHeader(for host: String, in webView: WKWebView) async -> String {
        return await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let hostCookies = cookies.filter {
                    let domain = $0.domain.hasPrefix(".") ? String($0.domain.dropFirst()) : $0.domain
                    return host == domain || host.hasSuffix("." + domain)
                }
                let header = hostCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                continuation.resume(returning: header)
            }
        }
    }

    private func cfClearanceCookie(for host: String, in webView: WKWebView) async -> String? {
        return await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let hostCookies = cookies.filter {
                    let domain = $0.domain.hasPrefix(".") ? String($0.domain.dropFirst()) : $0.domain
                    return host == domain || host.hasSuffix("." + domain)
                }
                if !hostCookies.isEmpty {
                    let names = hostCookies.map(\.name).joined(separator: ", ")
                    Logger.shared.log("[CFBypass] Cookies for \(host): \(names)", type: "Debug")
                }
                let value = hostCookies.first(where: { $0.name == "cf_clearance" })?.value
                continuation.resume(returning: value)
            }
        }
    }
}
