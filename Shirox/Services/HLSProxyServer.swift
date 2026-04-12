import Foundation
import Network
import Darwin

final class HLSProxyServer {
    static let shared = HLSProxyServer()

    private var listener: NWListener?
    private let port: NWEndpoint.Port = 8765
    private var proxyHeaders: [String: String] = [:]
    private(set) var isRunning = false
    private let listenerQueue = DispatchQueue(label: "com.shirox.hlsproxy", qos: .userInitiated)
    private var readyContinuations: [CheckedContinuation<Void, Never>] = []

    private init() {}

    /// Starts the server (if not already running) and suspends until the listener is ready.
    func startAndWait(headers: [String: String]) async {
        self.proxyHeaders = headers
        if isRunning { return }
        await withCheckedContinuation { continuation in
            readyContinuations.append(continuation)
            guard listener == nil else { return }
            startListener()
        }
    }

    func start(headers: [String: String]) {
        self.proxyHeaders = headers
        guard !isRunning, listener == nil else { return }
        startListener()
    }

    private func startListener() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        do {
            let l = try NWListener(using: params, on: port)
            l.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isRunning = true
                    print("[Proxy] Ready on 127.0.0.1:\(self.port.rawValue)")
                    let waiting = self.readyContinuations
                    self.readyContinuations.removeAll()
                    waiting.forEach { $0.resume() }
                case .failed(let error):
                    print("[Proxy] Listener failed: \(error)")
                    self.isRunning = false
                    self.listener = nil
                    let waiting = self.readyContinuations
                    self.readyContinuations.removeAll()
                    waiting.forEach { $0.resume() }
                case .cancelled:
                    self.isRunning = false
                default:
                    break
                }
            }
            l.newConnectionHandler = { [weak self] conn in
                self?.handle(conn)
            }
            l.start(queue: listenerQueue)
            self.listener = l
        } catch {
            print("[Proxy] Start failed: \(error)")
            let waiting = readyContinuations
            readyContinuations.removeAll()
            waiting.forEach { $0.resume() }
        }
    }

    func stop() {
        print("[Proxy] Stopping server")
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    func proxyURL(for url: URL) -> URL? {
        var c = URLComponents()
        c.scheme = "http"
        c.host = "127.0.0.1"
        c.port = Int(port.rawValue)
        c.path = "/proxy"
        c.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        return c.url
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: listenerQueue)
        receiveRequest(on: connection)
    }

    private func receiveRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self = self, let data = data, let requestText = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            
            let lines = requestText.components(separatedBy: "\r\n")
            guard let firstLine = lines.first else { connection.cancel(); return }
            let parts = firstLine.components(separatedBy: " ")
            guard parts.count >= 2 else { connection.cancel(); return }
            
            let method = parts[0]
            let path = parts[1]
            
            guard let urlComp = URLComponents(string: "http://localhost" + path),
                  let urlValue = urlComp.queryItems?.first(where: { $0.name == "url" })?.value,
                  let targetURL = URL(string: urlValue) else {
                self.sendSimpleResponse(connection, status: 400)
                return
            }
            
            var range: String?
            for line in lines {
                if line.lowercased().hasPrefix("range:") {
                    range = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces)
                    break
                }
            }
            
            Task {
                if targetURL.isFileURL {
                    await self.serveLocal(targetURL, connection: connection, range: range, isHead: method == "HEAD")
                } else {
                    await self.serveRemote(targetURL, connection: connection)
                }
                self.receiveRequest(on: connection)
            }
        }
    }

    private func serveLocal(_ url: URL, connection: NWConnection, range: String?, isHead: Bool) async {
        let isManifest = url.pathExtension.lowercased() == "m3u8"
        
        if isManifest, let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) {
            // Rewrite manifest to proxy local segments
            let rewritten = rewriteLocalManifest(text, baseURL: url)
            let body = rewritten.data(using: .utf8) ?? data
            sendData(body, contentType: "application/x-mpegURL", connection: connection)
            return
        }
        
        guard let attr = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attr[.size] as? Int64 else {
            sendSimpleResponse(connection, status: 404)
            return
        }
        
        var start: Int64 = 0
        var end: Int64 = fileSize - 1
        var isPartial = false
        if let range = range, range.hasPrefix("bytes="), let r = parseRange(range, size: fileSize) {
            start = r.0; end = r.1; isPartial = true
        }
        
        let length = end - start + 1
        let status = isPartial ? "206 Partial Content" : "200 OK"
        var header = "HTTP/1.1 \(status)\r\nContent-Type: \(getMimeType(for: url.pathExtension))\r\nContent-Length: \(length)\r\nAccept-Ranges: bytes\r\nAccess-Control-Allow-Origin: *\r\n"
        if isPartial { header += "Content-Range: bytes \(start)-\(end)/\(fileSize)\r\n" }
        header += "\r\n"
        
        connection.send(content: header.data(using: .utf8), completion: .contentProcessed({ _ in
            if isHead { return }
            if let handle = try? FileHandle(forReadingFrom: url) {
                try? handle.seek(toOffset: UInt64(start))
                self.streamFile(handle, connection: connection, remaining: length)
            }
        }))
    }

    private func rewriteLocalManifest(_ text: String, baseURL: URL) -> String {
        let folderURL = baseURL.deletingLastPathComponent()
        return text.components(separatedBy: .newlines).map { line -> String in
            let tr = line.trimmingCharacters(in: .whitespaces)
            guard !tr.isEmpty && !tr.hasPrefix("#") else { return line }
            let segURL = folderURL.appendingPathComponent(tr)
            return proxyURL(for: segURL)?.absoluteString ?? line
        }.joined(separator: "\n")
    }

    private func streamFile(_ handle: FileHandle, connection: NWConnection, remaining: Int64) {
        var left = remaining
        let chunk = Int64(128 * 1024)
        func sendNext() {
            guard left > 0 else { try? handle.close(); return }
            let toRead = min(left, chunk)
            if let data = try? handle.read(upToCount: Int(toRead)), !data.isEmpty {
                left -= Int64(data.count)
                connection.send(content: data, isComplete: false, completion: .contentProcessed({ error in
                    if error == nil { sendNext() } else { try? handle.close() }
                }))
            } else { try? handle.close() }
        }
        sendNext()
    }

    private func serveRemote(_ url: URL, connection: NWConnection) async {
        var req = URLRequest(url: url)
        proxyHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        if let (data, res) = try? await URLSession.shared.data(for: req) {
            let mime = (res as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
            sendData(data, contentType: mime, connection: connection)
        } else {
            sendSimpleResponse(connection, status: 502)
        }
    }

    private func sendData(_ data: Data, contentType: String, connection: NWConnection) {
        let h = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(data.count)\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
        var resp = h.data(using: .utf8)!
        resp.append(data)
        connection.send(content: resp, completion: .contentProcessed({ _ in }))
    }

    private func sendSimpleResponse(_ connection: NWConnection, status: Int) {
        let r = "HTTP/1.1 \(status) Error\r\nContent-Length: 0\r\n\r\n"
        connection.send(content: r.data(using: .utf8), completion: .contentProcessed({ _ in }))
    }

    private func parseRange(_ r: String, size: Int64) -> (Int64, Int64)? {
        let val = r.replacingOccurrences(of: "bytes=", with: "").components(separatedBy: "-")
        guard let s = Int64(val[0]) else { return nil }
        let e = val.count > 1 && !val[1].isEmpty ? Int64(val[1])! : size - 1
        return (s, e)
    }

    private func getMimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "mp4": return "video/mp4"
        case "ts": return "video/mp2t"
        case "m3u8": return "application/x-mpegURL"
        default: return "application/octet-stream"
        }
    }
}
