#if os(iOS)
import XCTest
import AVFoundation
import Network
@testable import Shirox

/// A ReAnime-style stream end to end: every playlist scrambled, video and audio as separate
/// renditions, and a CDN that refuses any request without the module's headers. It has to play
/// through the proxy, carry AirPlay subtitles, and download into something that plays offline.
@MainActor
final class ScrambledStreamPlaybackTests: XCTestCase {

    private static let moduleHeaders = ["X-Module-Client": "shirox-test", "Referer": "https://site.test/"]
    private var server: FixtureHTTPServer!
    private var video: URL!
    private var audio: URL!
    private let proxy = CastProxyServer.shared
    private var savedPort: NWEndpoint.Port!

    override func setUp() async throws {
        savedPort = proxy.port
        // Clear of the app's own port, which a copy running in a simulator on this Mac may hold.
        proxy.port = 18772
        video = try await TestVideo.makeHLS(seconds: 4, segmentSeconds: 1)
        audio = try await TestAudio.makeHLS(seconds: 4, segmentSeconds: 1)
        server = try await FixtureHTTPServer.start(requiredHeaders: Self.moduleHeaders)
        let key = ScrambledPlaylistTests.key
        server.routes["/master"] = (ScrambledPlaylistTests.scramble("""
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Japanese",LANGUAGE="ja",DEFAULT=YES,AUTOSELECT=YES,URI="audio/index.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=400000,AUDIO="aud"
        video/index.m3u8
        """, key: key), "text/plain")
        // HD-2: one 2 s TS segment dressed up as a .webp.
        server.routes["/hd2/master"] = (ScrambledPlaylistTests.scramble("""
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=200000,CODECS="avc1.4d400a",RESOLUTION=16x16
        index.m3u8
        """, key: key), "text/plain")
        server.routes["/hd2/index.m3u8"] = (ScrambledPlaylistTests.scramble("""
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:2
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:2.0,
        seg-0.webp
        #EXT-X-ENDLIST
        """, key: key), "text/plain")
        server.routes["/hd2/seg-0.webp"] = (ScrambledPlaylistTests.disguise(HLSServer.blackSegment), "image/webp")
        for (name, folder) in [("video", video!), ("audio", audio!)] {
            let playlist = try String(contentsOf: folder.appendingPathComponent("playlist.m3u8"), encoding: .utf8)
            server.routes["/\(name)/index.m3u8"] = (ScrambledPlaylistTests.scramble(playlist, key: key), "text/plain")
            for file in try FileManager.default.contentsOfDirectory(atPath: folder.path) where file != "playlist.m3u8" {
                server.routes["/\(name)/\(file)"] = (try Data(contentsOf: folder.appendingPathComponent(file)), "video/mp4")
            }
        }
    }

    override func tearDown() async throws {
        server.stop()
        proxy.stop(reason: "test")
        proxy.port = savedPort
        try? FileManager.default.removeItem(at: video)
        try? FileManager.default.removeItem(at: audio)
    }

    private var masterURL: URL { server.url("/master") }

    // MARK: Fixture sanity

    func testTheCDNRefusesARequestWithoutTheModuleHeaders() async throws {
        let (_, response) = try await URLSession.shared.data(from: server.url("/video/init.mp4"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 403)
    }

    // MARK: Through the proxy

    func testThePlaylistsComeBackUnscrambledAndTheSegmentsUntouched() async throws {
        let up = await proxy.startAndWait(headers: Self.moduleHeaders, reason: "test")
        XCTAssertTrue(up)
        let master = try await text(XCTUnwrap(proxy.loopbackURL(for: masterURL, playlistKey: ScrambledPlaylistTests.keyString)))
        XCTAssertTrue(master.hasPrefix("#EXTM3U"), master)
        let videoLine = try XCTUnwrap(master.components(separatedBy: "\n").last { $0.hasPrefix("http://127.0.0.1") })
        XCTAssertTrue(videoLine.contains("&k="), "a nested playlist keeps the key")

        let media = try await text(XCTUnwrap(URL(string: videoLine)))
        XCTAssertTrue(media.contains("#EXT-X-MAP:URI=\"http://127.0.0.1"), media)
        let segmentLine = try XCTUnwrap(media.components(separatedBy: "\n").first { $0.hasPrefix("http") })
        XCTAssertFalse(segmentLine.contains("&k="), "segments aren't scrambled")
        let (segment, _) = try await URLSession.shared.data(from: XCTUnwrap(URL(string: segmentLine)))
        XCTAssertEqual(segment, try Data(contentsOf: video.appendingPathComponent("seg_0.m4s")))
        XCTAssertFalse(server.refused.contains { _ in true }, "a request went out without the module's headers")
    }

    func testADisguisedSegmentComesBackUnwrapped() async throws {
        let up = await proxy.startAndWait(headers: Self.moduleHeaders, reason: "test")
        XCTAssertTrue(up)
        let master = try await text(XCTUnwrap(proxy.loopbackURL(for: server.url("/hd2/master"),
                                                                playlistKey: ScrambledPlaylistTests.keyString)))
        let variant = try XCTUnwrap(master.components(separatedBy: "\n").first { $0.hasPrefix("http") })
        let media = try await text(XCTUnwrap(URL(string: variant)))
        let segmentLine = try XCTUnwrap(media.components(separatedBy: "\n").first { $0.hasPrefix("http") })
        var request = URLRequest(url: try XCTUnwrap(URL(string: segmentLine)))
        request.setValue("bytes=0-", forHTTPHeaderField: "Range")
        let (segment, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual(segment, HLSServer.blackSegment)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), "video/mp2t")
    }

