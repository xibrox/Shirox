import Combine

#if !os(tvOS)
import Foundation
import Network
import Darwin
#if os(iOS)
import UIKit
#endif

/// Local HTTP proxy bound to every interface (0.0.0.0) so a Chromecast — a separate LAN
/// device — can reach it, and so an AirPlay receiver can too. It injects the stream's auth
/// headers into every request and rewrites HLS manifests (see ``CastManifestRewriter``) so
/// segments, keys, init segments and alternate renditions all route back through here.
///
/// Design notes, each one a bug that used to end a cast mid-movie:
///
///   * **Streaming, not buffering.** Responses are pumped through in chunks. The old code
///     did `URLSession.data(for:)` first, which meant a direct MP4 was pulled entirely into
///     RAM before a single byte reached the TV — a multi-GB allocation the OS jetsams.
///   * **Range passthrough.** `Range:` is forwarded upstream and the upstream's `206` /
///     `Content-Range` come back verbatim. Without it a Chromecast's seek (and its
///     post-rebuffer resume) was answered with the whole file from byte 0.
///   * **Connection lifecycle.** Connections are tracked, idle-timed-out and closed. They
///     used to be left open forever, so a feature-length movie's worth of segment requests
///     slowly exhausted the socket budget.
///   * **Self-healing.** A failed listener re-arms instead of going quietly dead, and a
///     network change re-publishes the LAN address so a Wi-Fi hiccup doesn't strand the
///     receiver on an IP the phone no longer owns.
///   * **Not an open relay.** Every proxied URL is signed with a per-run token, so other
///     devices on the network can't use the phone as a relay — or harvest the auth headers
///     it attaches.
///
/// All mutable state is confined to `stateQueue`; the old code raced it across threads.
final class CastProxyServer: @unchecked Sendable {
    static let shared = CastProxyServer()

    // MARK: - Configuration

    // `port` and `idleTimeout` change only while the proxy is down — tests move them, clear of
    // a copy of the app running in a simulator on the same Mac, which shares its ports.
    var port: NWEndpoint.Port = 8766
    /// How long a connection may go with nothing moving on it before it is reclaimed.
    var idleTimeout: TimeInterval = 60
    /// Backoff before re-arming a listener that failed.
    private let restartDelay: TimeInterval = 1.0

    // MARK: - State (stateQueue only)

    private let stateQueue = DispatchQueue(label: "com.shirox.castproxy.state")
    private let connectionQueue = DispatchQueue(label: "com.shirox.castproxy.conn", attributes: .concurrent)

    private var listener: NWListener?
    private var proxyHeaders: [String: String] = [:]
    private var readyContinuations: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var connections: [ObjectIdentifier: ProxyConnection] = [:]
    #if os(iOS)
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    #endif
    private var pathMonitor: NWPathMonitor?
    private var cachedIP: String?
    /// Who currently needs the proxy up. Reason-counted because Chromecast and AirPlay
    /// both use it: whichever finishes first must not pull the listener out from under the
    /// other. Also distinguishes a crash (re-arm) from a deliberate stop (stay down).
    private var reasons: Set<String> = []
    private var wanted: Bool { !reasons.isEmpty }
    private var running = false
    /// Signs proxy URLs so only URLs this app minted are honoured.
    private var token = CastProxyServer.makeToken()
    /// Subtitles handed to an AirPlay receiver as a WebVTT rendition (see ``AirPlaySubtitles``),
    /// by id. Only the latest is kept: one video plays at a time.
    private var subtitleSessions: [String: SubtitleSession] = [:]
    /// AES-128 keys fetched for audio segments being evened out (see ``AudioSegmentRepair``),
    /// by URL: a stream uses one or a few, and fetching one per segment would double requests.
    private var segmentKeys: [URL: Data] = [:]
    /// Hosts whose audio has had its timestamps evened out this run, logged once each.
    private var repairedHosts: Set<String> = []

    private struct SubtitleSession {
        var cues: [SubtitleCue]
        var name: String
        var duration: Double
        /// The stream's first media segment and its init map, found while its media playlist
        /// went through — read for the timestamp the cues are mapped onto.
        var firstSegment: URL?
        var initSegment: URL?
        var firstTimestamp: Int64?
    }

    /// Called on the main queue when the device's LAN address changes while casting. Any
    /// URL already handed to the receiver now points at an address the phone has given up,
    /// so the caller must re-issue the media.
    var onLocalAddressChanged: (() -> Void)?

    var isRunning: Bool { stateQueue.sync { running } }

