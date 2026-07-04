import XCTest
@testable import Shirox

@MainActor
final class MangaTrackingTests: XCTestCase {

    override func setUp() async throws {
        LocalLibraryManager.shared.clearAll()
    }

    private func match(anilist: Int? = nil, mal: Int? = nil, total: Int? = nil) -> MangaMatch {
        MangaMatch(mangaHref: "https://m/x", title: "Test Manga",
                   aniListID: anilist, malID: mal, coverImage: "cover",
                   totalChapters: total, confident: true)
    }

    // MARK: - recordReadChapter (local library)

    func testRecordReadChapterCreatesMangaLocalEntry() {
        LocalLibraryManager.shared.recordReadChapter(
            match: match(total: 100), moduleId: "mod1", chapter: 3,
            title: "Test Manga", coverImage: "cover")
        let entries = LocalLibraryManager.shared.entries
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].media.isManga)
        XCTAssertEqual(entries[0].progress, 3)
        XCTAssertEqual(entries[0].status, .current)   // Planning→Current at chapter>0
    }

    func testRecordReadChapterIsMonotonic() {
        let m = match(total: 100)
        LocalLibraryManager.shared.recordReadChapter(match: m, moduleId: "mod1", chapter: 5, title: "T", coverImage: nil)
        LocalLibraryManager.shared.recordReadChapter(match: m, moduleId: "mod1", chapter: 2, title: "T", coverImage: nil)
        XCTAssertEqual(LocalLibraryManager.shared.entries.first?.progress, 5)   // never lowers
    }

    func testRecordReadChapterCompletesAtTotal() {
        let m = match(total: 10)
        LocalLibraryManager.shared.recordReadChapter(match: m, moduleId: "mod1", chapter: 10, title: "T", coverImage: nil)
        XCTAssertEqual(LocalLibraryManager.shared.entries.first?.status, .completed)
    }

    func testRecordReadChapterNoCompleteWhenOngoing() {
        let m = match(total: nil)   // ongoing
        LocalLibraryManager.shared.recordReadChapter(match: m, moduleId: "mod1", chapter: 999, title: "T", coverImage: nil)
        XCTAssertEqual(LocalLibraryManager.shared.entries.first?.status, .current)
    }

    // MARK: - Coordinator records locally even without a match (regression)

    func testCoordinatorRecordsLocallyWithoutMatch() async {
        await MangaTrackingCoordinator.shared.record(
            match: nil, mangaHref: "https://m/y", moduleId: "mod1",
            chapterNumber: 4, title: "Unlinked Manga", coverImage: nil)
        let entries = LocalLibraryManager.shared.entries
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].media.isManga)
        XCTAssertEqual(entries[0].progress, 4)
    }

    // MARK: - Remote progress rule (pure)

    func testRemoteProgressRaisesAndPromotes() {
        let r = MangaTrackingCoordinator.remoteProgress(existing: 2, chapter: 5, total: 100)
        XCTAssertEqual(r?.progress, 5)
        XCTAssertEqual(r?.status, .current)
    }

    func testRemoteProgressNilWhenNotHigher() {
        XCTAssertNil(MangaTrackingCoordinator.remoteProgress(existing: 9, chapter: 5, total: 100))
    }

    func testRemoteProgressCompletesAtTotal() {
        let r = MangaTrackingCoordinator.remoteProgress(existing: 9, chapter: 10, total: 10)
        XCTAssertEqual(r?.progress, 10)
        XCTAssertEqual(r?.status, .completed)
    }

    func testRemoteProgressOngoingNeverCompletes() {
        let r = MangaTrackingCoordinator.remoteProgress(existing: nil, chapter: 500, total: nil)
        XCTAssertEqual(r?.status, .current)
    }

    // MARK: - MangaModuleResolver.pickTitleMatch (pure)

    func testPickTitleMatchPrefersExact() {
        let results = [
            SearchItem(title: "Naruto Gaiden", image: "", href: "a"),
            SearchItem(title: "Naruto", image: "", href: "b"),
        ]
        XCTAssertEqual(MangaModuleResolver.pickTitleMatch(title: "naruto", results: results)?.href, "b")
    }

    func testPickTitleMatchFallsBackToTop() {
        let results = [
            SearchItem(title: "Bleach: Colorful", image: "", href: "x"),
            SearchItem(title: "Bleach Side", image: "", href: "y"),
        ]
        XCTAssertEqual(MangaModuleResolver.pickTitleMatch(title: "bleach", results: results)?.href, "x")
    }

    func testPickTitleMatchNilForEmpty() {
        XCTAssertNil(MangaModuleResolver.pickTitleMatch(title: "x", results: []))
    }
}
