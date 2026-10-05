import Foundation

/// Decides whether AirPlay needs the stream re-pointed at ``CastProxyServer`` — pure, no
/// AVFoundation, fully unit-testable.
///
/// THE BUG THIS EXISTS FOR: AirPlay *video* does not send decoded frames to the Apple TV;
/// it hands over the asset's URL and lets the receiver fetch it. The headers the player was
/// built with (`AVURLAssetHTTPHeaderFieldsKey` — the Referer/User-Agent/Cookie a scraped
/// stream needs) do not travel with that handoff, so the Apple TV's own request is
/// unauthenticated and comes back 403. The app detected none of this: the user picked their
/// TV and got a black screen.
///
/// `CastProxyServer` already solves exactly this problem for Chromecast — it's bound to the
/// LAN and injects the headers on every request — so the fix is to route external playback
/// through it too.
enum AirPlayRouting {

    /// Whether playback should run through the LAN proxy right now.
    ///
    /// - Parameters:
    ///   - url: the stream's origin URL.
    ///   - headers: the auth headers the origin requires; empty means anonymous.
    ///   - isAirPlayActive: whether an AirPlay receiver currently owns the output route.
    ///     Taken from the audio session, not from an `AVPlayer` — the swap this decision
    ///     drives replaces the player, and a fresh instance reports `false` until it
    ///     re-attaches, which would oscillate the routing.
    ///   - hasScrambledPlaylists: the stream's playlists need unscrambling (`playlistKey`),
    ///     which only the proxy can do — the receiver gets them as the origin serves them.
    static func needsProxy(url: URL, headers: [String: String], isAirPlayActive: Bool,
                           hasScrambledPlaylists: Bool = false) -> Bool {
        // On-device playback keeps the direct URL: AVPlayer sends the headers itself, and a
        // localhost hop would cost throughput for nothing.
        guard isAirPlayActive else { return false }
        // A downloaded file is served by AVFoundation over AirPlay directly. There is no
        // origin request to authenticate, and the proxy can't reach the sandbox any better.
        guard !url.isFileURL else { return false }
        // An anonymous stream authenticates fine from the Apple TV — don't funnel a whole
        // movie through the phone's radio for no benefit.
        return !headers.isEmpty || hasScrambledPlaylists
    }

    /// Whether the change in routing warrants rebuilding the player item.
    ///
    /// Swapping the URL means a new `AVPlayerItem` and a re-seek, which is visible to the
    /// user, so it may only happen on an actual transition — not on every route-change
    /// notification (AirPlay emits several per connection).
    static func shouldRebuild(currentlyProxied: Bool, needsProxy: Bool) -> Bool {
        currentlyProxied != needsProxy
    }

    /// Whether an MPV session moves onto the native engine when AirPlay takes the route.
    ///
    /// MPV draws its own picture and has no way to hand it to a receiver — choosing an Apple
    /// TV under it sent only the sound. AVPlayer can, so a stream it plays carries on there
    /// from the same position. One it can't stays on MPV, and AirPlay gets the audio.
    /// - Parameters:
    ///   - url: the stream's URL.
    ///   - avPlayerFailedIt: AVPlayer already gave up on this session and MPV took over.
    static func handsMPVToNative(url: URL, avPlayerFailedIt: Bool) -> Bool {
        !avPlayerFailedIt && !PlaybackFallback.mpvOnlyExtensions.contains(url.pathExtension.lowercased())
    }
}
