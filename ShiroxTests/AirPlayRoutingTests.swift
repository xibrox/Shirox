import XCTest
@testable import Shirox

/// Tests for the AirPlay external-playback routing decision.
///
/// The reported bug (the AirPlay half): picking an Apple TV gives a black screen or an
/// immediate bounce back to the phone for most streams.
///
/// Root cause: AirPlay *video* hands the asset's URL to the receiver and lets the Apple TV
/// fetch it directly. The `AVURLAssetHTTPHeaderFieldsKey` headers the player was built with
/// — the Referer/User-Agent/Cookie a scraper stream needs — do not travel with it, so the
/// Apple TV's own request is unauthenticated and gets a 403. Nothing detected this, so the
/// user just saw a black TV.
///
/// The fix re-points those streams at `CastProxyServer`, which is already reachable on the
/// LAN and injects the headers itself. This pins when that swap should and shouldn't happen.
final class AirPlayRoutingTests: XCTestCase {

    private let remote = URL(string: "https://cdn.example/video/index.m3u8")!
    private let local = URL(fileURLWithPath: "/var/mobile/Downloads/ep1.mp4")

    // MARK: - THE BUG: header-authenticated streams need the proxy

    func testHeaderAuthenticatedRemoteStreamNeedsProxy() {
        XCTAssertTrue(AirPlayRouting.needsProxy(
            url: remote, headers: ["Referer": "https://cdn.example/"], isAirPlayActive: true))
    }

    /// Only while AirPlay is actually driving the TV. On-device playback must keep the
    /// direct URL — routing local playback through a localhost hop would cost throughput
    /// for nothing.
    func testDirectURLIsKeptWhenNotAirPlaying() {
        XCTAssertFalse(AirPlayRouting.needsProxy(
            url: remote, headers: ["Referer": "https://cdn.example/"], isAirPlayActive: false))
    }

    /// A stream with no headers authenticates fine from the Apple TV — leave it alone
    /// rather than funnelling the whole movie through the phone.
    func testHeaderlessStreamIsNotProxied() {
        XCTAssertFalse(AirPlayRouting.needsProxy(url: remote, headers: [:], isAirPlayActive: true))
    }

    /// A downloaded file is served by AVFoundation itself over AirPlay; there is no origin
    /// request to authenticate and the proxy can't read it any better than the player can.
    func testLocalFileIsNotProxied() {
        XCTAssertFalse(AirPlayRouting.needsProxy(
            url: local, headers: ["Referer": "x"], isAirPlayActive: true))
    }

    // MARK: - Rebuilding the player item

    /// Swapping the URL means rebuilding the player item, which is expensive and visibly
    /// interrupts playback — so it may only happen when the routing actually changed.
    func testRebuildOnlyWhenRoutingChanges() {
        XCTAssertTrue(AirPlayRouting.shouldRebuild(currentlyProxied: false, needsProxy: true))
        XCTAssertTrue(AirPlayRouting.shouldRebuild(currentlyProxied: true, needsProxy: false))
        XCTAssertFalse(AirPlayRouting.shouldRebuild(currentlyProxied: false, needsProxy: false))
        XCTAssertFalse(AirPlayRouting.shouldRebuild(currentlyProxied: true, needsProxy: true))
    }

    // MARK: - MPV under AirPlay

    /// MPV can't send its picture to a receiver; AVPlayer can, so a stream it plays moves over.
    func testMPVHandsAnHLSStreamToNative() {
        XCTAssertTrue(AirPlayRouting.handsMPVToNative(url: remote, avPlayerFailedIt: false))
        XCTAssertTrue(AirPlayRouting.handsMPVToNative(url: local, avPlayerFailedIt: false))
    }

    /// A container AVPlayer can't open stays on MPV; the receiver gets the sound.
    func testMPVKeepsAnMKV() {
        let mkv = URL(string: "https://cdn.example/video/ep1.MKV")!
        XCTAssertFalse(AirPlayRouting.handsMPVToNative(url: mkv, avPlayerFailedIt: false))
    }

    /// AVPlayer already failed this session — handing it back would only fail again.
    func testMPVKeepsWhatAVPlayerFailed() {
        XCTAssertFalse(AirPlayRouting.handsMPVToNative(url: remote, avPlayerFailedIt: true))
    }
}
