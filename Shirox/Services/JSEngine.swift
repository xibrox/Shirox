import Foundation
import JavaScriptCore

@MainActor
final class JSEngine: ObservableObject {
    static let shared = JSEngine()

    private(set) var context: JSContext

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        return URLSession(configuration: config)
    }()

    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    private init() {
        context = JSContext()!
        setupContext()
    }

    // MARK: - Module Loading

    func loadModule(_ module: ModuleDefinition) async throws {
        guard let url = URL(string: module.scriptUrl) else {
            throw URLError(.badURL)
        }
        let (data, _) = try await session.data(from: url)
        guard let script = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
        // Fresh context for each module
        context = JSContext()!
        setupContext()
        context.evaluateScript(script)
        if let exception = context.exception {
            print("[JSEngine] Script load error: \(exception)")
        }
    }

    // MARK: - Context Setup

    private func setupContext() {
        setupConsoleLogging()
        setupBase64()
        setupFetchV2()
        setupScrapingUtilities()
        context.setupNetworkFetch()
        context.setupNetworkFetchSimple()

        context.exceptionHandler = { _, exception in
            print("[JS Exception] \(exception?.toString() ?? "unknown")")
        }
    }

    // MARK: - Console Bridge

    private func setupConsoleLogging() {
        let consoleLog: @convention(block) (JSValue) -> Void = { value in
            print("[JS] \(value.toString() ?? "undefined")")
        }
        let consoleError: @convention(block) (JSValue) -> Void = { value in
            print("[JS Error] \(value.toString() ?? "undefined")")
        }
        let consoleWarn: @convention(block) (JSValue) -> Void = { value in
            print("[JS Warn] \(value.toString() ?? "undefined")")
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
        // the resolve/reject callbacks when done.
        // All parameters are JSValue (non-optional) — JSCore always provides non-nil JSValue
        // objects; null/undefined JS values have isNull/isUndefined == true, never Swift nil.
        let fetchNative: @convention(block) (String, JSValue, JSValue, JSValue, JSValue, JSValue) -> Void =
        { [weak self] urlString, headersVal, methodVal, bodyVal, resolve, reject in
            guard let self else {
                reject.call(withArguments: ["JSEngine deallocated"])
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

            // Apply headers from JS
            if !headersVal.isUndefined, !headersVal.isNull {
                if let dict = headersVal.toDictionary() as? [String: String] {
                    for (key, value) in dict {
                        request.setValue(value, forHTTPHeaderField: key)
                    }
                }
            }

            if let body, let bodyData = body.data(using: .utf8) {
                request.httpBody = bodyData
            }

            let ctx = self.context

            self.session.dataTask(with: request) { data, response, error in
                if let error {
                    DispatchQueue.main.async {
                        reject.call(withArguments: [error.localizedDescription])
                    }
                    return
                }
                guard let data, let httpResponse = response as? HTTPURLResponse else {
                    DispatchQueue.main.async {
                        reject.call(withArguments: ["No response data"])
                    }
                    return
                }

                let responseText = String(data: data, encoding: .utf8) ?? ""
                let status = httpResponse.statusCode

                // Build headers dict
                var headersDict: [String: String] = [:]
                for (key, value) in httpResponse.allHeaderFields {
                    headersDict[String(describing: key)] = String(describing: value)
                }

                DispatchQueue.main.async {
                    let responseObj = JSValue(newObjectIn: ctx)!
                    responseObj.setValue(status, forProperty: "status")
                    responseObj.setValue(status >= 200 && status < 300, forProperty: "ok")
                    responseObj.setValue(httpResponse.url?.absoluteString ?? urlString, forProperty: "url")
                    responseObj.setValue(headersDict, forProperty: "headers")

                    // text() method
                    let textFn: @convention(block) () -> String = { responseText }
                    responseObj.setObject(textFn, forKeyedSubscript: "text" as NSString)

                    // json() method
                    let jsonFn: @convention(block) () -> JSValue = {
                        let script = "JSON.parse(\(Self.jsStringLiteral(responseText)))"
                        return ctx.evaluateScript(script) ?? JSValue(undefinedIn: ctx)
                    }
                    responseObj.setObject(jsonFn, forKeyedSubscript: "json" as NSString)

                    resolve.call(withArguments: [responseObj])
                }
            }.resume()
        }

        context.setObject(fetchNative, forKeyedSubscript: "fetchv2Native" as NSString)

        // JS wrapper that returns a Promise
        let fetchv2JS = """
        function fetchv2(url, headers, method, body) {
            return new Promise(function(resolve, reject) {
                fetchv2Native(url, headers || {}, method || 'GET', body || null, resolve, reject);
            });
        }
        """
        context.evaluateScript(fetchv2JS)
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

    /// Async wrapper for callAsyncJS
    func callAsyncJS(_ functionName: String, args: [Any]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            callAsyncJS(functionName, args: args) { result in
                cont.resume(with: result)
            }
        }
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

enum JSEngineError: LocalizedError {
    case functionNotFound(String)
    case nullResult
    case jsError(String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .functionNotFound(let name): return "JS function '\(name)' not found in module"
        case .nullResult: return "JS function returned null/undefined"
        case .jsError(let msg): return "JS error: \(msg)"
        case .parseError(let msg): return "Parse error: \(msg)"
        }
    }
}