    /// Reported: HD-2 stalled at 0:00 on both players, its segments arriving as image files.
    func testAVPlayerPlaysAStreamWithDisguisedSegments() async throws {
        let engine = AVPlayerEngine()
        var source = PlaybackSource(url: server.url("/hd2/master"), headers: Self.moduleHeaders)
        source.playlistKey = ScrambledPlaylistTests.keyString
        engine.load(source)
        let item = try await readyItem(engine.player)
        engine.play()
        try await waitUntil("playback advances") { engine.player.currentTime().seconds > 0.5 }
        XCTAssertEqual(item.duration.seconds, 2, accuracy: 0.5)
        engine.stop()
    }

    /// Given the proxy's URL as its router would: the router leaves the fixture's loopback
    /// host alone.
    func testMPVPlaysAStreamWithDisguisedSegments() async throws {
        let up = await proxy.startAndWait(headers: Self.moduleHeaders, reason: "test")
        XCTAssertTrue(up)
        let url = try XCTUnwrap(proxy.loopbackURL(for: server.url("/hd2/master"),
                                                  playlistKey: ScrambledPlaylistTests.keyString))
        let engine = MPVEngine(output: .none)
        defer { engine.stop() }
        let ready = expectation(description: "ready")
        ready.assertForOverFulfill = false
        engine.events.itemReady = { ready.fulfill() }
        engine.load(PlaybackSource(url: url))
        await fulfillment(of: [ready], timeout: 15)
        engine.play()
        try await waitUntil("playback advances") { engine.currentTime > 0.5 }
    }

    func testAVPlayerPlaysTheScrambledStreamWithItsSeparateAudio() async throws {
        let engine = AVPlayerEngine()
        var source = PlaybackSource(url: masterURL, headers: Self.moduleHeaders)
        source.playlistKey = ScrambledPlaylistTests.keyString
        engine.load(source)
        let item = try await readyItem(engine.player)
        XCTAssertEqual(item.duration.seconds, 4, accuracy: 0.5)
        engine.play()
        try await waitUntil("playback advances") { engine.player.currentTime().seconds > 0.5 }
        let kinds = Set(item.tracks.compactMap { $0.assetTrack?.mediaType })
        XCTAssertTrue(kinds.contains(.video), "\(kinds)")
        XCTAssertTrue(kinds.contains(.audio), "\(kinds)")
        XCTAssertTrue(server.served.contains("/audio/init.mp4"))
        XCTAssertTrue(server.refused.isEmpty, "refused: \(server.refused)")
        engine.stop()
    }

