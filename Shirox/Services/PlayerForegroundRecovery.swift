import Foundation

/// Pure decision for whether returning to the foreground should proactively re-resolve the
/// playback source — no app dependencies, fully unit-testable.
///
/// Background: every other recovery path (the stall watchdog) only arms while the player is
/// actively trying to play. A PAUSED player stranded across an OS suspension — forward buffer
/// evicted, streaming CDN URL expired or a download's localhost HLS proxy sockets dead — has
/// no trigger, so its resume-seek wedges to a black frame and an endless spinner. This decides
/// when to skip that doomed seek and re-resolve the source instead.
enum PlayerForegroundRecovery {

    /// How long suspended before the source is assumed dead. Local re-resolve is cheap (restart
    /// the proxy) so we act fast; a network re-extract is expensive and CDN URLs live longer, so
    /// we wait more before paying for it.
    static func recoverThreshold(isLocalPlayback: Bool) -> TimeInterval {
        isLocalPlayback ? 10 : 45
    }

    /// Whether to re-resolve the source rather than blindly seek into a possibly-dead one.
    /// - Parameters:
    ///   - suspendedFor: seconds between `didEnterBackground` and now (0 for a transient
    ///     resign-active that never truly backgrounded us).
    ///   - isPlaying: the user's play/pause intent on return.
    ///   - isLocalPlayback: a downloaded file / localhost HLS proxy, vs. a network stream.
    ///   - canRecoverStream: whether a fresh source can actually be re-resolved.
    static func shouldRecoverOnForeground(
        suspendedFor: TimeInterval,
        isPlaying: Bool,
        isLocalPlayback: Bool,
        canRecoverStream: Bool
    ) -> Bool {
        // The PLAYING case self-heals via the stall watchdog; refetching here would needlessly
        // interrupt smooth PiP / background-audio playback on return.
        guard !isPlaying else { return false }
        // Nothing to re-resolve to (e.g. a network stream launched with no expiry loader).
        guard canRecoverStream else { return false }
        // Below the threshold the source likely survived — don't churn a refetch.
        return suspendedFor >= recoverThreshold(isLocalPlayback: isLocalPlayback)
    }
}
