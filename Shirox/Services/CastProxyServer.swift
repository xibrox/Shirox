#if os(iOS)
import Foundation
import Network
import Darwin
import UIKit

/// Local HTTP proxy that binds to all network interfaces (0.0.0.0) so
/// Chromecast — a separate LAN device — can reach it. Injects auth
/// headers into every request and rewrites HLS manifest segment URLs
/// so they also route through the proxy.
final class CastProxyServer {
    static let shared = CastProxyServer()

    private var listener: NWListener?
    private let port: NWEndpoint.Port = 8766
    private var proxyHeaders: [String: String] = [:]
    private(set) var isRunning = false
    private let listenerQueue = DispatchQueue(label: "com.shirox.castproxy", qos: .userInitiated)
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    private init() {}

    // MARK: - Public API

    func start(headers: [String: String]) {
        proxyHeaders = headers
        guard !isRunning else { return }

        beginBackgroundTask()

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        do {
            let l = try NWListener(using: params, on: port)
            l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            l.start(queue: listenerQueue)
            listener = l
            isRunning = true
            print("[CastProxy] Started on \(localIP()):\(port.rawValue)")
        } catch {
            print("[CastProxy] Start failed: \(error)")
            endBackgroundTask()
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        endBackgroundTask()
        print("[CastProxy] Stopped")
    }

    // MARK: - Background task

    /// Requests background execution time so iOS keeps the proxy alive
    /// when the screen locks. The app's UIBackgroundModes: audio entry
    /// (held active by PlayerView's AVAudioSession) provides indefinite
    /// runtime; this is a safety net for the gap before that kicks in.
    private func beginBackgroundTask() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "CastProxyServer") {
                UIApplication.shared.endBackgroundTask(self.backgroundTaskID)
                self.backgroundTaskID = .invalid
            }
        }
    }

    private func endBackgroundTask() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.backgroundTaskID != .invalid else { return }
            UIApplication.shared.endBackgroundTask(self.backgroundTaskID)
            self.backgroundTaskID = .invalid
        }
    }

    /// Returns a URL using the device's LAN IP — reachable by Chromecast.
    func proxyURL(for url: URL) -> URL? {
        var c = URLComponents()
        c.scheme = "http"
        c.host = localIP()
        c.port = Int(port.rawValue)
        c.path = "/proxy"
        c.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        return c.url
    }

    // MARK: - Connection handling

    private func handle(_ connection: NWConnection) {
        connection.start(queue: listenerQueue)
        receiveRequest(on: connection)
    }

    private func receiveRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let text = String(data: data, encoding: .utf8) else {
                connection.cancel(); return
            }

            let lines = text.components(separatedBy: "\r\n")
            guard let firstLine = lines.first else { connection.cancel(); return }
            let parts = firstLine.components(separatedBy: " ")
            guard parts.count >= 2 else { connection.cancel(); return }

            let path = parts[1]

            guard let urlComp = URLComponents(string: "http://localhost" + path),
                  let urlValue = urlComp.queryItems?.first(where: { $0.name == "url" })?.value,
                  let targetURL = URL(string: urlValue) else {
                self.sendSimpleResponse(connection, status: 400); return
            }

            Task {
                await self.serve(targetURL, connection: connection)
                self.receiveRequest(on: connection)
            }
        }
    }

    // MARK: - Serving

    private func serve(_ url: URL, connection: NWConnection) async {
        var req = URLRequest(url: url, timeoutInterval: 30)
        proxyHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }

        guard let (data, response) = try? await URLSession.shared.data(for: req) else {
            sendSimpleResponse(connection, status: 502); return
        }

        let mime = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
            ?? mimeType(for: url.pathExtension)

        // HLS manifests: rewrite all segment/variant URLs to route through this proxy
        if isManifest(mime: mime, url: url), let text = String(data: data, encoding: .utf8) {
            let rewritten = rewriteManifest(text, baseURL: url)
            sendData(rewritten.data(using: .utf8) ?? data, contentType: mime, connection: connection)
        } else {
            sendData(data, contentType: mime, connection: connection)
        }
    }

    // MARK: - Manifest rewriting

    private func isManifest(mime: String, url: URL) -> Bool {
        let m = mime.lowercased()
        return m.contains("mpegurl") || url.pathExtension.lowercased() == "m3u8"
    }

    /// Rewrites every non-comment line to a proxied URL so segments
    /// also get auth headers injected when Chromecast requests them.
    private func rewriteManifest(_ text: String, baseURL: URL) -> String {
        let base = baseURL.deletingLastPathComponent()
        return text.components(separatedBy: .newlines).map { line -> String in
            let tr = line.trimmingCharacters(in: .whitespaces)
            guard !tr.isEmpty && !tr.hasPrefix("#") else { return line }
            let resolved: URL
            if tr.lowercased().hasPrefix("http://") || tr.lowercased().hasPrefix("https://") {
                guard let u = URL(string: tr) else { return line }
                resolved = u
            } else {
                resolved = base.appendingPathComponent(tr)
            }
            return proxyURL(for: resolved)?.absoluteString ?? line
        }.joined(separator: "\n")
    }

    // MARK: - Response helpers

    private func sendData(_ data: Data, contentType: String, connection: NWConnection) {
        let header = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(data.count)\r\nAccess-Control-Allow-Origin: *\r\nCache-Control: no-cache\r\n\r\n"
        var resp = header.data(using: .utf8)!
        resp.append(data)
        connection.send(content: resp, completion: .contentProcessed({ _ in }))
    }

    private func sendSimpleResponse(_ connection: NWConnection, status: Int) {
        let r = "HTTP/1.1 \(status) Error\r\nContent-Length: 0\r\n\r\n"
        connection.send(content: r.data(using: .utf8), completion: .contentProcessed({ _ in }))
    }

    private func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "m3u8": return "application/x-mpegURL"
        case "ts":   return "video/mp2t"
        case "mp4":  return "video/mp4"
        default:     return "application/octet-stream"
        }
    }

    // MARK: - Local IP

    /// Returns the device's current WiFi IP (en0). Falls back to 127.0.0.1.
    private func localIP() -> String {
        var address = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return address }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }
            let iface = current.pointee
            guard iface.ifa_addr.pointee.sa_family == UInt8(AF_INET),
                  let name = iface.ifa_name.map({ String(cString: $0) }),
                  name == "en0" else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(iface.ifa_addr,
                        socklen_t(iface.ifa_addr.pointee.sa_len),
                        &hostname, socklen_t(hostname.count),
                        nil, 0, NI_NUMERICHOST)
            address = String(cString: hostname)
            break
        }
        return address
    }
}
#endif