    func testAirPlaySubtitlesRideInTheStream() async throws {
        let up = await proxy.startAndWait(headers: Self.moduleHeaders, reason: "test")
        XCTAssertTrue(up)
        let id = proxy.registerSubtitles(cues: [SubtitleCue(start: 0.5, end: 3, text: "Hello from Shirox")],
                                         name: "English", duration: 4)
        let url = try XCTUnwrap(proxy.loopbackURL(for: masterURL, playlistKey: ScrambledPlaylistTests.keyString,
                                                  subtitlesID: id))
        let master = try await text(url)
        XCTAssertTrue(master.contains("TYPE=SUBTITLES,GROUP-ID=\"shirox-subs\",NAME=\"English\""), master)
        XCTAssertTrue(master.contains("SUBTITLES=\"shirox-subs\""), master)

        var source = PlaybackSource(url: url)
        source.selectsSubtitles = true
        let engine = AVPlayerEngine()
        engine.load(source)
        let item = try await readyItem(engine.player)
        let legible = try await item.asset.loadMediaSelectionGroup(for: .legible)
        let group = try XCTUnwrap(legible)
        XCTAssertEqual(group.options.map(\.displayName), ["English"])
        try await waitUntil("the subtitles are switched on") {
            item.currentMediaSelection.selectedMediaOption(in: group) != nil
        }
        engine.stop()

        let tag = try XCTUnwrap(master.components(separatedBy: "\n").first { $0.contains("TYPE=SUBTITLES") })
        let uriStart = try XCTUnwrap(tag.range(of: "URI=\"")).upperBound
        let subsURL = String(tag[uriStart...].dropLast())
        let playlist = try await text(XCTUnwrap(URL(string: subsURL)))
        let vttURL = try XCTUnwrap(playlist.components(separatedBy: "\n").first { $0.hasPrefix("http") })
        let vtt = try await text(XCTUnwrap(URL(string: vttURL)))
        XCTAssertTrue(vtt.hasPrefix("WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000"), vtt)
        XCTAssertTrue(vtt.contains("00:00:00.500 --> 00:00:03.000\nHello from Shirox"), vtt)
    }

    // MARK: Downloading

    func testItDownloadsWithItsAudioAndPlaysOffline() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        let progress = ProgressBox()
        let path = try await HLSDownloader().download(
            id: id, url: masterURL, headers: Self.moduleHeaders, playlistKey: ScrambledPlaylistTests.keyString,
            downloadDir: dir, onProgress: { progress.last = $0 })
        XCTAssertEqual(path, "\(id.uuidString)/playlist.m3u8")
        XCTAssertEqual(progress.last, 1, accuracy: 0.0001)

