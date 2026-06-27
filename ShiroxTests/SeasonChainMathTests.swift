import XCTest
@testable import Shirox

/// Tests for the pure global-episode → season-entry boundary math.
///
/// The reported bug: watching ep 12 of the *latest* Dr. Stone cour (Science Future
/// Part III) auto-tracked progress onto the *original* Dr. Stone S1, because the math
/// treated the module's per-cour episode number as a franchise-absolute number counted
/// from the first season. The fix anchors the number to the entry the user is watching.
final class SeasonChainMathTests: XCTestCase {

    /// The real Dr. Stone chain (anira tvdb_id 355774, TV entries only) with real
    /// per-entry episode counts. Global ranges that result:
    ///   S1            (0, 24]   Stone Wars   (24, 35]
    ///   New World     (35, 46]  New World II (46, 57]
    ///   Sci Future    (57, 69]  Sci Future II(69, 81]  Sci Future III (81, 93]
    private func drStoneChain() -> [SiblingSeason] {
        [
            SiblingSeason(aniListID: 105333, malID: 38691, tvdbSeason: 1, tvdbEpoffset: 0,  episodeCount: 24), // S1
            SiblingSeason(aniListID: 113936, malID: 40852, tvdbSeason: 2, tvdbEpoffset: 0,  episodeCount: 11), // Stone Wars
            SiblingSeason(aniListID: 131518, malID: 48549, tvdbSeason: 3, tvdbEpoffset: 0,  episodeCount: 11), // New World
            SiblingSeason(aniListID: 162670, malID: 55644, tvdbSeason: 3, tvdbEpoffset: 11, episodeCount: 11), // New World II
            SiblingSeason(aniListID: 172019, malID: 57592, tvdbSeason: 4, tvdbEpoffset: 0,  episodeCount: 12), // Science Future
            SiblingSeason(aniListID: 189117, malID: 61322, tvdbSeason: 4, tvdbEpoffset: 12, episodeCount: 12), // Science Future II
            SiblingSeason(aniListID: 199221, malID: 62568, tvdbSeason: 4, tvdbEpoffset: 24, episodeCount: 12), // Science Future III
        ]
    }

    /// THE BUG: a per-cour number (ep 12) while watching the latest cour must stay on that
    /// cour — not get reinterpreted as franchise ep 12 (original Dr. Stone S1 ep 12).
    func testPerCourEpisodeStaysOnAnchorCour() {
        let m = SeasonChainMath.map(globalEpisode: 12,
                                    anchorAniListID: 199221, anchorMALID: 62568,
                                    siblings: drStoneChain())
        XCTAssertEqual(m?.aniListID, 199221, "should track Science Future III, not S1")
        XCTAssertEqual(m?.malID, 62568)
        XCTAssertEqual(m?.relativeEpisode, 12)
    }

    /// Continuous module matched to the franchise root (S1, start 0): a cross-season number
    /// still flows forward to the right later season. ep 30 → Stone Wars ep 6.
    func testContinuousFromRootMapsForward() {
        let m = SeasonChainMath.map(globalEpisode: 30,
                                    anchorAniListID: 105333, anchorMALID: 38691,
                                    siblings: drStoneChain())
        XCTAssertEqual(m?.aniListID, 113936, "Stone Wars")
        XCTAssertEqual(m?.relativeEpisode, 6)
    }

    /// Continuous-within-season module matched to the season's first cour (Science Future,
    /// start 57): counting forward across that season's cours still works. ep 30 → SF III ep 6.
    func testContinuousWithinSeasonFromFirstCour() {
        let m = SeasonChainMath.map(globalEpisode: 30,
                                    anchorAniListID: 172019, anchorMALID: 57592,
                                    siblings: drStoneChain())
        XCTAssertEqual(m?.aniListID, 199221, "Science Future III")
        XCTAssertEqual(m?.relativeEpisode, 6)
    }

    /// Unknown anchor (not in the chain) → legacy absolute-from-first-season behavior.
    func testUnknownAnchorFallsBackToAbsolute() {
        let m = SeasonChainMath.map(globalEpisode: 12,
                                    anchorAniListID: 999999, anchorMALID: nil,
                                    siblings: drStoneChain())
        XCTAssertEqual(m?.aniListID, 105333, "no anchor match → counts from S1")
        XCTAssertEqual(m?.relativeEpisode, 12)
    }

    /// THE BUG: the newest cour (Science Future III, 199221) is still missing from the
    /// cached offline chain. Watching its ep 1 (continuous module number 25, anchored to
    /// the first Science Future cour) overflows past the last KNOWN cour (Science Future II,
    /// 189117, 12 eps). The math used to dump it onto that last cour as ep 13 — an episode
    /// that cannot exist. An episode beyond the known chain must decline (nil) so the caller
    /// falls back to the anchor the user actually matched, never invent ep 13 of a 12-ep cour.
    func testEpisodeBeyondKnownChainDeclinesInsteadOfOverflowingLastCour() {
        let chainMissingNewest = drStoneChain().filter { $0.aniListID != 199221 }
        let m = SeasonChainMath.map(globalEpisode: 25,
                                    anchorAniListID: 172019, anchorMALID: 57592,
                                    siblings: chainMissingNewest)
        XCTAssertNil(m, "episode past the last known cour must not map to a nonexistent ep")
    }

    // MARK: - priorEpisodeCount (forward offset for episode selection)

