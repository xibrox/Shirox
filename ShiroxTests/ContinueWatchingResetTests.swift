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

    // MARK: - Tracker syncs after a reset

    /// AniList's sync marks 1…progress watched for a show on the Watching list; a reset show
    /// mustn't come straight back on the next one, nor its Continue Watching card.
    func testAResetShowStaysResetThroughTheSync() {
        let plan = TrackerResetFloor.plan(progress: 5, floor: TrackerResetFloor.adding(nil, to: nil))
        XCTAssertEqual(plan.seed, [])
        XCTAssertTrue(plan.holdCard)
        XCTAssertEqual(plan.floor, TrackerResetFloor(baseline: 5, episodes: nil))
        // The next sync, the list unchanged: still held.
        let again = TrackerResetFloor.plan(progress: 5, floor: plan.floor)
        XCTAssertEqual(again.seed, [])
        XCTAssertEqual(again.floor, plan.floor)
    }

    func testOnlyTheResetEpisodesAreHeldBack() {
        let plan = TrackerResetFloor.plan(progress: 4, floor: TrackerResetFloor(baseline: nil, episodes: [2, 3]))
        XCTAssertEqual(plan.seed, [1, 4])
        XCTAssertFalse(plan.holdCard)
    }

    /// Watched further since — on another device, or marked here — the list is believed again.
    func testProgressPastTheResetLiftsIt() {
        let plan = TrackerResetFloor.plan(progress: 6, floor: TrackerResetFloor(baseline: 5, episodes: nil))
        XCTAssertEqual(plan.seed, [1, 2, 3, 4, 5, 6])
        XCTAssertNil(plan.floor)
        XCTAssertFalse(plan.holdCard)
    }

    func testNoResetSeedsAsBefore() {
        XCTAssertEqual(TrackerResetFloor.plan(progress: 3, floor: nil).seed, [1, 2, 3])
        XCTAssertEqual(TrackerResetFloor.plan(progress: 0, floor: nil).seed, [])
    }

    func testEpisodeResetsAddUpAndAShowResetHoldsItAll() {
        let episode = TrackerResetFloor.adding([2], to: nil)
        XCTAssertEqual(episode.episodes, [2], "one episode, not the whole show")
        XCTAssertEqual(TrackerResetFloor.adding([3], to: episode).episodes, [2, 3])
        XCTAssertNil(TrackerResetFloor.adding(nil, to: episode).episodes)
        XCTAssertNil(TrackerResetFloor.adding([4], to: TrackerResetFloor.adding(nil, to: nil)).episodes)
        // A baseline already taken is kept.
        XCTAssertEqual(TrackerResetFloor.adding([1], to: TrackerResetFloor(baseline: 7, episodes: [2])).baseline, 7)
    }
}
