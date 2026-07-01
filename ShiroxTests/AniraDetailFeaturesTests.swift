import XCTest
@testable import Shirox

final class AniraDetailFeaturesTests: XCTestCase {

    // MARK: - AniraMediaEntry decoding (watch_order / similar shape)

    func testAniraMediaEntryDecodesWatchOrderEntry() throws {
        let json = Data("""
        { "title": "One Piece",
          "cover": "https://api.anira.dev/images/anime/21",
          "mappings": { "mal_id": 21, "anilist_id": 21, "media_type": "TV" } }
        """.utf8)
        let entry = try JSONDecoder().decode(TVDBMappingService.AniraMediaEntry.self, from: json)
        XCTAssertEqual(entry.title, "One Piece")
        XCTAssertEqual(entry.cover, "https://api.anira.dev/images/anime/21")
        XCTAssertEqual(entry.mappings.anilist_id, 21)
        XCTAssertEqual(entry.mappings.mal_id, 21)
    }

    func testAniraMediaEntryDecodesNullAnilistId() throws {
        let json = Data("""
        { "title": "One Piece: Special",
          "cover": "https://api.anira.dev/images/anime/16143",
          "mappings": { "mal_id": 16143, "anilist_id": null, "media_type": "SPECIAL" } }
        """.utf8)
        let entry = try JSONDecoder().decode(TVDBMappingService.AniraMediaEntry.self, from: json)
        XCTAssertNil(entry.mappings.anilist_id)
        XCTAssertEqual(entry.mappings.mal_id, 16143)
    }

    func testAniraMediaEntryArrayDecodes() throws {
        let json = Data("""
        [ { "title": "A", "cover": "c1", "mappings": { "anilist_id": 1 } },
          { "title": "B", "cover": "c2", "mappings": { "anilist_id": 2 } } ]
        """.utf8)
        let entries = try JSONDecoder().decode([TVDBMappingService.AniraMediaEntry].self, from: json)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map { $0.mappings.anilist_id }, [1, 2])
    }

    // MARK: - Filler badge mapping

    func testFillerBadgeMapping() {
        XCTAssertEqual(ThumbnailEpisodeRow.fillerBadge(for: "filler"), .filler)
        XCTAssertEqual(ThumbnailEpisodeRow.fillerBadge(for: "mixed-manga"), .mixed)
        XCTAssertNil(ThumbnailEpisodeRow.fillerBadge(for: "manga-canon"))
        XCTAssertNil(ThumbnailEpisodeRow.fillerBadge(for: "anime-canon"))
        XCTAssertNil(ThumbnailEpisodeRow.fillerBadge(for: "unknown"))
        XCTAssertNil(ThumbnailEpisodeRow.fillerBadge(for: nil))
    }

    // MARK: - Airdate formatting

    func testFormattedAirdate() {
        XCTAssertEqual(ThumbnailEpisodeRow.formattedAirdate("2002-10-03"), "Oct 3, 2002")
        XCTAssertEqual(ThumbnailEpisodeRow.formattedAirdate("2024-01-05"), "Jan 5, 2024")
        XCTAssertNil(ThumbnailEpisodeRow.formattedAirdate(nil))
        XCTAssertNil(ThumbnailEpisodeRow.formattedAirdate(""))
        XCTAssertNil(ThumbnailEpisodeRow.formattedAirdate("not-a-date"))
    }
}
