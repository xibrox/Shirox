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
}
