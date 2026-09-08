import XCTest
@testable import Shirox

/// Tests for how the MyAnimeList (Jikan) client decides to retry.
///
/// The report was a bare "MyAnimeList 504". Jikan is a free, heavily loaded public API and
/// gateway errors are routine — one showed up on the very first request made while checking
/// this. Only 429 was retried before, so a single 504 became a hard "Couldn't load" for what is
/// almost always a blip that clears in a second.
final class JikanRetryTests: XCTestCase {

    // MARK: - What gets another go

    func testGatewayErrorsAreRetried() {
        // 504 is the one that was reported; the neighbours fail the same way.
        XCTAssertTrue(MALDiscoveryService.isRetryable(504))
        XCTAssertTrue(MALDiscoveryService.isRetryable(502))
        XCTAssertTrue(MALDiscoveryService.isRetryable(503))
        XCTAssertTrue(MALDiscoveryService.isRetryable(500))
    }

    func testRateLimitIsRetried() {
        XCTAssertTrue(MALDiscoveryService.isRetryable(429))
    }

    // MARK: - What doesn't

    /// A client error won't fix itself, so retrying only delays the message.
    func testClientErrorsAreNotRetried() {
        for status in [400, 401, 403, 404, 422] {
            XCTAssertFalse(MALDiscoveryService.isRetryable(status), "\(status) must not be retried")
        }
    }

    func testSuccessIsNotRetried() {
        XCTAssertFalse(MALDiscoveryService.isRetryable(200))
    }

    // MARK: - Backoff

    /// A rate limit needs its full window; a gateway error clears sooner, so it waits less.
    func testRateLimitWaitsLongerThanAGatewayError() {
        XCTAssertGreaterThan(
            MALDiscoveryService.backoffNanos(status: 429, attempt: 1),
            MALDiscoveryService.backoffNanos(status: 504, attempt: 1)
        )
    }

    /// Each attempt waits longer, so a struggling server isn't hammered.
    func testBackoffDoubles() {
        let first = MALDiscoveryService.backoffNanos(status: 504, attempt: 1)
        let second = MALDiscoveryService.backoffNanos(status: 504, attempt: 2)
        XCTAssertEqual(second, first * 2, accuracy: 1_000_000)
    }

    /// Bounded: a stuck endpoint must surface an error rather than retrying forever.
    func testAttemptsAreBounded() {
        XCTAssertGreaterThan(MALDiscoveryService.maxAttempts, 1, "one attempt is no retry at all")
        XCTAssertLessThanOrEqual(MALDiscoveryService.maxAttempts, 4, "must not stall the UI")
    }
}

/// Tests for which Jikan endpoint a browse request should use.
///
/// Genre filtering exists only on `/anime`, Jikan's search endpoint, which is much less
/// reliable than the rest of the API — it returned 504 to every request, parameters or not,
/// while this was written. `/top/anime` has no genre filter but is dependable and covers three
/// of the four sorts, so an unfiltered browse should prefer it.
final class JikanEndpointChoiceTests: XCTestCase {

    func testPopularMapsToTheRankedEndpoint() {
        XCTAssertEqual(DiscoverSort.popular.jikanTopFilter, .some("bypopularity"))
    }

    func testTrendingMapsToAiring() {
        XCTAssertEqual(DiscoverSort.trending.jikanTopFilter, .some("airing"))
    }

    /// Top Rated is `/top/anime`'s default ordering, so it needs no filter — but it *is*
    /// expressible, which is why this is `.some(nil)` rather than `nil`.
    func testTopRatedUsesTheDefaultRanking() {
        let filter = DiscoverSort.topRated.jikanTopFilter
        XCTAssertNotNil(filter, "Top Rated must be expressible on /top/anime")
        XCTAssertEqual(filter, .some(nil))
    }

    /// Newest has no ranked equivalent, so it has to fall back to the search endpoint.
    func testNewestHasNoRankedEquivalent() {
        XCTAssertNil(DiscoverSort.newest.jikanTopFilter)
    }

    /// Popularity is ranked ascending on MAL — rank 1 is the most popular — and getting this
    /// backwards would quietly return the least popular titles.
    func testPopularitySortsAscending() {
        XCTAssertEqual(DiscoverSort.popular.jikanDirection, "asc")
        for other in [DiscoverSort.trending, .topRated, .newest] {
            XCTAssertEqual(other.jikanDirection, "desc")
        }
    }

    /// The genre vocabulary must resolve on MAL, or the filter silently does nothing.
    func testEveryOfferedGenreResolvesToAMALIdentifier() {
        for genre in DiscoverGenre.all {
            XCTAssertNotNil(DiscoverGenre.malID(for: genre), "\(genre) has no MyAnimeList id")
        }
    }

    /// MAL files AniList's "Thriller" under "Suspense" — the one name that doesn't match.
    func testThrillerMapsToSuspense() {
        XCTAssertEqual(DiscoverGenre.malID(for: "Thriller"), 41)
    }

    func testUnknownGenreHasNoIdentifier() {
        XCTAssertNil(DiscoverGenre.malID(for: "Isekai"))
    }
}
