import XCTest
@testable import Shirox

/// Tests for the season-before-now math behind the "Last Season · Complete" home row.
///
/// The row exists because a cour that has finished airing is the one people want to binge,
/// and "This Season" stops listing it the moment the next cour starts. Getting the rollback
/// wrong would quietly show the wrong three months of anime, so the boundaries are pinned.
final class AniListSeasonTests: XCTestCase {

    private func date(month: Int, year: Int = 2026) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: 15))!
    }

    func testWinterRollsBackToPreviousYearsFall() {
        let (season, year) = AniListSeason.previous(from: date(month: 2))
        XCTAssertEqual(season, .fall)
        XCTAssertEqual(year, 2025, "January–March must look back into last calendar year")
    }

    func testSpringLooksBackToWinter() {
        let (season, year) = AniListSeason.previous(from: date(month: 5))
        XCTAssertEqual(season, .winter)
        XCTAssertEqual(year, 2026)
    }

    func testSummerLooksBackToSpring() {
        let (season, year) = AniListSeason.previous(from: date(month: 8))
        XCTAssertEqual(season, .spring)
        XCTAssertEqual(year, 2026)
    }

    func testFallLooksBackToSummer() {
        let (season, year) = AniListSeason.previous(from: date(month: 11))
        XCTAssertEqual(season, .summer)
        XCTAssertEqual(year, 2026)
    }

    /// Every month resolves to the season immediately before the one `current()` reports.
    func testPreviousIsNeverTheCurrentSeason() {
        for month in 1...12 {
            let ref = date(month: month)
            let prev = AniListSeason.previous(from: ref)
            let cal = Calendar.current
            let curSeason: AniListSeason
            switch cal.component(.month, from: ref) {
            case 1...3: curSeason = .winter
            case 4...6: curSeason = .spring
            case 7...9: curSeason = .summer
            default:    curSeason = .fall
            }
            XCTAssertNotEqual(prev.0, curSeason, "month \(month) returned the current season")
        }
    }
}
