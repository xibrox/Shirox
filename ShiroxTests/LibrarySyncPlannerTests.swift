import XCTest
@testable import Shirox

/// Tests for the AniList ↔ MyAnimeList library sync decisions.
///
/// These writes land on somebody's real tracking account, where an overwrite destroys watch
/// history the app can't get back. The planner's whole contract is that it only ever moves an
/// entry *forward* — so the cases that matter most here are the ones where it must refuse.
final class LibrarySyncPlannerTests: XCTestCase {

    private func entry(
        id: Int = 1,
        status: MediaListStatus = .current,
        progress: Int,
        score: Double = 0
    ) -> LibraryEntry {
        LibraryEntry(
            id: id,
            media: Media(
                id: id, idMal: id, provider: .anilist,
                title: MediaTitle(romaji: "Title", english: "Title", native: nil),
                coverImage: MediaCoverImage(large: nil, extraLarge: nil),
                bannerImage: nil, description: nil, episodes: nil, status: nil,
                averageScore: nil, genres: nil, season: nil, seasonYear: nil,
                nextAiringEpisode: nil, relations: nil, type: nil, format: nil
            ),
            status: status,
            progress: progress,
            score: score
        )
    }

    // MARK: - Creating

    func testMissingOnTargetIsCreated() {
        let decision = LibrarySyncPlanner.decide(
            source: entry(status: .completed, progress: 12, score: 8), target: nil)
        XCTAssertEqual(decision, .create(status: .completed, progress: 12, score: 8))
    }

    // MARK: - Advancing

    func testTargetBehindIsAdvanced() {
        let decision = LibrarySyncPlanner.decide(
            source: entry(progress: 10), target: entry(progress: 4))
        XCTAssertEqual(decision, .advance(status: .current, progress: 10, score: 0))
    }

    /// An unrated source must not wipe a score the destination already has.
    func testAdvancingKeepsTargetScoreWhenSourceIsUnrated() {
        let decision = LibrarySyncPlanner.decide(
            source: entry(progress: 10, score: 0), target: entry(progress: 4, score: 9))
        XCTAssertEqual(decision, .advance(status: .current, progress: 10, score: 9))
    }

    // MARK: - Refusing (the cases that protect the account)

    /// THE ONE THAT MATTERS: syncing the wrong way round must not roll a library back.
    func testTargetAheadIsNeverOverwritten() {
        let decision = LibrarySyncPlanner.decide(
            source: entry(progress: 3), target: entry(progress: 24))
        XCTAssertEqual(decision, .skipWouldRegress(sourceProgress: 3, targetProgress: 24))
    }

    /// A completed entry on the destination is not demoted by a half-watched source.
    func testCompletedTargetSurvivesAPartialSource() {
        let decision = LibrarySyncPlanner.decide(
            source: entry(status: .current, progress: 5),
            target: entry(status: .completed, progress: 12))
        XCTAssertEqual(decision, .skipWouldRegress(sourceProgress: 5, targetProgress: 12))
    }

    func testIdenticalEntriesAreLeftAlone() {
        let decision = LibrarySyncPlanner.decide(
            source: entry(status: .current, progress: 7, score: 8),
            target: entry(status: .current, progress: 7, score: 8))
        XCTAssertEqual(decision, .skipUpToDate)
    }

    /// Dropped and paused say something about intent, not progress — neither overwrites
    /// the other when progress already matches.
    func testSidewaysStatusChangeIsNotAWrite() {
        let decision = LibrarySyncPlanner.decide(
            source: entry(status: .dropped, progress: 6),
            target: entry(status: .paused, progress: 6))
        XCTAssertEqual(decision, .skipUpToDate)
    }

    // MARK: - Filling in gaps at equal progress

    /// "Planning" on the destination is the one status worth replacing: the source shows the
    /// title was actually watched.
    func testPlanningIsUpgradedByARealStatus() {
        let decision = LibrarySyncPlanner.decide(
            source: entry(status: .completed, progress: 0),
            target: entry(status: .planning, progress: 0))
        XCTAssertEqual(decision, .advance(status: .completed, progress: 0, score: 0))
    }

    func testScoreIsCarriedOverWhenTargetHasNone() {
        let decision = LibrarySyncPlanner.decide(
            source: entry(status: .completed, progress: 12, score: 9),
            target: entry(status: .completed, progress: 12, score: 0))
        XCTAssertEqual(decision, .advance(status: .completed, progress: 12, score: 9))
    }

    /// A rating already on the destination is never replaced by a different one.
    func testExistingScoreIsNotOverwritten() {
        let decision = LibrarySyncPlanner.decide(
            source: entry(status: .completed, progress: 12, score: 6),
            target: entry(status: .completed, progress: 12, score: 9))
        XCTAssertEqual(decision, .skipUpToDate)
    }

    // MARK: - Idempotence

    /// Running a sync twice must do nothing the second time.
    func testApplyingTwiceIsANoOp() {
        let source = entry(status: .completed, progress: 12, score: 8)
        guard case .create(let status, let progress, let score) =
                LibrarySyncPlanner.decide(source: source, target: nil) else {
            return XCTFail("first pass should create")
        }
        let written = entry(status: status, progress: progress, score: score)
        XCTAssertEqual(LibrarySyncPlanner.decide(source: source, target: written), .skipUpToDate)
    }

    // MARK: - Summary copy

    func testSummarySentenceReadsCleanWhenNothingChanged() {
        XCTAssertEqual(LibrarySyncSummary().sentence, "Everything was already up to date.")
    }

    func testSummarySentenceListsWhatHappened() {
        var s = LibrarySyncSummary()
        s.created = 3
        s.advanced = 2
        s.keptAhead = 1
        XCTAssertEqual(s.sentence, "3 added, 2 updated, 1 left ahead")
    }
}
