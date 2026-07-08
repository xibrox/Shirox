import XCTest
@testable import Shirox

final class MangaDownloadPlanningTests: XCTestCase {

    // MARK: - pageFileName

    func testPageFileNameZeroPadsByTotalWidth() {
        let url = URL(string: "https://cdn.example.com/img/page-1.jpg")!
        XCTAssertEqual(MangaDownloadPlanning.pageFileName(index: 0, total: 12, url: url), "000.jpg")
        XCTAssertEqual(MangaDownloadPlanning.pageFileName(index: 11, total: 12, url: url), "011.jpg")
    }

    func testPageFileNameWidensForLargeChapters() {
        let url = URL(string: "https://cdn.example.com/p.webp")!
        XCTAssertEqual(MangaDownloadPlanning.pageFileName(index: 5, total: 1500, url: url), "0005.webp")
    }

    func testPageFileNameFallsBackToJpgWhenNoExtension() {
        let url = URL(string: "https://cdn.example.com/image?id=42")!
        XCTAssertEqual(MangaDownloadPlanning.pageFileName(index: 0, total: 3, url: url), "000.jpg")
    }

    // MARK: - refererOrigin

    func testRefererOriginIsSchemeAndHostOnly() {
        XCTAssertEqual(
            MangaDownloadPlanning.refererOrigin(forMangaHref: "https://mangasite.org/manga/one-piece"),
            "https://mangasite.org/")
    }

    func testRefererOriginEmptyForGarbage() {
        XCTAssertEqual(MangaDownloadPlanning.refererOrigin(forMangaHref: ""), "")
    }

    // MARK: - orphanFolderNames

    func testOrphanFolderNamesReturnsOnlyUnknownUUIDs() {
        let keep = UUID()
        let orphan = UUID()
        let names = [keep.uuidString, orphan.uuidString, "manga_downloads_manifest.json", "not-a-uuid"]
        XCTAssertEqual(
            MangaDownloadPlanning.orphanFolderNames(names, validIDs: [keep]),
            [orphan.uuidString])
    }

    // MARK: - reconcileLoaded

    private func makeItem(state: MangaDownloadState, pageFiles: [String] = ["000.jpg"]) -> MangaDownloadItem {
        MangaDownloadItem(
            id: UUID(), mangaTitle: "M", mangaHref: "h", coverImage: "c", moduleId: "mod",
            chapterHref: "ch", chapterNumber: 1, chapterName: "Chapter 1",
            pageFiles: pageFiles, totalPages: pageFiles.count,
            state: state, progress: state == .completed ? 1 : 0, error: nil,
            createdAt: Date(), completedAt: nil)
    }

    func testReconcileMarksInterruptedItemsFailed() {
        let items = [makeItem(state: .pending), makeItem(state: .downloading)]
        let out = MangaDownloadPlanning.reconcileLoaded(items) { _ in true }
        XCTAssertTrue(out.allSatisfy { $0.state == .failed })
        XCTAssertTrue(out.allSatisfy { ($0.error ?? "").contains("interrupted") })
    }

    func testReconcileMarksCompletedWithMissingFilesFailed() {
        let items = [makeItem(state: .completed)]
        let out = MangaDownloadPlanning.reconcileLoaded(items) { _ in false }
        XCTAssertEqual(out[0].state, .failed)
        XCTAssertTrue(out[0].pageFiles.isEmpty)
        XCTAssertEqual(out[0].progress, 0)
    }

    func testReconcileKeepsCompletedWithPresentFiles() {
        let items = [makeItem(state: .completed)]
        let out = MangaDownloadPlanning.reconcileLoaded(items) { _ in true }
        XCTAssertEqual(out[0].state, .completed)
    }

    // MARK: - pendingDownloadCount

    func testPendingDownloadCountExcludesAlreadyDownloaded() {
        let count = MangaDownloadPlanning.pendingDownloadCount(
            selectedHrefs: ["a", "b", "c"], completedHrefs: ["b"])
        XCTAssertEqual(count, 2)
    }
}
