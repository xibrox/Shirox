import WebKit
#if os(iOS)
import UIKit
#endif

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

    // Shared across all bypass attempts so the WebKit process accumulates state
    // that looks more like a real browser to CF's fingerprinting.
    private static let sharedProcessPool = WKProcessPool()

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

    /// Loads the host root in a hidden WKWebView attached to the key window so CF's
    /// challenge JS can execute. Polls up to 15 s for `cf_clearance` to appear.
    func triggerBypass(for url: URL) async throws {
        guard let host = url.host else { return }
        if cookie(for: host) != nil { return }

        let webView = makeHiddenWebView()

        #if os(iOS)
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        keyWindow?.addSubview(webView)
        defer { webView.removeFromSuperview() }
        #endif

        let rootUrl = URL(string: "\(url.scheme ?? "https")://\(host)/") ?? url
        Logger.shared.log("[CFBypass] Loading \(rootUrl) for host \(host)", type: "Debug")
        webView.load(URLRequest(url: rootUrl))

        for i in 0..<30 {
            try await Task.sleep(nanoseconds: 500_000_000)
            if let value = await cfClearanceCookie(for: host, in: webView) {
                Logger.shared.log("[CFBypass] Got cf_clearance for \(host) after \(i + 1) polls", type: "Debug")
                store(cookie: value, for: host)
                return
            }
        }
        Logger.shared.log("[CFBypass] Timeout waiting for cf_clearance for \(host)", type: "Error")
        throw CloudflareBypassError.timeout
    }

    // MARK: - Private

    private func makeHiddenWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        // Shared process pool gives the WebKit process accumulated state across bypass calls.
        config.processPool = Self.sharedProcessPool
        // Isolated store so cookies from other WKWebViews (e.g. module fetches) don't
        // appear here and confuse the cf_clearance poll.
        config.websiteDataStore = .nonPersistent()

        let antiBot = """
        (function() {
            // Automation flag
            Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
            try { delete navigator.__proto__.webdriver; } catch(e) {}

            // Realistic plugin list (empty array is a bot signal)
            Object.defineProperty(navigator, 'plugins', {
                get: () => [
                    { name: 'PDF Viewer', filename: 'mhjfbmdgcfjbbpaeojofohoefgiehjai', description: 'Portable Document Format', length: 1 },
                    { name: 'Chrome PDF Viewer', filename: 'mhjfbmdgcfjbbpaeojofohoefgiehjai', description: '', length: 1 },
                    { name: 'Chromium PDF Viewer', filename: 'mhjfbmdgcfjbbpaeojofohoefgiehjai', description: '', length: 1 },
                    { name: 'Microsoft Edge PDF Viewer', filename: 'mhjfbmdgcfjbbpaeojofohoefgiehjai', description: '', length: 1 },
                    { name: 'WebKit built-in PDF', filename: 'webkit_pdf_viewer', description: '', length: 1 }
                ]
            });

            // Language
            Object.defineProperty(navigator, 'languages', { get: () => ['en-US', 'en'] });
            Object.defineProperty(navigator, 'language',  { get: () => 'en-US' });

            // Hardware properties typical for a real iPhone
            Object.defineProperty(navigator, 'deviceMemory',       { get: () => 4 });
            Object.defineProperty(navigator, 'hardwareConcurrency', { get: () => 6 });
            Object.defineProperty(navigator, 'maxTouchPoints',      { get: () => 5 });

            // Screen
            Object.defineProperty(screen, 'colorDepth', { get: () => 24 });
            Object.defineProperty(screen, 'pixelDepth',  { get: () => 24 });
            Object.defineProperty(window, 'devicePixelRatio', { get: () => 3 });

            // WKWebView exposes window.webkit — CF uses this to detect WebViews.
            // Wrap in try/catch because the native property may resist reassignment.
            try {
                Object.defineProperty(window, 'webkit', {
                    get: () => undefined,
                    configurable: true,
                    enumerable: false
                });
            } catch(e) {}

            // Minimal chrome shim so CF's Chrome-browser checks don't flag us
            window.chrome = { runtime: {}, loadTimes: function(){}, csi: function(){}, app: {} };

            // Notification API stub
            if (!window.Notification) {
                window.Notification = function(){};
                window.Notification.permission = 'default';
                window.Notification.requestPermission = function() { return Promise.resolve('default'); };
            }
        })();
        """
        config.userContentController.addUserScript(
            WKUserScript(source: antiBot, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )

        // iPhone 15 Pro Max dimensions — CF checks viewport/screen against UA
        let wv = WKWebView(frame: CGRect(x: -430, y: -932, width: 430, height: 932), configuration: config)
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
        return wv
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
