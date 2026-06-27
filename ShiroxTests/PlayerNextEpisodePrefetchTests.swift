import XCTest
@testable import Shirox

/// Tests for the pure "should we start prefetching the next episode now?" decision.
///
/// The prefetch fires once per episode at the `watchedPercentage` threshold, but only when a
/// next-episode loader actually exists, and never twice. This pins down exactly that.
final class PlayerNextEpisodePrefetchTests: XCTestCase {

    // MARK: Fires once, at/after the threshold

    func testStartsAtThreshold() {
        XCTAssertTrue(PlayerNextEpisodePrefetch.shouldStart(
            progress: 0.90, threshold: 0.90, hasLoader: true, alreadyStarted: false))
    }

    func testStartsAboveThreshold() {
        XCTAssertTrue(PlayerNextEpisodePrefetch.shouldStart(
            progress: 0.95, threshold: 0.90, hasLoader: true, alreadyStarted: false))
    }

    // MARK: Does not fire

    func testDoesNotStartBelowThreshold() {
        XCTAssertFalse(PlayerNextEpisodePrefetch.shouldStart(
            progress: 0.50, threshold: 0.90, hasLoader: true, alreadyStarted: false))
    }

    /// No next-episode loader (last episode, or sequel-only) → nothing to prefetch.
    func testDoesNotStartWithoutLoader() {
        XCTAssertFalse(PlayerNextEpisodePrefetch.shouldStart(
            progress: 0.99, threshold: 0.90, hasLoader: false, alreadyStarted: false))
    }

    /// Already kicked off this episode → never start a second prefetch (the loader's cursor
    /// is stateful; a second call would advance it).
    func testDoesNotStartWhenAlreadyStarted() {
        XCTAssertFalse(PlayerNextEpisodePrefetch.shouldStart(
            progress: 0.99, threshold: 0.90, hasLoader: true, alreadyStarted: true))
    }

    /// A custom (lower) watchedPercentage still gates correctly.
    func testRespectsCustomThreshold() {
        XCTAssertFalse(PlayerNextEpisodePrefetch.shouldStart(
            progress: 0.79, threshold: 0.80, hasLoader: true, alreadyStarted: false))
        XCTAssertTrue(PlayerNextEpisodePrefetch.shouldStart(
            progress: 0.80, threshold: 0.80, hasLoader: true, alreadyStarted: false))
    }
}