    /// One shared session so TLS connections to the CDN are pooled across segments.
    /// Re-handshaking per segment visibly hurts HLS playback.
    private lazy var upstream: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 6
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 3600
        config.waitsForConnectivity = true
        let queue = OperationQueue()
        // Concurrent so one exchange blocking for backpressure can't stall the others.
        queue.maxConcurrentOperationCount = 6
        return URLSession(configuration: config, delegate: exchanges, delegateQueue: queue)
    }()

    private let exchanges = ProxyExchangeRegistry()

    private init() {}

    // MARK: - Lifecycle

    /// Starts the server (if not already running) and suspends until the listener is ready, or
    /// until `timeout` passes: a port something else holds never becomes ready, and waiting
    /// for it used to hang forever. The listener keeps retrying either way until stopped.
    /// - Parameter reason: who needs it up; pass the same value to ``stop(reason:)``.
    /// - Returns: whether the proxy is up.
    @discardableResult
    func startAndWait(headers: [String: String], reason: String = "cast",
                      timeout: TimeInterval = 10) async -> Bool {
        await withCheckedContinuation { continuation in
            stateQueue.async {
                self.proxyHeaders = headers
                self.reasons.insert(reason)
                guard self.running else {
                    self.waitLocked(for: continuation, timeout: timeout)
                    return
                }
                // THE BUG: iOS takes a suspended app's listening socket back and the listener
                // isn't told — it stayed ready while every connection was refused, so after the
                // phone had been locked a while mpv couldn't reopen a stream until the player
                // was closed. So a running listener is checked before it's trusted.
                let probed = self.listener
                self.probeLocked { accepting in
                    // Only the listener probed is replaced: another wait may have replaced it already.
                    if !accepting, let probed, self.listener === probed {
                        Logger.shared.log("[CastProxy] Listener stopped taking connections; re-arming", type: "Stream")
                        probed.stateUpdateHandler = nil
                        probed.cancel()
                        self.listener = nil
                        self.running = false
                    }
                    if self.running {
                        continuation.resume(returning: true)
                    } else {
                        self.waitLocked(for: continuation, timeout: timeout)
                    }
                }
            }
        }
    }

    /// Resumes `continuation` once the listener is ready — starting one if there's none — or
    /// with whether it is once `timeout` passes.
    private func waitLocked(for continuation: CheckedContinuation<Bool, Never>, timeout: TimeInterval) {
        let waiter = UUID()
        readyContinuations[waiter] = continuation
        if listener == nil { startListenerLocked() }
        stateQueue.asyncAfter(deadline: .now() + timeout) {
            self.readyContinuations.removeValue(forKey: waiter)?.resume(returning: self.running)
        }
    }

    /// Answers on `stateQueue` whether anything takes a connection on the proxy's port.
    private func probeLocked(_ answer: @escaping (Bool) -> Void) {
        let probe = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        var answered = false
        let finish = { (accepting: Bool) in
            guard !answered else { return }
            answered = true
            probe.stateUpdateHandler = nil
            probe.cancel()
            answer(accepting)
        }
        probe.stateUpdateHandler = { state in
            switch state {
            case .ready: finish(true)
            // A refused connection waits for the network to change rather than failing.
            case .waiting, .failed: finish(false)
            default: break
            }
        }
        probe.start(queue: stateQueue)
        stateQueue.asyncAfter(deadline: .now() + 1) { finish(false) }
    }

    func start(headers: [String: String], reason: String = "cast") {
        stateQueue.async {
            self.proxyHeaders = headers
            self.reasons.insert(reason)
            guard !self.running, self.listener == nil else { return }
            self.startListenerLocked()
        }
    }

    /// Releases one reason. The listener only comes down once nothing needs it.
    func stop(reason: String = "cast") {
        stateQueue.async {
            self.reasons.remove(reason)
            guard self.reasons.isEmpty else { return }
            self.teardownLocked()
            // A new token per run invalidates every URL from the previous cast, so a stale
            // receiver still replaying an old URL can't keep pulling through the proxy.
            self.token = CastProxyServer.makeToken()
            Logger.shared.log("[CastProxy] Stopped", type: "Stream")
        }
    }

    private func teardownLocked() {
        listener?.cancel()
        listener = nil
        running = false
        pathMonitor?.cancel()
        pathMonitor = nil
        connections.values.forEach { $0.close() }
        connections.removeAll()
        endBackgroundTaskLocked()
        resumeWaitersLocked()
    }

    private func resumeWaitersLocked() {
        let waiting = Array(readyContinuations.values)
        readyContinuations.removeAll()
        waiting.forEach { $0.resume(returning: running) }
    }

    private func startListenerLocked() {
        beginBackgroundTaskLocked()
        startPathMonitorLocked()

        let params = NWParameters.tcp
        #if os(macOS)
        // On a Mac it serves only the players on this machine, so it listens on loopback alone,
        // which also keeps the firewall from asking to accept incoming connections.
        params.acceptLocalOnly = true
        #endif
        params.allowLocalEndpointReuse = true

        do {
            let l = try NWListener(using: params, on: port)
            l.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                self.stateQueue.async {
                    switch state {
                    case .ready:
                        self.running = true
                        self.cachedIP = Self.currentLocalIP()
                        Logger.shared.log("[CastProxy] Ready on \(self.cachedIP ?? "?"):\(self.port.rawValue)",
                                          type: "Stream")
                        self.resumeWaitersLocked()
                    case .failed(let error), .waiting(let error):
                        Logger.shared.log("[CastProxy] Listener \(state): \(error)", type: "Error")
                        // THE BUG: this used to null the listener and give up, so every
                        // later segment request hit a closed port and the TV stalled for
                        // good. Re-arm instead, as long as a cast still wants us up.
                        self.scheduleRestartLocked()
                    case .cancelled:
                        self.running = false
                    default:
                        break
                    }
                }
            }
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.start(queue: stateQueue)
            listener = l
        } catch {
            Logger.shared.log("[CastProxy] Start failed: \(error)", type: "Error")
            scheduleRestartLocked()
        }
    }

    private func scheduleRestartLocked() {
        listener?.cancel()
        listener = nil
        running = false
        guard wanted else {
            endBackgroundTaskLocked()
            resumeWaitersLocked()
            return
        }
        stateQueue.asyncAfter(deadline: .now() + restartDelay) { [weak self] in
            guard let self, self.wanted, self.listener == nil else { return }
            Logger.shared.log("[CastProxy] Re-arming listener", type: "Stream")
            self.startListenerLocked()
        }
    }

    // MARK: - Network path

    /// Watches for the LAN address changing under a live cast (Wi-Fi drop/reconnect, a
    /// hotspot switch). Every URL already on the receiver names the old address, so the
    /// media has to be re-issued or the TV simply stops fetching.
    private func startPathMonitorLocked() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            guard let self else { return }
            self.stateQueue.async {
                let fresh = Self.currentLocalIP()
                guard self.running, let fresh, fresh != self.cachedIP else { return }
                Logger.shared.log("[CastProxy] LAN address changed \(self.cachedIP ?? "?") → \(fresh)",
                                  type: "Stream")
                self.cachedIP = fresh
                let notify = self.onLocalAddressChanged
                DispatchQueue.main.async { notify?() }
            }
        }
        monitor.start(queue: stateQueue)
        pathMonitor = monitor
    }

    // MARK: - Background task

    /// Requests background execution time so the proxy survives the screen locking. The
    /// app's `audio` background mode (held by ``BackgroundKeepAlive`` during a cast) is what
    /// provides indefinite runtime; this covers the gap before that takes effect.
    private func beginBackgroundTaskLocked() {
        // A Mac app keeps running in the background without asking.
        #if os(iOS)
        // THE BUG: this used to overwrite a live identifier on every start, leaking the
        // previous assertion — iOS eventually stops granting them.
        guard backgroundTaskID == .invalid else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let id = UIApplication.shared.beginBackgroundTask(withName: "CastProxyServer") { [weak self] in
                self?.endBackgroundTask()
            }
            self.stateQueue.async {
                if self.backgroundTaskID == .invalid && self.wanted {
                    self.backgroundTaskID = id
                } else {
                    DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(id) }
                }
            }
        }
        #endif
    }

    private func endBackgroundTask() { stateQueue.async { self.endBackgroundTaskLocked() } }

    private func endBackgroundTaskLocked() {
        #if os(iOS)
        let id = backgroundTaskID
        guard id != .invalid else { return }
        backgroundTaskID = .invalid
        DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(id) }
        #endif
    }

    // MARK: - URL minting

    /// Registers subtitles to hand an AirPlay receiver with the next stream minted with the id
    /// this returns. `duration` is the video's, in seconds.
    func registerSubtitles(cues: [SubtitleCue], name: String, duration: Double) -> String {
        let id = String(UUID().uuidString.prefix(8))
        stateQueue.sync {
            subtitleSessions = [id: SubtitleSession(cues: cues, name: name, duration: duration)]
        }
        return id
    }

    /// Returns a proxied URL on the device's LAN address, signed with this run's token.
    /// - Parameters:
    ///   - playlistKey: the stream's playlist key (see ``HLSPlaylistCipher``), for a playlist
    ///     URL; nil for anything else.
    ///   - subtitlesID: from ``registerSubtitles(cues:name:duration:)``, to add those subtitles
    ///     to the stream's master playlist.
    func proxyURL(for url: URL, playlistKey: String? = nil, subtitlesID: String? = nil) -> URL? {
        stateQueue.sync {
            // Cached: a manifest rewrite calls this once per line, and `getifaddrs` per
            // segment on a long playlist is real work for a constant answer.
            let host = cachedIP ?? Self.currentLocalIP()
            cachedIP = host
            guard let host, host != "127.0.0.1" else { return nil }
            return mintLocked(url, host: host, playlistKey: playlistKey,
                              extra: subtitlesID.map { [URLQueryItem(name: "s", value: $0)] } ?? [])
        }
    }

    /// Returns a proxied URL on loopback, signed with this run's token — for a client on this
    /// device (mpv), which reaches the proxy with or without Wi-Fi.
    func loopbackURL(for url: URL, playlistKey: String? = nil, subtitlesID: String? = nil) -> URL? {
        stateQueue.sync {
            mintLocked(url, host: "127.0.0.1", playlistKey: playlistKey,
                       extra: subtitlesID.map { [URLQueryItem(name: "s", value: $0)] } ?? [])
        }
    }

    private func mintLocked(_ url: URL, host: String, playlistKey: String?, extra: [URLQueryItem] = []) -> URL? {
        var c = URLComponents()
        c.scheme = "http"
        c.host = host
        c.port = Int(port.rawValue)
        c.path = "/proxy"
        c.queryItems = [
            URLQueryItem(name: "url", value: url.absoluteString),
            URLQueryItem(name: "t", value: token)
        ]
        if let playlistKey { c.queryItems?.append(URLQueryItem(name: "k", value: playlistKey)) }
        c.queryItems?.append(contentsOf: extra)
        // `URLComponents` leaves `+` alone, which a server reads back as a space; a base64 key
        // is full of them.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url
    }

    /// Whether a request reached the proxy over loopback, going by its `Host`. Its playlists are
    /// then rewritten with loopback URLs too, so the segments don't depend on Wi-Fi either.
    static func isLoopback(hostHeader: String?) -> Bool {
        guard let host = hostHeader?.split(separator: ":").first?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost"
    }

    private static func makeToken() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    private func validate(path: String) -> Bool {
        guard let comps = URLComponents(string: "http://localhost" + path),
              let supplied = comps.queryItems?.first(where: { $0.name == "t" })?.value
        else { return false }
        return stateQueue.sync { supplied == token }
    }

    // MARK: - Connections

    private func accept(_ nwConnection: NWConnection) {
        let connection = ProxyConnection(
            connection: nwConnection,
            queue: connectionQueue,
            idleTimeout: idleTimeout,
            server: self
        )
        stateQueue.async { self.connections[ObjectIdentifier(connection)] = connection }
        connection.start()
    }

    fileprivate func retire(_ connection: ProxyConnection) {
        stateQueue.async { self.connections.removeValue(forKey: ObjectIdentifier(connection)) }
    }

    fileprivate func currentHeaders() -> [String: String] { stateQueue.sync { proxyHeaders } }

    /// Serves one parsed request onto `connection`. Returns once the response is fully
    /// written, so the connection can decide whether to read another request.
    fileprivate func serve(_ head: HTTPRequestHead, on connection: ProxyConnection) async {
        let query = URLComponents(string: "http://localhost" + head.path)
        if let path = query?.path, path == "/subs.m3u8" || path == "/subs.vtt" {
            guard validate(path: head.path),
                  let id = query?.queryItems?.first(where: { $0.name == "id" })?.value else {
                connection.writeStatus(403)
                return
            }
            await serveSubtitles(id: id, playlist: path == "/subs.m3u8", head: head, on: connection)
            return
        }
        guard validate(path: head.path), let target = head.targetURL else {
            connection.writeStatus(head.targetURL == nil ? 400 : 403)
            return
        }

        // Present only on a scrambled stream's playlists: its responses are unscrambled, and
        // the playlists they name are minted with it in turn.
        let playlistKey = URLComponents(string: "http://localhost" + head.path)?
            .queryItems?.first(where: { $0.name == "k" })?.value

        var request = URLRequest(url: target)
        request.httpMethod = head.wantsBody ? "GET" : "HEAD"
        currentHeaders().forEach { request.setValue($1, forHTTPHeaderField: $0) }

        // A manifest gets rewritten, which changes its length — so a range over it would be
        // a lie. Manifests are small and never usefully ranged, so ask for the whole thing.
        let expectManifest = playlistKey != nil || target.pathExtension.lowercased() == "m3u8"
        // A segment dressed up as an image (see HLSSegmentDisguise) is fetched whole and
        // unwrapped; the unwrapped one is shorter, so a range over it is the same lie.
        let unwrapsDisguise = !expectManifest && head.wantsBody && HLSSegmentDisguise.mayBeDisguised(target)
        if !expectManifest, !unwrapsDisguise, let range = head.value(for: "range") {
            request.setValue(range, forHTTPHeaderField: "Range")
        }

        let loopback = Self.isLoopback(hostHeader: head.value(for: "host"))
        let items = query?.queryItems ?? []
        // An alternate-audio playlist (`ar`) names its segments for evening out; such a segment
        // (`fx`) carries its key and IV (`fk`, `fiv`) when it's encrypted. Only a whole segment
        // is rewritten: a ranged request is passed through as it is.
        let isAudioPlaylist = items.contains { $0.name == "ar" }
        let repairPlan = RepairPlanBox()
        var segmentRepair: ProxyExchangeRegistry.SegmentRepair?
        if items.contains(where: { $0.name == "fx" }), head.wantsBody, unwrapsDisguise || head.value(for: "range") == nil {
            let keyURL = items.first(where: { $0.name == "fk" })?.value.flatMap(URL.init(string:))
            let iv = items.first(where: { $0.name == "fiv" })?.value.flatMap(Self.bytes(hex:))
            let crypto = keyURL.flatMap { key in iv.map { AudioSegmentRepair.Crypto(key: key, iv: $0) } }
            let host = target.host ?? "?"
            segmentRepair = .init(crypto: crypto, key: { [weak self] url in await self?.segmentKey(url) },
                                  repaired: { [weak self] in self?.noteRepaired(host: host) })
        }
        // AirPlay subtitles: `s` on the stream's own URL (add the rendition), `sp` on the
        // playlists it names (find the first segment, for the timing).
        let subtitlesID = query?.queryItems?.first(where: { $0.name == "s" })?.value
        let probeID = subtitlesID ?? query?.queryItems?.first(where: { $0.name == "sp" })?.value
        let finish: ((String, String) -> String)? = probeID.map { id in
            { [weak self] original, rewritten in
                guard let self else { return rewritten }
                self.recordSegments(of: original, baseURL: target, subtitlesID: id)
                guard let subtitlesID else { return rewritten }
                return self.addSubtitles(to: original, rewritten: rewritten, target: target,
                                         playlistKey: playlistKey, subtitlesID: subtitlesID,
                                         loopback: loopback)
            }
        }
        await exchanges.run(request: request,
                            on: upstream,
                            connection: connection,
                            wantsBody: head.wantsBody,
                            rewriteManifestFrom: target,
                            playlistKey: playlistKey,
                            finish: finish,
                            prepare: isAudioPlaylist ? { text in
                                repairPlan.plan = AudioSegmentRepair.plan(mediaPlaylist: text, baseURL: target)
                            } : nil,
                            segmentRepair: segmentRepair,
                            unwrapsDisguise: unwrapsDisguise,
                            proxy: { [weak self] url, resource in
                                self?.mintNested(url, resource: resource, playlistKey: playlistKey,
                                                 probeID: probeID, loopback: loopback,
                                                 repair: repairPlan.plan?[url])
                            })
    }

    /// The repair plan of the audio playlist being rewritten, filled in before its URLs are.
    private final class RepairPlanBox: @unchecked Sendable {
        var plan: [URL: AudioSegmentRepair.Crypto?]?
    }

    /// `hex` as bytes; nil unless it's an even run of hex digits.
    static func bytes(hex: String) -> Data? {
        let digits = Array(hex.utf8)
        guard digits.count % 2 == 0 else { return nil }
        var out = Data(capacity: digits.count / 2)
        for i in stride(from: 0, to: digits.count, by: 2) {
            guard let byte = UInt8(String(decoding: digits[i..<i + 2], as: UTF8.self), radix: 16) else { return nil }
            out.append(byte)
        }
        return out
    }

    /// An audio segment's AES-128 key, fetched once with the stream's headers.
    private func segmentKey(_ url: URL) async -> Data? {
        if let cached = stateQueue.sync(execute: { segmentKeys[url] }) { return cached }
        var request = URLRequest(url: url)
        currentHeaders().forEach { request.setValue($1, forHTTPHeaderField: $0) }
        guard let (data, response) = try? await upstream.data(for: request),
              (response as? HTTPURLResponse)?.statusCode ?? 200 < 400, data.count == 16 else { return nil }
        stateQueue.sync { segmentKeys[url] = data }
        return data
    }

    private func noteRepaired(host: String) {
        let first = stateQueue.sync { repairedHosts.insert(host).inserted }
        if first { Logger.shared.log("[CastProxy] Evening out audio timestamps from \(host)", type: "Stream") }
    }

    /// A URL a playlist names, minted back through the proxy: playlists keep the stream's key
    /// and the subtitle probe, segments and keys need neither. An audio rendition is marked so
    /// its segments are minted for evening out (`repair`: nil for any other URL, `.some(nil)`
    /// for a segment in the clear).
    private func mintNested(_ url: URL, resource: CastManifestRewriter.Resource, playlistKey: String?,
                            probeID: String?, loopback: Bool,
                            repair: AudioSegmentRepair.Crypto??) -> URL? {
        stateQueue.sync {
            let host = loopback ? "127.0.0.1" : (cachedIP ?? Self.currentLocalIP())
            guard let host else { return nil }
            var extra: [URLQueryItem] = []
            if resource.isPlaylist, let probeID { extra.append(URLQueryItem(name: "sp", value: probeID)) }
            if resource == .audioPlaylist { extra.append(URLQueryItem(name: "ar", value: "1")) }
            if case .some(let crypto) = repair {
                extra.append(URLQueryItem(name: "fx", value: "1"))
                if let crypto {
                    extra.append(URLQueryItem(name: "fk", value: crypto.key.absoluteString))
                    extra.append(URLQueryItem(name: "fiv", value: crypto.iv.map { String(format: "%02x", $0) }.joined()))
                }
            }
            return mintLocked(url, host: host, playlistKey: resource.isPlaylist ? playlistKey : nil, extra: extra)
        }
    }

    // MARK: - AirPlay subtitles

    private func subtitleURL(_ path: String, id: String, loopback: Bool) -> String? {
        stateQueue.sync {
            let host = loopback ? "127.0.0.1" : (cachedIP ?? Self.currentLocalIP())
            guard let host else { return nil }
            var c = URLComponents()
            c.scheme = "http"
            c.host = host
            c.port = Int(port.rawValue)
            c.path = path
            c.queryItems = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "t", value: token)]
            return c.url?.absoluteString
        }
    }

    /// The stream's top playlist with the subtitle rendition in it — or, for a stream that is a
    /// single media playlist, a master around it that names both.
    private func addSubtitles(to original: String, rewritten: String, target: URL, playlistKey: String?,
                              subtitlesID: String, loopback: Bool) -> String {
        let name = stateQueue.sync { subtitleSessions[subtitlesID]?.name }
        guard let name, let uri = subtitleURL("/subs.m3u8", id: subtitlesID, loopback: loopback) else { return rewritten }
        let tag = AirPlaySubtitles.mediaTag(uri: uri, name: name)
        if original.contains("#EXT-X-STREAM-INF") {
            return AirPlaySubtitles.inject(into: rewritten, mediaTag: tag)
        }
        guard let media = mintNested(target, resource: .playlist, playlistKey: playlistKey,
                                     probeID: subtitlesID, loopback: loopback, repair: nil) else { return rewritten }
        return AirPlaySubtitles.wrap(mediaPlaylistURL: media.absoluteString, mediaTag: tag)
    }

    /// Notes a media playlist's first segment and init map, once per subtitle session.
    private func recordSegments(of playlist: String, baseURL: URL, subtitlesID: String) {
        guard !playlist.contains("#EXT-X-STREAM-INF") else { return }
        var initSegment: URL?
        var first: URL?
        for raw in playlist.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-MAP:"),
               let range = line.range(of: "(?<=[:,])URI=\"[^\"]*\"", options: .regularExpression) {
                let value = String(line[range].dropFirst(5).dropLast())
                initSegment = CastManifestRewriter.resolve(value, relativeTo: baseURL)
            } else if !line.isEmpty, !line.hasPrefix("#") {
                first = CastManifestRewriter.resolve(line, relativeTo: baseURL)
                break
            }
        }
        guard let first else { return }
        stateQueue.sync {
            guard subtitleSessions[subtitlesID] != nil, subtitleSessions[subtitlesID]?.firstSegment == nil else { return }
            subtitleSessions[subtitlesID]?.firstSegment = first
            subtitleSessions[subtitlesID]?.initSegment = initSegment
        }
    }

    private func serveSubtitles(id: String, playlist: Bool, head: HTTPRequestHead, on connection: ProxyConnection) async {
        guard let session = stateQueue.sync(execute: { subtitleSessions[id] }) else {
            connection.writeStatus(404)
            return
        }
        let loopback = Self.isLoopback(hostHeader: head.value(for: "host"))
        if playlist {
            guard let vtt = subtitleURL("/subs.vtt", id: id, loopback: loopback) else {
                connection.writeStatus(404)
                return
            }
            respond(AirPlaySubtitles.subtitlePlaylist(vttURL: vtt, duration: session.duration),
                    type: "application/x-mpegURL", wantsBody: head.wantsBody, on: connection)
            return
        }
        let timestamp = await firstTimestamp(for: id)
        respond(AirPlaySubtitles.webVTT(cues: session.cues, firstTimestamp: timestamp ?? 0),
                type: "text/vtt", wantsBody: head.wantsBody, on: connection)
    }

    /// The stream's first timestamp, read once off its first segment. The receiver can ask for
    /// the subtitles before the video's media playlist has come through, so this waits a little
    /// for that to name the segment.
    private func firstTimestamp(for id: String) async -> Int64? {
        var session = stateQueue.sync { subtitleSessions[id] }
        for _ in 0..<30 where session?.firstSegment == nil {
            try? await Task.sleep(nanoseconds: 100_000_000)
            session = stateQueue.sync { subtitleSessions[id] }
        }
        guard let session, let segment = session.firstSegment else {
            Logger.shared.log("[AirPlay] Subtitles served unmapped: no segment seen yet", type: "Stream")
            return nil
        }
        if let known = session.firstTimestamp { return known }
        let headers = currentHeaders()
        func fetch(_ url: URL, range: String?) async -> Data? {
            var request = URLRequest(url: url, timeoutInterval: 15)
            headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
            if let range { request.setValue(range, forHTTPHeaderField: "Range") }
            return try? await URLSession.shared.data(for: request).0
        }
        let timestamp: Int64?
        if let initURL = session.initSegment {
            guard let initData = await fetch(initURL, range: nil),
                  let start = await fetch(segment, range: "bytes=0-65535") else { return nil }
            timestamp = AirPlaySubtitles.firstTimestamp(fragmentedInit: initData, segment: start)
        } else {
            guard let start = await fetch(segment, range: "bytes=0-37599") else { return nil }
            timestamp = AirPlaySubtitles.firstTimestamp(transportStream: start)
        }
        Logger.shared.log("[AirPlay] Subtitles mapped to timestamp \(timestamp.map(String.init) ?? "none")", type: "Stream")
        stateQueue.sync { subtitleSessions[id]?.firstTimestamp = timestamp }
        return timestamp
    }

    private func respond(_ text: String, type: String, wantsBody: Bool, on connection: ProxyConnection) {
        let body = Data(text.utf8)
        var head = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
        head += "Access-Control-Allow-Origin: *\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
        guard connection.writeBlocking(Data(head.utf8)) else { return }
        if wantsBody { _ = connection.writeBlocking(body) }
    }

    // MARK: - Local IP

    /// The device's current Wi-Fi address (en0) — the one a Chromecast or Apple TV can
    /// reach. Returns nil rather than 127.0.0.1 so callers can refuse to mint a URL that
    /// could never work off-device.
    private static func currentLocalIP() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }
            let iface = current.pointee
            guard iface.ifa_addr.pointee.sa_family == UInt8(AF_INET),
                  (iface.ifa_flags & UInt32(IFF_UP)) != 0,
                  let name = iface.ifa_name.map({ String(cString: $0) }),
                  name == "en0" else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(iface.ifa_addr,
                              socklen_t(iface.ifa_addr.pointee.sa_len),
                              &hostname, socklen_t(hostname.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            address = String(cString: hostname)
            break
        }
        return address
    }
}

