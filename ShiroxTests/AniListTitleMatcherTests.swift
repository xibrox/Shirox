import XCTest
@testable import Shirox

/// A module page's AniList match when no title matches exactly, and where an episode past a
/// season's end is tracked.
final class AniListTitleMatcherTests: XCTestCase {

    private let drStone = [
        AniListTitleMatcher.Candidate(id: 1, titles: ["Dr. STONE"]),
        AniListTitleMatcher.Candidate(id: 2, titles: ["Dr. STONE SCIENCE FUTURE"]),
        AniListTitleMatcher.Candidate(id: 3, titles: ["Dr. STONE SCIENCE FUTURE Cour 2"]),
        AniListTitleMatcher.Candidate(id: 4, titles: ["Dr. STONE SCIENCE FUTURE Cour 3"]),
    ]

    /// Reported: a later cour's episode 12 was marked on the original Dr. STONE, AniList's top result.
    func testALaterCourMatchesThatCourNotTheBestKnownEntry() {
        XCTAssertEqual(AniListTitleMatcher.bestMatch(for: "Dr. Stone: Science Future Part 3", among: drStone), 4)
        XCTAssertEqual(AniListTitleMatcher.bestMatch(for: "Dr. Stone Season 4 Part 3", among: drStone), 4)
        XCTAssertEqual(AniListTitleMatcher.bestMatch(for: "Dr. Stone Science Future 2nd Cour", among: drStone), 3)
        XCTAssertEqual(AniListTitleMatcher.bestMatch(for: "Dr Stone Science Future", among: drStone), 2)
    }

    func testNoEntryOfThatSeasonIsNoMatch() {
        XCTAssertNil(AniListTitleMatcher.bestMatch(for: "Dr. Stone Science Future Part 5", among: drStone))
        XCTAssertNil(AniListTitleMatcher.bestMatch(for: "Completely Different Show",
                                                    among: [.init(id: 9, titles: ["Different Story"])]))
    }

    func testANumberInTheNameIsntASeason() {
        let kaiju = [AniListTitleMatcher.Candidate(id: 1, titles: ["Kaiju No. 8"]),
                     AniListTitleMatcher.Candidate(id: 2, titles: ["Kaiju No. 8 Season 2"])]
        XCTAssertEqual(AniListTitleMatcher.bestMatch(for: "Kaiju No. 8", among: kaiju), 1)
        XCTAssertEqual(AniListTitleMatcher.bestMatch(for: "Kaiju No.8 2nd Season", among: kaiju), 2)
    }

    /// A title in another script shares no words; AniList's order decides, within the season.
    func testATitleInAnotherScriptKeepsAniListsOrder() {
        let violet = [AniListTitleMatcher.Candidate(id: 7, titles: ["Violet Evergarden"]),
                      AniListTitleMatcher.Candidate(id: 8, titles: ["Violet Evergarden II"])]
        XCTAssertEqual(AniListTitleMatcher.bestMatch(for: "Вайолет Эвергарден", among: violet), 7)
        XCTAssertEqual(AniListTitleMatcher.bestMatch(for: "Вайолет Эвергарден 2 сезон", among: violet), 8)
    }

    // MARK: - Past a season's end

    private let cours = [SequelOverflow.Season(aniListID: 3, malID: 30, episodes: 12),
                         SequelOverflow.Season(aniListID: 4, malID: 40, episodes: 13)]

    /// Reported: Up Next from Cour 2's last episode marked "13 / 12" on Cour 2.
    func testEpisodeThirteenOfATwelveEpisodeCourIsTheNextCoursFirst() {
        XCTAssertEqual(SequelOverflow.carry(episode: 13, through: cours),
                       .init(aniListID: 4, malID: 40, episode: 1, seasonEpisodeCount: 13))
        XCTAssertEqual(SequelOverflow.carry(episode: 25, through: cours)?.episode, 13)
    }

    func testWithinTheSeasonOrPastEverySeasonNothingMoves() {
        XCTAssertNil(SequelOverflow.carry(episode: 12, through: cours))
        XCTAssertNil(SequelOverflow.carry(episode: 30, through: cours), "no season holds it")
    }

    func testASequelStillAiringTakesWhatsLeft() {
        let airing = [cours[0], SequelOverflow.Season(aniListID: 4, malID: nil, episodes: nil)]
        XCTAssertEqual(SequelOverflow.carry(episode: 15, through: airing),
                       .init(aniListID: 4, malID: nil, episode: 3, seasonEpisodeCount: nil))
    }
}
