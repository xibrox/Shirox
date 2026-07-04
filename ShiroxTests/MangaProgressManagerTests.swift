import XCTest
@testable import Shirox

final class MangaProgressManagerTests: XCTestCase {

    private func item(href: String, chapter: String = "c1", page: Int = 0) -> MangaReadingItem {
        MangaReadingItem(
            mangaTitle: "T", mangaHref: href, coverImage: "", moduleId: "m1",
            chapterHref: chapter, chapterName: "Chapter 1", chapterNumber: 1,
            pageIndex: page, totalPages: 20, lastReadAt: .now)
    }

    // MARK: - Upsert (pure core)

    func testUpsertInsertsNewItemAtFront() {
        let existing = [item(href: "a"), item(href: "b")]
        let result = MangaProgressManager.upsert(item(href: "c"), into: existing)
        XCTAssertEqual(result.map(\.mangaHref), ["c", "a", "b"])
    }

    func testUpsertReplacesSameMangaAndMovesToFront() {
        let existing = [item(href: "a"), item(href: "b", page: 3)]
        let result = MangaProgressManager.upsert(item(href: "b", chapter: "c2", page: 7), into: existing)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].mangaHref, "b")
        XCTAssertEqual(result[0].chapterHref, "c2")
        XCTAssertEqual(result[0].pageIndex, 7)
        XCTAssertEqual(result[1].mangaHref, "a")
    }

    func testUpsertCapsListLength() {
        let existing = (0..<3).map { item(href: "m\($0)") }
        let result = MangaProgressManager.upsert(item(href: "new"), into: existing, max: 3)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].mangaHref, "new")
        XCTAssertEqual(result.last?.mangaHref, "m1") // m2 evicted
    }

    // MARK: - Read-marking rule

    func testReachedLastPage() {
        XCTAssertTrue(MangaProgressManager.reachedLastPage(pageIndex: 19, totalPages: 20))
        XCTAssertTrue(MangaProgressManager.reachedLastPage(pageIndex: 25, totalPages: 20))
        XCTAssertFalse(MangaProgressManager.reachedLastPage(pageIndex: 18, totalPages: 20))
        XCTAssertFalse(MangaProgressManager.reachedLastPage(pageIndex: 0, totalPages: 0))
    }

    func testProgressFraction() {
        XCTAssertEqual(MangaProgressManager.progressFraction(pageIndex: 0, totalPages: 20), 0.05, accuracy: 0.0001)
        XCTAssertEqual(MangaProgressManager.progressFraction(pageIndex: 9, totalPages: 20), 0.5, accuracy: 0.0001)
        XCTAssertEqual(MangaProgressManager.progressFraction(pageIndex: 19, totalPages: 20), 1.0)
        XCTAssertEqual(MangaProgressManager.progressFraction(pageIndex: 0, totalPages: 0), 0)     // no pages
        XCTAssertEqual(MangaProgressManager.progressFraction(pageIndex: 50, totalPages: 20), 1.0) // clamped
    }

    // MARK: - Model persistence

    func testLegacyItemWithoutPageFractionDecodes() throws {
        // Items persisted before pageFraction existed must keep decoding (default 0).
        let legacy = """
        {"mangaTitle":"T","mangaHref":"h","coverImage":"","moduleId":"m","chapterHref":"c","chapterName":"Ch 1","chapterNumber":1,"pageIndex":4,"totalPages":20,"lastReadAt":0}
        """.data(using: .utf8)!
        let item = try JSONDecoder().decode(MangaReadingItem.self, from: legacy)
        XCTAssertEqual(item.pageFraction, 0)
        XCTAssertEqual(item.pageIndex, 4)
    }

    func testMangaReadingItemRoundTripsThroughJSON() throws {
        let original = item(href: "https://mangapark.net/title/x", chapter: "https://mangapark.net/title/x/c1", page: 4)
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(MangaReadingItem.self, from: data)
        XCTAssertEqual(restored, original)
    }
}
