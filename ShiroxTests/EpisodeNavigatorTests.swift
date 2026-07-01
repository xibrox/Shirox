import XCTest
@testable import Shirox

/// Tests for next-episode navigation over a flat, multi-season episode list.
///
/// The reported bug: a module returns one list for the whole franchise — season 1's
/// episodes 1–12 followed by season 2's episodes 1–4 — so the numbers read
/// 1,2,…,12,1,2,3,4. Playing S2 E1 and pressing "next episode" played S2's *successor by
/// number* — but resolving by number alone always finds season 1's occurrence, so it
/// jumped to S1 E2 instead of S2 E2. The fix anchors on list position, not number.
final class EpisodeNavigatorTests: XCTestCase {

    /// S1 1–12 then S2 1–4. hrefs are unique per episode even though numbers repeat.
    private func twoSeasonChain() -> [EpisodeLink] {
        let s1 = (1...12).map { EpisodeLink(number: Double($0), href: "s1/ep\($0)") }
        let s2 = (1...4).map { EpisodeLink(number: Double($0), href: "s2/ep\($0)") }
        return s1 + s2
    }

    /// THE BUG: next after S2 E1 (index 12, number 1) must be S2 E2 (index 13), not the
    /// first occurrence of number 2 — S1 E2 (index 1).
    func testNextAfterSeasonTwoEpisodeOneStaysInSeasonTwo() {
        let eps = twoSeasonChain()
        let anchor = eps.firstIndex { $0.href == "s2/ep1" }!  // = 12
        let step = EpisodeNavigator.next(currentNumber: 1, anchor: anchor, in: eps)
        XCTAssertEqual(step?.current, 12)
        XCTAssertEqual(step?.episode.href, "s2/ep2", "must be season 2 ep 2, not season 1 ep 2")
        XCTAssertEqual(step?.episode.number, 2)
    }

    /// Chaining forward through season 2: after the first hop the anchor advances, so the
    /// next number-2 lookup still resolves to season 2, never back to season 1.
    func testChainAdvancesThroughSeasonTwoWithoutFallingBack() {
        let eps = twoSeasonChain()
        var anchor = eps.firstIndex { $0.href == "s2/ep1" }!  // 12
        var visited: [String] = []
        // Simulate the player advancing: feed back the number we just landed on.
        var currentNumber = 1
        while let step = EpisodeNavigator.next(currentNumber: currentNumber, anchor: anchor, in: eps) {
            anchor = step.current
            currentNumber = Int(step.episode.number)
            visited.append(step.episode.href)
        }
        XCTAssertEqual(visited, ["s2/ep2", "s2/ep3", "s2/ep4"])
    }

    /// The last episode of season 2 (index 15) has no successor → nil.
    func testLastEpisodeHasNoNext() {
        let eps = twoSeasonChain()
        let anchor = eps.firstIndex { $0.href == "s2/ep4" }!  // 15
        XCTAssertNil(EpisodeNavigator.next(currentNumber: 4, anchor: anchor, in: eps))
    }

    /// Last episode of season 1 (index 11) DOES have a successor: season 2 ep 1.
    func testSeasonOneFinaleAdvancesIntoSeasonTwo() {
        let eps = twoSeasonChain()
        let anchor = eps.firstIndex { $0.href == "s1/ep12" }!  // 11
        let step = EpisodeNavigator.next(currentNumber: 12, anchor: anchor, in: eps)
        XCTAssertEqual(step?.episode.href, "s2/ep1")
        XCTAssertEqual(step?.episode.number, 1)
    }

    /// A simple single-season list still advances by number from the default anchor.
    func testSingleSeasonAdvancesNormally() {
        let eps = (1...5).map { EpisodeLink(number: Double($0), href: "ep\($0)") }
        let step = EpisodeNavigator.next(currentNumber: 3, anchor: 0, in: eps)
        XCTAssertEqual(step?.current, 2)
        XCTAssertEqual(step?.episode.number, 4)
    }

    // MARK: - href-based navigation (AniList / offset-numbered modules)

    /// Next after S2 E1 by href lands on S2 E2, regardless of the repeated number.
    func testNextAfterHrefStaysInSeasonTwo() {
        let eps = twoSeasonChain()
        let step = EpisodeNavigator.next(afterHref: "s2/ep1", in: eps)
        XCTAssertEqual(step?.current, 12)
        XCTAssertEqual(step?.episode.href, "s2/ep2")
        XCTAssertEqual(step?.episode.number, 2)
    }

