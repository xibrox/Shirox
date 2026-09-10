import XCTest
@testable import Shirox

/// The round-trip assertions here are the ones that catch the stale-singleton bug the
/// BackupSection design exists to prevent: after `apply`, the manager's *published*
/// state — not just UserDefaults — has to hold the restored values.
@MainActor
final class BackupProgressSectionTests: XCTestCase {

    private let touchedKeys = ["continueWatchingItems", "watchedEpisodeKeys",
                               "watchedEpisodeHrefKeys", "cwDataVersion",
                               "continueReadingItems", "readMangaChapters", "watchHistory"]
    private var savedDefaults: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        for key in touchedKeys {
            if let value = UserDefaults.standard.object(forKey: key) { savedDefaults[key] = value }
        }
    }

    override func tearDown() {
        for key in touchedKeys {
            if let value = savedDefaults[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        savedDefaults = [:]
        super.tearDown()
    }

    private func makeReadingItem(href: String) -> MangaReadingItem {
        MangaReadingItem(mangaTitle: "Test Manga \(href)",
                         mangaHref: href,
                         coverImage: "",
                         moduleId: "mod-1",
                         chapterHref: "\(href)/c1",
                         chapterName: "Chapter 1",
                         chapterNumber: 1,
                         pageIndex: 3,
                         totalPages: 20,
                         lastReadAt: Date(timeIntervalSince1970: 1_757_500_000))
    }

    private func makeWatchProgress(id: Int) -> WatchProgress {
        WatchProgress(mediaId: id,
                      title: "Show \(id)",
                      coverImage: nil,
                      lastEpisode: 4,
                      totalEpisodes: 12,
                      watchedAt: Date(timeIntervalSince1970: 1_757_500_000))
    }

    func testProgressRoundTripsBackIntoPublishedState() async throws {
        let manga = MangaProgressManager.shared
        let history = WatchHistoryService.shared
        let cw = ContinueWatchingManager.shared

        // Seed
        manga.restore(items: [makeReadingItem(href: "/manga/a")],
                      readChapters: ["/manga/a": ["/manga/a/c1"]])
        history.restore(history: [makeWatchProgress(id: 101)])
        cw.restore(items: [], watchedKeys: ["ah:1:2"], watchedHrefKeys: ["ah:1:/ep/2"])

        // Export
        let section = ProgressBackupSection()
        let payload = try XCTUnwrap(section.export())

        // Mutate away from the seed
        manga.restore(items: [], readChapters: [:])
        history.restore(history: [])
        cw.restore(items: [], watchedKeys: [], watchedHrefKeys: [])
        XCTAssertTrue(manga.items.isEmpty)

        // Apply
        let warnings = try await section.apply(payload)
        XCTAssertTrue(warnings.isEmpty)

        // Published state is back
        XCTAssertEqual(manga.items.map(\.mangaHref), ["/manga/a"])
        XCTAssertEqual(manga.readChapters["/manga/a"], ["/manga/a/c1"])
        XCTAssertEqual(history.history.map(\.mediaId), [101])
        XCTAssertEqual(cw.watchedKeys, ["ah:1:2"])
        XCTAssertEqual(cw.watchedHrefKeys, ["ah:1:/ep/2"])
    }

    func testApplyAlsoWritesStorageNotJustMemory() async throws {
        let section = ProgressBackupSection()
        MangaProgressManager.shared.restore(items: [makeReadingItem(href: "/manga/b")],
                                            readChapters: [:])
        let payload = try XCTUnwrap(section.export())
        MangaProgressManager.shared.restore(items: [], readChapters: [:])

        _ = try await section.apply(payload)

        let data = try XCTUnwrap(UserDefaults.standard.data(forKey: "continueReadingItems"))
        let stored = try JSONDecoder().decode([MangaReadingItem].self, from: data)
        XCTAssertEqual(stored.map(\.mangaHref), ["/manga/b"])
    }

    func testRestoreStampsTheCurrentDataVersionSoLoadDoesNotWipeIt() async throws {
        UserDefaults.standard.set(0, forKey: "cwDataVersion")
        ContinueWatchingManager.shared.restore(items: [],
                                                watchedKeys: ["ah:9:1"],
                                                watchedHrefKeys: [])
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "cwDataVersion"),
                       ContinueWatchingManager.currentDataVersion)
    }

    func testIncompatibleDataVersionIsRejectedRatherThanImportedBlind() async throws {
        let section = ProgressBackupSection()
        var payload = try XCTUnwrap(section.export())
        payload.dataVersion = ContinueWatchingManager.currentDataVersion + 1

        do {
            _ = try await section.apply(payload)
            XCTFail("Expected incompatibleDataVersion")
        } catch {
            XCTAssertEqual(error as? BackupSectionError,
                           .incompatibleDataVersion(
                                found: ContinueWatchingManager.currentDataVersion + 1,
                                expected: ContinueWatchingManager.currentDataVersion))
        }
    }

    func testExportRecordsTheCurrentDataVersion() throws {
        let payload = try XCTUnwrap(ProgressBackupSection().export())
        XCTAssertEqual(payload.dataVersion, ContinueWatchingManager.currentDataVersion)
    }

    func testSectionIdIsProgress() {
        XCTAssertEqual(ProgressBackupSection.id, BackupSectionID.progress)
    }
}