// MARK: - Connection

/// One accepted TCP connection: reads request heads (across as many packets as it takes),
/// hands each to the server, and reclaims itself when idle or broken.
fileprivate final class ProxyConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let idleTimeout: TimeInterval
    private weak var server: CastProxyServer?

    private let lock = NSLock()
    private var buffer = Data()
    private var closed = false
    private var idleTimer: DispatchSourceTimer?
    /// When bytes last moved either way. Idle means nothing moved for `idleTimeout`, not that
    /// the request is older than that: a whole episode goes out over one response, and timing
    /// from the request cut mpv off mid-file once a minute.
    private var lastActivity = DispatchTime.now()

    /// A head larger than this is not a real request — refuse it rather than buffer forever.
    private static let maxHeadBytes = 64 * 1024

    init(connection: NWConnection, queue: DispatchQueue, idleTimeout: TimeInterval, server: CastProxyServer) {
        self.connection = connection
        self.queue = queue
        self.idleTimeout = idleTimeout
        self.server = server
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
        armIdleTimer()
        receive()
    }

    // MARK: Reading

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil || (isComplete && data == nil) { self.close(); return }
            guard let data, !data.isEmpty else {
                if isComplete { self.close() } else { self.receive() }
                return
            }

            self.lock.lock()
            self.buffer.append(data)
            let pending = self.buffer
            self.lock.unlock()

            guard pending.count <= Self.maxHeadBytes else {
                self.writeStatus(431); self.close(); return
            }

            // THE BUG this loop fixes: the old server parsed whatever a single `receive`
            // happened to deliver. A head split across TCP segments — routine — parsed as
            // garbage and the connection was dropped, stalling the cast with no error.
            guard let head = HTTPRequestHead.parse(pending) else {
                self.receive()   // incomplete, keep reading
                return
            }

            self.lock.lock(); self.buffer.removeAll(keepingCapacity: true); self.lock.unlock()
            self.armIdleTimer()

            Task { [weak self] in
                guard let self, let server = self.server else { return }
                await server.serve(head, on: self)
                guard !self.isClosed else { return }
                self.armIdleTimer()
                self.receive()   // HTTP/1.1 keep-alive: the receiver reuses this socket
            }
        }
    }

    // MARK: Writing

    /// Sends `data`, blocking the caller until the socket has taken it. That block is the
    /// backpressure: without it a fast CDN outruns a slow Wi-Fi link and the queued chunks
    /// become an unbounded buffer — which is how the old whole-file approach died.
    func writeBlocking(_ data: Data) -> Bool {
        guard !isClosed, !data.isEmpty else { return !isClosed }
        let semaphore = DispatchSemaphore(value: 0)
        var ok = true
        connection.send(content: data, completion: .contentProcessed { error in
            if error != nil { ok = false }
            semaphore.signal()
        })
        semaphore.wait()
        if !ok { close() } else { markActivity() }
        return ok
    }

    func writeStatus(_ status: Int) {
        let reason = HTTPURLResponse.localizedString(forStatusCode: status)
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        _ = writeBlocking(Data(head.utf8))
        close()
    }

    // MARK: Lifecycle

    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    private func armIdleTimer() {
        lock.lock()
        lastActivity = .now()
        idleTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + idleTimeout)
        timer.setEventHandler { [weak self] in self?.idleTimerFired() }
        idleTimer = timer
        timer.resume()
        lock.unlock()
    }

    private func markActivity() {
        lock.lock()
        lastActivity = .now()
        lock.unlock()
    }

    /// Closes the connection if nothing has moved for the whole timeout; otherwise waits out
    /// the rest of it from the last activity.
    private func idleTimerFired() {
        lock.lock()
        let deadline = lastActivity + idleTimeout
        if deadline > .now(), let timer = idleTimer {
            timer.schedule(deadline: deadline)
            lock.unlock()
            return
        }
        lock.unlock()
        close()
    }

    /// Idempotent — every path (idle, peer hangup, send failure, server shutdown) lands here.
    /// The old server never closed anything, so a movie's worth of segment requests slowly
    /// used up the process's sockets.
    func close() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        idleTimer?.cancel()
        idleTimer = nil
        lock.unlock()

        connection.stateUpdateHandler = nil
        connection.cancel()
        server?.retire(self)
    }
}

