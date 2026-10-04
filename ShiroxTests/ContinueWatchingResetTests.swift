import XCTest
@testable import Shirox

/// Reset Progress has to clear a title however its progress was saved. A download keeps its
/// AniList id, a stream from a module page may not, and the rows read progress saved under
/// either — so resetting under only one left the other showing.
@MainActor
final class ContinueWatchingResetTests: XCTestCase {

    private let touchedKeys = ["continueWatchingItems", "watchedEpisodeKeys",
                               "watchedEpisodeHrefKeys", "cwDataVersion"]
    private var savedDefaults: [String: Any] = [:]
    private var cw: ContinueWatchingManager { .shared }

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

    private func item(_ episode: Int, aniListID: Int?) -> ContinueWatchingItem {
        ContinueWatchingItem(
            id: UUID(), mediaTitle: "Link Click", episodeNumber: episode,
            episodeTitle: nil, imageUrl: "", streamUrl: "http://127.0.0.1:8765/x/\(episode)",
            headers: nil, subtitle: nil, streamTitle: nil,
            aniListID: aniListID, malID: nil, moduleId: "mod", detailHref: nil,
            episodeHref: "/ep/\(episode)",
            watchedSeconds: 100, totalSeconds: 1000, totalEpisodes: nil,
            availableEpisodes: nil, isAiring: nil, lastWatchedAt: .now, thumbnailUrl: nil)
    }

    func testEpisodeResetClearsProgressSavedWithoutTheAniListID() {
        cw.restore(items: [item(3, aniListID: nil)], watchedKeys: [], watchedHrefKeys: [])
        cw.resetEpisodeProgress(aniListID: 42, moduleId: "mod", mediaTitle: "Link Click", episodeNumber: 3)
        XCTAssertTrue(cw.items.isEmpty)
    }

    func testEpisodeResetClearsBothWatchedMarks() {
        cw.restore(items: [], watchedKeys: ["a:42:3", "m:mod:link click:3"],
                   watchedHrefKeys: ["ah:42:/ep/3", "mh:mod:link click:/ep/3"])
        cw.resetEpisodeProgress(aniListID: 42, moduleId: "mod", mediaTitle: "Link Click",
                                episodeNumber: 3, episodeHref: "/ep/3")
        XCTAssertFalse(cw.isWatched(aniListID: nil, moduleId: "mod", mediaTitle: "Link Click", episodeNumber: 3))
        XCTAssertFalse(cw.isWatched(aniListID: 42, moduleId: nil, mediaTitle: "Link Click", episodeNumber: 3))
        XCTAssertTrue(cw.watchedHrefKeys.isEmpty)
    }

    /// Module watched marks are stored with the title lowercased; the show reset looked for it
    /// as written, so it never matched a title with capitals.
    func testShowResetClearsAModuleTitlesMarks() {
        cw.restore(items: [item(1, aniListID: nil)], watchedKeys: ["m:mod:link click:1", "m:mod:link click:2"],
                   watchedHrefKeys: ["mh:mod:link click:/ep/1"])
        XCTAssertTrue(cw.hasProgress(aniListID: nil, moduleId: "mod", mediaTitle: "Link Click"))
        cw.resetProgress(aniListID: nil, moduleId: "mod", mediaTitle: "Link Click")
        XCTAssertTrue(cw.watchedKeys.isEmpty)
        XCTAssertTrue(cw.watchedHrefKeys.isEmpty)
        XCTAssertTrue(cw.items.isEmpty)
    }

    func testShowResetClearsEveryIdentity() {
        cw.restore(items: [item(1, aniListID: 42), item(2, aniListID: nil)],
                   watchedKeys: ["a:42:1", "m:mod:link click:2", "a:7:1"], watchedHrefKeys: [])
        cw.resetProgress(aniListID: 42, moduleId: "mod", mediaTitle: "Link Click")
        XCTAssertTrue(cw.items.isEmpty)
        XCTAssertEqual(cw.watchedKeys, ["a:7:1"], "another show's marks stay")
    }
}
