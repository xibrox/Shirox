import XCTest
import AVFoundation
import Network
#if os(iOS)
import UIKit
#endif
@testable import Shirox

/// The mpv engine against real files — silent audio of a known length — with no video or audio
/// output, so it runs without a GPU or a sound device.
@MainActor
final class MPVEngineTests: XCTestCase {

    private var engine: MPVEngine!
    private var files: [URL] = []

    override func setUp() async throws {
        engine = MPVEngine(output: .none)
    }

    override func tearDown() async throws {
        engine.stop()
        engine = nil
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    private func silence(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mpv-\(UUID().uuidString).caf")
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

    private func loadReady(seconds: Double) async throws {
        let ready = expectation(description: "ready")
        ready.assertForOverFulfill = false
        engine.events.itemReady = { ready.fulfill() }
        engine.load(PlaybackSource(url: try silence(seconds: seconds)))
        await fulfillment(of: [ready], timeout: 10)
    }

    /// mpv read ahead as far as 150 MB would take it — minutes of a stream, every byte through the
    /// proxy and decrypted as fast as the network would go, and all of it thrown away by a seek.
    /// It reads two minutes ahead, which rides out any stall worth riding out.
    func testReadsAheadTwoMinutesNotTheWholeFile() async throws {
        try await loadReady(seconds: 300)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertGreaterThan(engine.bufferedUntil, 60, "it should still read well ahead")
        XCTAssertLessThan(engine.bufferedUntil, 150, "read ahead to \(engine.bufferedUntil) s")
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
        await fulfillment(of: [failed], timeout: 10)
        XCTAssertTrue(engine.isItemFailed)
        XCTAssertFalse(engine.isItemReady)
    }

    /// A load doesn't start playback — the player decides when.
    func testLoadingLeavesItPaused() async throws {
        try await loadReady(seconds: 2)
        XCTAssertEqual(engine.rate, 0)
        XCTAssertEqual(engine.timeControl, .paused)
    }

    func testPlayingReportsPlayingAndTheClockTicks() async throws {
        try await loadReady(seconds: 3)
        let playing = expectation(description: "playing")
        playing.assertForOverFulfill = false
        let ticked = expectation(description: "ticked")
        ticked.assertForOverFulfill = false
        engine.events.timeControlChanged = { if $0 == .playing { playing.fulfill() } }
        // The first tick is the starting position; wait for one where the clock has moved.
        engine.events.tick = { [unowned engine] in if engine!.currentTime > 0 { ticked.fulfill() } }
        engine.rate = 1.5
        await fulfillment(of: [playing, ticked], timeout: 10)
        XCTAssertEqual(engine.rate, 1.5)
        engine.pause()
        XCTAssertEqual(engine.rate, 0)
        XCTAssertEqual(engine.timeControl, .paused)
    }

    func testAnExactSeekLandsOnItsTime() async throws {
        try await loadReady(seconds: 2)
        await engine.seek(to: 1.25, precision: .exact)
        XCTAssertEqual(engine.currentTime, 1.25, accuracy: 0.05)
    }

    /// The resume seek can come while the file is still opening; mpv can't seek until it has, so
    /// the seek waits for it instead of being dropped.
    func testASeekAskedForWhileLoadingLandsOnceLoaded() async throws {
        engine.load(PlaybackSource(url: try silence(seconds: 3)))
        XCTAssertFalse(engine.isItemReady)
        await engine.seek(to: 2, precision: .exact)
        XCTAssertTrue(engine.isItemReady)
        XCTAssertEqual(engine.currentTime, 2, accuracy: 0.05)
    }

    /// The saved quality preference arrives while the file opens; it's reported ready once, as it
    /// is when the cap reopens it (see `testACapOnAnotherVariantReopensTheStreamOnIt`).
    func testACapSetWhileLoadingReportsReadyOnce() async throws {
        var readyCount = 0
        let ready = expectation(description: "ready")
        engine.events.itemReady = {
            readyCount += 1
            ready.fulfill()
        }
        engine.load(PlaybackSource(url: try silence(seconds: 2)))
        engine.setPeakBitRate(1_000_000)
        await fulfillment(of: [ready], timeout: 10)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(readyCount, 1)
        XCTAssertTrue(engine.isItemReady)
        XCTAssertEqual(engine.duration ?? 0, 2, accuracy: 0.05)
    }

    func testASeekWithACompletionCallsIt() async throws {
        try await loadReady(seconds: 2)
        let done = expectation(description: "seeked")
        engine.seek(to: 0.5, precision: .within(0.5)) { _ in done.fulfill() }
        await fulfillment(of: [done], timeout: 10)
    }

    func testPlayingToTheEndIsReported() async throws {
        try await loadReady(seconds: 0.5)
        let ended = expectation(description: "ended")
        engine.events.playedToEnd = { ended.fulfill() }
        engine.rate = 1
        await fulfillment(of: [ended], timeout: 10)
    }

    func testASecondLoadReplacesTheFirst() async throws {
        try await loadReady(seconds: 2)
        try await loadReady(seconds: 1)
        XCTAssertEqual(engine.duration ?? 0, 1, accuracy: 0.05)
    }

    func testVolumeIsKeptAsSet() {
        engine.volume = 0.25
        XCTAssertEqual(engine.volume, 0.25, accuracy: 0.001)
    }

    func testAFileWithOneAudioTrackOffersIt() async throws {
        try await loadReady(seconds: 1)
        if engine.audioOptions.isEmpty {
            let options = expectation(description: "options")
            options.assertForOverFulfill = false
            engine.events.audioOptionsChanged = { options.fulfill() }
            await fulfillment(of: [options], timeout: 10)
        }
        XCTAssertEqual(engine.audioOptions.count, 1)
    }

    // MARK: - Quality

    /// Loads `url` with the cap set as it opens, as the player does. Returns how often it was
    /// reported ready.
    @discardableResult
    private func loadReady(_ url: URL, cappedAt cap: Int?) async -> Int {
        var readyCount = 0
        let ready = expectation(description: "ready")
        ready.assertForOverFulfill = false
        engine.events.itemReady = {
            readyCount += 1
            ready.fulfill()
        }
        engine.load(PlaybackSource(url: url))
        engine.setPeakBitRate(cap)
        await fulfillment(of: [ready], timeout: 10)
        // Long enough for a reopen to have fetched the stream again.
        try? await Task.sleep(nanoseconds: 500_000_000)
        return readyCount
    }

    /// The saved quality preference arrives while the stream opens. When it picks the variant
    /// mpv opens anyway — the highest, as it did on every stream in the logs — the stream is
    /// left be: reopening fetched all of it a second time, and every open took twice as long.
    func testACapOnTheVariantBeingOpenedDoesntFetchTheStreamAgain() async throws {
        let server = try await HLSServer.twoVariants()
        defer { server.stop() }
        await loadReady(server.url(of: "/master.m3u8"), cappedAt: 1_000_000)
        XCTAssertEqual(server.fetches(of: "/low.m3u8"), 1)
        XCTAssertEqual(engine.selectedAudioOption, 2, "on the high variant")
    }

    /// A cap on another variant reopens the stream on that one, and it's reported ready once.
    func testACapOnAnotherVariantReopensTheStreamOnIt() async throws {
        let server = try await HLSServer.twoVariants()
        defer { server.stop() }
        let readyCount = await loadReady(server.url(of: "/master.m3u8"), cappedAt: 600_000)
        XCTAssertEqual(engine.selectedAudioOption, 1, "on the low variant")
        XCTAssertEqual(readyCount, 1)
    }

    /// Choosing the quality already playing from the menu doesn't restart it either.
    func testACapOnTheVariantPlayingDoesntFetchTheStreamAgain() async throws {
        let server = try await HLSServer.twoVariants()
        defer { server.stop() }
        await loadReady(server.url(of: "/master.m3u8"), cappedAt: nil)
        engine.setPeakBitRate(1_000_000)
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(server.fetches(of: "/low.m3u8"), 1)
    }

    /// Choosing another quality from the menu reopens the stream on it.
    func testACapOnAnotherVariantOnceOpenReopensTheStreamOnIt() async throws {
        let server = try await HLSServer.twoVariants()
        defer { server.stop() }
        await loadReady(server.url(of: "/master.m3u8"), cappedAt: nil)
        let reopened = expectation(description: "reopened")
        reopened.assertForOverFulfill = false
        engine.events.itemReady = { reopened.fulfill() }
        engine.setPeakBitRate(600_000)
        await fulfillment(of: [reopened], timeout: 10)
        XCTAssertEqual(engine.selectedAudioOption, 1, "on the low variant")
    }

    /// The saved quality usually arrives once the stream is already playing, and a cap on
    /// another variant reopens it. The audio rendition put on before then is still on after.
    func testAnAudioRenditionPickedBeforeAReopenStaysOn() async throws {
        let server = try await HLSServer.twoVariantsTwoLanguages()
        defer { server.stop() }
        await loadReady(server.url(of: "/master.m3u8"), cappedAt: nil)
        let english = try XCTUnwrap(engine.audioOptions.first { $0.title == "English" })
        engine.selectAudioOption(english.id)
        let reopened = expectation(description: "reopened")
        reopened.assertForOverFulfill = false
        engine.events.itemReady = { reopened.fulfill() }
        engine.setPeakBitRate(600_000)
        await fulfillment(of: [reopened], timeout: 10)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(server.fetches(of: "/low.m3u8"), 2, "reopened on the low variant")
        XCTAssertEqual(engine.selectedAudioOption, english.id)
    }

    // MARK: - Routing

    /// Stands in for the proxy: sends every source to a local file, and records what it was asked.
    final class FakeRouter: MPVRouter {
        var target: URL
        var routed: [URL] = []
        var released = 0
        var delay: UInt64 = 0
        init(target: URL) { self.target = target }
        func route(_ source: PlaybackSource) async -> PlaybackSource {
            routed.append(source.url)
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            return PlaybackSource(url: target)
        }
        func release() { released += 1 }
    }

    /// mpv plays what the router hands it, not the stream's own URL.
    func testARoutedSourceIsWhatPlays() async throws {
        let router = FakeRouter(target: try silence(seconds: 2))
        engine.stop()
        engine = MPVEngine(output: .none, router: router)
        let ready = expectation(description: "ready")
        engine.events.itemReady = { ready.fulfill() }
        engine.load(PlaybackSource(url: URL(string: "https://cdn.invalid/ep1.m3u8")!,
                                   headers: ["Referer": "https://site.invalid/"]))
        await fulfillment(of: [ready], timeout: 10)
        XCTAssertEqual(router.routed, [URL(string: "https://cdn.invalid/ep1.m3u8")!])
        XCTAssertEqual(engine.duration ?? 0, 2, accuracy: 0.05)
    }

    /// A load that's replaced while its route is still being worked out never opens.
    func testASupersededRouteIsDropped() async throws {
        let first = try silence(seconds: 3)
        let router = FakeRouter(target: first)
        router.delay = 300_000_000
        engine.stop()
        engine = MPVEngine(output: .none, router: router)
        engine.load(PlaybackSource(url: URL(string: "https://cdn.invalid/ep1.m3u8")!))
        router.delay = 0
        router.target = try silence(seconds: 1)
        let ready = expectation(description: "ready")
        ready.assertForOverFulfill = false
        engine.events.itemReady = { ready.fulfill() }
        engine.load(PlaybackSource(url: URL(string: "https://cdn.invalid/ep2.m3u8")!))
        await fulfillment(of: [ready], timeout: 10)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertEqual(engine.duration ?? 0, 1, accuracy: 0.05, "the second episode is what's loaded")
    }

    func testStoppingReleasesTheRoute() throws {
        let router = FakeRouter(target: try silence(seconds: 1))
        engine.stop()
        engine = MPVEngine(output: .none, router: router)
        engine.load(PlaybackSource(url: URL(string: "https://cdn.invalid/ep1.m3u8")!))
        engine.stop()
        XCTAssertEqual(router.released, 1)
    }

    /// Thirty seconds of a 16×16 black picture at 2 fps as HLS, with no audio: ten 3 s segments and
    /// a keyframe every 10 s, so most segments don't start on one. Made with ffmpeg: `-f lavfi -i
    /// color=c=black:s=16x16:r=2:d=30,format=yuv420p -c:v libx264 -profile:v main -g 20
    /// -keyint_min 20 -sc_threshold 0 -bf 0 -f hls -hls_time 3 -hls_flags split_by_time`.
    private static let sparseKeyframeSegments = [
        "R0AREABC8CUAAcEAAP8B/wAB/IAUSBIBBkZGbXBlZwlTZXJ2aWNlMDF3fEPK//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////9HQAAQAACwDQABwQAAAAHwACqxBLL//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////0dQABAAArASAAHBAADhAPAAG+EA8AAVvU1W////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////R0EAMAdQAAB7DH4AAAAB4AAAgIAFIQAH2GEAAAABCfAAAAABZ01ACtkewEQAAAMABAAAAwAQPEiZIAAAAAFo68PLIAAAAQYF//9r3EXpvebZSLeWLNgg2SPu73gyNjQgLSBjb3JlIDE2NCByMzEwOCAzMWUxOWY5IC0gSC4yNjQvTVBFRy00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyMyAtIGh0dHA6Ly93d3cudmlkZW9sYW5HAQARLm9yZy94MjY0Lmh0bWwgLSBvcHRpb25zOiBjYWJhYz0xIHJlZj0zIGRlYmxvY2s9MTowOjAgYW5hbHlzZT0weDE6MHgxMTEgbWU9aGV4IHN1Ym1lPTcgcHN5PTEgcHN5X3JkPTEuMDA6MC4wMCBtaXhlZF9yZWY9MSBtZV9yYW5nZT0xNiBjaHJvbWFfbWU9MSB0cmVsbGlzPTEgOHg4ZGN0PTAgY3FtPTAgZGVhZHpvbmU9MjEsMUcBABIxIGZhc3RfcHNraXA9MSBjaHJvbWFfcXBfb2Zmc2V0PS0yIHRocmVhZHM9MSBsb29rYWhlYWRfdGhyZWFkcz0xIHNsaWNlZF90aHJlYWRzPTAgbnI9MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTAgd2VpZ2h0cD0yIGtleWludD0yMCBrZXlpbnRfRwEAMxsA//////////////////////////////////9taW49MTEgc2NlbmVjdXQ9MCBpbnRyYV9yZWZyZXNoPTAgcmNfbG9va2FoZWFkPTIwIHJjPWNyZiBtYnRyZWU9MSBjcmY9MjMuMCBxY29tcD0wLjYwIHFwbWluPTAgcXBtYXg9NjkgcXBzdGVwPTQgaXBfcmF0aW89MS40MCBhcT0xOjEuMDAAgAAAAAFliIQFf/73ye/Apuvb34FHQQA0lxAAANLwfgD///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHgAACAgAUhAAs38QAAAAEJ8AAAAAFBmjsQV//+8EdBADWUEAABKtR+AP///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////wAAAeAAAICABSEADZeBAAAAAQnwAAAAAUGaTwhkymEFf/7xR0EANpMQAAGCuH4A//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHgAACAgAUhAA/3EQAAAAEJ8AAAAAFBmnJ4Q8mUwIK//vBHQQA3kxAAAdqcfgD//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////wAAAeAAAICABSEAE1ahAAAAAQnwAAAAAUGaknhDyZTAgr/+8UdBADiTEAACMoB+AP//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAAB4AAAgIAFIQAVtjEAAAABCfAAAAABQZqyeEPJlMCCv/7x",
        "R0AREQBC8CUAAcEAAP8B/wAB/IAUSBIBBkZGbXBlZwlTZXJ2aWNlMDF3fEPK//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////9HQAARAACwDQABwQAAAAHwACqxBLL//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////0dQABEAArASAAHBAADhAPAAG+EA8AAVvU1W////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////R0EAOZMQAAKKZH4A//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHgAACAgAUhABkVwQAAAAEJ8AAAAAFBmtJ4Q8mUwIK//vFHQQA6kxAAAuJIfgD//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////wAAAeAAAICABSEAG3VRAAAAAQnwAAAAAUGa8nhDyZTAgr/+8UdBADuTEAADOix+AP//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAAB4AAAgIAFIQAd1OEAAAABCfAAAAABQZsSeEPJlMCCv/7wR0EAPJMQAAOSEH4A//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHgAACAgAUhACE0cQAAAAEJ8AAAAAFBmzJ4Q8mUwIK//vBHQQA9kxAAA+n0fgD//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////wAAAeAAAICABSEAI5QBAAAAAQnwAAAAAUGbUnhDyZTAgr/+8UdBAD6TEAAEQdh+AP//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAAB4AAAgIAFIQAl85EAAAABCfAAAAABQZtyeEPJlMCCv/7w",
        "R0AREgBC8CUAAcEAAP8B/wAB/IAUSBIBBkZGbXBlZwlTZXJ2aWNlMDF3fEPK//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////9HQAASAACwDQABwQAAAAHwACqxBLL//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////0dQABIAArASAAHBAADhAPAAG+EA8AAVvU1W////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////R0EAP5MQAASZvH4A//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHgAACAgAUhAClTIQAAAAEJ8AAAAAFBm5J4Q8mUwIK//vBHQQAwkxAABPGgfgD//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////wAAAeAAAICABSEAK7KxAAAAAQnwAAAAAUGbsnhDyZTAgr/+8UdBADGTEAAFSYR+AP//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAAB4AAAgIAFIQAvEkEAAAABCfAAAAABQZvSeEPJlMCCv/7xR0EAMpMQAAWhaH4A//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHgAACAgAUhADFx0QAAAAEJ8AAAAAFBm/J4Q8mUwIK//vFHQQAzkxAABflMfgD//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////wAAAeAAAICABSEAM9FhAAAAAQnwAAAAAUGaEnhDyZTAgr/+8EdBADSTEAAGUTB+AP//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAAB4AAAgIAFIQA3MPEAAAABCfAAAAABQZoyeEPJlMCCv/7w",
        "R0AREwBC8CUAAcEAAP8B/wAB/IAUSBIBBkZGbXBlZwlTZXJ2aWNlMDF3fEPK//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////9HQAATAACwDQABwQAAAAHwACqxBLL//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////0dQABMAArASAAHBAADhAPAAG+EA8AAVvU1W////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////R0EANZMQAAapFH4A//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHgAACAgAUhADmQgQAAAAEJ8AAAAAFBmlJ4Q8mUwIK//vFHQQA2kxAABwD4fgD//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////wAAAeAAAICABSEAO/ARAAAAAQnwAAAAAUGacnhDyZTAgr/+8EdAABQAALANAAHBAAAAAfAAKrEEsv//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////R1AAFAACsBIAAcEAAOEA8AAb4QDwABW9TVb///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////9HQQA3bVAAB1jcfgD///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHgAACAgAUhAD9PoQAAAAEJ8AAAAAFnTUAK2R7ARAAAAwAEAAADABA8SJkgAAAAAWjrw8sgAAAAAWWIggF//vfUt8yy7gcjgEdBADiXEAAHsMB+AP///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////wAAAeAAAICABSEAQa8xAAAAAQnwAAAAAUGaOxBX//7xR0EAOZQQAAgIpH4A////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAAB4AAAgIAFIQBFDsEAAAABCfAAAAABQZpPCGTKYQV//vBHQQA6kxAACGCIfgD//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////wAAAeAAAICABSEAR25RAAAAAQnwAAAAAUGacnhDyZTAgr/+8Q==",
        "R0ARFABC8CUAAcEAAP8B/wAB/IAUSBIBBkZGbXBlZwlTZXJ2aWNlMDF3fEPK//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////9HQAAVAACwDQABwQAAAAHwACqxBLL//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////0dQABUAArASAAHBAADhAPAAG+EA8AAVvU1W////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////R0EAO5MQAAi4bH4A//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHgAACAgAUhAEnN4QAAAAEJ8AAAAAFBmpJ4Q8mUwIK//vFHQQA8kxAACRBQfgD//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////wAAAeAAAICABSEATS1xAAAAAQnwAAAAAUGasnhDyZTAgr/+8EdBAD2TEAAJaDR+AP//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAAB4AAAgIAFIQBPjQEAAAABCfAAAAABQZrSeEPJlMCCv/7xR0EAPpMQAAnAGH4A//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHgAACAgAUhAFHskQAAAAEJ8AAAAAFBmvJ4Q8mUwIK//vBHQQA/kxAAChf8fgD//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////wAAAeAAAICABSEAVUwhAAAAAQnwAAAAAUGbEnhDyZTAgr/+8UdBADCTEAAKb+B+AP//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAAB4AAAgIAFIQBXq7EAAAABCfAAAAABQZsyeEPJlMCCv/7x",
        "R0ARFQBC8CUAAcEAAP8B/wAB/IAUSBIBBkZGbXBlZwlTZXJ2aWNlMDF3fEPK//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////9HQAAWAACwDQABwQAAAAHwACqxBLL//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////0dQABYAArASAAHBAADhAPAAG+EA8AAVvU1W////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////R0EAMZMQAArHxH4A//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHgAACAgAUhAFsLQQAAAAEJ8AAAAAFBm1J4Q8mUwIK//vBHQQAykxAACx+ofgD//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////wAAAeAAAICABSEAXWrRAAAAAQnwAAAAAUGbcnhDyZTAgr/+8EdBADOTEAALd4x+AP//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAAB4AAAgIAFIQBfymEAAAABCfAAAAABQZuSeEPJlMCCv/7xR0EANJMQAAvPcH4A//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHgAACAgAUhAGMp8QAAAAEJ8AAAAAFBm7J4Q8mUwIK//vBHQQA1kxAADCdUfgD//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////wAAAeAAAICABSEAZYmBAAAAAQnwAAAAAUGb0nhDyZTAgr/+8UdBADaTEAAMfzh+AP//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAAB4AAAgIAFIQBn6REAAAABCfAAAAABQZvyeEPJlMCCv/7w",
        "R0ARFgBC8CUAAcEAAP8B/wAB/IAUSBIBBkZGbXBlZwlTZXJ2aWNlMDF3fEPK//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////9HQAAXAACwDQABwQAAAAHwACqxBLL//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////0dQABcAArASAAHBAADhAPAAG+EA8AAVvU1W////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////R0EAN5MQAAzXHH4A//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHgAACAgAUhAGtIoQAAAAEJ8AAAAAFBmhJ4Q8mUwIK//vFHQQA4kxAADS8AfgD//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////wAAAeAAAICABSEAbagxAAAAAQnwAAAAAUGaMnhDyZTAgr/+8UdBADmTEAANhuR+AP//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAAB4AAAgIAFIQBxB8EAAAABCfAAAAABQZpSeEPJlMCCv/7xR0EAOpMQAA3eyH4A//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHgAACAgAUhAHNnUQAAAAEJ8AAAAAFBmnJ4Q8mUwIK//vFHQAAYAACwDQABwQAAAAHwACqxBLL//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////0dQABgAArASAAHBAADhAPAAG+EA8AAVvU1W////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////R0EAO21QAA42rH4A////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAAB4AAAgIAFIQB1xuEAAAABCfAAAAABZ01ACtkewEQAAAMABAAAAwAQPEiZIAAAAAFo68PLIAAAAAFliIQF//731LfMsu4HI4BHQQA8lxAADo6QfgD///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHgAACAgAUhAHkmcQAAAAEJ8AAAAAFBmjsQV//+8A==",
        "R0ARFwBC8CUAAcEAAP8B/wAB/IAUSBIBBkZGbXBlZwlTZXJ2aWNlMDF3fEPK//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////9HQAAZAACwDQABwQAAAAHwACqxBLL//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////0dQABkAArASAAHBAADhAPAAG+EA8AAVvU1W////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////R0EAPZQQAA7mdH4A////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAAB4AAAgIAFIQB7hgEAAAABCfAAAAABQZpPCGTKYQV//vFHQQA+kxAADz5YfgD//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////wAAAeAAAICABSEAfeWRAAAAAQnwAAAAAUGacnhDyZTAgr/+8EdBAD+TEAAPljx+AP//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAAB4AAAgIAFIQCBRSEAAAABCfAAAAABQZqSeEPJlMCCv/7wR0EAMJMQAA/uIH4A//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHgAACAgAUhAIOksQAAAAEJ8AAAAAFBmrJ4Q8mUwIK//vFHQQAxkxAAEEYEfgD//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////wAAAeAAAICABSEAhwRBAAAAAQnwAAAAAUGa0nhDyZTAgr/+8UdBADKTEAAQneh+AP//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAAB4AAAgIAFIQCJY9EAAAABCfAAAAABQZryeEPJlMCCv/7x",
        "R0ARGABC8CUAAcEAAP8B/wAB/IAUSBIBBkZGbXBlZwlTZXJ2aWNlMDF3fEPK//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////9HQAAaAACwDQABwQAAAAHwACqxBLL//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////0dQABoAArASAAHBAADhAPAAG+EA8AAVvU1W////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////R0EAM5MQABD1zH4A//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHgAACAgAUhAIvDYQAAAAEJ8AAAAAFBmxJ4Q8mUwIK//vBHQQA0kxAAEU2wfgD//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////wAAAeAAAICABSEAjyLxAAAAAQnwAAAAAUGbMnhDyZTAgr/+8EdBADWTEAARpZR+AP//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAAB4AAAgIAFIQCRgoEAAAABCfAAAAABQZtSeEPJlMCCv/7xR0EANpMQABH9eH4A//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHgAACAgAUhAJPiEQAAAAEJ8AAAAAFBm3J4Q8mUwIK//vBHQQA3kxAAElVcfgD//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////wAAAeAAAICABSEAl0GhAAAAAQnwAAAAAUGbknhDyZTAgr/+8EdBADiTEAASrUB+AP//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAAB4AAAgIAFIQCZoTEAAAABCfAAAAABQZuyeEPJlMCCv/7x",
        "R0ARGQBC8CUAAcEAAP8B/wAB/IAUSBIBBkZGbXBlZwlTZXJ2aWNlMDF3fEPK//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////9HQAAbAACwDQABwQAAAAHwACqxBLL//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////0dQABsAArASAAHBAADhAPAAG+EA8AAVvU1W////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////R0EAOZMQABMFJH4A//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHgAACAgAUhAJ0AwQAAAAEJ8AAAAAFBm9J4Q8mUwIK//vBHQQA6kxAAE10IfgD//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////wAAAeAAAICABSEAn2BRAAAAAQnwAAAAAUGb8nhDyZTAgr/+8UdBADuTEAATtOx+AP//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAAB4AAAgIAFIQChv+EAAAABCfAAAAABQZoSeEPJlMCCn/7xR0EAPJMQABQM0H4A//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHgAACAgAUhAKUfcQAAAAEJ8AAAAAFBmjJ4Q8mUwIKf/vBHQQA9kxAAFGS0fgD//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////wAAAeAAAICABSEAp38BAAAAAQnwAAAAAUGaUnhDyZTAgp/+8UdBAD6TEAAUvJh+AP//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAAB4AAAgIAFIQCp3pEAAAABCfAAAAABQZpyeEPJlMCCX/7g",
    ]

    /// Reported: resumed from Continue Watching on MPV, a skip back landed where it started, and it
    /// took a run of taps to get anywhere. Nothing before the resume point is cached, so the seek
    /// goes to ffmpeg's HLS demuxer, which only lands on a keyframe at or after where it's asked
    /// to: a stream whose segments don't start on keyframes came back after the target, often
    /// on the frame it left. A skip back lands where it was asked to.
    func testASeekBackPastWhatsCachedLandsOnItsTarget() async throws {
        var files: [String: Data] = [:]
        var playlist = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:3\n#EXT-X-PLAYLIST-TYPE:VOD\n"
        for (index, segment) in Self.sparseKeyframeSegments.enumerated() {
            files["/v\(index).ts"] = Data(base64Encoded: segment)!
            playlist += "#EXTINF:3.0,\nv\(index).ts\n"
        }
        files["/media.m3u8"] = Data((playlist + "#EXT-X-ENDLIST\n").utf8)
        let server = try await HLSServer.start(files: files)
        // Slow enough that mpv hasn't read up to the resume point by the time it's asked to go there.
        server.segmentDelay = 1
        defer { server.stop() }
        let ready = expectation(description: "ready")
        ready.assertForOverFulfill = false
        engine.events.itemReady = { ready.fulfill() }
        engine.load(PlaybackSource(url: server.url(of: "/media.m3u8")))
        await fulfillment(of: [ready], timeout: 20)

        // The resume, as the player makes it.
        await engine.seek(to: 25, precision: .fast)
        await engine.seek(to: 14, precision: .within(0.5))
        XCTAssertEqual(engine.currentTime, 14, accuracy: 0.6)
        // Asking ten seconds before a target this close to the start would be asking before the
        // stream, and mpv would carry on from wherever it had read to instead.
        await engine.seek(to: 2, precision: .within(0.5))
        XCTAssertEqual(engine.currentTime, 2, accuracy: 0.6)
    }

    func testAStoppedEngineReportsNothing() throws {
        var heard = false
        engine.events.itemReady = { heard = true }
        engine.load(PlaybackSource(url: try silence(seconds: 1)))
        engine.stop()
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertFalse(heard)
    }
}

/// Serves files from memory over loopback, one request a connection, and counts what's asked of it.
final class HLSServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.hls-server")
    private let files: [String: Data]
    /// How long a `.ts` segment takes to start coming, as a CDN's would.
    var segmentDelay: TimeInterval = 0
    /// The paths asked for, in order. Only touched on `queue`.
    private var requested: [String] = []

    private init(listener: NWListener, files: [String: Data]) {
        self.listener = listener
        self.files = files
    }

    static func start(files: [String: Data]) async throws -> HLSServer {
        let server = HLSServer(listener: try NWListener(using: .tcp, on: .any), files: files)
        await withCheckedContinuation { (ready: CheckedContinuation<Void, Never>) in
            var resumed = false
            server.listener.stateUpdateHandler = { state in
                guard case .ready = state, !resumed else { return }
                resumed = true
                ready.resume()
            }
            server.listener.newConnectionHandler = { [weak server] in server?.serve($0) }
            server.listener.start(queue: server.queue)
        }
        return server
    }

    /// Two variants of two seconds of silence, at 500 and 1000 kb/s, in `/master.m3u8`. mpv
    /// numbers the low one's track 1 and the high one's 2.
    static func twoVariants() async throws -> HLSServer {
        let media = { (segment: String) in
            "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:0\n"
                + "#EXTINF:2.0,\n\(segment)\n#EXT-X-ENDLIST\n"
        }
        return try await start(files: [
            "/master.m3u8": Data(("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=500000\nlow.m3u8\n"
                + "#EXT-X-STREAM-INF:BANDWIDTH=1000000\nhigh.m3u8\n").utf8),
            "/low.m3u8": Data(media("low.wav").utf8),
            "/high.m3u8": Data(media("high.wav").utf8),
            "/low.wav": silentWAV(seconds: 2),
            "/high.wav": silentWAV(seconds: 2),
        ])
    }

    /// Two variants of a 2 s 16×16 black picture, at 500 and 1000 kb/s, sharing two audio
    /// renditions, Japanese and English, as a dubbed show's stream does. The segment is ffmpeg's
    /// `-f lavfi -i color=c=black:s=16x16:r=2:d=2,format=yuv420p -c:v libx264 -profile:v main
    /// -g 4 -bf 0 -f mpegts`.
    static func twoVariantsTwoLanguages() async throws -> HLSServer {
        let media = { (segment: String) in
            "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:0\n"
                + "#EXTINF:2.0,\n\(segment)\n#EXT-X-ENDLIST\n"
        }
        return try await start(files: [
            "/master.m3u8": Data(("#EXTM3U\n"
                + "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"Japanese\",LANGUAGE=\"ja\",DEFAULT=YES,URI=\"ja.m3u8\"\n"
                + "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"English\",LANGUAGE=\"en\",URI=\"en.m3u8\"\n"
                + "#EXT-X-STREAM-INF:BANDWIDTH=500000,AUDIO=\"aud\"\nlow.m3u8\n"
                + "#EXT-X-STREAM-INF:BANDWIDTH=1000000,AUDIO=\"aud\"\nhigh.m3u8\n").utf8),
            "/low.m3u8": Data(media("low.ts").utf8),
            "/high.m3u8": Data(media("high.ts").utf8),
            "/ja.m3u8": Data(media("ja.wav").utf8),
            "/en.m3u8": Data(media("en.wav").utf8),
            "/low.ts": blackSegment,
            "/high.ts": blackSegment,
            "/ja.wav": silentWAV(seconds: 2),
            "/en.wav": silentWAV(seconds: 2),
        ])
    }

    static let blackSegment = Data(base64Encoded: "R0AREABC8CUAAcEAAP8B/wAB/IAUSBIBBkZGbXBlZwlTZXJ2aWNlMDF3fEPK//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////9HQAAQAACwDQABwQAAAAHwACqxBLL//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////0dQABAAArASAAHBAADhAPAAG+EA8AAVvU1W////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////R0EAMAdQAAB7DH4AAAAB4AAAgIAFIQAH2GEAAAABCfAAAAABZ01ACtkewEQAAAMABAAAAwAQPEiZIAAAAAFo68PLIAAAAQYF//9p3EXpvebZSLeWLNgg2SPu73gyNjQgLSBjb3JlIDE2NCByMzEwOCAzMWUxOWY5IC0gSC4yNjQvTVBFRy00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyMyAtIGh0dHA6Ly93d3cudmlkZW9sYW5HAQARLm9yZy94MjY0Lmh0bWwgLSBvcHRpb25zOiBjYWJhYz0xIHJlZj0zIGRlYmxvY2s9MTowOjAgYW5hbHlzZT0weDE6MHgxMTEgbWU9aGV4IHN1Ym1lPTcgcHN5PTEgcHN5X3JkPTEuMDA6MC4wMCBtaXhlZF9yZWY9MSBtZV9yYW5nZT0xNiBjaHJvbWFfbWU9MSB0cmVsbGlzPTEgOHg4ZGN0PTAgY3FtPTAgZGVhZHpvbmU9MjEsMUcBABIxIGZhc3RfcHNraXA9MSBjaHJvbWFfcXBfb2Zmc2V0PS0yIHRocmVhZHM9MSBsb29rYWhlYWRfdGhyZWFkcz0xIHNsaWNlZF90aHJlYWRzPTAgbnI9MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTAgd2VpZ2h0cD0yIGtleWludD00IGtleWludF9tRwEAMx8A////////////////////////////////////////aW49MSBzY2VuZWN1dD00MCBpbnRyYV9yZWZyZXNoPTAgcmNfbG9va2FoZWFkPTQgcmM9Y3JmIG1idHJlZT0xIGNyZj0yMy4wIHFjb21wPTAuNjAgcXBtaW49MCBxcG1heD02OSBxcHN0ZXA9NCBpcF9yYXRpbz0xLjQwIGFxPTE6MS4wMACAAAABZYiEBT/+98dPwKbq3CdHQBERAELwJQABwQAA/wH/AAH8gBRIEgEGRkZtcGVnCVNlcnZpY2UwMXd8Q8r//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////0dAABEAALANAAHBAAAAAfAAKrEEsv//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////R1AAEQACsBIAAcEAAOEA8AAb4QDwABW9TVb///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////9HQQA0lxAAANLwfgD///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHgAACAgAUhAAs38QAAAAEJ8AAAAAFBmjsQU//+8EdAERIAQvAlAAHBAAD/Af8AAfyAFEgSAQZGRm1wZWcJU2VydmljZTAxd3xDyv//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////R0AAEgAAsA0AAcEAAAAB8AAqsQSy//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////9HUAASAAKwEgABwQAA4QDwABvhAPAAFb1NVv///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////0dBADWUEAABKtR+AP///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////wAAAeAAAICABSEADZeBAAAAAQnwAAAAAUGaTwhkymEFP/7xR0AREwBC8CUAAcEAAP8B/wAB/IAUSBIBBkZGbXBlZwlTZXJ2aWNlMDF3fEPK//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////9HQAATAACwDQABwQAAAAHwACqxBLL//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////0dQABMAArASAAHBAADhAPAAG+EA8AAVvU1W////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////R0EANpMQAAGCuH4A//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHgAACAgAUhAA/3EQAAAAEJ8AAAAAFBmnJ4Q8mUwIJf/uA=")!

    func url(of path: String) -> URL {
        URL(string: "http://127.0.0.1:\(listener.port!.rawValue)\(path)")!
    }

    func fetches(of path: String) -> Int {
        queue.sync { requested.filter { $0 == path }.count }
    }

    func stop() { listener.cancel() }

    /// `seconds` of 8 kHz 16-bit mono silence as a WAV file.
    static func silentWAV(seconds: Int) -> Data {
        let samples = 8_000 * seconds
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + samples * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))       // PCM
        append(UInt16(1))       // mono
        append(UInt32(8_000))   // sample rate
        append(UInt32(16_000))  // bytes a second
        append(UInt16(2))       // bytes a frame
        append(UInt16(16))      // bits a sample
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(samples * 2))
        data.append(Data(count: samples * 2))
        return data
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        readHead(on: connection, buffered: Data())
    }

    private func readHead(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            var buffered = buffered
            if let data { buffered.append(data) }
            guard let head = String(data: buffered, encoding: .utf8), head.contains("\r\n\r\n") else {
                if isComplete || error != nil { connection.cancel() } else { readHead(on: connection, buffered: buffered) }
                return
            }
            let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            requested.append(path)
            if path.hasSuffix(".ts"), segmentDelay > 0 {
                queue.asyncAfter(deadline: .now() + segmentDelay) { [self] in respond(path, on: connection) }
                return
            }
            respond(path, on: connection)
        }
    }

    private func respond(_ path: String, on connection: NWConnection) {
        let body = files[path]
        let type = path.hasSuffix(".m3u8") ? "application/vnd.apple.mpegurl"
            : path.hasSuffix(".ts") ? "video/mp2t" : "audio/wav"
        let response = "HTTP/1.1 \(body == nil ? "404 Not Found" : "200 OK")\r\nContent-Type: \(type)\r\n"
            + "Content-Length: \(body?.count ?? 0)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8) + (body ?? Data()), contentContext: .finalMessage,
                        isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// mpv's software output, which Picture in Picture shows: frames come while it's on, and going
/// back to the Metal layer carries on playing.
@MainActor
final class MPVSoftwareOutputTests: XCTestCase {
    private var files: [URL] = []

    override func tearDown() async throws {
        for file in files { try? FileManager.default.removeItem(at: file) }
        files = []
    }

    /// Counts frames delivered on the output's own queue.
    private final class FrameCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    /// An engine playing a ten-frames-a-second clip on its Metal layer, a second and a half in.
    private func playingEngine() async throws -> MPVEngine {
        let url = try await TestVideo.make(seconds: 20)
        files.append(url)
        let engine = MPVEngine(output: .metal)
        engine.layer.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        engine.layer.contentsScale = 2
        let ready = expectation(description: "ready")
        ready.assertForOverFulfill = false
        engine.events.itemReady = { ready.fulfill() }
        engine.load(PlaybackSource(url: url))
        await fulfillment(of: [ready], timeout: 10)
        engine.play()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        return engine
    }

    /// The longest the engine's clock stood still, sampled every 20 ms for `seconds`.
    private func longestStall(of engine: MPVEngine, over seconds: Double) async -> Double {
        var last = engine.currentTime, lastMove = Date(), longest = 0.0
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if engine.currentTime != last {
                last = engine.currentTime
                lastMove = Date()
            }
            longest = max(longest, Date().timeIntervalSince(lastMove))
        }
        return longest
    }

    func testFramesComeWhileTheSoftwareOutputIsOn() async throws {
        let engine = try await playingEngine()
        defer { engine.stop() }
        let frames = FrameCount()
        XCTAssertNotNil(engine.beginSoftwareOutput { _ in frames.add() })
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertGreaterThan(frames.value, 10, "a ten-frames-a-second clip drew \(frames.value) in 2 s")
        engine.endSoftwareOutput()
        try await Task.sleep(nanoseconds: 200_000_000)
        let afterEnd = frames.value
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(frames.value, afterEnd, "frames still came after the output ended")
    }

    /// THE BUG, part of the second's stall back from Picture in Picture: mpv seeks back to where it
    /// was by itself when its output changes, and the engine sent a seek of its own on top, so it
    /// flushed the sound and decoded its way back from the keyframe twice. Paused, the clock only
    /// ticks when playback restarts after a seek.
    func testGoingBackToMetalRestartsPlaybackOnce() async throws {
        let engine = try await playingEngine()
        defer { engine.stop() }
        XCTAssertNotNil(engine.beginSoftwareOutput { _ in })
        try await Task.sleep(nanoseconds: 1_500_000_000)
        engine.pause()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        var restarts = 0
        engine.events.tick = { restarts += 1 }
        engine.endSoftwareOutput()
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertEqual(restarts, 1)
    }

    /// The same going into Picture in Picture, where a second seek held up its first frame.
    func testMovingToSoftwareRestartsPlaybackOnce() async throws {
        let engine = try await playingEngine()
        defer { engine.stop() }
        engine.pause()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        var restarts = 0
        engine.events.tick = { restarts += 1 }
        XCTAssertNotNil(engine.beginSoftwareOutput { _ in })
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertEqual(restarts, 1)
        engine.endSoftwareOutput()
    }

    /// Picture in Picture's layer has to stay up until the Metal layer has a picture again, or the
    /// picture flashes: the engine says when mpv shows its first frame back on Metal — paused too.
    func testGoingBackToMetalSaysWhenThePictureIsBack() async throws {
        let engine = try await playingEngine()
        defer { engine.stop() }
        XCTAssertNotNil(engine.beginSoftwareOutput { _ in })
        try await Task.sleep(nanoseconds: 1_500_000_000)
        engine.pause()
        try await Task.sleep(nanoseconds: 500_000_000)
        var restarted = false, shown = 0, shownAfterRestart = false
        engine.events.tick = { restarted = true }
        engine.endSoftwareOutput {
            shown += 1
            shownAfterRestart = restarted
        }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertEqual(shown, 1)
        XCTAssertTrue(shownAfterRestart, "told before mpv had drawn")
    }

    /// Picture in Picture closed from another app: back on Metal, mpv draws nothing till the app
    /// is back, so the picture isn't back till then either — and Picture in Picture's layer stays up.
    func testGoingBackToMetalInTheBackgroundIsShownOnlyOnReturn() async throws {
        let engine = try await playingEngine()
        defer { engine.stop() }
        XCTAssertNotNil(engine.beginSoftwareOutput { _ in })
        try await Task.sleep(nanoseconds: 1_000_000_000)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        var shown = 0
        engine.endSoftwareOutput { shown += 1 }
        try await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertEqual(shown, 0, "told while nothing could be drawn")
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertEqual(shown, 1)
    }

    /// Back from Picture in Picture the picture flashed and playback stood still for a second,
    /// while mpv rebuilt its Metal output and decoded its way back to where it was.
    func testGoingBackToMetalKeepsTheClockMoving() async throws {
        let engine = try await playingEngine()
        defer { engine.stop() }
        XCTAssertNotNil(engine.beginSoftwareOutput { _ in })
        try await Task.sleep(nanoseconds: 2_000_000_000)
        engine.endSoftwareOutput()
        let stall = await longestStall(of: engine, over: 2)
        XCTAssertLessThan(stall, 0.35, "the clock stood still for \(String(format: "%.2f", stall)) s")
    }
}