// MARK: - Upstream exchange

/// Pumps one upstream response into one client connection.
///
/// Streams by default. Only a manifest is buffered — it has to be complete before its URLs
/// can be rewritten — and manifests are kilobytes.
fileprivate final class ProxyExchangeRegistry: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    private final class Exchange {
        let connection: ProxyConnection
        let wantsBody: Bool
        let manifestBase: URL
        let playlistKey: String?
        /// Last say over a rewritten manifest: (as fetched, rewritten) → served.
        let finishManifest: ((String, String) -> String)?
        let proxy: (URL, CastManifestRewriter.Resource) -> URL?
        let prepare: ((String) -> Void)?
        let segmentRepair: SegmentRepair?
        let unwrapsDisguise: Bool
        var isManifest = false
        /// A segment held whole to be unwrapped or evened out before it's sent.
        var isRepairing = false
        var manifestBuffer = Data()
        var headerSent = false
        var failed = false
        var finish: ((Void) -> Void)?

        init(connection: ProxyConnection, wantsBody: Bool, manifestBase: URL, playlistKey: String?,
             finish: ((String, String) -> String)?, prepare: ((String) -> Void)?,
             segmentRepair: SegmentRepair?, unwrapsDisguise: Bool,
             proxy: @escaping (URL, CastManifestRewriter.Resource) -> URL?) {
            self.finishManifest = finish
            self.prepare = prepare
            self.segmentRepair = segmentRepair
            self.unwrapsDisguise = unwrapsDisguise
            self.connection = connection
            self.wantsBody = wantsBody
            self.manifestBase = manifestBase
            self.playlistKey = playlistKey
            self.proxy = proxy
        }
    }

    /// How to even out an audio segment's timestamps (see ``AudioSegmentRepair``).
    struct SegmentRepair {
        let crypto: AudioSegmentRepair.Crypto?
        let key: (URL) async -> Data?
        let repaired: () -> Void
    }

    private let lock = NSLock()
    private var active: [Int: Exchange] = [:]
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]

    func run(request: URLRequest,
             on session: URLSession,
             connection: ProxyConnection,
             wantsBody: Bool,
             rewriteManifestFrom base: URL,
             playlistKey: String? = nil,
             finish: ((String, String) -> String)? = nil,
             prepare: ((String) -> Void)? = nil,
             segmentRepair: SegmentRepair? = nil,
             unwrapsDisguise: Bool = false,
             proxy: @escaping (URL, CastManifestRewriter.Resource) -> URL?) async {
        let task = session.dataTask(with: request)
        let exchange = Exchange(connection: connection, wantsBody: wantsBody, manifestBase: base,
                                playlistKey: playlistKey, finish: finish, prepare: prepare,
                                segmentRepair: segmentRepair, unwrapsDisguise: unwrapsDisguise, proxy: proxy)
        lock.lock(); active[task.taskIdentifier] = exchange; lock.unlock()

        await withCheckedContinuation { continuation in
            lock.lock(); continuations[task.taskIdentifier] = continuation; lock.unlock()
            task.resume()
        }
    }

    private func exchange(for task: URLSessionTask) -> Exchange? {
        lock.lock(); defer { lock.unlock() }
        return active[task.taskIdentifier]
    }

    private func complete(_ task: URLSessionTask) {
        lock.lock()
        active.removeValue(forKey: task.taskIdentifier)
        let continuation = continuations.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        continuation?.resume()
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let exchange = exchange(for: dataTask) else { completionHandler(.cancel); return }
        let http = response as? HTTPURLResponse
        if let http, http.statusCode >= 400 {
            // Passed on as is; logged so a refusal is plainly the server's, not the proxy's.
            Logger.shared.log("[CastProxy] \(http.url?.host ?? "Upstream") answered \(http.statusCode)", type: "Error")
        }
        let mime = http?.value(forHTTPHeaderField: "Content-Type")
            ?? response.mimeType
            ?? Self.mimeType(for: exchange.manifestBase.pathExtension)

        // A scrambled playlist comes back as text/plain base64, so its key marks it instead.
        exchange.isManifest = exchange.playlistKey != nil
            || CastManifestRewriter.isManifest(mime: mime, url: exchange.manifestBase)

        if exchange.isManifest {
            // Length is unknown until the rewrite is done, so the head waits.
            completionHandler(.allow)
            return
        }
        if exchange.segmentRepair != nil || exchange.unwrapsDisguise, (200..<300).contains(http?.statusCode ?? 200) {
            // Held whole until it's unwrapped or evened out; the head goes with it.
            exchange.isRepairing = true
            completionHandler(.allow)
            return
        }

        // Pass the upstream's own status and framing through untouched: a 206 with its
        // Content-Range is exactly what lets the receiver seek.
        let status = http?.statusCode ?? 200
        var head = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))\r\n"
        head += "Content-Type: \(mime)\r\n"
        if let range = http?.value(forHTTPHeaderField: "Content-Range") { head += "Content-Range: \(range)\r\n" }
        if let length = http?.value(forHTTPHeaderField: "Content-Length") { head += "Content-Length: \(length)\r\n" }
        // Advertised unconditionally: the receiver only attempts a seek if it believes
        // ranges are available, and the upstream honours them.
        head += "Accept-Ranges: bytes\r\n"
        head += "Access-Control-Allow-Origin: *\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"

        exchange.headerSent = true
        if !exchange.connection.writeBlocking(Data(head.utf8)) {
            exchange.failed = true
            completionHandler(.cancel)
            return
        }
        completionHandler(exchange.wantsBody ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let exchange = exchange(for: dataTask), !exchange.failed else { return }
        guard exchange.wantsBody else { return }

        if exchange.isManifest || exchange.isRepairing {
            exchange.manifestBuffer.append(data)
            return
        }
        // Blocks until the socket accepts it — see ProxyConnection.writeBlocking.
        if !exchange.connection.writeBlocking(data) {
            exchange.failed = true
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let exchange = exchange(for: task) else { complete(task); return }
        if exchange.isRepairing, error == nil, !exchange.failed {
            // Answered once it's unwrapped and evened out: the request isn't done until then,
            // so the connection reads no next request before this one's body is written.
            let original = exchange.unwrapsDisguise
                ? HLSSegmentDisguise.unwrap(exchange.manifestBuffer) : exchange.manifestBuffer
            let repair = exchange.segmentRepair
            Task {
                var fixed: Data?
                if let repair {
                    var key: Data?
                    if let crypto = repair.crypto { key = await repair.key(crypto.key) }
                    fixed = AudioSegmentRepair.repaired(original, crypto: repair.crypto, key: key)
                    if fixed != nil { repair.repaired() }
                }
                let body = fixed ?? original
                var head = "HTTP/1.1 200 OK\r\n"
                head += "Content-Type: video/mp2t\r\n"
                head += "Content-Length: \(body.count)\r\n"
                head += "Access-Control-Allow-Origin: *\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
                if exchange.connection.writeBlocking(Data(head.utf8)) {
                    _ = exchange.connection.writeBlocking(body)
                }
                self.complete(task)
            }
            return
        }
        defer { complete(task) }

        if exchange.failed { exchange.connection.close(); return }

        if let error {
            let cancelled = (error as NSError).code == NSURLErrorCancelled
            if !cancelled && !exchange.headerSent {
                Logger.shared.log("[CastProxy] Upstream failed: \(error.localizedDescription)", type: "Error")
                exchange.connection.writeStatus(502)
            } else if !cancelled {
                // Already streaming when it broke — the framing is unrecoverable, so drop
                // the socket and let the receiver re-request.
                exchange.connection.close()
            }
            return
        }

        guard exchange.isManifest else { return }

        let body: Data
        let text = exchange.playlistKey.map { HLSPlaylistCipher.decode(exchange.manifestBuffer, key: $0) }
            ?? String(data: exchange.manifestBuffer, encoding: .utf8)
        if exchange.playlistKey != nil, text == nil {
            Logger.shared.log("[CastProxy] Couldn't unscramble a playlist from \(exchange.manifestBase.host ?? "?") with the module's key", type: "Error")
        }
        if let text {
            exchange.prepare?(text)
            let rewritten = CastManifestRewriter.rewrite(text,
                                                         baseURL: exchange.manifestBase,
                                                         resource: exchange.proxy)
            body = Data((exchange.finishManifest?(text, rewritten) ?? rewritten).utf8)
        } else {
            body = exchange.manifestBuffer
        }

        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: application/x-mpegURL\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Access-Control-Allow-Origin: *\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
        guard exchange.connection.writeBlocking(Data(head.utf8)) else { return }
        if exchange.wantsBody { _ = exchange.connection.writeBlocking(body) }
    }

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "m3u8": return "application/x-mpegURL"
        case "ts":   return "video/mp2t"
        case "mp4", "m4s": return "video/mp4"
        case "vtt":  return "text/vtt"
        default:     return "application/octet-stream"
        }
    }
}
#endif
