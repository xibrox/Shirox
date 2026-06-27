import Foundation

/// Pure decision for whether playback progress has reached the point where we should start
/// resolving the next episode's stream URL ahead of time — no app dependencies, fully
/// unit-testable.
///
/// Background: advancing to the next episode runs a slow JS pipeline (fetch the episode list,
/// then `extractStreamUrl`). Doing that only when the episode ends shows a multi-second
/// spinner. Resolving the URL early — at the same threshold the episode is marked "watched" —
/// lets the end-of-episode swap (auto-advance and the manual Next tap) be near-instant.
///
/// The next-episode loader is stateful (each successful call advances an internal season-aware
/// cursor), so the prefetch must fire at most once per episode; `alreadyStarted` enforces that.
enum PlayerNextEpisodePrefetch {

    /// - Parameters:
    ///   - progress: current playback fraction (currentTime / duration), 0…1.
    ///   - threshold: the `watchedPercentage` fraction (e.g. 0.90) at which to prefetch.
    ///   - hasLoader: whether a next-episode loader (`onWatchNext`) exists at all.
    ///   - alreadyStarted: whether the prefetch has already been kicked off this episode.
    static func shouldStart(progress: Double, threshold: Double, hasLoader: Bool, alreadyStarted: Bool) -> Bool {
        hasLoader && !alreadyStarted && progress >= threshold
    }
}
