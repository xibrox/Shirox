import Foundation
@preconcurrency import JavaScriptCore

/// A short-lived, standalone JS runner for a single module.
/// Creates its own JSContext so it never interferes with JSEngine.shared.
@MainActor
final class ModuleJSRunner {

    private var context: JSContext?

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        return URLSession(configuration: config)
    }()

    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    // MARK: - Load module

    func load(module: ModuleDefinition) async throws {
        guard let url = URL(string: module.scriptUrl) else {
            throw URLError(.badURL)
        }
        let (data, _) = try await session.data(from: url)
        guard let script = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
        let ctx = JSContext()!
        setupContext(ctx)
        ctx.evaluateScript(script)
        if let exception = ctx.exception {
            print("[ModuleJSRunner] Script load error: \(exception)")
        }
        self.context = ctx
    }

    // MARK: - Search

    func search(keyword: String) async throws -> [SearchItem] {
        let json = try await callAsyncJS("searchResults", args: [keyword])
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw JSEngineError.parseError("Could not parse search results")
        }
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
        return array.compactMap { item in
            guard let href = item["href"] as? String else { return nil }
            let number: Double
            if let n = item["number"] as? Double { number = n }
            else if let n = item["number"] as? Int { number = Double(n) }
            else { number = 0 }
            return EpisodeLink(number: number, href: href)
        }
        .sorted { $0.number < $1.number }
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

        var results: [StreamResult] = []

        if let streams = obj["streams"] as? [[String: Any]] {
            for stream in streams {
                guard let urlStr = stream["streamUrl"] as? String ?? stream["url"] as? String,
                      let url = URL(string: urlStr) else { continue }
                let title = stream["title"] as? String ?? "Stream"
                let headers = stream["headers"] as? [String: String] ?? [:]
                results.append(StreamResult(title: title, url: url, headers: headers))
            }
        } else if let streams = obj["streams"] as? [String] {
            for (i, urlStr) in streams.enumerated() {
                guard let url = URL(string: urlStr) else { continue }
                results.append(StreamResult(title: "Stream \(i + 1)", url: url, headers: [:]))
            }
        } else if let stream = obj["stream"] as? String, let url = URL(string: stream) {
            results.append(StreamResult(title: "Stream", url: url, headers: [:]))
        } else if let stream = obj["stream"] as? [String: Any],
                  let urlStr = stream["url"] as? String,
                  let url = URL(string: urlStr) {
            let headers = stream["headers"] as? [String: String] ?? [:]
            results.append(StreamResult(title: "Stream", url: url, headers: headers))
        }

        return results
    }

    // MARK: - Promise resolution

    private func callAsyncJS(_ functionName: String, args: [Any]) async throws -> String {
        guard let ctx = context else {
            throw JSEngineError.functionNotFound("context not loaded")
        }
        guard let fn = ctx.objectForKeyedSubscript(functionName), !fn.isUndefined else {
            throw JSEngineError.functionNotFound(functionName)
        }

        return try await withCheckedThrowingContinuation { cont in
            let promise = fn.call(withArguments: args)
            guard let promise, !promise.isUndefined, !promise.isNull else {
                cont.resume(throwing: JSEngineError.nullResult)
                return
            }

            let thenBlock: @convention(block) (JSValue) -> Void = { result in
                DispatchQueue.main.async {
                    cont.resume(returning: result.toString() ?? "")
                }
            }
            let catchBlock: @convention(block) (JSValue) -> Void = { error in
                DispatchQueue.main.async {
                    cont.resume(throwing: JSEngineError.jsError(error.toString() ?? "Unknown JS error"))
                }
            }

            let thenFn = JSValue(object: thenBlock, in: ctx)
            let catchFn = JSValue(object: catchBlock, in: ctx)
            promise.invokeMethod("then", withArguments: [thenFn as Any])
            promise.invokeMethod("catch", withArguments: [catchFn as Any])
        }
    }

    // MARK: - Context setup (mirrors JSEngine.setupContext)

    private func setupContext(_ ctx: JSContext) {
        setupConsole(ctx)
        setupBase64(ctx)
        setupFetchV2(ctx)
        setupScrapingUtilities(ctx)
        ctx.setupNetworkFetch()
        ctx.setupNetworkFetchSimple()

        ctx.exceptionHandler = { _, exception in
            print("[ModuleJSRunner JS] \(exception?.toString() ?? "unknown")")
        }
    }

    private func setupConsole(_ ctx: JSContext) {
        let log: @convention(block) (JSValue) -> Void = { print("[JS] \($0.toString() ?? "")") }
        let err: @convention(block) (JSValue) -> Void = { print("[JS Error] \($0.toString() ?? "")") }
        let warn: @convention(block) (JSValue) -> Void = { print("[JS Warn] \($0.toString() ?? "")") }
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
        let fetchNative: @convention(block) (String, JSValue, JSValue, JSValue, JSValue, JSValue) -> Void =
        { [weak self] urlString, headersVal, methodVal, bodyVal, resolve, reject in
            guard let self else {
                reject.call(withArguments: ["ModuleJSRunner deallocated"])
                return
            }
            guard let url = URL(string: urlString) else {
                reject.call(withArguments: ["Invalid URL: \(urlString)"])
                return
            }

            let method = (methodVal.isNull || methodVal.isUndefined) ? "GET" : (methodVal.toString() ?? "GET")
            let body: String? = (bodyVal.isNull || bodyVal.isUndefined) ? nil : bodyVal.toString()

            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue(self.userAgent, forHTTPHeaderField: "User-Agent")

            if !headersVal.isUndefined, !headersVal.isNull {
                if let dict = headersVal.toDictionary() as? [String: String] {
                    for (key, value) in dict { request.setValue(value, forHTTPHeaderField: key) }
                }
            }

            if let body, let bodyData = body.data(using: .utf8) {
                request.httpBody = bodyData
            }

            Task {
                do {
                    let (data, response) = try await self.session.data(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        reject.call(withArguments: ["No response data"])
                        return
                    }

                    let responseText = String(data: data, encoding: .utf8) ?? ""
                    let status = httpResponse.statusCode
                    var headersDict: [String: String] = [:]
                    for (key, value) in httpResponse.allHeaderFields {
                        headersDict[String(describing: key)] = String(describing: value)
                    }

                    let responseObj = JSValue(newObjectIn: ctx)!
                    responseObj.setValue(status, forProperty: "status")
                    responseObj.setValue(status >= 200 && status < 300, forProperty: "ok")
                    responseObj.setValue(httpResponse.url?.absoluteString ?? urlString, forProperty: "url")
                    responseObj.setValue(headersDict, forProperty: "headers")

                    let textFn: @convention(block) () -> String = { responseText }
                    responseObj.setObject(textFn, forKeyedSubscript: "text" as NSString)

                    let jsonFn: @convention(block) () -> JSValue = {
                        let escaped = JSEngine.jsStringLiteral(responseText)
                        return ctx.evaluateScript("JSON.parse(\(escaped))") ?? JSValue(undefinedIn: ctx)
                    }
                    responseObj.setObject(jsonFn, forKeyedSubscript: "json" as NSString)

                    resolve.call(withArguments: [responseObj])
                } catch {
                    reject.call(withArguments: [error.localizedDescription])
                }
            }
        }

        ctx.setObject(fetchNative, forKeyedSubscript: "fetchv2Native" as NSString)
        ctx.evaluateScript("""
        function fetchv2(url, headers, method, body) {
            return new Promise(function(resolve, reject) {
                fetchv2Native(url, headers || {}, method || 'GET', body || null, resolve, reject);
            });
        }
        """)
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
