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
}
