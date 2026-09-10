import Combine
import Foundation

#if os(tvOS)
    import FakeWebKit
    import CoreGraphics
#else
    import WebKit
#endif

enum CloudflareBypassError: Error {
    case timeout
}

extension Notification.Name {
    /// Posted (object = host String) when a Turnstile challenge is solved and a cookie cached.
    static let cloudflareBypassSolved = Notification.Name("CloudflareBypassSolved")
}

@MainActor
final class CloudflareBypassManager: ObservableObject {
    static let shared = CloudflareBypassManager()
    private init() { loadPersistedCache() }

    /// Non-nil while a Turnstile challenge is in progress — drives the bypass sheet.
    @Published var activeBypassWebView: WKWebView? = nil

    /// Set when a fetch hits a Turnstile wall but we have no cookie yet. Drives the
    /// "Verify Cloudflare" button in the stream picker instead of auto-popping the
    /// bypass window. Cleared at the start of each new stream load.
    @Published var pendingVerificationURL: URL? = nil

    /// Records that `url`'s host needs verification. Called only after a request actually
    /// hit a Turnstile wall — which means any cookie we sent was rejected, so we drop the
    /// stale cache entry (otherwise `cookie(for:)` keeps reporting it valid and both the
    /// flag and `triggerBypass` get skipped).
    func flagPendingVerification(for url: URL) {
        guard let host = url.host else { return }
        cache.removeValue(forKey: host)
        persistCache()
        pendingVerificationURL = url
    }

    private struct CachedBypass: Codable {
        let value: String
        let cookieHeader: String
        /// User-Agent the bypass WKWebView used when it solved the challenge. cf_clearance is
        /// bound to this UA, so it must be replayed on every request that reuses the cookie.
        let userAgent: String
        let expires: Date
    }

    private var cache: [String: CachedBypass] = [:]

    private enum Keys {
        static let persistedCache = "cloudflareBypassCache"
    }

    // Kept alive after solving so we can extract cookies + UA for the URLSession retry.
    private var bypassWebViews: [String: WKWebView] = [:]

    // Hosts currently being solved — dedupes concurrent callers (e.g. a grid of posters)
    // so only one bypass sheet appears per host instead of one per image.
    private var inProgressHosts: Set<String> = []

    func cookie(for host: String) -> String? {
        guard let entry = cache[host], entry.expires > Date() else {
            if cache.removeValue(forKey: host) != nil { persistCache() }
            return nil
        }
        return entry.value
    }

    /// Returns the full cookie header (all bypass session cookies) cached at solve time.
    func fullCookieHeader(for host: String) -> String? {
        guard let entry = cache[host], entry.expires > Date() else { return nil }
        return entry.cookieHeader
    }

    /// Returns the User-Agent the bypass session used when solving `host`'s challenge.
    /// cf_clearance is UA-bound, so callers that inject the cached cookie MUST also send
    /// this UA or Cloudflare rejects the cookie and re-walls the request. Survives restarts
    /// (unlike `bypassSessionInfo`, which reads from a live in-memory WKWebView).
    func bypassUserAgent(for host: String) -> String? {
        guard let entry = cache[host], entry.expires > Date(), !entry.userAgent.isEmpty else { return nil }
        return entry.userAgent
    }

    /// Drops the cached bypass for `host` without arming the user-facing "Verify Cloudflare"
    /// affordance. For callers that proved the cookie is dead (a request that still came back
    /// walled) but shouldn't hijack the stream picker's verification UI — a poster load is not
    /// a stream load. Also drops the live bypass WebView, whose jar holds the same dead cookie.
    func invalidateCookie(for host: String) {
        let hadEntry = cache.removeValue(forKey: host) != nil
        bypassWebViews.removeValue(forKey: host)
        if hadEntry { persistCache() }
    }

    func store(cookie: String, cookieHeader: String, userAgent: String = "", for host: String) {
        cache[host] = CachedBypass(
            value: cookie,
            cookieHeader: cookieHeader,
            userAgent: userAgent,
            expires: Date().addingTimeInterval(3600)
        )
        persistCache()
    }

    // MARK: - Persistence

    /// cf_clearance survives app restarts (it's valid ~30 min–hours server-side). We persist the
    /// cookie + UA + expiry so a relaunch within the hour reuses it instead of re-walling the user.
    private func persistCache() {
        let live = cache.filter { $0.value.expires > Date() }
        guard let data = try? JSONEncoder().encode(live) else { return }
        UserDefaults.standard.set(data, forKey: Keys.persistedCache)
    }

