import XCTest
@testable import Shirox

/// Tests for `AniListThrottle`, the gate every AniList call site (content, library, social,
/// auth) reserves a turn through before firing a request.
///
/// An earlier version paced *every* request, even with nothing ever having gone wrong — that
/// serialized Home's five concurrent rows into a strict queue and made ordinary loads visibly
/// slow ("really really long") for no reason. These tests pin down the corrected contract:
/// healthy traffic passes straight through with no delay, and pacing only turns on once AniList
/// has actually rate-limited something. Mirrors the style of `JikanRetryTests`: cover the pure
/// scheduling function so the backoff math is verifiable without sleeping in CI.
final class AniListThrottleTests: XCTestCase {

    func testBaseIntervalWithNoRateLimiting() {
        XCTAssertEqual(AniListThrottle.interval(consecutive429s: 0), 0.4, accuracy: 0.0001)
    }

    /// Each consecutive 429 must widen the gap, so a struggling endpoint isn't hammered.
    func testIntervalGrowsWithConsecutive429s() {
        let zero = AniListThrottle.interval(consecutive429s: 0)
        let one = AniListThrottle.interval(consecutive429s: 1)
        let two = AniListThrottle.interval(consecutive429s: 2)
        XCTAssertGreaterThan(one, zero)
        XCTAssertGreaterThan(two, one)
    }

    func testIntervalDoublesEachStreak() {
        let first = AniListThrottle.interval(consecutive429s: 1)
        let second = AniListThrottle.interval(consecutive429s: 2)
        XCTAssertEqual(second, first * 2, accuracy: 0.0001)
    }

    /// Bounded: a long unlucky streak must not stall the app for good.
    func testIntervalIsCapped() {
        let capped = AniListThrottle.interval(consecutive429s: 20)
        XCTAssertEqual(capped, 3.0, accuracy: 0.0001)
    }

    func testCustomBaseAndCapAreRespected() {
        XCTAssertEqual(AniListThrottle.interval(consecutive429s: 0, base: 1.0, cap: 6.0), 1.0, accuracy: 0.0001)
        XCTAssertEqual(AniListThrottle.interval(consecutive429s: 10, base: 1.0, cap: 3.0), 3.0, accuracy: 0.0001)
    }

    // MARK: - Healthy traffic is never delayed

    /// The whole point of the fix: with nothing ever having gone wrong, concurrent callers
    /// (Home's five rows, for instance) must pass straight through together, not queue up one
    /// at a time. Uses an isolated instance (the initializer isn't private) rather than the
    /// app-wide singleton, so this doesn't interact with state from other tests.
    func testHealthyCallersAreNotDelayed() async {
        let throttle = AniListThrottle()
        let start = Date()
        async let first: Void = throttle.waitForTurn()
        async let second: Void = throttle.waitForTurn()
        async let third: Void = throttle.waitForTurn()
        _ = await (first, second, third)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1)
    }

    // MARK: - Backoff only after an actual rate limit

    /// Once a 429 has landed, the caller *after* the one that reserves the widened slot must
    /// wait rather than firing immediately behind it — that's the actual coordination this
    /// gate exists for. (The first call post-report still goes through immediately if nothing
    /// was already queued; it's the one reserving a future slot for whoever comes next.)
    func testCallerWaitsAfterAReportedRateLimit() async {
        let throttle = AniListThrottle()
        await throttle.reportRateLimited(retryAfter: nil)
        await throttle.waitForTurn() // reserves the widened slot for the next caller

        let start = Date()
        await throttle.waitForTurn()
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.35)
    }

    /// An explicit `Retry-After` must push the next caller's slot out to at least that far.
    func testRetryAfterIsHonouredByNextWaiter() async {
        let throttle = AniListThrottle()
        await throttle.reportRateLimited(retryAfter: 1.0)

        let start = Date()
        await throttle.waitForTurn()
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.9)
    }

    /// A long server-named window must not be honoured in full — it would stall every other
    /// caller on the shared gate, not just the one that actually got throttled.
    func testLongRetryAfterIsBoundedForOtherCallers() async {
        let throttle = AniListThrottle()
        await throttle.reportRateLimited(retryAfter: 60.0)

        let start = Date()
        await throttle.waitForTurn()
        XCTAssertLessThan(Date().timeIntervalSince(start), 5.0)
    }
}
