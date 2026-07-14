import XCTest
@testable import Shirox

final class MALMangaStatusMappingTests: XCTestCase {
    func testStatusToMALManga() {
        let s = MALMangaLibraryService.shared
        XCTAssertEqual(s.mapStatusToMAL(.current), "reading")
        XCTAssertEqual(s.mapStatusToMAL(.planning), "plan_to_read")
        XCTAssertEqual(s.mapStatusToMAL(.completed), "completed")
        XCTAssertEqual(s.mapStatusToMAL(.dropped), "dropped")
        XCTAssertEqual(s.mapStatusToMAL(.paused), "on_hold")
        XCTAssertEqual(s.mapStatusToMAL(.repeating), "reading")
    }

    func testStatusFromMALManga() {
        let s = MALMangaLibraryService.shared
        XCTAssertEqual(s.mapStatusFromMAL("reading"), .current)
        XCTAssertEqual(s.mapStatusFromMAL("plan_to_read"), .planning)
        XCTAssertEqual(s.mapStatusFromMAL("completed"), .completed)
        XCTAssertEqual(s.mapStatusFromMAL("dropped"), .dropped)
        XCTAssertEqual(s.mapStatusFromMAL("on_hold"), .paused)
        XCTAssertEqual(s.mapStatusFromMAL(nil), .planning)
    }

    func testMangaListEntryMapsToLibraryEntry() {
        let node = MALMangaLibraryService.MALMangaNode(
            id: 11, title: "Berserk", main_picture: nil, num_chapters: 364,
            status: "currently_publishing", mean: 9.3, genres: nil, synopsis: nil, media_type: "manga")
        let status = MALMangaLibraryService.MALMangaListStatus(
            status: "reading", score: 8, num_chapters_read: 42, num_times_reread: 0, updated_at: nil)
        let entry = MALMangaLibraryService.MALMangaListEntry(node: node, list_status: status)
        let media = Media(
            id: 11, idMal: 11, provider: .mal,
            title: MediaTitle(romaji: "Berserk", english: "Berserk", native: nil),
            coverImage: MediaCoverImage(large: nil, extraLarge: nil), bannerImage: nil,
            description: nil, episodes: 364, status: nil, averageScore: nil, genres: nil,
            season: nil, seasonYear: nil, nextAiringEpisode: nil, relations: nil,
            type: "MANGA", format: nil)

        let lib = MALMangaLibraryService.libraryEntry(from: entry, media: media)
        XCTAssertEqual(lib.id, 11)
        XCTAssertEqual(lib.status, .current)
        XCTAssertEqual(lib.progress, 42)
        XCTAssertEqual(lib.score, 8.0)
    }

    func testMangaStaticStatusMapping() {
        XCTAssertEqual(MALMangaLibraryService.mapStatus("reading"), .current)
        XCTAssertEqual(MALMangaLibraryService.mapStatus("plan_to_read"), .planning)
        XCTAssertEqual(MALMangaLibraryService.mapStatus("on_hold"), .paused)
        XCTAssertEqual(MALMangaLibraryService.mapStatus(nil), .planning)
    }
}