    private func loadPersistedCache() {
        guard let data = UserDefaults.standard.data(forKey: Keys.persistedCache),
              let decoded = try? JSONDecoder().decode([String: CachedBypass].self, from: data) else { return }
        cache = decoded.filter { $0.value.expires > Date() }
    }

    /// Returns all cookies for `host` from the bypass store as a Cookie header string,
    /// plus the actual User-Agent the bypass WKWebView used when it solved the challenge.
    /// Used by fetchv2 to retry CF-protected requests with the correct session identity.
    func bypassSessionInfo(for host: String) async -> (cookieHeader: String, userAgent: String)? {
        #if os(tvOS)
        return nil
        #else
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
        #endif
    }

    /// Retries `url` directly (so URLSession can't strip the Cookie on a cross-domain redirect)
    /// using whatever solved session we have: the live bypass WebView's cookies+UA, or a persisted
    /// cookie+UA after a relaunch. Returns the response only if it's genuinely past the wall — nil
    /// when we have no session or the session itself is walled, in which case the caller should
    /// prompt the user via `flagPendingVerification`. This is what lets a once-solved host keep
    /// working silently instead of re-popping the bypass sheet on every request.
    func retryWithSolvedSession(
        for url: URL,
        method: String,
        body: Data?,
        extraHeaders: [String: String],
        session: URLSession
    ) async -> (data: Data, response: HTTPURLResponse)? {
        guard let host = url.host else { return nil }

        let cookieHeader: String
        let userAgent: String
        if let info = await bypassSessionInfo(for: host) {
            cookieHeader = info.cookieHeader
            userAgent = info.userAgent
        } else if let header = fullCookieHeader(for: host) {
            cookieHeader = header
            userAgent = bypassUserAgent(for: host) ?? ""
        } else {
            return nil
        }
        guard !cookieHeader.isEmpty else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        for (key, val) in extraHeaders where key.lowercased() != "cookie" && key.lowercased() != "user-agent" {
            request.setValue(val, forHTTPHeaderField: key)
        }
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        if !userAgent.isEmpty {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }

        let text = String(data: data, encoding: .utf8) ?? ""
        if JSEngine.isTurnstileResponse(status: http.statusCode, body: text) {
            return nil  // the session itself is now walled — needs a fresh user solve
        }
        Logger.shared.log("[CFBypass] Recovered \(host) via solved session, status=\(http.statusCode)", type: "Debug")
        return (data, http)
    }

    // MARK: - Clearance verification

    /// What the bypass WebView saw when it re-requested the walled URL.
    struct ClearanceProbe {
        let status: Int
        let cfMitigated: String?
    }

    /// Whether a probe response means we're genuinely past the wall.
    ///
    /// Cloudflare puts a `cf_clearance` cookie in the jar the moment it *serves* a managed
    /// challenge — roughly a second in, long before the user has touched the Turnstile widget.
    /// (Verified against i.animepahe.pw: cookie present at t=1 s while every request still
    /// returns 403 `cf-mitigated: challenge` and the page reads "Performing security
    /// verification".) So the cookie's presence proves nothing; only a request that comes back
    /// unmitigated does. A non-2xx origin status is fine — a cleared host that 404s the exact
    /// poster path is still past Cloudflare.
    nonisolated static func probeIndicatesClearance(_ probe: ClearanceProbe) -> Bool {
        if let mitigated = probe.cfMitigated, !mitigated.isEmpty { return false }
        return probe.status != 403 && probe.status != 503
    }

    /// Re-requests `url` from inside the bypass WebView (same jar, same session) to find out
    /// whether the `cf_clearance` sitting in the jar is a real clearance or the placeholder CF
    /// sets alongside the challenge. Returns true when we can't probe at all — an unverifiable
    /// cookie is still worth trying, and blocking on it would break hosts that work today.
    private func clearanceIsUsable(for url: URL, in webView: WKWebView) async -> Bool {
        #if os(tvOS)
        return true
        #else
        let js = """
        const response = await fetch(target, { credentials: "include", cache: "no-store" });
        return JSON.stringify({
            status: response.status,
            mitigated: response.headers.get("cf-mitigated") || ""
        });
        """
        let raw: String?
        do {
            raw = try await webView.callAsyncJavaScript(
                js,
                arguments: ["target": url.absoluteString],
                contentWorld: .defaultClient
            ) as? String
        } catch {
            return true
        }
        guard let raw,
              let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? Int else { return true }
        return Self.probeIndicatesClearance(
            ClearanceProbe(status: status, cfMitigated: json["mitigated"] as? String)
        )
        #endif
    }