    /// The first season has no preceding episodes.
    func testPriorEpisodeCountIsZeroForFirstSeason() {
        let p = SeasonChainMath.priorEpisodeCount(anchorAniListID: 105333, anchorMALID: 38691,
                                                  siblings: drStoneChain())
        XCTAssertEqual(p, 0)
    }

    /// Crossing into a later tvdb_season sums every earlier season. Science Future starts at 57.
    func testPriorEpisodeCountCrossesSeasons() {
        let p = SeasonChainMath.priorEpisodeCount(anchorAniListID: 172019, anchorMALID: 57592,
                                                  siblings: drStoneChain())
        XCTAssertEqual(p, 57, "S1(24)+Stone Wars(11)+New World cours(22) = 57")
    }

    /// A later cour within a season adds its epoffset on top of the season base.
    func testPriorEpisodeCountWithinSeasonCour() {
        let nw2 = SeasonChainMath.priorEpisodeCount(anchorAniListID: 162670, anchorMALID: 55644,
                                                    siblings: drStoneChain())
        XCTAssertEqual(nw2, 46, "New World II = base 35 + epoffset 11")
        let sf3 = SeasonChainMath.priorEpisodeCount(anchorAniListID: 199221, anchorMALID: 62568,
                                                    siblings: drStoneChain())
        XCTAssertEqual(sf3, 81, "Science Future III = base 57 + epoffset 24")
    }

    /// A missing earlier-season count makes a cross-season offset unknowable → nil.
    func testPriorEpisodeCountNilWhenEarlierCountMissing() {
        let chain = drStoneChain().map { s in
            s.aniListID == 105333
                ? SiblingSeason(aniListID: s.aniListID, malID: s.malID, tvdbSeason: s.tvdbSeason,
                                tvdbEpoffset: s.tvdbEpoffset, episodeCount: nil)
                : s
        }
        let p = SeasonChainMath.priorEpisodeCount(anchorAniListID: 172019, anchorMALID: 57592,
                                                  siblings: chain)
        XCTAssertNil(p, "can't sum S1 with an unknown count")
    }

    /// Unknown anchor (not in the chain) → nil, so the caller applies no offset.
    func testPriorEpisodeCountNilForUnknownAnchor() {
        let p = SeasonChainMath.priorEpisodeCount(anchorAniListID: 999999, anchorMALID: nil,
                                                  siblings: drStoneChain())
        XCTAssertNil(p)
    }
}

/// Tests for season-aware ordering of a module's search results against an AniList title.
///
/// The reported bug: opening an AniList Season-N entry on a module that lists each season as a
/// separate search result could land on the wrong season, because results came back in the
/// module's own order (e.g. "3rd Season" first, "Season 2" second, base title later). Ranking by
/// base-title + season match floats the correct entry to the front.
final class SearchResultMatcherTests: XCTestCase {

    func testParseExtractsSeasonAndNormalizesBase() {
        let p = SearchResultMatcher.parse("Frieren: Beyond Journey's End Season 2")
        XCTAssertEqual(p, SearchResultMatcher.Parsed(base: "frieren beyond journeys end", season: 2))
    }

    func testParseOrdinalSeason() {
        XCTAssertEqual(SearchResultMatcher.parse("Sousou no Frieren 3rd Season"),
                       SearchResultMatcher.Parsed(base: "sousou no frieren", season: 3))
    }

    func testParseDefaultsToSeasonOneAndDecodesEntities() {
        // base entry (no season stated) and an HTML-entity apostrophe normalize to season 1.
        XCTAssertEqual(SearchResultMatcher.parse("Frieren: Beyond Journey&#039;s End"),
                       SearchResultMatcher.Parsed(base: "frieren beyond journeys end", season: 1))
    }

    /// THE BUG: the season-2 entry must rank ahead of the base (season 1) and a romaji 3rd-season
    /// look-alike, given the AniList "… Season 2" query.
    func testRanksCorrectSeasonFirst() {
        let candidates = [
            "Sousou no Frieren 3rd Season",
            "Frieren: Beyond Journey's End",          // season 1 base
            "Frieren: Beyond Journey's End Season 2",  // the right one
        ]
        let ordered = SearchResultMatcher.ranked(
            query: "Frieren: Beyond Journey's End Season 2", items: candidates, title: { $0 })
        XCTAssertEqual(ordered.first, "Frieren: Beyond Journey's End Season 2")
    }

    func testRanksSlimeSeasonFour() {
        let candidates = [
            "That Time I Got Reincarnated as a Slime Season 2",
            "That Time I Got Reincarnated as a Slime",
            "That Time I Got Reincarnated as a Slime Season 4",
            "That Time I Got Reincarnated as a Slime Season 3",
        ]
        let ordered = SearchResultMatcher.ranked(
            query: "That Time I Got Reincarnated as a Slime Season 4", items: candidates, title: { $0 })
        XCTAssertEqual(ordered.first, "That Time I Got Reincarnated as a Slime Season 4")
    }

    /// No confident match (unrelated titles) keeps the original order — nothing is reordered
    /// to the front spuriously.
    func testUnrelatedResultsKeepOrder() {
        let candidates = ["One Piece", "Naruto", "Bleach"]
        let ordered = SearchResultMatcher.ranked(query: "Frieren Season 2", items: candidates, title: { $0 })
        XCTAssertEqual(ordered, candidates)
    }
}
