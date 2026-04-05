import Foundation
import Network
import Darwin

/// Minimal local HTTP proxy that forwards HLS requests with custom headers.
/// Chromecast fetches the rewritten m3u8 from the phone; the phone fetches
/// the real segments with the required Referer / User-Agent headers.
final class HLSProxyServer {
    static let shared = HLSProxyServer()

    private var listener: NWListener?
    private let port: NWEndpoint.Port = 8765
    private var proxyHeaders: [String: String] = [:]
    private(set) var isRunning = false

    private init() {}

    // MARK: - Public API

    func start(headers: [String: String]) {
        proxyHeaders = headers
        guard !isRunning else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params, on: port) else { return }
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        l.start(queue: .global(qos: .userInitiated))
        listener = l
        isRunning = true
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    /// Returns a proxy URL for the given original URL, routed through this server.
    func proxyURL(for url: URL) -> URL? {
        guard let ip = localIPAddress() else { return nil }
        var c = URLComponents()
        c.scheme = "http"
        c.host = ip
        c.port = Int(port.rawValue)
        c.path = "/proxy"
        c.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        return c.url
    }

    // MARK: - Connection handling

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self, let data, let requestText = String(data: data, encoding: .utf8) else { return }
            guard let urlString = self.parsePath(from: requestText),
                  let targetURL = URL(string: urlString) else {
                self.respond(connection, status: 400, body: Data())
                return
            }
            Task { await self.fetchAndForward(url: targetURL, connection: connection) }
        }
    }

    private func parsePath(from request: String) -> String? {
        guard let firstLine = request.components(separatedBy: "\r\n").first else { return nil }
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }
        let path = parts[1]
        guard let comps = URLComponents(string: "http://localhost" + path),
              let urlValue = comps.queryItems?.first(where: { $0.name == "url" })?.value
        else { return nil }
        return urlValue
    }

    // MARK: - Fetch & rewrite

    private func fetchAndForward(url: URL, connection: NWConnection) async {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        proxyHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }

        guard let (data, response) = try? await URLSession.shared.data(for: req) else {
            respond(connection, status: 502, body: Data())
            return
        }

        let contentType = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"

        let isPlaylist = contentType.contains("mpegurl")
            || url.pathExtension.lowercased() == "m3u8"

        let body: Data
        if isPlaylist, let text = String(data: data, encoding: .utf8) {
            body = rewriteM3U8(text, baseURL: url).data(using: .utf8) ?? data
        } else {
            body = data
        }

        respond(connection, status: 200, contentType: contentType, body: body)
    }

    private func rewriteM3U8(_ text: String, baseURL: URL) -> String {
        text.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return line }
            let resolved: URL?
            if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
                resolved = URL(string: trimmed)
            } else {
                resolved = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
            }
            guard let src = resolved, let proxied = proxyURL(for: src) else { return line }
            return proxied.absoluteString
        }.joined(separator: "\n")
    }

    // MARK: - HTTP response

    private func respond(_ connection: NWConnection, status: Int,
                         contentType: String = "application/octet-stream", body: Data) {
        let header = "HTTP/1.1 \(status) OK\r\n" +
            "Content-Type: \(contentType)\r\n" +
            "Content-Length: \(body.count)\r\n" +
            "Access-Control-Allow-Origin: *\r\n" +
            "Connection: close\r\n\r\n"
        var response = header.data(using: .utf8)!
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: - Local IP

    private func localIPAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let ifa = ptr {
            let flags = Int32(ifa.pointee.ifa_flags)
            let addr = ifa.pointee.ifa_addr.pointee
            if (flags & (IFF_UP | IFF_RUNNING | IFF_LOOPBACK)) == (IFF_UP | IFF_RUNNING),
               addr.sa_family == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(ifa.pointee.ifa_addr, socklen_t(addr.sa_len),
                            &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                return String(cString: hostname)
            }
            ptr = ifa.pointee.ifa_next
        }
        return nil
    }
}
