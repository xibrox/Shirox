import XCTest
@testable import Shirox

/// Tests for the pure "should we re-resolve the source on foreground?" decision.
///
/// The reported bug: pause a stream, switch apps for a long time, return — the player shows
/// a black frame and spins forever. Root cause: every recovery path is gated on the player
/// actively trying to play (the stall watchdog only arms on `.waitingToPlayAtSpecifiedRate`),
/// so a PAUSED player stranded across an OS suspension (forward buffer evicted, CDN URL
/// expired / localhost HLS proxy sockets dead) has no trigger and the resume-seek wedges.
///
/// The fix proactively re-resolves the source when we come back PAUSED after a real
/// suspension. This pins down exactly when that should and should not happen.
final class PlayerForegroundRecoveryTests: XCTestCase {

    // MARK: The bug — paused + long suspension must recover

    /// THE BUG (downloads): paused, returned after a suspension long enough to kill the
    /// localhost proxy. Local re-resolve is cheap, so the threshold is short.
    func testPausedLocalAfterLongSuspensionRecovers() {
        XCTAssertTrue(PlayerForegroundRecovery.shouldRecoverOnForeground(
            suspendedFor: 30, isPlaying: false, isLocalPlayback: true, canRecoverStream: true))
    }

    /// THE BUG (streaming): paused, returned after a suspension long enough to expire the CDN
    /// URL. Network re-extract is expensive, so the threshold is longer than local.
    func testPausedNetworkAfterLongSuspensionRecovers() {
        XCTAssertTrue(PlayerForegroundRecovery.shouldRecoverOnForeground(
            suspendedFor: 60, isPlaying: false, isLocalPlayback: false, canRecoverStream: true))
    }

    // MARK: Don't recover — the playing case self-heals

    /// A PLAYING player self-heals via the stall watchdog. Proactively refetching here would
    /// needlessly interrupt smooth PiP / background-audio playback on return.
    func testPlayingNeverProactivelyRecovers() {
        XCTAssertFalse(PlayerForegroundRecovery.shouldRecoverOnForeground(
            suspendedFor: 600, isPlaying: true, isLocalPlayback: true, canRecoverStream: true))
        XCTAssertFalse(PlayerForegroundRecovery.shouldRecoverOnForeground(
            suspendedFor: 600, isPlaying: true, isLocalPlayback: false, canRecoverStream: true))
    }

    // MARK: Don't recover — short suspension, source likely still alive

    /// A brief background (or a transient resign-active that left `suspendedFor` near 0) hasn't
    /// killed the source — the buffer and URL survive, so don't churn a refetch.
    func testPausedNetworkShortSuspensionDoesNotRecover() {
        XCTAssertFalse(PlayerForegroundRecovery.shouldRecoverOnForeground(
            suspendedFor: 30, isPlaying: false, isLocalPlayback: false, canRecoverStream: true))
    }

    func testPausedLocalShortSuspensionDoesNotRecover() {
        XCTAssertFalse(PlayerForegroundRecovery.shouldRecoverOnForeground(
            suspendedFor: 5, isPlaying: false, isLocalPlayback: true, canRecoverStream: true))
    }

    func testTransientResignActiveDoesNotRecover() {
        // backgroundedAt never set → suspendedFor reads 0.
        XCTAssertFalse(PlayerForegroundRecovery.shouldRecoverOnForeground(
            suspendedFor: 0, isPlaying: false, isLocalPlayback: true, canRecoverStream: true))
    }

    // MARK: Don't recover — nothing to recover to

    /// A network stream launched without an expiry loader can't be re-resolved; never claim
    /// we can recover when there's no source to refetch.
    func testUnrecoverableSourceDoesNotRecover() {
        XCTAssertFalse(PlayerForegroundRecovery.shouldRecoverOnForeground(
            suspendedFor: 600, isPlaying: false, isLocalPlayback: false, canRecoverStream: false))
    }

    // MARK: Threshold boundaries

    /// Exactly at the threshold counts as long enough (>=), for both source kinds.
    func testRecoversExactlyAtThreshold() {
        let local = PlayerForegroundRecovery.recoverThreshold(isLocalPlayback: true)
        let network = PlayerForegroundRecovery.recoverThreshold(isLocalPlayback: false)
        XCTAssertTrue(PlayerForegroundRecovery.shouldRecoverOnForeground(
            suspendedFor: local, isPlaying: false, isLocalPlayback: true, canRecoverStream: true))
        XCTAssertTrue(PlayerForegroundRecovery.shouldRecoverOnForeground(
            suspendedFor: network, isPlaying: false, isLocalPlayback: false, canRecoverStream: true))
    }

    /// Local re-resolve is cheap, network re-extract is expensive — so local must trip sooner.
    func testLocalThresholdIsShorterThanNetwork() {
        XCTAssertLessThan(
            PlayerForegroundRecovery.recoverThreshold(isLocalPlayback: true),
            PlayerForegroundRecovery.recoverThreshold(isLocalPlayback: false))
    }
}
