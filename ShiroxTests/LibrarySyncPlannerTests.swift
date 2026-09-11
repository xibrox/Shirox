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
        score: Double = 0,
        timesRewatched: Int? = nil
    ) -> LibraryEntry {
        LibraryEntry(
            id: id,
            media: Media(
                id: id, idMal: id, provider: .anilist,
                title: MediaTitle(romaji: "Title \(id)", english: "Title \(id)", native: nil),
                coverImage: MediaCoverImage(large: nil, extraLarge: nil),
                bannerImage: nil, description: nil, episodes: nil, status: nil,
                averageScore: nil, genres: nil, season: nil, seasonYear: nil,
                nextAiringEpisode: nil, relations: nil, type: nil, format: nil
            ),
            status: status,
            progress: progress,
            score: score,
            timesRewatched: timesRewatched
        )
    }

    // MARK: - Creating

    func testMissingOnTargetIsCreated() {
        let decision = LibrarySyncPlanner.decide(
            source: entry(status: .completed, progress: 12, score: 8), target: nil)
        XCTAssertEqual(decision, .create(status: .completed, progress: 12, score: 8, timesRewatched: nil))
    }

    func testCreateCarriesTheRewatchCountAcross() {
        let decision = LibrarySyncPlanner.decide(
            source: entry(status: .completed, progress: 12, score: 8, timesRewatched: 3), target: nil)
        XCTAssertEqual(decision, .create(status: .completed, progress: 12, score: 8, timesRewatched: 3))
    }

    // MARK: - Advancing

    func testTargetBehindIsAdvanced() {
        let decision = LibrarySyncPlanner.decide(
            source: entry(progress: 10), target: entry(progress: 4))
        XCTAssertEqual(decision, .advance(status: .current, progress: 10, score: 0, timesRewatched: nil))
    }

    /// An unrated source must not wipe a score the destination already has.
    func testAdvancingKeepsTargetScoreWhenSourceIsUnrated() {
        let decision = LibrarySyncPlanner.decide(
            source: entry(progress: 10, score: 0), target: entry(progress: 4, score: 9))
        XCTAssertEqual(decision, .advance(status: .current, progress: 10, score: 9, timesRewatched: nil))
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

    // MARK: - Rewatch cycles
    //
    // Raw episode counts are meaningless across different rewatch cycles: episode 4 of a third
    // rewatch is *further along* than episode 12 of a second. Ordering is therefore
    // (viewings finished, progress within the current one).

    /// Completed after 3 rewatches beats a 3rd rewatch sitting on episode 4, even though 4 < 12.
    func testMoreRewatchesBeatsAnEarlierRewatchInProgress() {
        let decision = LibrarySyncPlanner.decide(
            source: entry(status: .completed, progress: 12, timesRewatched: 3),
            target: entry(status: .repeating, progress: 4, timesRewatched: 2))
        XCTAssertEqual(decision, .advance(status: .completed, progress: 12, score: 0, timesRewatched: 3))
    }

    /// The mirror image: the same rewatch count means the one mid-rewatch is the live state,
    /// so it wins despite the lower episode number.
    func testRewatchInProgressBeatsACompletionOnTheSameCycle() {
        let decision = LibrarySyncPlanner.decide(
            source: entry(status: .repeating, progress: 4, timesRewatched: 2),
            target: entry(status: .completed, progress: 12, timesRewatched: 2))
        XCTAssertEqual(decision, .advance(status: .repeating, progress: 4, score: 0, timesRewatched: 2))
    }

    /// ...and run the other way round it must refuse, or it would erase the rewatch.
    func testAStaleCompletionNeverErasesARewatchInProgress() {
        let decision = LibrarySyncPlanner.decide(
            source: entry(status: .completed, progress: 12, timesRewatched: 2),
            target: entry(status: .repeating, progress: 4, timesRewatched: 2))
        XCTAssertEqual(decision, .skipWouldRegress(sourceProgress: 12, targetProgress: 4))
    }

    /// A first rewatch carries no repeat count yet, but starting one still counts as having
    /// finished the series once.
    func testAFirstRewatchOutranksTheOriginalCompletion() {
        let decision = LibrarySyncPlanner.decide(
            source: entry(status: .repeating, progress: 3, timesRewatched: 0),
            target: entry(status: .completed, progress: 12, timesRewatched: 0))
        XCTAssertEqual(decision, .advance(status: .repeating, progress: 3, score: 0, timesRewatched: 0))
    }

    /// MyAnimeList has no "rewatching" status — it reports a rewatch as `watching`. The repeat
    /// count is what gives it away, so ordering must key off that rather than the status.
    func testAMyAnimeListRewatchIsRecognisedFromItsRepeatCount() {
        let decision = LibrarySyncPlanner.decide(
            source: entry(status: .current, progress: 4, timesRewatched: 2),
            target: entry(status: .current, progress: 8, timesRewatched: 0))
        XCTAssertEqual(decision, .advance(status: .current, progress: 4, score: 0, timesRewatched: 2))
    }

    /// Finishing a rewatch must not write `completed` alongside a progress of 0.
    func testCompletingAJustStartedRewatchKeepsTheFullEpisodeCount() {
        let decision = LibrarySyncPlanner.decide(
            source: entry(status: .completed, progress: 12, timesRewatched: 1),
            target: entry(status: .repeating, progress: 0, timesRewatched: 1))
        XCTAssertEqual(decision, .advance(status: .completed, progress: 12, score: 0, timesRewatched: 1))
    }

    // MARK: - Status ranking at equal progress

    /// Dropping something is a deliberate act; "watching" is mostly just the residue of progress
    /// tracking. At equal progress the deliberate statement wins, so the two accounts converge.
    func testDroppedOutranksWatchingAtEqualProgress() {
        let decision = LibrarySyncPlanner.decide(
            source: entry(status: .dropped, progress: 6),
            target: entry(status: .current, progress: 6))
        XCTAssertEqual(decision, .advance(status: .dropped, progress: 6, score: 0, timesRewatched: nil))
    }

    func testWatchingDoesNotUndoADropAtEqualProgress() {
        let decision = LibrarySyncPlanner.decide(
            source: entry(status: .current, progress: 6),
            target: entry(status: .dropped, progress: 6))
        XCTAssertEqual(decision, .skipUpToDate)
    }

    /// Watching more episodes *is* evidence you picked it back up, so progress still wins.
    func testWatchingFurtherAheadRevivesADroppedEntry() {
        let decision = LibrarySyncPlanner.decide(
            source: entry(status: .current, progress: 9),
            target: entry(status: .dropped, progress: 6))
        XCTAssertEqual(decision, .advance(status: .current, progress: 9, score: 0, timesRewatched: nil))
    }

    /// Paused and dropped are equally deliberate, so there is no honest way to pick between
    /// them. The accounts are left disagreeing, and the run says so rather than claiming
    /// everything matched.
    func testPausedVersusDroppedIsReportedRatherThanGuessed() {
        let decision = LibrarySyncPlanner.decide(
            source: entry(status: .dropped, progress: 6),
            target: entry(status: .paused, progress: 6))
        XCTAssertEqual(decision, .skipLeftDiffering(source: .dropped, target: .paused))
    }

    /// `repeating` vs `current` is an artefact of MyAnimeList's data model, not a real
    /// disagreement — reporting it every run would be pure noise.
    func testRewatchingVersusWatchingIsNotReportedAsADisagreement() {
        let decision = LibrarySyncPlanner.decide(
            source: entry(status: .repeating, progress: 6, timesRewatched: 1),
            target: entry(status: .current, progress: 6, timesRewatched: 1))
        XCTAssertEqual(decision, .skipUpToDate)
    }

    // MARK: - Filling in gaps at equal progress

    /// "Planning" on the destination is the one status worth replacing: the source shows the
    /// title was actually watched.
    func testPlanningIsUpgradedByARealStatus() {
        let decision = LibrarySyncPlanner.decide(
            source: entry(status: .completed, progress: 0),
            target: entry(status: .planning, progress: 0))
        XCTAssertEqual(decision, .advance(status: .completed, progress: 0, score: 0, timesRewatched: nil))
    }

    func testScoreIsCarriedOverWhenTargetHasNone() {
        let decision = LibrarySyncPlanner.decide(
            source: entry(status: .completed, progress: 12, score: 9),
            target: entry(status: .completed, progress: 12, score: 0))
        XCTAssertEqual(decision, .advance(status: .completed, progress: 12, score: 9, timesRewatched: nil))
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
        let source = entry(status: .completed, progress: 12, score: 8, timesRewatched: 2)
        guard case .create(let status, let progress, let score, let rewatched) =
                LibrarySyncPlanner.decide(source: source, target: nil) else {
            return XCTFail("first pass should create")
        }
        let written = entry(status: status, progress: progress, score: score, timesRewatched: rewatched)
        XCTAssertEqual(LibrarySyncPlanner.decide(source: source, target: written), .skipUpToDate)
    }

    /// A two-way merge settles in one pass: after applying it, running it again writes nothing
    /// in either direction.
    func testATwoWayMergeConvergesInOnePass() {
        // Each side knows something the other doesn't: AniList has the status, MAL the score.
        let anilist = entry(status: .completed, progress: 12, score: 0)
        let mal = entry(status: .current, progress: 12, score: 8)

        guard case .advance(let s1, let p1, let sc1, let r1) =
                LibrarySyncPlanner.decide(source: anilist, target: mal) else {
            return XCTFail("AniList's completed status should reach MAL")
        }
        guard case .advance(let s2, let p2, let sc2, let r2) =
                LibrarySyncPlanner.decide(source: mal, target: anilist) else {
            return XCTFail("MAL's score should reach AniList")
        }
        let mergedMAL = entry(status: s1, progress: p1, score: sc1, timesRewatched: r1)
        let mergedAniList = entry(status: s2, progress: p2, score: sc2, timesRewatched: r2)

        XCTAssertEqual(mergedAniList.status, mergedMAL.status)
        XCTAssertEqual(mergedAniList.progress, mergedMAL.progress)
        XCTAssertEqual(mergedAniList.score, mergedMAL.score)
        XCTAssertEqual(LibrarySyncPlanner.decide(source: mergedAniList, target: mergedMAL), .skipUpToDate)
        XCTAssertEqual(LibrarySyncPlanner.decide(source: mergedMAL, target: mergedAniList), .skipUpToDate)
    }

    // MARK: - Pairing the two libraries

    func testPairingMatchesTitlesPresentOnBothServices() {
        let pairing = LibrarySyncPlanner.pair(
            anilist: [entry(id: 100, progress: 5)],
            mal: [entry(id: 900, progress: 2)],
            malIdForAniListId: [100: 900],
            anilistIdForMALId: [900: 100])

        XCTAssertEqual(pairing.pairs.count, 1)
        XCTAssertEqual(pairing.pairs.first?.anilistId, 100)
        XCTAssertEqual(pairing.pairs.first?.malId, 900)
        XCTAssertEqual(pairing.pairs.first?.anilist?.progress, 5)
        XCTAssertEqual(pairing.pairs.first?.mal?.progress, 2)
        XCTAssertTrue(pairing.unmatched.isEmpty)
    }

    /// The union, not just one side: a title only MyAnimeList knows about still has to come back
    /// the other way, which is the whole point of a two-way run.
    func testPairingCoversTitlesOnlyOneServiceHas() {
        let pairing = LibrarySyncPlanner.pair(
            anilist: [entry(id: 100, progress: 5)],
            mal: [entry(id: 901, progress: 7)],
            malIdForAniListId: [100: 900],
            anilistIdForMALId: [901: 101])

        XCTAssertEqual(pairing.pairs.count, 2)
        let anilistOnly = pairing.pairs.first { $0.anilistId == 100 }
        XCTAssertNotNil(anilistOnly?.anilist)
        XCTAssertNil(anilistOnly?.mal)
        let malOnly = pairing.pairs.first { $0.anilistId == 101 }
        XCTAssertNil(malOnly?.anilist)
        XCTAssertNotNil(malOnly?.mal)
    }

    /// A title present on both must not also come back as a MyAnimeList-only entry.
    func testPairingDoesNotClaimTheSameTitleTwice() {
        let pairing = LibrarySyncPlanner.pair(
            anilist: [entry(id: 100, progress: 5)],
            mal: [entry(id: 900, progress: 2)],
            malIdForAniListId: [100: 900],
            anilistIdForMALId: [900: 100])
        XCTAssertEqual(pairing.pairs.count, 1)
    }

    func testPairingReportsTitlesWithNoCounterpartId() {
        let pairing = LibrarySyncPlanner.pair(
            anilist: [entry(id: 100, progress: 5)],
            mal: [entry(id: 900, progress: 2)],
            malIdForAniListId: [:],
            anilistIdForMALId: [:])
        XCTAssertTrue(pairing.pairs.isEmpty)
        XCTAssertEqual(pairing.unmatched.sorted(), ["Title 100", "Title 900"])
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

    /// Entries the merge deliberately refused to guess at are surfaced, not silently counted
    /// as up to date.
    func testSummarySentenceReportsEntriesLeftDiffering() {
        var s = LibrarySyncSummary()
        s.leftDiffering = 2
        XCTAssertEqual(s.sentence, "2 left differing")
    }
}
