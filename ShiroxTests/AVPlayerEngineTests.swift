import XCTest
import AVFoundation
@testable import Shirox

/// The AVPlayer engine against real files: silent audio of a known length, written for each test.
@MainActor
final class AVPlayerEngineTests: XCTestCase {

    private var engine: AVPlayerEngine!
    private var files: [URL] = []

    override func setUp() async throws {
        engine = AVPlayerEngine()
    }

    override func tearDown() async throws {
        engine.stop()
        engine = nil
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    /// `seconds` of silence as a CAF file.
    private func silence(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("engine-\(UUID().uuidString).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let frames = AVAudioFrameCount(seconds * 44_100)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        files.append(url)
        return url
    }

    /// Loads a file and waits for it to be ready.
    private func loadReady(seconds: Double) async throws {
        let ready = expectation(description: "ready")
        ready.assertForOverFulfill = false
        engine.events.itemReady = { ready.fulfill() }
        engine.load(PlaybackSource(url: try silence(seconds: seconds)))
        await fulfillment(of: [ready], timeout: 5)
    }

    func testALoadedFileBecomesReadyWithItsDuration() async throws {
        try await loadReady(seconds: 2)
        XCTAssertTrue(engine.isItemReady)
        XCTAssertFalse(engine.isItemFailed)
        XCTAssertEqual(engine.duration ?? 0, 2, accuracy: 0.05)
    }

    func testAMissingFileFails() async {
        let failed = expectation(description: "failed")
        failed.assertForOverFulfill = false
        engine.events.itemFailed = { _ in failed.fulfill() }
        engine.load(PlaybackSource(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).caf")))
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertTrue(engine.isItemFailed)
    }

    func testPlayingReportsPlayingAndTheClockTicks() async throws {
        try await loadReady(seconds: 2)
        let playing = expectation(description: "playing")
        playing.assertForOverFulfill = false
        let ticked = expectation(description: "ticked")
        ticked.assertForOverFulfill = false
        engine.events.timeControlChanged = { if $0 == .playing { playing.fulfill() } }
        engine.events.tick = { ticked.fulfill() }
        engine.rate = 1
        await fulfillment(of: [playing, ticked], timeout: 5)
        engine.pause()
        XCTAssertEqual(engine.timeControl, .paused)
        XCTAssertEqual(engine.rate, 0)
    }

    /// A downloaded HLS episode, served over the loopback proxy as the player gets one, with
    /// stall-minimisation off as the player sets it for downloads. AVPlayer told to play before
    /// anything has arrived gives up — rate 0 while still reporting `.playing` — and never
    /// started on its own, so every downloaded HLS episode opened from the start sat on its
    /// first frame.
    func testADownloadedHLSEpisodeStartsWithStallWaitingOff() async throws {
        let folder = try await TestVideo.makeHLS(seconds: 6, segmentSeconds: 2)
        files.append(folder)
        let proxy = HLSProxyServer.shared
        let savedPort = proxy.port
        proxy.stop()
        proxy.port = 18765
        await proxy.startAndWait(headers: [:])
        defer {
            proxy.stop()
            proxy.port = savedPort
        }
        let url = try XCTUnwrap(proxy.proxyURL(for: folder.appendingPathComponent("playlist.m3u8")))

        // In the order `PlayerView.setupPlayer()` starts a downloaded episode.
        engine.load(PlaybackSource(url: url))
        // Somewhere to draw, as the player's layer is: AVPlayer doesn't start a picture-only
        // item with nowhere to show it.
        engine.player.currentItem?.add(AVPlayerItemVideoOutput(pixelBufferAttributes: nil))
        engine.waitsToMinimizeStalling = false
        engine.rate = 1
        engine.play()

        let deadline = Date().addingTimeInterval(8)
        while engine.currentTime < 1, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertGreaterThan(engine.currentTime, 1, "playback never left the first frame")
    }

    func testAnExactSeekLandsOnItsTime() async throws {
        try await loadReady(seconds: 2)
        await engine.seek(to: 1.25, precision: .exact)
        XCTAssertEqual(engine.currentTime, 1.25, accuracy: 0.02)
    }

    func testASeekWithACompletionCallsIt() async throws {
        try await loadReady(seconds: 2)
        let done = expectation(description: "seeked")
        engine.seek(to: 0.5, precision: .within(0.5)) { _ in done.fulfill() }
        await fulfillment(of: [done], timeout: 5)
    }

    func testPlayingToTheEndIsReported() async throws {
        try await loadReady(seconds: 0.5)
        let ended = expectation(description: "ended")
        engine.events.playedToEnd = { ended.fulfill() }
        engine.rate = 1
        await fulfillment(of: [ended], timeout: 5)
    }

    /// A swap replaces the item, as `replaceCurrentItem(with:)` did.
    func testASecondLoadReplacesTheFirst() async throws {
        try await loadReady(seconds: 2)
        try await loadReady(seconds: 1)
        XCTAssertEqual(engine.duration ?? 0, 1, accuracy: 0.05)
    }

    func testTheBitrateCapReachesTheItemAndNilLiftsIt() throws {
        engine.load(PlaybackSource(url: try silence(seconds: 1)))
        engine.setPeakBitRate(2_000_000)
        XCTAssertEqual(engine.player.currentItem?.preferredPeakBitRate, 2_000_000)
        engine.setPeakBitRate(nil)
        XCTAssertEqual(engine.player.currentItem?.preferredPeakBitRate, 0)
    }

    func testStallMinimisationAndVolumePassThrough() {
        engine.waitsToMinimizeStalling = false
        XCTAssertFalse(engine.player.automaticallyWaitsToMinimizeStalling)
        engine.volume = 0.25
        XCTAssertEqual(engine.player.volume, 0.25)
    }

    /// A plain audio file offers no choice of language, so there's nothing to pick.
    func testAFileWithoutAlternativesOffersNoAudioOptions() async throws {
        try await loadReady(seconds: 1)
        XCTAssertTrue(engine.audioOptions.isEmpty)
        XCTAssertNil(engine.selectedAudioOption)
    }

    /// After `stop()` nothing reaches the old listener — the next `setupPlayer()` owns the screen.
    func testAStoppedEngineReportsNothing() throws {
        var heard = false
        engine.events.itemReady = { heard = true }
        engine.load(PlaybackSource(url: try silence(seconds: 1)))
        engine.stop()
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertFalse(heard)
    }
    /// Opens the two-language stream, putting `wanted` on as the player does when the engine
    /// lists the tracks, and returns the track playing a second after the item is ready.
    private func playTwoLanguages(wanting wanted: String, prefersJapanese: Bool) async throws -> String? {
        let server = try await HLSServer.twoLanguages()
        defer { server.stop() }
        engine.events.audioOptionsChanged = { [unowned self] in
            if let id = TrackPreferences.audioToRestore(wanted, options: engine.audioOptions) {
                engine.selectAudioOption(id)
            }
        }
        let ready = expectation(description: "ready")
        ready.assertForOverFulfill = false
        engine.events.itemReady = { ready.fulfill() }
        var source = PlaybackSource(url: server.url(of: "/master.m3u8"))
        source.prefersJapaneseAudio = prefersJapanese
        engine.load(source)
        engine.player.currentItem?.add(AVPlayerItemVideoOutput(pixelBufferAttributes: nil))
        await fulfillment(of: [ready], timeout: 10)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        return engine.audioOptions.first { $0.id == engine.selectedAudioOption }?.title
    }

    /// The player switches to the show's remembered track as soon as the engine lists the
    /// tracks, here over the Japanese a subbed stream starts on. It has to hold once the item
    /// is ready.
    func testARememberedTrackPutOnAsTheTracksAreListedHolds() async throws {
        let playing = try await playTwoLanguages(wanting: "English", prefersJapanese: true)
        XCTAssertEqual(playing, "English")
    }

    /// Reported: the audio picked for a show wasn't there when it was opened again, though the
    /// subtitles were. The stream's default track, Japanese, read as already on while the item
    /// loaded, so the remembered Japanese was left be; then, once ready, AVPlayer moved to the
    /// device's language on its own. Picked outright, it stays.
    func testARememberedTrackThatLooksOnAlreadyStaysOn() async throws {
        let playing = try await playTwoLanguages(wanting: "Japanese", prefersJapanese: false)
        XCTAssertEqual(playing, "Japanese")
    }
}

extension HLSServer {
    /// One variant of a 2 s 16×16 black picture with two AAC audio renditions, Japanese (the
    /// default) and English. Audio made with ffmpeg: `-f lavfi -i anullsrc=r=44100:cl=mono -t 2
    /// -c:a aac -b:a 24k -f mpegts`.
    static func twoLanguages() async throws -> HLSServer {
        let media = { (segment: String) in
            "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:0\n"
                + "#EXT-X-PLAYLIST-TYPE:VOD\n#EXTINF:2.0,\n\(segment)\n#EXT-X-ENDLIST\n"
        }
        let audio = Data(base64Encoded: "R0AREABC8CUAAcEAAP8B/wAB/IAUSBIBBkZGbXBlZwlTZXJ2aWNlMDF3fEPK//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////9HQAAQAACwDQABwQAAAAHwACqxBLL//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////0dQABAAArASAAHBAADhAPAAD+EA8AC2m8DZ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////R0EAMAdQAAB7DH4AAAABwADJgIAFIQAH2GH/8VBAA5/83gIATGF2YzYxLjE5LjEwMQACMEAO//FQQAF//AEYIAf/8VBAAX/8ARggB//xUEABf/wBGCAH//FQQAF//AEYIAf/8VBAAX/8ARggB//xUEABf/wBGCAH//FQQAF//AEYIAf/8VBAAX/8ARggB//xUEABf/wBGCAH//FQQAF//AEYIAf/8VBAAX/8ARggB//xUEABf/wBGCAH//FHAQAxmAD/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////UEABf/wBGCAH//FQQAF//AEYIAf/8VBAAX/8ARggB0dAABEAALANAAHBAAAAAfAAKrEEsv//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////R1AAEQACsBIAAcEAAOEA8AAP4QDwALabwNn///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////9HQQAyB1AAALxa/gAAAAHAALiAgAUhAAndm//xUEABf/wBGCAH//FQQAF//AEYIAf/8VBAAX/8ARggB//xUEABf/wBGCAH//FQQAF//AEYIAf/8VBAAX/8ARggB//xUEABf/wBGCAH//FQQAF//AEYIAf/8VBAAX/8ARggB//xUEABf/wBGCAH//FQQAF//AEYIAf/8VBAAX/8ARggB//xUEABf/wBGCAH//FQQAF//AEYIAf/8VBAAX/8AUcBADOpAP///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////xggB//xUEABf/wBGCAHR0AREQBC8CUAAcEAAP8B/wAB/IAUSBIBBkZGbXBlZwlTZXJ2aWNlMDF3fEPK//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////9HQAASAACwDQABwQAAAAHwACqxBLL//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////0dQABIAArASAAHBAADhAPAAD+EA8AC2m8DZ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////R0EANAdQAAD9qX4AAAABwAC4gIAFIQAL4tX/8VBAAX/8ARggB//xUEABf/wBGCAH//FQQAF//AEYIAf/8VBAAX/8ARggB//xUEABf/wBGCAH//FQQAF//AEYIAf/8VBAAX/8ARggB//xUEABf/wBGCAH//FQQAF//AEYIAf/8VBAAX/8ARggB//xUEABf/wBGCAH//FQQAF//AEYIAf/8VBAAX/8ARggB//xUEABf/wBGCAH//FQQAF//AFHAQA1qQD///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8YIAf/8VBAAX/8ARggB0dAABMAALANAAHBAAAAAfAAKrEEsv//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////R1AAEwACsBIAAcEAAOEA8AAP4QDwALabwNn///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////9HQQA2B1AAAT73fgAAAAHAALiAgAUhAA3oDf/xUEABf/wBGCAH//FQQAF//AEYIAf/8VBAAX/8ARggB//xUEABf/wBGCAH//FQQAF//AEYIAf/8VBAAX/8ARggB//xUEABf/wBGCAH//FQQAF//AEYIAf/8VBAAX/8ARggB//xUEABf/wBGCAH//FQQAF//AEYIAf/8VBAAX/8ARggB//xUEABf/wBGCAH//FQQAF//AEYIAf/8VBAAX/8AUcBADepAP///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////xggB//xUEABf/wBGCAHR0AREgBC8CUAAcEAAP8B/wAB/IAUSBIBBkZGbXBlZwlTZXJ2aWNlMDF3fEPK//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////9HQAAUAACwDQABwQAAAAHwACqxBLL//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////0dQABQAArASAAHBAADhAPAAD+EA8AC2m8DZ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////R0EAOAdQAAGARf4AAAABwAC4gIAFIQAP7Uf/8VBAAX/8ARggB//xUEABf/wBGCAH//FQQAF//AEYIAf/8VBAAX/8ARggB//xUEABf/wBGCAH//FQQAF//AEYIAf/8VBAAX/8ARggB//xUEABf/wBGCAH//FQQAF//AEYIAf/8VBAAX/8ARggB//xUEABf/wBGCAH//FQQAF//AEYIAf/8VBAAX/8ARggB//xUEABf/wBGCAH//FQQAF//AFHAQA5qQD///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8YIAf/8VBAAX/8ARggB0dAABUAALANAAHBAAAAAfAAKrEEsv//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////R1AAFQACsBIAAcEAAOEA8AAP4QDwALabwNn///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////9HQQA6UVAAAcGUfgD//////////////////////////////////////////////////////////////////////////////////////////////////wAAAcAAYICABSEAEfKB//FQQAF//AEYIAf/8VBAAX/8ARggB//xUEABf/wBGCAH//FQQAF//AEYIAf/8VBAAX/8ARggB//xUEABf/wBGCAH//FQQAF//AEYIAf/8VBAAX/8ARggBw==")!
        return try await start(files: [
            "/master.m3u8": Data(("#EXTM3U\n"
                + "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"Japanese\",LANGUAGE=\"ja\",DEFAULT=YES,AUTOSELECT=YES,URI=\"ja.m3u8\"\n"
                + "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"English\",LANGUAGE=\"en\",AUTOSELECT=YES,URI=\"en.m3u8\"\n"
                + "#EXT-X-STREAM-INF:BANDWIDTH=200000,CODECS=\"avc1.4d400a,mp4a.40.2\",RESOLUTION=16x16,AUDIO=\"aud\"\nvideo.m3u8\n").utf8),
            "/video.m3u8": Data(media("video.ts").utf8),
            "/ja.m3u8": Data(media("ja.ts").utf8),
            "/en.m3u8": Data(media("en.ts").utf8),
            "/video.ts": blackSegment,
            "/ja.ts": audio,
            "/en.ts": audio,
        ])
    }
}
