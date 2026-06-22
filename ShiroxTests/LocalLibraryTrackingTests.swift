import XCTest
@testable import Shirox

/// Unit tests for the local-library auto-track decision logic and synthetic `.local`
/// identity — the parts of "local library holds everything" that are pure and isolatable
/// from the disk-backed `LocalLibraryManager` singleton.
final class LocalLibraryTrackingTests: XCTestCase {

    // MARK: - mergedTracking: completion (the Gosick bug)

    /// Finishing the final episode of a finished show marks it Completed at N/N — the bug
    /// where the local entry stayed "Watching 22/24" after the show was completed.
    func testFinalEpisodeOfFinishedShowCompletes() {
        let result = LocalLibraryManager.mergedTracking(
            existingProgress: 22, existingStatus: .current,
            watchedEpisode: 24, totalEpisodes: 24, isAiring: false)
        XCTAssertEqual(result.progress, 24)
        XCTAssertEqual(result.status, .completed)
    }

    /// A mid-show episode keeps it Watching with progress raised to the watched episode.
    func testMidShowStaysWatching() {
        let result = LocalLibraryManager.mergedTracking(
            existingProgress: 5, existingStatus: .current,
            watchedEpisode: 12, totalEpisodes: 24, isAiring: false)
        XCTAssertEqual(result.progress, 12)
        XCTAssertEqual(result.status, .current)
    }

    /// An airing show is never auto-completed even when the watched episode reaches the
    /// currently-aired count (more episodes are still coming).
    func testAiringShowNeverCompletes() {
        let result = LocalLibraryManager.mergedTracking(
            existingProgress: 11, existingStatus: .current,
            watchedEpisode: 12, totalEpisodes: 12, isAiring: true)
        XCTAssertEqual(result.progress, 12)
        XCTAssertEqual(result.status, .current)
    }

    /// Unknown total episodes can never complete (we don't know the final episode).
    func testUnknownTotalNeverCompletes() {
        let result = LocalLibraryManager.mergedTracking(
            existingProgress: 3, existingStatus: .current,
            watchedEpisode: 4, totalEpisodes: nil, isAiring: false)
        XCTAssertEqual(result.status, .current)
    }

    // MARK: - mergedTracking: status transitions

    /// Watching the first episode promotes a Planning entry to Watching.
    func testPlanningPromotesToWatching() {
        let result = LocalLibraryManager.mergedTracking(
            existingProgress: 0, existingStatus: .planning,
            watchedEpisode: 1, totalEpisodes: 12, isAiring: false)
        XCTAssertEqual(result.progress, 1)
        XCTAssertEqual(result.status, .current)
    }

    /// An already-Completed entry is never demoted by a later (e.g. rewatch) event.
    func testCompletedIsNeverDemoted() {
        let result = LocalLibraryManager.mergedTracking(
            existingProgress: 24, existingStatus: .completed,
            watchedEpisode: 1, totalEpisodes: 24, isAiring: false)
        XCTAssertEqual(result.status, .completed)
    }

    /// A manually-chosen status (Paused/Dropped) is preserved by auto-track.
    func testManualStatusPreserved() {
        let paused = LocalLibraryManager.mergedTracking(
            existingProgress: 3, existingStatus: .paused,
            watchedEpisode: 4, totalEpisodes: 24, isAiring: false)
        XCTAssertEqual(paused.status, .paused)
        XCTAssertEqual(paused.progress, 4)
    }

    /// Progress is monotonic — a lower watched episode never lowers stored progress.
    func testProgressNeverDecreases() {
        let result = LocalLibraryManager.mergedTracking(
            existingProgress: 10, existingStatus: .current,
            watchedEpisode: 4, totalEpisodes: 24, isAiring: false)
        XCTAssertEqual(result.progress, 10)
    }

    /// A brand-new entry (nil existing) starts Watching, or Completed if it's the finale.
    func testNewEntryStartsWatchingOrCompleted() {
        let watching = LocalLibraryManager.mergedTracking(
            existingProgress: nil, existingStatus: nil,
            watchedEpisode: 1, totalEpisodes: 12, isAiring: false)
        XCTAssertEqual(watching.progress, 1)
        XCTAssertEqual(watching.status, .current)

        let completed = LocalLibraryManager.mergedTracking(
            existingProgress: nil, existingStatus: nil,
            watchedEpisode: 12, totalEpisodes: 12, isAiring: false)
        XCTAssertEqual(completed.status, .completed)
    }

    // MARK: - Synthetic .local identity

    /// The same module source key always produces the same id (stable across launches).
    func testLocalIdIsDeterministic() {
        let key = "module-x|/anime/foo"
        XCTAssertEqual(Media.localId(forKey: key), Media.localId(forKey: key))
    }

    /// Different source keys produce different ids.
    func testLocalIdDiffersByKey() {
        XCTAssertNotEqual(Media.localId(forKey: "a|/one"), Media.localId(forKey: "b|/two"))
    }

    /// Ids are always positive (the uniqueId / Identifiable must be stable and well-formed).
    func testLocalIdIsPositive() {
        for key in ["", "module|/href", "a very long key with spaces", "🎬|/x"] {
            XCTAssertGreaterThanOrEqual(Media.localId(forKey: key), 0)
        }
    }

    /// A `.local` module Media is keyed on moduleId + href and uniqueId is "local-<id>".
    func testLocalMediaUniqueId() {
        let source = LocalSource(kind: .module, moduleId: "mod1",
                                 detailHref: "/anime/123", localImportName: nil)
        let media = Media.local(source: source, title: "Foo", imageUrl: nil, episodes: 12)
        XCTAssertEqual(media.provider, .local)
        XCTAssertTrue(media.uniqueId.hasPrefix("local-"))
        // Same source → same identity.
        let media2 = Media.local(source: source, title: "Foo (renamed)", imageUrl: "x", episodes: 24)
        XCTAssertEqual(media.uniqueId, media2.uniqueId)
    }

    /// A local-file Media is keyed on its import filename.
    func testLocalFileMediaKeyedByImportName() {
        let a = Media.local(source: LocalSource(kind: .localFile, moduleId: nil, detailHref: nil,
                                                localImportName: "movie.mkv"),
                            title: "Movie", imageUrl: nil, episodes: nil)
        let b = Media.local(source: LocalSource(kind: .localFile, moduleId: nil, detailHref: nil,
                                                localImportName: "other.mkv"),
                            title: "Movie", imageUrl: nil, episodes: nil)
        XCTAssertNotEqual(a.uniqueId, b.uniqueId)
    }
}
