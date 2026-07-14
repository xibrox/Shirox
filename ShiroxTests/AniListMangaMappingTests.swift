import XCTest
@testable import Shirox

@MainActor
final class AniListMangaMappingTests: XCTestCase {
    private func decodeMedia(_ json: String) throws -> AniListMedia {
        try JSONDecoder().decode(AniListMedia.self, from: Data(json.utf8))
    }

    func testMapMangaMediaPutsChaptersInEpisodesAndMarksManga() throws {
        let json = """
        {"id":30002,"idMal":11,"title":{"romaji":"Berserk","english":"Berserk","native":null},
         "coverImage":{"large":"l.jpg","extraLarge":"xl.jpg"},"bannerImage":null,
         "description":"desc","episodes":null,"chapters":364,"status":"RELEASING",
         "averageScore":93,"genres":["Action","Drama"],"season":null,"seasonYear":null,
         "nextAiringEpisode":null,"relations":null,"type":"MANGA","format":"MANGA"}
        """
        let media = AniListProvider.shared.mapMangaMedia(try decodeMedia(json))
        XCTAssertEqual(media.episodes, 364)          // chapters land in the episodes slot
        XCTAssertEqual(media.type, "MANGA")
        XCTAssertTrue(media.isManga)
        XCTAssertEqual(media.averageScore, 93)
        XCTAssertEqual(media.genres, ["Action", "Drama"])
    }

    func testMapMangaMediaMapsRelations() throws {
        let json = """
        {"id":1,"idMal":null,"title":{"romaji":"A","english":null,"native":null},
         "coverImage":{"large":null,"extraLarge":null},"bannerImage":null,"description":null,
         "episodes":null,"chapters":10,"status":null,"averageScore":null,"genres":null,
         "season":null,"seasonYear":null,"nextAiringEpisode":null,
         "relations":{"edges":[{"relationType":"SEQUEL",
           "node":{"id":2,"title":{"romaji":"B","english":null,"native":null},
                   "coverImage":{"large":null,"extraLarge":null},"status":null,
                   "type":"MANGA","format":"MANGA"}}]},
         "type":"MANGA","format":"MANGA"}
        """
        let media = AniListProvider.shared.mapMangaMedia(try decodeMedia(json))
        XCTAssertEqual(media.relations?.edges.count, 1)
        XCTAssertEqual(media.relations?.edges.first?.relationType, "SEQUEL")
        XCTAssertEqual(media.relations?.edges.first?.node.id, 2)
    }
}