        let folder = dir.appendingPathComponent(id.uuidString)
        let master = try String(contentsOf: folder.appendingPathComponent("playlist.m3u8"), encoding: .utf8)
        XCTAssertTrue(master.contains("URI=\"audio.m3u8\""), master)
        XCTAssertTrue(master.hasSuffix("video.m3u8"), master)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("a_init.mp4")),
                       try Data(contentsOf: audio.appendingPathComponent("init.mp4")))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("a_seg_0.m4s")),
                       try Data(contentsOf: audio.appendingPathComponent("seg_0.m4s")))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("seg_0.m4s")),
                       try Data(contentsOf: video.appendingPathComponent("seg_0.m4s")))

        // Played the way a finished download is: through the local HLS server.
        await HLSProxyServer.shared.startAndWait(headers: [:])
        let local = try XCTUnwrap(HLSProxyServer.shared.proxyURL(for: folder.appendingPathComponent("playlist.m3u8")))
        let served = try await text(local)
        XCTAssertTrue(served.contains("#EXT-X-MEDIA:TYPE=AUDIO") && served.contains("URI=\"http://"), served)
        let engine = AVPlayerEngine()
        engine.load(PlaybackSource(url: local))
        let item = try await readyItem(engine.player)
        engine.play()
        try await waitUntil("offline playback advances") { engine.player.currentTime().seconds > 0.5 }
        let kinds = Set(item.tracks.compactMap { $0.assetTrack?.mediaType })
        XCTAssertTrue(kinds.contains(.audio) && kinds.contains(.video), "\(kinds)")
        engine.stop()
    }

    /// Only the default subtitle used to be saved, so offline the other languages were gone.
    func testADownloadKeepsEverySubtitleTrack() async throws {
        server.routes["/subs/en.vtt"] = (Data("WEBVTT\n\n00:00:00.500 --> 00:00:02.000\nHello\n".utf8), "text/vtt")
        server.routes["/subs/es.vtt"] = (Data("WEBVTT\n\n00:00:00.500 --> 00:00:02.000\nHola\n".utf8), "text/vtt")
        let english = SubtitleTrack(title: "English", url: server.url("/subs/en.vtt"), headers: Self.moduleHeaders)
        let spanish = SubtitleTrack(title: "Español", url: server.url("/subs/es.vtt"), headers: Self.moduleHeaders)
        let stream = StreamResult(title: "1080p", url: masterURL, headers: Self.moduleHeaders,
                                  subtitle: english.url.absoluteString, subtitleHeaders: Self.moduleHeaders,
                                  allSubtitles: [english, spanish], playlistKey: ScrambledPlaylistTests.keyString)
        let manager = DownloadManager.shared
        let href = "test://subs/\(UUID().uuidString)"
        manager.download(stream: stream, episodeHref: href, context: DownloadContext(
            mediaTitle: "Subtitle Test", episodeNumber: 1, episodeTitle: nil, imageUrl: "", aniListID: nil,
            moduleId: "test", detailHref: nil, episodeHref: href, streamTitle: "1080p", totalEpisodes: nil),
            enrichSnapshot: false)
        var item: DownloadItem? { manager.items.first { $0.episodeHref == href } }
        defer { if let item { manager.remove(item) } }

        try await waitUntil("the episode and both tracks are downloaded", timeout: 60) {
            guard let item else { return false }
            if item.state == .failed { throw URLError(.badServerResponse) }
            return item.state == .completed && item.subtitleTracks?.allSatisfy { $0.relativePath != nil } == true
        }
        let done = try XCTUnwrap(item)
        XCTAssertEqual(done.subtitleTracks?.map(\.title), ["English", "Español"])
        XCTAssertEqual(done.subtitleTracks?.first?.relativePath, done.relativeSubtitlePath,
                       "the default is one of the tracks: one file serves both")

        let offline = await manager.getStream(for: done)
        let played = try XCTUnwrap(offline)
        let tracks = try XCTUnwrap(played.allSubtitles)
        XCTAssertEqual(tracks.map(\.title), ["English", "Español"])
        XCTAssertTrue(tracks.allSatisfy(\.url.isFileURL))
        XCTAssertEqual(try String(contentsOf: tracks[1].url, encoding: .utf8).contains("Hola"), true)
        XCTAssertEqual(played.subtitle, tracks[0].url.absoluteString, "the default still comes up first")

        // Deleting the download takes every track with it.
        manager.remove(done)
        for track in tracks { XCTAssertFalse(FileManager.default.fileExists(atPath: track.url.path), track.title) }
    }

    func testADownloadSavedBeforeTracksWereKeptStillDecodes() throws {
        let json = #"{"id":"5E3D0000-0000-4000-8000-0000000000AA","mediaTitle":"T","episodeNumber":1,"imageUrl":"","episodeHref":"h","headers":{},"state":"completed","progress":1,"createdAt":0,"retryCount":0}"#
        let item = try JSONDecoder().decode(DownloadItem.self, from: Data(json.utf8))
        XCTAssertNil(item.subtitleTracks)
    }

    func testADownloadWithTheWrongKeyFailsPlainly() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            _ = try await HLSDownloader().download(
                id: UUID(), url: masterURL, headers: Self.moduleHeaders,
                playlistKey: Data([1, 2, 3]).base64EncodedString(), downloadDir: dir, onProgress: { _ in })
            XCTFail("downloaded with the wrong key")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("unscrambled"), error.localizedDescription)
        }
    }

    // MARK: Helpers

    private func text(_ url: URL) async throws -> String {
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, url.absoluteString)
        return String(decoding: data, as: UTF8.self)
    }

    /// The player's item once it's ready, with a video sink attached — AVPlayer won't start a
    /// video item without one.
    private func readyItem(_ player: AVPlayer) async throws -> AVPlayerItem {
        try await waitUntil("an item is loaded") { player.currentItem != nil }
        let item = try XCTUnwrap(player.currentItem)
        item.add(AVPlayerItemVideoOutput(pixelBufferAttributes: nil))
        try await waitUntil("the item is ready (\(String(describing: item.error)))", timeout: 20) {
            if item.status == .failed { throw item.error ?? URLError(.unknown) }
            return item.status == .readyToPlay
        }
        return item
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 15, _ condition: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while try !condition() {
            if Date() > deadline { XCTFail("timed out waiting until \(what)"); throw URLError(.timedOut) }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

private final class ProgressBox: @unchecked Sendable {
    var last = 0.0
}

/// Test audio made on the spot: a 440 Hz tone, AAC, as an fMP4 HLS rendition.
enum TestAudio {
    static func makeHLS(seconds: Int, segmentSeconds: Int) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // PCM tone in a CAF, read back as sample buffers for the AAC encoder.
        let tone = folder.appendingPathComponent("tone.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let frames = AVAudioFrameCount(44_100 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<2 {
            let samples = buffer.floatChannelData![channel]
            for i in 0..<Int(frames) { samples[i] = 0.2 * sin(2 * .pi * 440 * Float(i) / 44_100) }
        }
        do {
            let file = try AVAudioFile(forWriting: tone, settings: format.settings)
            try file.write(from: buffer)
        }

        let asset = AVURLAsset(url: tone)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)

        let writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(value: CMTimeValue(segmentSeconds), timescale: 1)
        writer.initialSegmentStartTime = .zero
        let collector = Collector()
        writer.delegate = collector
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000,
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        XCTAssertTrue(reader.startReading())
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        while let sample = output.copyNextSampleBuffer() {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            input.append(sample)
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, String(describing: writer.error))

        try XCTUnwrap(collector.initialization).write(to: folder.appendingPathComponent("init.mp4"))
        for (index, segment) in collector.media.enumerated() {
            try segment.data.write(to: folder.appendingPathComponent("seg_\(index).m4s"))
        }
        try FileManager.default.removeItem(at: tone)
        let playlist = HLSManifestParser.localManifest(durations: collector.media.map(\.duration),
                                                       segmentExtension: "m4s", initFileName: "init.mp4")
        try playlist.write(to: folder.appendingPathComponent("playlist.m3u8"), atomically: true, encoding: .utf8)
        return folder
    }

    private final class Collector: NSObject, AVAssetWriterDelegate {
        var initialization: Data?
        var media: [(data: Data, duration: Double)] = []
        func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data,
                         segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
            switch segmentType {
            case .initialization: initialization = segmentData
            case .separable:
                let duration = segmentReport?.trackReports.first?.duration.seconds ?? 1
                media.append((segmentData, duration))
            @unknown default: break
            }
        }
    }
}

