import Foundation
@preconcurrency import JavaScriptCore
import Combine

#if os(tvOS)
    import FakeWebKit
#else
    import WebKit
#endif


@MainActor
final class JSEngine: ObservableObject {
    static let shared = JSEngine()

    private(set) var context: JSContext
    /// The loaded module is a Stremio addon or a Nuvio, Vega or SkyStream provider.
    private(set) var loadedModuleIsExtension = false

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        return URLSession(configuration: config)
    }()

    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    private init() {
        context = JSContext.forModule()
        setupContext()
    }

    // MARK: - Module Loading

    func loadModule(_ module: ModuleDefinition) async throws {
        // Clear cookies so the previous module's session doesn't bleed into this one
        HTTPCookieStorage.shared.cookies?.forEach { HTTPCookieStorage.shared.deleteCookie($0) }
        NetworkFetchManager.clearCookies()

        let script: String
        if let cached = module.scriptContent {
            script = cached
        } else {
            guard let url = URL(string: module.scriptUrl) else {
                throw URLError(.badURL)
            }
            let (data, _) = try await session.decodedData(for: URLRequest(url: url))
            guard let fetched = String(data: data, encoding: .utf8) else {
                throw URLError(.cannotDecodeContentData)
            }
            script = fetched
        }

        // Fresh context for each module
        context = JSContext.forModule()
        setupContext()
        SeanimeScripts.prepare(context, module: module)
        ExtensionScripts.prepare(context, module: module)
        context.evaluateScript(script)
        ExtensionScripts.finish(context, module: module)
        loadedModuleIsExtension = module.ext != nil
        if let exception = context.exception {
            Logger.shared.log("[JSEngine] Script load error: \(exception)", type: "Error")
        }
    }

    // MARK: - Context Setup

    private func setupContext() {
        setupConsoleLogging()
        setupBase64()
        setupFetchV2()
        setupFetchAliases()
        setupSoraCompat()
        setupScrapingUtilities()
        setupMangaBridge()
        setupTimers()
        context.setupNetworkFetch()
        context.setupNetworkFetchSimple()

        context.exceptionHandler = { _, exception in
            Logger.shared.log("[JS Exception] \(exception?.toString() ?? "unknown")", type: "Error")
        }
    }

    // MARK: - Console Bridge

    private func setupConsoleLogging() {
        let consoleLog: @convention(block) (JSValue) -> Void = { value in
            Logger.shared.log("[JS] \(value.toString() ?? "undefined")", type: "Debug")
        }
        let consoleError: @convention(block) (JSValue) -> Void = { value in
            Logger.shared.log("[JS Error] \(value.toString() ?? "undefined")", type: "Error")
        }
        let consoleWarn: @convention(block) (JSValue) -> Void = { value in
            Logger.shared.log("[JS Warn] \(value.toString() ?? "undefined")", type: "General")
        }
        let consoleObj = JSValue(newObjectIn: context)!
        consoleObj.setObject(consoleLog, forKeyedSubscript: "log" as NSString)
        consoleObj.setObject(consoleError, forKeyedSubscript: "error" as NSString)
        consoleObj.setObject(consoleWarn, forKeyedSubscript: "warn" as NSString)
        consoleObj.setObject(consoleLog, forKeyedSubscript: "debug" as NSString)
        context.setObject(consoleObj, forKeyedSubscript: "console" as NSString)
    }

    // MARK: - Base64 Bridge

    private func setupBase64() {
        let btoa: @convention(block) (String) -> String = { input in
            Data(input.utf8).base64EncodedString()
        }
        let atob: @convention(block) (String) -> String = { input in
            guard let data = Data(base64Encoded: input) else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
        context.setObject(btoa, forKeyedSubscript: "btoa" as NSString)
        context.setObject(atob, forKeyedSubscript: "atob" as NSString)
    }

    // MARK: - fetchv2 Bridge

    private func setupFetchV2() {
        // The native function called from JS. It starts a URLSession task and calls
        // the resolve/reject callbacks when done. Supports optional extra/impersonate options.
        let fetchNative: @convention(block) (String, JSValue, JSValue, JSValue, JSValue, JSValue, JSValue) -> Void =
        { [weak self] urlString, headersVal, methodVal, bodyVal, extraVal, resolve, reject in
            guard let self else {
                reject.call(withArguments: ["JSEngine deallocated"])
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
            var jsHeaders = (!headersVal.isUndefined && !headersVal.isNull)
                ? (headersVal.toDictionary() as? [String: String] ?? [:])
                : [String: String]()

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

            let ctx = self.context

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
                    // CF cookie injection — inject all bypass session cookies, not just cf_clearance,
                    // because some APIs (e.g. AllAnime) require additional Turnstile session cookies.
                    if let host = url.host,
                       let bypassHeader = CloudflareBypassManager.shared.fullCookieHeader(for: host) {
                        let existing = request.value(forHTTPHeaderField: "Cookie") ?? ""
                        request.setValue(
                            existing.isEmpty ? bypassHeader : "\(existing); \(bypassHeader)",
                            forHTTPHeaderField: "Cookie"
                        )
                        // cf_clearance is UA-bound — replay the UA that solved the challenge,
                        // otherwise CF rejects the cookie and evicts the cache via flagPendingVerification.
                        if let ua = CloudflareBypassManager.shared.bypassUserAgent(for: host) {
                            request.setValue(ua, forHTTPHeaderField: "User-Agent")
                        }
                    }

                    // Decoded before the body is read at all: the Cloudflare wall check below reads it too.
                    var (data, response) = try await self.session.decodedData(for: request)
                    guard var httpResponse = response as? HTTPURLResponse else {
                        reject.call(withArguments: ["No response data"])
                        return
                    }
                    var responseText = String(data: data, encoding: .utf8) ?? ""

                    // CF reactive retry: bypass the final redirect destination, then retry directly
                    // against that URL — avoids cross-domain Cookie stripping on URLSession redirects.
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
                            data = try HTTPBodyDecoding.decoded(recovered.data, response: recovered.response)
                            httpResponse = recovered.response
                            responseText = String(data: data, encoding: .utf8) ?? ""
                        } else {
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

        context.setObject(fetchNative, forKeyedSubscript: "fetchv2Native" as NSString)

        // JS wrapper that returns a Promise with impersonator support
        let fetchv2JS = """
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
        """
        context.evaluateScript(fetchv2JS)
    }

    // MARK: - Fetch Aliases (Sora compatibility)

    /// `fetch` holds Shirox's own `soraFetch` and `fetchv2`, not the globals of those names: a
    /// module that defines its own `soraFetch` and falls back to `fetch` on a failure (HydraHD)
    /// otherwise bounced between the two forever on a host that kept failing.
    private func setupFetchAliases() {
        context.evaluateScript("""
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

    private func setupSoraCompat() {
        // _0xB4F2 is a module validation function required by some Sora modules.
        // It must return a 16-char string whose lowercase chars contain c,r,a,n,c,i.
        let tokenBlock: @convention(block) () -> String = { "shirox-cranci-10" }
        context.setObject(tokenBlock, forKeyedSubscript: "_0xB4F2" as NSString)

        context.evaluateScript("""
        if (typeof sendLog === 'undefined') {
            function sendLog(msg) { console.log('[Module] ' + msg); }
        }
        """)
    }

    // MARK: - Timers

    private func setupTimers() {
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

        context.setObject(setTimeoutBlock, forKeyedSubscript: "setTimeout" as NSString)
        context.setObject(clearTimeoutBlock, forKeyedSubscript: "clearTimeout" as NSString)
        context.setObject(setIntervalBlock, forKeyedSubscript: "setInterval" as NSString)
        context.setObject(clearTimeoutBlock, forKeyedSubscript: "clearInterval" as NSString)
    }

    // MARK: - Scraping Utilities

    private func setupScrapingUtilities() {
        let utilsJS = """
        function getElementsByTag(html, tag) {
            var regex = new RegExp('<' + tag + '[^>]*>([\\\\s\\\\S]*?)</' + tag + '>', 'gi');
            var matches = [];
            var match;
            while ((match = regex.exec(html)) !== null) {
                matches.push(match[0]);
            }
            return matches;
        }

        function getAttribute(element, attr) {
            var regex = new RegExp(attr + '=["\\'](.*?)["\\']');
            var match = element.match(regex);
            return match ? match[1] : '';
        }

        function getInnerText(element) {
            return element.replace(/<[^>]*>/g, '').trim();
        }

        function stripHtml(html) {
            return html.replace(/<[^>]*>/g, '');
        }
        """
        context.evaluateScript(utilsJS)
    }

    // MARK: - Helpers

    /// Resolves a JS Promise by calling the given function name with arguments,
    /// then invokes the completion handler with the result string.
    func callAsyncJS(_ functionName: String, args: [Any], completion: @escaping (Result<String, Error>) -> Void) {
        guard let fn = context.objectForKeyedSubscript(functionName),
              !fn.isUndefined else {
            completion(.failure(JSEngineError.functionNotFound(functionName)))
            return
        }

        let promise = fn.call(withArguments: args)

        guard let promise, !promise.isUndefined, !promise.isNull else {
            completion(.failure(JSEngineError.nullResult))
            return
        }

        // Async module functions return a Promise; synchronous ones (e.g. the
        // local-playback bridge) return a plain value. If the return isn't a
        // thenable, resolve with it directly — calling .then/.catch on a string
        // throws "undefined is not an object" and the completion never fires.
        let thenValue = promise.objectForKeyedSubscript("then")
        if thenValue == nil || thenValue?.isUndefined == true {
            let str = promise.toString() ?? ""
            DispatchQueue.main.async { completion(.success(str)) }
            return
        }

        let thenBlock: @convention(block) (JSValue) -> Void = { result in
            let str = result.toString() ?? ""
            DispatchQueue.main.async {
                completion(.success(str))
            }
        }

        let catchBlock: @convention(block) (JSValue) -> Void = { error in
            let msg = error.toString() ?? "Unknown JS error"
            DispatchQueue.main.async {
                completion(.failure(JSEngineError.jsError(msg)))
            }
        }

        let thenFn = JSValue(object: thenBlock, in: context)
        let catchFn = JSValue(object: catchBlock, in: context)

        promise.invokeMethod("then", withArguments: [thenFn as Any])
        promise.invokeMethod("catch", withArguments: [catchFn as Any])
    }

    /// Async wrapper for callAsyncJS.
    ///
    /// Bounded and resume-once, because the underlying callback is driven by a JS Promise from an
    /// untrusted module script:
    ///
    /// * A promise that never settles (a hung request inside the module, a swallowed rejection,
    ///   a code path that simply never calls resolve) left the continuation suspended forever.
    ///   Every caller inherited that: the stream picker span forever, `refetchStream` never
    ///   released `isRefetchingStream` — blocking all later recovery — and the next-episode
    ///   prefetch leaked a task. Cancelling the enclosing Task does not resume a continuation, so
    ///   even backing out of the screen didn't clear it. The timeout converts a hang into a normal
    ///   error the existing paths already handle.
    /// * A thenable that invokes both its resolve and reject callbacks (or either one twice) would
    ///   resume the continuation more than once, which traps at runtime. The gate makes the first
    ///   outcome win and drops the rest.
    func callAsyncJS(_ functionName: String, args: [Any], timeout: TimeInterval = 120) async throws -> String {
        let gate = ContinuationGate()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                gate.attach(cont)
                callAsyncJS(functionName, args: args) { result in
                    gate.settle(result)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                    gate.settle(.failure(JSEngineError.timedOut(functionName)))
                }
            }
        } onCancel: {
            gate.settle(.failure(CancellationError()))
        }
    }

    static func isTurnstileResponse(status: Int, body: String) -> Bool {
        let lower = body.lowercased()
        guard lower.contains("cloudflare") else { return false }
        let hasChallenge = lower.contains("cf-turnstile") ||
               lower.contains("challenges.cloudflare.com") ||
               lower.contains("__cf_chl_") ||
               lower.contains("jschl") ||
               lower.contains("challenge-platform") ||
               lower.contains("cf-spinner")
        guard hasChallenge else { return false }
        return status == 403 || status == 503 || (status == 200 && lower.contains("just a moment"))
    }

    static func jsStringLiteral(_ string: String) -> String {
        let escaped = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}

extension JSContext {
    /// One virtual machine for every module context. A bare `JSContext()` brings its own VM, each
    /// with its own heap and collector, and with a few module rows searching at once that was
    /// several heaps alive together. All of these contexts run on the main thread, so they can
    /// share one; each context still gets its own globals.
    @MainActor private static let moduleVM = JSVirtualMachine()!

    @MainActor static func forModule() -> JSContext {
        JSContext(virtualMachine: moduleVM)!
    }

    /// The fetch-style response handed to a module's `fetchv2` promise. It's built in JS around
    /// one JS copy of the body: `text()` and `json()` read that copy rather than calling back into
    /// Swift, which converted the body again on every call and held the context from a block the
    /// context itself owned. A body that isn't JSON makes `json()` return undefined, as before.
    func makeFetchResponse(status: Int, statusText: String?, url: String, headers: [String: String], body: String) -> JSValue {
        var make = objectForKeyedSubscript("__shiroxMakeResponse")
        if make == nil || make?.isUndefined == true {
            evaluateScript("""
            var __shiroxMakeResponse = function (status, statusText, url, headers, body) {
                var response = {
                    status: status,
                    ok: status >= 200 && status < 300,
                    url: url,
                    headers: headers,
                    text: function () { return body; },
                    json: function () {
                        try { return JSON.parse(body); }
                        catch (e) { console.log('[fetchv2] json(): ' + e); return undefined; }
                    }
                };
                if (statusText != null) response.statusText = statusText;
                return response;
            };
            """)
            make = objectForKeyedSubscript("__shiroxMakeResponse")
        }
        let args: [Any] = [status, statusText ?? NSNull(), url, headers, body]
        return make?.call(withArguments: args) ?? JSValue(undefinedIn: self)
    }
}

/// Resume-once gate for a checked continuation that several independent callbacks can complete
/// (the JS promise, a timeout, task cancellation). Only the first outcome is delivered.
/// Shared by `JSEngine` and `ModuleJSRunner`, which both bridge untrusted module promises.
final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var pending: Result<String, Error>?
    private var finished = false

    /// Stores the continuation, delivering immediately if an outcome already arrived.
    func attach(_ cont: CheckedContinuation<String, Error>) {
        lock.lock()
        if let pending {
            self.pending = nil
            finished = true
            lock.unlock()
            cont.resume(with: pending)
            return
        }
        continuation = cont
        lock.unlock()
    }

    /// Delivers the first outcome; later calls are no-ops.
    func settle(_ result: Result<String, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard let cont = continuation else {
            // Raced ahead of attach (cancellation can fire before the body runs) — hold it.
            pending = result
            lock.unlock()
            return
        }
        continuation = nil
        finished = true
        lock.unlock()
        cont.resume(with: result)
    }
}

enum JSEngineError: LocalizedError {
    case functionNotFound(String)
    case nullResult
    case jsError(String)
    case parseError(String)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .functionNotFound(let name): return "JS function '\(name)' not found in module"
        case .nullResult: return "JS function returned null/undefined"
        case .jsError(let msg): return "JS error: \(msg)"
        case .parseError(let msg): return "Parse error: \(msg)"
        case .timedOut(let name): return "Module function '\(name)' timed out"
        }
    }
}

// MARK: - Browser Impersonator & Fingerprint Profiles

public enum BrowserTarget: String, CaseIterable, Sendable {
    case safari
    case chrome
    case firefox
    case auto
}

public struct BrowserImpersonator: Sendable {
    public static let safariMacOSUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    public static let safariIOSUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    public static let chromeWindowsUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"
    public static let chromeMacOSUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"
    public static let firefoxWindowsUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:130.0) Gecko/20100101 Firefox/130.0"

    public static func apply(
        to request: inout URLRequest,
        target: BrowserTarget = .auto,
        customHeaders: [String: String] = [:]
    ) {
        let selected: BrowserTarget = (target == .auto) ? .safari : target

        switch selected {
        case .safari, .auto:
            applySafariProfile(to: &request)
        case .chrome:
            applyChromeProfile(to: &request)
        case .firefox:
            applyFirefoxProfile(to: &request)
        }

        for (key, value) in customHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
    }

    private static func applySafariProfile(to request: inout URLRequest) {
        #if os(iOS)
        request.setValue(safariIOSUA, forHTTPHeaderField: "User-Agent")
        #else
        request.setValue(safariMacOSUA, forHTTPHeaderField: "User-Agent")
        #endif

        if request.value(forHTTPHeaderField: "Accept") == nil {
            request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        }
        if request.value(forHTTPHeaderField: "Accept-Language") == nil {
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        }
        if request.value(forHTTPHeaderField: "Accept-Encoding") == nil {
            request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
        }
        if request.value(forHTTPHeaderField: "Sec-Fetch-Site") == nil {
            request.setValue("none", forHTTPHeaderField: "Sec-Fetch-Site")
        }
        if request.value(forHTTPHeaderField: "Sec-Fetch-Mode") == nil {
            request.setValue("navigate", forHTTPHeaderField: "Sec-Fetch-Mode")
        }
        if request.value(forHTTPHeaderField: "Sec-Fetch-Dest") == nil {
            request.setValue("document", forHTTPHeaderField: "Sec-Fetch-Dest")
        }
        if request.value(forHTTPHeaderField: "Upgrade-Insecure-Requests") == nil {
            request.setValue("1", forHTTPHeaderField: "Upgrade-Insecure-Requests")
        }
    }

    private static func applyChromeProfile(to request: inout URLRequest) {
        request.setValue(chromeWindowsUA, forHTTPHeaderField: "User-Agent")

        if request.value(forHTTPHeaderField: "sec-ch-ua") == nil {
            request.setValue("\"Chromium\";v=\"128\", \"Not;A=Brand\";v=\"24\", \"Google Chrome\";v=\"128\"", forHTTPHeaderField: "sec-ch-ua")
        }
        if request.value(forHTTPHeaderField: "sec-ch-ua-mobile") == nil {
            request.setValue("?0", forHTTPHeaderField: "sec-ch-ua-mobile")
        }
        if request.value(forHTTPHeaderField: "sec-ch-ua-platform") == nil {
            request.setValue("\"Windows\"", forHTTPHeaderField: "sec-ch-ua-platform")
        }
        if request.value(forHTTPHeaderField: "Accept") == nil {
            request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7", forHTTPHeaderField: "Accept")
        }
        if request.value(forHTTPHeaderField: "Accept-Language") == nil {
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        }
        if request.value(forHTTPHeaderField: "Accept-Encoding") == nil {
            request.setValue("gzip, deflate, br, zstd", forHTTPHeaderField: "Accept-Encoding")
        }
        if request.value(forHTTPHeaderField: "Sec-Fetch-Site") == nil {
            request.setValue("none", forHTTPHeaderField: "Sec-Fetch-Site")
        }
        if request.value(forHTTPHeaderField: "Sec-Fetch-Mode") == nil {
            request.setValue("navigate", forHTTPHeaderField: "Sec-Fetch-Mode")
        }
        if request.value(forHTTPHeaderField: "Sec-Fetch-User") == nil {
            request.setValue("?1", forHTTPHeaderField: "Sec-Fetch-User")
        }
        if request.value(forHTTPHeaderField: "Sec-Fetch-Dest") == nil {
            request.setValue("document", forHTTPHeaderField: "Sec-Fetch-Dest")
        }
        if request.value(forHTTPHeaderField: "Upgrade-Insecure-Requests") == nil {
            request.setValue("1", forHTTPHeaderField: "Upgrade-Insecure-Requests")
        }
    }

    private static func applyFirefoxProfile(to request: inout URLRequest) {
        request.setValue(firefoxWindowsUA, forHTTPHeaderField: "User-Agent")

        if request.value(forHTTPHeaderField: "Accept") == nil {
            request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/png,image/svg+xml,*/*;q=0.8", forHTTPHeaderField: "Accept")
        }
        if request.value(forHTTPHeaderField: "Accept-Language") == nil {
            request.setValue("en-US,en;q=0.5", forHTTPHeaderField: "Accept-Language")
        }
        if request.value(forHTTPHeaderField: "Accept-Encoding") == nil {
            request.setValue("gzip, deflate, br, zstd", forHTTPHeaderField: "Accept-Encoding")
        }
        if request.value(forHTTPHeaderField: "Sec-Fetch-Dest") == nil {
            request.setValue("document", forHTTPHeaderField: "Sec-Fetch-Dest")
        }
        if request.value(forHTTPHeaderField: "Sec-Fetch-Mode") == nil {
            request.setValue("navigate", forHTTPHeaderField: "Sec-Fetch-Mode")
        }
        if request.value(forHTTPHeaderField: "Sec-Fetch-Site") == nil {
            request.setValue("none", forHTTPHeaderField: "Sec-Fetch-Site")
        }
        if request.value(forHTTPHeaderField: "Sec-Fetch-User") == nil {
            request.setValue("?1", forHTTPHeaderField: "Sec-Fetch-User")
        }
        if request.value(forHTTPHeaderField: "Upgrade-Insecure-Requests") == nil {
            request.setValue("1", forHTTPHeaderField: "Upgrade-Insecure-Requests")
        }
    }
}

@MainActor
final class WebKitFetchEngine: NSObject, WKNavigationDelegate {
    static let shared = WebKitFetchEngine()

    private lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        return WKWebView(frame: .zero, configuration: config)
    }()

    typealias Answer = (data: Data, statusCode: Int, headers: [String: String], finalURL: String)

    /// The request before this one: requests take turns, since each puts the one web view on its site.
    private var previous: Task<Void, Never>?
    private var pageLoad: CheckedContinuation<Void, Error>?

    func fetch(
        url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: String? = nil
    ) async throws -> Answer {
        let before = previous
        let turn = Task { () throws -> Answer in
            await before?.value
            try await self.showSite(of: url)
            return try await self.perform(url: url, method: method, headers: headers, body: body)
        }
        previous = Task { _ = try? await turn.value }
        return try await turn.value
    }

    /// Puts the web view on the site's origin (an empty page, no request made), so its `fetch`
    /// is same-origin: no CORS refusal, and the site's cookies go along.
    private func showSite(of url: URL) async throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host else { return }
        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = host
        origin.port = url.port
        origin.path = "/"
        guard let base = origin.url, webView.url?.scheme != scheme || webView.url?.host != host
                || webView.url?.port != url.port else { return }
        webView.navigationDelegate = self
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pageLoad = continuation
            webView.loadHTMLString("<!doctype html><title></title>", baseURL: base)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoad?.resume()
        pageLoad = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        pageLoad?.resume(throwing: error)
        pageLoad = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        pageLoad?.resume(throwing: error)
        pageLoad = nil
    }

    private func perform(url: URL, method: String, headers: [String: String], body: String?) async throws -> Answer {
        let escapedURL = JSEngine.jsStringLiteral(url.absoluteString)
        let headersData = (try? JSONSerialization.data(withJSONObject: headers)) ?? Data()
        let headersJSON = String(data: headersData, encoding: .utf8) ?? "{}"
        let bodyScript: String
        if let body, method != "GET" && method != "HEAD" {
            bodyScript = "body: \(JSEngine.jsStringLiteral(body)),"
        } else {
            bodyScript = ""
        }

        // callAsyncJavaScript runs this as a function body: without `return`, the answer is lost.
        let js = """
        return (async function() {
            try {
                const res = await fetch(\(escapedURL), {
                    method: \(JSEngine.jsStringLiteral(method)),
                    headers: \(headersJSON),
                    \(bodyScript)
                    credentials: 'include'
                });
                const text = await res.text();
                const resHeaders = {};
                res.headers.forEach((val, key) => { resHeaders[key] = val; });
                return JSON.stringify({
                    status: res.status,
                    url: res.url,
                    headers: resHeaders,
                    body: text
                });
            } catch (err) {
                return JSON.stringify({ error: err.toString() });
            }
        })();
        """

        let raw = try await webView.callAsyncJavaScript(js, arguments: [:], contentWorld: .defaultClient) as? String
        guard let raw, let rawData = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }

        if let errorMsg = json["error"] as? String {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }

        let status = json["status"] as? Int ?? 200
        let finalURL = json["url"] as? String ?? url.absoluteString
        let resHeaders = json["headers"] as? [String: String] ?? [:]
        let resBody = json["body"] as? String ?? ""
        let resData = resBody.data(using: .utf8) ?? Data()

        return (resData, status, resHeaders, finalURL)
    }
}