    /// Presents a WKWebView sheet so the user can complete the Turnstile challenge.
    /// Polls up to 90 s for a `cf_clearance` that a probe request confirms actually works,
    /// then throws `.timeout`. The window has to be long enough for a human to find and tap
    /// the Turnstile checkbox, since CF's cookie no longer tells us when they have.
    func triggerBypass(for url: URL) async throws {
        guard let host = url.host else { return }
        if HostBlocklist.shared.isBlocked(url) { return }
        if cookie(for: host) != nil { return }

        // Another caller is already solving this host — wait for it instead of opening a
        // second sheet, then fall through (the cookie will be cached on success).
        if inProgressHosts.contains(host) {
            for _ in 0..<120 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if !inProgressHosts.contains(host) { break }
            }
            return
        }
        inProgressHosts.insert(host)
        defer { inProgressHosts.remove(host) }

        let webView = makeBypassWebView()
        let rootUrl = URL(string: "\(url.scheme ?? "https")://\(host)/") ?? url
        Logger.shared.log("[CFBypass] Loading \(rootUrl) for host \(host)", type: "Debug")
        webView.load(URLRequest(url: rootUrl))

        activeBypassWebView = webView
        defer { activeBypassWebView = nil }

        // Throttles the probe below — it's a real network request against the walled host,
        // and the cookie shows up within a second, so an unthrottled probe would fire on
        // every one of the 500 ms polls.
        var lastProbe = Date.distantPast
        var loggedUnsolved = false

        // 180 polls × 500 ms = 90 s
        for i in 0..<180 {
            try await Task.sleep(nanoseconds: 500_000_000)
            guard activeBypassWebView != nil else { return }  // user cancelled
            if let value = await cfClearanceCookie(for: host, in: webView) {
                guard Date().timeIntervalSince(lastProbe) >= 2 else { continue }
                lastProbe = Date()
                guard await clearanceIsUsable(for: url, in: webView) else {
                    if !loggedUnsolved {
                        loggedUnsolved = true
                        Logger.shared.log(
                            "[CFBypass] \(host) has a cf_clearance but requests are still walled — challenge not solved yet",
                            type: "Debug"
                        )
                    }
                    continue
                }
                let fullHeader = await allCookiesHeader(for: host, in: webView)
                let ua = (try? await webView.evaluateJavaScript("navigator.userAgent") as? String) ?? ""
                // Log the cookie *names* only. The header's values include the live cf_clearance
                // session token, and these logs are written to logs.txt and exported from
                // Settings → App Logs — which is exactly what users paste into bug reports.
                let cookieNames = fullHeader
                    .split(separator: ";")
                    .compactMap { $0.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) }
                    .joined(separator: ",")
                Logger.shared.log("[CFBypass] Got cf_clearance for \(host) after \(i + 1) polls, cookies=[\(cookieNames)]", type: "Debug")
                store(cookie: value, cookieHeader: fullHeader, userAgent: ua, for: host)
                bypassWebViews[host] = webView
                if pendingVerificationURL?.host == host { pendingVerificationURL = nil }
                // Let any placeholder'd images on this host retry now that we have a cookie.
                NotificationCenter.default.post(name: .cloudflareBypassSolved, object: host)
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
        #if !os(tvOS)
        config.websiteDataStore = .nonPersistent()
        #endif

        // No anti-bot script and no custom UA — Turnstile fingerprints the real browser to
        // verify it's legitimate. Modifying navigator/screen/window properties causes CF to
        // reject the challenge even after the user taps, because the fingerprint looks spoofed.

        // Frame is set by the caller (full-screen on iOS, zero on macOS)
        let wv = WKWebView(frame: .zero, configuration: config)
        return wv
    }

    private func allCookiesHeader(for host: String, in webView: WKWebView) async -> String {
        #if os(tvOS)
        return ""
        #else
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
        #endif
    }

    private func cfClearanceCookie(for host: String, in webView: WKWebView) async -> String? {
        #if os(tvOS)
        return nil
        #else
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
        #endif
    }
}