/// A tiny HTTP server for fixtures: answers each path from `routes`, refuses (403) any request
/// missing `requiredHeaders`, and remembers what it served and refused.
final class FixtureHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.fixture-server")
    private let requiredHeaders: [String: String]
    private let lock = NSLock()
    private var _routes: [String: (Data, String)] = [:]
    private var _served: [String] = []
    private var _refused: [String] = []

    var routes: [String: (Data, String)] {
        get { lock.lock(); defer { lock.unlock() }; return _routes }
        set { lock.lock(); _routes = newValue; lock.unlock() }
    }
    var served: [String] { lock.lock(); defer { lock.unlock() }; return _served }
    var refused: [String] { lock.lock(); defer { lock.unlock() }; return _refused }

    private init(listener: NWListener, requiredHeaders: [String: String]) {
        self.listener = listener
        self.requiredHeaders = requiredHeaders
    }

    static func start(requiredHeaders: [String: String]) async throws -> FixtureHTTPServer {
        let server = FixtureHTTPServer(listener: try NWListener(using: .tcp, on: .any), requiredHeaders: requiredHeaders)
        await withCheckedContinuation { (ready: CheckedContinuation<Void, Never>) in
            var resumed = false
            server.listener.stateUpdateHandler = { state in
                guard case .ready = state, !resumed else { return }
                resumed = true
                ready.resume()
            }
            server.listener.newConnectionHandler = { [weak server] in server?.accept($0) }
            server.listener.start(queue: server.queue)
        }
        return server
    }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)\(path)")! }
    func stop() { listener.cancel() }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, done, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if done || error != nil { connection.cancel() } else { read(connection, buffer: buffer) }
                return
            }
            let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let target = head.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let path = target.components(separatedBy: "?")[0]
            var headers: [String: String] = [:]
            for line in head.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let authorised = requiredHeaders.allSatisfy { headers[$0.key.lowercased()] == $0.value }
            let route = routes[path]
            lock.lock()
            if !authorised { _refused.append(path) } else if route != nil { _served.append(path) }
            lock.unlock()
            let (status, body, type): (String, Data, String) = !authorised ? ("403 Forbidden", Data(), "text/plain")
                : route.map { ("200 OK", $0.0, $0.1) } ?? ("404 Not Found", Data(), "text/plain")
            let response = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(response.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
#endif
