import XCTest
@testable import Shirox

final class MangaMatchManagerTests: XCTestCase {

    private func media(_ id: Int, _ english: String, idMal: Int? = nil, chapters: Int? = nil) -> AniListMedia {
        AniListMedia(
            id: id, idMal: idMal,
            title: AniListTitle(romaji: nil, english: english, native: nil),
            coverImage: AniListCoverImage(large: "cover", extraLarge: nil),
            bannerImage: nil, description: nil, episodes: nil, chapters: chapters,
            status: nil, averageScore: nil, genres: nil, season: nil, seasonYear: nil,
            nextAiringEpisode: nil, relations: nil, type: "MANGA", format: nil)
    }

    // MARK: - selectMatch (pure)

    func testSelectMatchPrefersExactCaseInsensitiveInTop3() {
        let results = [media(1, "Something Else"), media(2, "One Piece"), media(3, "One Piece: Extra")]
        let picked = MangaMatchManager.selectMatch(title: "one piece", results: results)
        XCTAssertEqual(picked?.media.id, 2)
        XCTAssertTrue(picked?.confident == true)
    }

    func testSelectMatchFallsBackToTopResultAsNotConfident() {
        let results = [media(10, "Berserk Deluxe"), media(11, "Berserk Side Story")]
        let picked = MangaMatchManager.selectMatch(title: "berserk", results: results)
        XCTAssertEqual(picked?.media.id, 10)   // top result
        XCTAssertFalse(picked?.confident == true)
    }

    func testSelectMatchReturnsNilForEmptyResults() {
        XCTAssertNil(MangaMatchManager.selectMatch(title: "x", results: []))
    }

    // MARK: - buildMatch (pure)

    func testBuildMatchCarriesIdMalAndChapters() {
        let m = MangaMatchManager.buildMatch(
            mangaHref: "href", title: "One Piece",
            from: media(2, "One Piece", idMal: 13, chapters: 1100), confident: true)
        XCTAssertEqual(m.aniListID, 2)
        XCTAssertEqual(m.malID, 13)
        XCTAssertEqual(m.totalChapters, 1100)
        XCTAssertEqual(m.coverImage, "cover")
        XCTAssertTrue(m.confident)
    }

    func testBuildMatchNilIdMalMeansNoMal() {
        let m = MangaMatchManager.buildMatch(
            mangaHref: "href", title: "Obscure", from: media(5, "Obscure"), confident: false)
        XCTAssertNil(m.malID)
        XCTAssertNil(m.totalChapters)
    }
}