    /// Offset numbering (module labels S2 as eps 25–28). href anchoring still advances
    /// to the right successor even though no episode is numbered `currentEpNum + 1`.
    func testNextAfterHrefHandlesOffsetNumbering() {
        let eps = (25...28).map { EpisodeLink(number: Double($0), href: "s2/ep\($0)") }
        let step = EpisodeNavigator.next(afterHref: "s2/ep25", in: eps)
        XCTAssertEqual(step?.episode.href, "s2/ep26")
        XCTAssertEqual(step?.episode.number, 26)
    }

    /// Last episode by href has no successor; unknown href returns nil.
    func testNextAfterHrefBoundaries() {
        let eps = twoSeasonChain()
        XCTAssertNil(EpisodeNavigator.next(afterHref: "s2/ep4", in: eps))
        XCTAssertNil(EpisodeNavigator.next(afterHref: "does/not/exist", in: eps))
        XCTAssertNil(EpisodeNavigator.next(afterHref: nil, in: eps))
    }

    // MARK: - href-or-number (resume paths)

    /// With a saved href, the resume helper advances within the right season.
    func testNextAfterHrefOrNumberPrefersHref() {
        let eps = twoSeasonChain()
        let next = EpisodeNavigator.next(afterHref: "s2/ep1", orNumber: 1, in: eps)
        XCTAssertEqual(next?.href, "s2/ep2")
    }

    /// Legacy items (no saved href) fall back to number — the known limitation that the first
    /// hop on a flat list lands in season 1, kept for items saved before hrefs existed.
    func testNextAfterHrefOrNumberFallsBackToNumber() {
        let eps = twoSeasonChain()
        let next = EpisodeNavigator.next(afterHref: nil, orNumber: 1, in: eps)
        XCTAssertEqual(next?.href, "s1/ep2")
    }

    /// Fallback uses nearest-number when there's no exact match (offset numbering).
    func testNextAfterHrefOrNumberNearestNumberFallback() {
        let eps = (25...28).map { EpisodeLink(number: Double($0), href: "ep\($0)") }
        let next = EpisodeNavigator.next(afterHref: nil, orNumber: 1, in: eps)
        XCTAssertEqual(next?.href, "ep26", "nearest to 1 is ep25, so next is ep26")
    }

    // MARK: - resolve (stream refetch / recovery of the current episode)

    /// THE REFETCH BUG: after auto-advancing 7→8, a foreground/stall refetch must re-resolve the
    /// episode *currently on screen*. On a flat two-season list both seasons have an "ep 2", so a
    /// number-only lookup would return season 1's — the href anchor pins season 2.
    func testResolvePrefersHrefOnRepeatedNumbers() {
        let eps = twoSeasonChain()
        let ep = EpisodeNavigator.resolve(href: "s2/ep2", orNumber: 2, in: eps)
        XCTAssertEqual(ep?.href, "s2/ep2", "must refetch the season-2 occurrence, not season 1")
    }

    /// Offset numbering (module labels S2 as eps 25–28): the current number won't match, but the
    /// saved href still identifies the episode to refetch.
    func testResolveHandlesOffsetNumberingViaHref() {
        let eps = (25...28).map { EpisodeLink(number: Double($0), href: "s2/ep\($0)") }
        let ep = EpisodeNavigator.resolve(href: "s2/ep26", orNumber: 2, in: eps)
        XCTAssertEqual(ep?.number, 26)
    }

    /// Legacy items with no saved href fall back to an exact number match.
    func testResolveFallsBackToNumberWithoutHref() {
        let eps = (1...5).map { EpisodeLink(number: Double($0), href: "ep\($0)") }
        XCTAssertEqual(EpisodeNavigator.resolve(href: nil, orNumber: 3, in: eps)?.href, "ep3")
    }

    /// href wins even when a different episode happens to carry the target number.
    func testResolveHrefBeatsNumber() {
        let eps = twoSeasonChain()
        // Ask for href s2/ep3 but number 1 (mismatched on purpose) — href must win.
        XCTAssertEqual(EpisodeNavigator.resolve(href: "s2/ep3", orNumber: 1, in: eps)?.href, "s2/ep3")
    }

    /// Neither an unknown href nor an absent number matches → nil (refetch aborts rather than
    /// resurrecting the wrong episode).
    func testResolveReturnsNilWhenNothingMatches() {
        let eps = twoSeasonChain()
        XCTAssertNil(EpisodeNavigator.resolve(href: "does/not/exist", orNumber: 99, in: eps))
    }
}
