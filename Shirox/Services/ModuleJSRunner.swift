import Foundation
import Combine

#if os(tvOS)
    import FakeWebKit
#else
    import WebKit
#endif

@preconcurrency import JavaScriptCore

/// A short-lived, standalone JS runner for a single module.
/// Creates its own JSContext so it never interferes with JSEngine.shared.
@MainActor
final class ModuleJSRunner {

    private var context: JSContext?
    private var module: ModuleDefinition?

    /// The show a Seanime streaming provider's search is for — set by the anime page's picker.
    var seanimeMedia: SeanimeSearchMedia?

    /// Set when a request made by *this* runner hit a Turnstile wall with no cached cookie.
    /// Host-scoped to this module, so the picker only offers verification for the module
    /// that's actually Cloudflare-protected (not every visible module).
    var lastTurnstileURL: URL?

    // Ephemeral config gives each runner its own isolated cookie store so bypass
    // cookies from search persist through to fetchEpisodes without bleeding into
    // other runners or being wiped by HTTPCookieStorage.shared clears.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        return URLSession(configuration: config)
    }()

    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    // MARK: - Load module

    func load(module: ModuleDefinition) async throws {
        // Clear WKWebView cookies (used by networkFetch/extractStreamUrl) for isolation.
        // HTTPCookieStorage.shared is NOT cleared — the ephemeral URLSession has its own
        // isolated store, so bypass cookies from earlier calls in this runner persist.
        NetworkFetchManager.clearCookies()

        let script: String
        if let cached = module.scriptContent {
            script = cached
        } else {
            guard let url = URL(string: module.scriptUrl) else {
                throw URLError(.badURL)
            }
            let (data, _) = try await session.data(from: url)
            guard let fetched = String(data: data, encoding: .utf8) else {
                throw URLError(.cannotDecodeContentData)
            }
            script = fetched
        }
        
        let ctx = JSContext.forModule()
        setupContext(ctx)
        SeanimeScripts.prepare(ctx, module: module)
        ExtensionScripts.prepare(ctx, module: module)
        ctx.evaluateScript(script)
        ExtensionScripts.finish(ctx, module: module)
        if let exception = ctx.exception {
            Logger.shared.log("[ModuleJSRunner] Script load error: \(exception)", type: "Error")
        }
        self.context = ctx
        self.module = module
    }

    // MARK: - Search

    func search(keyword: String) async throws -> [SearchItem] {
        if module?.seanime != nil, let context { SeanimeScripts.setSearchMedia(seanimeMedia, in: context) }
        if module?.ext != nil, let context {
            // The anime page's show, with the TMDB/IMDb ids and season Stremio and Nuvio look up.
            let media: ExtensionSearchMedia?
            if let seanimeMedia { media = await ExtensionSearchMedia.resolve(seanimeMedia) } else { media = nil }
            ExtensionScripts.setSearchMedia(media, in: context)
        }
        let json = try await callAsyncJS("searchResults", args: [keyword])
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw JSEngineError.parseError("Could not parse search results")
        }
        ModuleWebLinks.shared.record(array, moduleId: module?.id)
        return array.compactMap { item in
            guard let title = item["title"] as? String,
                  let image = item["image"] as? String,
                  let href = item["href"] as? String else { return nil }
            return SearchItem(title: title, image: image, href: href)
        }
    }

    // MARK: - Episodes

    func fetchEpisodes(url: String) async throws -> [EpisodeLink] {
        let json = try await callAsyncJS("extractEpisodes", args: [url])
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw JSEngineError.parseError("Could not parse episodes")
        }
        let links = array.compactMap { item -> EpisodeLink? in
            guard let href = item["href"] as? String else { return nil }
            let number: Double
            if let n = item["number"] as? Double { number = n }
            else if let n = item["number"] as? Int { number = Double(n) }
            else { number = 0 }
            return EpisodeLink(number: number, href: href)
        }
        // Logged so episode-number mismatches (the usual cause of "only ep 1 downloads"
        // on split-cour shows) are visible in Settings → App Logs.
        Logger.shared.log(
            "[Episodes] \(url) → \(links.count) eps numbers=[\(links.prefix(60).map { $0.number.truncatingRemainder(dividingBy: 1) == 0 ? String(Int($0.number)) : String($0.number) }.joined(separator: ","))]",
            type: "Download"
        )
        return links
    }

    // MARK: - Streams

    func fetchStreams(episodeUrl: String) async throws -> [StreamResult] {
        let json = try await callAsyncJS("extractStreamUrl", args: [episodeUrl])
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)

        if let url = URL(string: trimmed), url.scheme != nil, !trimmed.hasPrefix("{") {
            return [StreamResult(title: "Play", url: url, headers: [:])]
        }

        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JSEngineError.parseError("Could not parse stream result")
        }

        let streams = parseStreamResults(from: obj)
        // Extensions' scrapers list dead links and download pages alongside real streams.
        return module?.ext != nil ? await StreamProbe.playable(streams) : streams
    }

    // MARK: - Promise resolution

    private func callAsyncJS(_ functionName: String, args: [Any]) async throws -> String {
        guard let ctx = context else {
            throw JSEngineError.functionNotFound("context not loaded")
        }
        guard let fn = ctx.objectForKeyedSubscript(functionName), !fn.isUndefined else {
            throw JSEngineError.functionNotFound(functionName)
        }

        // Bounded and resume-once for the same reasons as JSEngine.callAsyncJS: an untrusted
        // module promise that never settles would otherwise suspend this continuation forever,
        // and a thenable that fires both callbacks would resume it twice and trap.
        let gate = ContinuationGate()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                gate.attach(cont)
                let promise = fn.call(withArguments: args)
                guard let promise, !promise.isUndefined, !promise.isNull else {
                    gate.settle(.failure(JSEngineError.nullResult))
                    return
                }

                // Synchronous module functions return a plain value rather than a Promise.
                // JSEngine handles this; without the same guard here, invoking .then on a
                // non-thenable threw inside JS and neither callback ever fired — so every
                // caller of this runner (batch download, sequel resolution, the download
                // module pickers) hung forever on modules that return a raw URL string.
                let thenValue = promise.objectForKeyedSubscript("then")
                if thenValue == nil || thenValue?.isUndefined == true {
                    gate.settle(.success(promise.toString() ?? ""))
                    return
                }

                let thenBlock: @convention(block) (JSValue) -> Void = { result in
                    gate.settle(.success(result.toString() ?? ""))
                }
                let catchBlock: @convention(block) (JSValue) -> Void = { error in
                    gate.settle(.failure(JSEngineError.jsError(error.toString() ?? "Unknown JS error")))
                }

                let thenFn = JSValue(object: thenBlock, in: ctx)
                let catchFn = JSValue(object: catchBlock, in: ctx)
                promise.invokeMethod("then", withArguments: [thenFn as Any])
                promise.invokeMethod("catch", withArguments: [catchFn as Any])

                DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
                    gate.settle(.failure(JSEngineError.timedOut(functionName)))
                }
            }
        } onCancel: {
            gate.settle(.failure(CancellationError()))
        }
    }

    // MARK: - Context setup (mirrors JSEngine.setupContext)

    private func setupContext(_ ctx: JSContext) {
        setupConsole(ctx)
        setupBase64(ctx)
        setupFetchV2(ctx)
        setupFetchAliases(ctx)
        setupSoraCompat(ctx)
        setupScrapingUtilities(ctx)
        setupTimers(ctx)
        ctx.setupNetworkFetch()
        ctx.setupNetworkFetchSimple()

        ctx.exceptionHandler = { _, exception in
            Logger.shared.log("[ModuleJSRunner JS] \(exception?.toString() ?? "unknown")", type: "Error")
        }
    }

    private func setupConsole(_ ctx: JSContext) {
        let log: @convention(block) (JSValue) -> Void = {
            Logger.shared.log("[JS] \($0.toString() ?? "")", type: "Debug")
        }
        let err: @convention(block) (JSValue) -> Void = {
            Logger.shared.log("[JS Error] \($0.toString() ?? "")", type: "Error")
        }
        let warn: @convention(block) (JSValue) -> Void = {
            Logger.shared.log("[JS Warn] \($0.toString() ?? "")", type: "General")
        }
        let console = JSValue(newObjectIn: ctx)!
        console.setObject(log, forKeyedSubscript: "log" as NSString)
        console.setObject(err, forKeyedSubscript: "error" as NSString)
        console.setObject(warn, forKeyedSubscript: "warn" as NSString)
        console.setObject(log, forKeyedSubscript: "debug" as NSString)
        ctx.setObject(console, forKeyedSubscript: "console" as NSString)
    }

    private func setupBase64(_ ctx: JSContext) {
        let btoa: @convention(block) (String) -> String = { Data($0.utf8).base64EncodedString() }
        let atob: @convention(block) (String) -> String = { input in
            guard let data = Data(base64Encoded: input) else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
        ctx.setObject(btoa, forKeyedSubscript: "btoa" as NSString)
        ctx.setObject(atob, forKeyedSubscript: "atob" as NSString)
    }

    private func setupFetchV2(_ ctx: JSContext) {
        let fetchNative: @convention(block) (String, JSValue, JSValue, JSValue, JSValue, JSValue, JSValue) -> Void =
        { [weak self] urlString, headersVal, methodVal, bodyVal, extraVal, resolve, reject in
            guard let self else {
                reject.call(withArguments: ["ModuleJSRunner deallocated"])
                return
            }
            guard let url = URL(string: urlString) else {
                reject.call(withArguments: ["Invalid URL: \(urlString)"])
                return
            }
            if HostBlocklist.shared.isBlocked(url) {
                reject.call(withArguments: ["Blocked host: \(url.host ?? urlString)"])
                return
            }

            let method = (methodVal.isNull || methodVal.isUndefined) ? "GET" : (methodVal.toString() ?? "GET")
            let body: String? = (bodyVal.isNull || bodyVal.isUndefined) ? nil : bodyVal.toString()
            var jsHeaders: [String: String] = [:]
            if !headersVal.isUndefined, !headersVal.isNull {
                if let dict = headersVal.toDictionary() as? [String: String] {
                    jsHeaders = dict
                }
            }

            var impersonateTarget: BrowserTarget? = nil
            var useWebView = false

            if !extraVal.isUndefined && !extraVal.isNull {
                if extraVal.isBoolean {
                    if extraVal.toBool() { impersonateTarget = .auto }
                } else if extraVal.isString {
                    let str = extraVal.toString()?.lowercased()
                    if str == "webview" {
                        useWebView = true
                    } else if let target = BrowserTarget(rawValue: str ?? "") {
                        impersonateTarget = target
                    } else {
                        impersonateTarget = .auto
                    }
                } else if extraVal.isObject {
                    let dict = extraVal.toDictionary()
                    if let impVal = dict?["impersonate"] {
                        if let boolVal = impVal as? Bool, boolVal {
                            impersonateTarget = .auto
                        } else if let strVal = impVal as? String {
                            let low = strVal.lowercased()
                            if low == "webview" {
                                useWebView = true
                            } else if let target = BrowserTarget(rawValue: low) {
                                impersonateTarget = target
                            } else {
                                impersonateTarget = .auto
                            }
                        }
                    }
                    if let engine = dict?["engine"] as? String, engine.lowercased() == "webview" {
                        useWebView = true
                    }
                }
            }

            if impersonateTarget == nil && !useWebView {
                if let imp = jsHeaders["impersonate"] {
                    jsHeaders.removeValue(forKey: "impersonate")
                    if imp.lowercased() == "webview" {
                        useWebView = true
                    } else if let target = BrowserTarget(rawValue: imp.lowercased()) {
                        impersonateTarget = target
                    } else {
                        impersonateTarget = .auto
                    }
                }
            }

            if useWebView {
                Task {
                    do {
                        let (data, status, headersDict, finalURL) = try await WebKitFetchEngine.shared.fetch(
                            url: url,
                            method: method,
                            headers: jsHeaders,
                            body: body
                        )
                        let responseText = String(data: data, encoding: .utf8) ?? ""
                        let responseObj = ctx.makeFetchResponse(
                            status: status, statusText: nil, url: finalURL, headers: headersDict, body: responseText
                        )

                        resolve.call(withArguments: [responseObj])
                    } catch {
                        reject.call(withArguments: [error.localizedDescription])
                    }
                }
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue(self.userAgent, forHTTPHeaderField: "User-Agent")

            if let impersonateTarget {
                BrowserImpersonator.apply(to: &request, target: impersonateTarget, customHeaders: jsHeaders)
            } else {
                for (key, value) in jsHeaders {
                    request.setValue(value, forHTTPHeaderField: key)
                }
            }

            if let body, let bodyData = body.data(using: .utf8) {
                request.httpBody = bodyData
            }

            Task {
                do {
                    // CF cookie injection — use full cookie header (matches JSEngine behaviour)
                    if let host = url.host,
                       let cfHeader = CloudflareBypassManager.shared.fullCookieHeader(for: host) {
                        let existing = request.value(forHTTPHeaderField: "Cookie") ?? ""
                        request.setValue(
                            existing.isEmpty ? cfHeader : "\(existing); \(cfHeader)",
                            forHTTPHeaderField: "Cookie"
                        )
                        // cf_clearance is UA-bound — replay the solving UA so CF accepts the cookie.
                        if let ua = CloudflareBypassManager.shared.bypassUserAgent(for: host) {
                            request.setValue(ua, forHTTPHeaderField: "User-Agent")
                        }
                    }

                    var (data, response) = try await self.session.data(for: request)
                    guard var httpResponse = response as? HTTPURLResponse else {
                        reject.call(withArguments: ["No response data"])
                        return
                    }
                    var responseText = String(data: data, encoding: .utf8) ?? ""

                    // CF reactive retry: bypass the final redirect destination, retry directly against it
                    if JSEngine.isTurnstileResponse(status: httpResponse.statusCode, body: responseText) {
                        let cfResponseURL = httpResponse.url ?? url
                        let recovered = await CloudflareBypassManager.shared.retryWithSolvedSession(
                            for: cfResponseURL,
                            method: request.httpMethod ?? "GET",
                            body: request.httpBody,
                            extraHeaders: request.allHTTPHeaderFields ?? [:],
                            session: self.session
                        )
                        if let recovered {
                            data = recovered.data
                            httpResponse = recovered.response
                            responseText = String(data: recovered.data, encoding: .utf8) ?? ""
                        } else {
                            self.lastTurnstileURL = cfResponseURL
                            await CloudflareBypassManager.shared.flagPendingVerification(for: cfResponseURL)
                        }
                    }

                    let status = httpResponse.statusCode
                    var headersDict: [String: String] = [:]
                    for (key, value) in httpResponse.allHeaderFields {
                        headersDict[String(describing: key)] = String(describing: value)
                    }

                    let responseObj = ctx.makeFetchResponse(
                        status: status,
                        statusText: HTTPURLResponse.localizedString(forStatusCode: status),
                        url: httpResponse.url?.absoluteString ?? urlString,
                        headers: headersDict,
                        body: responseText
                    )

                    resolve.call(withArguments: [responseObj])
                } catch {
                    reject.call(withArguments: [error.localizedDescription])
                }
            }
        }

        ctx.setObject(fetchNative, forKeyedSubscript: "fetchv2Native" as NSString)
        ctx.evaluateScript("""
        function fetchv2(url, headers, method, body, extra) {
            var h = headers || {};
            var m = method || 'GET';
            var b = body || null;
            var opt = extra || null;

            if (typeof headers === 'boolean' || typeof headers === 'string') {
                opt = { impersonate: headers };
                h = {};
            } else if (typeof headers === 'object' && headers !== null && (headers.method || headers.headers || headers.body || headers.impersonate !== undefined || headers.engine !== undefined)) {
                h = headers.headers || {};
                m = headers.method || (typeof method === 'string' ? method : 'GET');
                b = headers.body || (typeof body === 'string' ? body : null);
                opt = headers;
            } else if (typeof extra === 'boolean') {
                opt = { impersonate: extra };
            } else if (typeof method === 'boolean') {
                opt = { impersonate: method };
                m = 'GET';
            } else if (typeof body === 'boolean') {
                opt = { impersonate: body };
                b = null;
            }

            return new Promise(function(resolve, reject) {
                fetchv2Native(url, h, m, b, opt || {}, resolve, reject);
            });
        }
        """)
    }

    /// Bridges `fetch` and `soraFetch` to `fetchv2`, properly unwrapping the
    /// Sora-style options object `{ headers, method, body }` into the positional
    /// arguments that `fetchv2` expects.
    ///
    /// `fetch` holds Shirox's own `soraFetch` and `fetchv2`, not the globals of those names: a
    /// module that defines its own `soraFetch` and falls back to `fetch` on a failure (HydraHD)
    /// otherwise bounced between the two forever on a host that kept failing — one request per
    /// bounce, ~1,700 a second, for as long as the runner lived.
    private func setupFetchAliases(_ ctx: JSContext) {
        ctx.evaluateScript("""
        (function(global) {
            var shiroxFetchV2 = global.fetchv2;
            function shiroxSoraFetch(url, options) {
                var headers = {}, method = 'GET', body = null, extra = null;
                if (options && typeof options === 'object') {
                    headers = options.headers || {};
                    method  = options.method  || 'GET';
                    body    = options.body    || null;
                    extra   = options;
                }
                return shiroxFetchV2(url, headers, method, body, extra);
            }
            global.soraFetch = shiroxSoraFetch;
            global.fetch = function(url, options) {
                return shiroxSoraFetch(url, options);
            };
        })(this);
        """)
    }

    /// Injects Sora-specific compatibility shims expected by some modules:
    ///   • `_0xB4F2` — module validation function; must return a 16-char string
    ///     whose lowercase form contains every letter in "cranci" (including both c's).
    ///   • `sendLog` — no-op logger fallback in case modules call it before
    ///     the module script defines its own version.
    private func setupSoraCompat(_ ctx: JSContext) {
        // 16-char string that satisfies _0x7E9A's cranci-character check
        let validationToken = "shirox-cranci-10"  // length=16, contains c,r,a,n,c,i
        let tokenBlock: @convention(block) () -> String = { validationToken }
        ctx.setObject(tokenBlock, forKeyedSubscript: "_0xB4F2" as NSString)

        // Fallback sendLog so early calls before module defines its own don't throw
        ctx.evaluateScript("""
        if (typeof sendLog === 'undefined') {
            function sendLog(msg) { console.log('[Module] ' + msg); }
        }
        """)
    }

    private func setupTimers(_ ctx: JSContext) {
        var timerMap: [Int: DispatchWorkItem] = [:]
        var nextId = 1

        let setTimeoutBlock: @convention(block) (JSValue, Double) -> Int = { callback, delay in
            let id = nextId
            nextId += 1
            let item = DispatchWorkItem {
                timerMap.removeValue(forKey: id)
                callback.call(withArguments: [])
            }
            timerMap[id] = item
            DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0) / 1000.0, execute: item)
            return id
        }

        let clearTimeoutBlock: @convention(block) (Int) -> Void = { id in
            timerMap[id]?.cancel()
            timerMap.removeValue(forKey: id)
        }

        let setIntervalBlock: @convention(block) (JSValue, Double) -> Int = { callback, delay in
            let id = nextId
            nextId += 1
            let interval = max(delay, 16) / 1000.0
            func schedule() {
                guard timerMap[id] != nil else { return }
                let item = DispatchWorkItem {
                    guard timerMap[id] != nil else { return }
                    callback.call(withArguments: [])
                    schedule()
                }
                timerMap[id] = item
                DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: item)
            }
            timerMap[id] = DispatchWorkItem {}
            schedule()
            return id
        }

        ctx.setObject(setTimeoutBlock, forKeyedSubscript: "setTimeout" as NSString)
        ctx.setObject(clearTimeoutBlock, forKeyedSubscript: "clearTimeout" as NSString)
        ctx.setObject(setIntervalBlock, forKeyedSubscript: "setInterval" as NSString)
        ctx.setObject(clearTimeoutBlock, forKeyedSubscript: "clearInterval" as NSString)
    }

    private func setupScrapingUtilities(_ ctx: JSContext) {
        ctx.evaluateScript("""
        function getElementsByTag(html, tag) {
            var regex = new RegExp('<' + tag + '[^>]*>([\\\\s\\\\S]*?)</' + tag + '>', 'gi');
            var matches = [], match;
            while ((match = regex.exec(html)) !== null) { matches.push(match[0]); }
            return matches;
        }
        function getAttribute(element, attr) {
            var regex = new RegExp(attr + '=[\"\\'](.+?)[\"\\']');
            var match = element.match(regex);
            return match ? match[1] : '';
        }
        function getInnerText(element) { return element.replace(/<[^>]*>/g, '').trim(); }
        function stripHtml(html) { return html.replace(/<[^>]*>/g, ''); }
        """)
    }
}
