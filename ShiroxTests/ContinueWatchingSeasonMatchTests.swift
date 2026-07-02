import XCTest
@testable import Shirox

/// Tests that a Continue Watching item is matched to the correct episode row on a flat,
/// multi-season episode list.
///
/// The reported bug: a module returns one list for a whole franchise, so episode *numbers*
/// repeat across seasons (S1 1…12, then S2 1…12). Starting S1 E5 and closing it mid-way
/// left an in-progress item with episodeNumber 5. The detail view matched that item to
/// *every* row numbered 5 — so S2 E5 showed S1 E5's progress bar and, when tapped, resumed
/// season 1's stream. The unique per-episode `href` disambiguates the two.
final class ContinueWatchingSeasonMatchTests: XCTestCase {

    /// Builds an item carrying only the fields the matcher inspects; the rest are inert.
    private func makeItem(episodeNumber: Int, episodeHref: String?) -> ContinueWatchingItem {
        ContinueWatchingItem(
            id: UUID(), mediaTitle: "Show", episodeNumber: episodeNumber,
            episodeTitle: nil, imageUrl: "", streamUrl: "https://x/s\(episodeNumber)",
            headers: nil, subtitle: nil, streamTitle: nil,
            aniListID: nil, malID: nil, moduleId: "mod", detailHref: nil,
            episodeHref: episodeHref,
            watchedSeconds: 100, totalSeconds: 1000, totalEpisodes: nil,
            availableEpisodes: nil, isAiring: nil, lastWatchedAt: .now, thumbnailUrl: nil
        )
    }

    /// THE BUG: an in-progress item saved for S1 E5 must match S1 E5's row (same href)…
    func testItemMatchesOwnSeasonRowByHref() {
        let item = makeItem(episodeNumber: 5, episodeHref: "s1/ep5")
        XCTAssertTrue(item.matchesEpisode(number: 5, href: "s1/ep5"))
    }

    /// …and must NOT match S2 E5's row, even though the episode number is identical.
    func testItemDoesNotMatchOtherSeasonRowWithSameNumber() {
        let item = makeItem(episodeNumber: 5, episodeHref: "s1/ep5")
        XCTAssertFalse(item.matchesEpisode(number: 5, href: "s2/ep5"),
                       "S1 E5's progress must not bleed onto S2 E5")
    }

    /// Legacy items (saved before episodeHref existed) can only fall back to the number.
    func testLegacyItemWithoutHrefFallsBackToNumber() {
        let item = makeItem(episodeNumber: 5, episodeHref: nil)
        XCTAssertTrue(item.matchesEpisode(number: 5, href: "s2/ep5"))
        XCTAssertFalse(item.matchesEpisode(number: 6, href: "s2/ep6"))
    }

    /// A row without an href (shouldn't happen for module episodes, but be defensive)
    /// falls back to the number rather than silently failing to match.
    func testRowWithoutHrefFallsBackToNumber() {
        let item = makeItem(episodeNumber: 5, episodeHref: "s1/ep5")
        XCTAssertTrue(item.matchesEpisode(number: 5, href: nil))
        XCTAssertTrue(item.matchesEpisode(number: 5, href: ""))
    }

    // MARK: - Completed (watched) display decision

    /// A per-episode href marker is authoritative — the row is watched regardless of the
    /// number key, so completing S1 E5 marks exactly S1 E5.
    func testHrefMarkerAlwaysCountsAsWatched() {
        XCTAssertTrue(ContinueWatchingManager.isEpisodeWatched(
            watchedByHref: true, watchedByNumber: false,
            showUsesHrefTracking: true, numberIsAmbiguous: true))
    }

    /// Shows with no in-app completion keep the legacy behavior: the number key is trusted
    /// (this is how remote-sync and mark-as-watched state shows today). No regression.
    func testNumberKeyTrustedWhenShowHasNoHrefTracking() {
        XCTAssertTrue(ContinueWatchingManager.isEpisodeWatched(
            watchedByHref: false, watchedByNumber: true,
            showUsesHrefTracking: false, numberIsAmbiguous: true))
    }

    /// THE BUG: once the show is href-tracked, a number key on an *ambiguous* number (repeats
    /// across seasons) must NOT count — otherwise S1 E5's completion bleeds onto S2 E5.
    func testAmbiguousNumberSuppressedWhenShowIsHrefTracked() {
        XCTAssertFalse(ContinueWatchingManager.isEpisodeWatched(
            watchedByHref: false, watchedByNumber: true,
            showUsesHrefTracking: true, numberIsAmbiguous: true))
    }

    /// An href-tracked show still honors number keys on *unambiguous* numbers (a uniquely
    /// numbered episode can't belong to another season), preserving sync/single-season display.
    func testUnambiguousNumberStillCountsWhenHrefTracked() {
        XCTAssertTrue(ContinueWatchingManager.isEpisodeWatched(
            watchedByHref: false, watchedByNumber: true,
            showUsesHrefTracking: true, numberIsAmbiguous: false))
    }

    /// Nothing recorded → not watched.
    func testNoMarkersMeansNotWatched() {
        XCTAssertFalse(ContinueWatchingManager.isEpisodeWatched(
            watchedByHref: false, watchedByNumber: false,
            showUsesHrefTracking: false, numberIsAmbiguous: false))
    }
}
