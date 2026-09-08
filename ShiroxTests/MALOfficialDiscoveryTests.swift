import XCTest
@testable import Shirox

/// Tests for discovery through MyAnimeList's own API.
///
/// The app had always split its MyAnimeList access — library through the official API, browsing
/// through Jikan — which was invisible until Jikan went down and took the rankings behind three
/// Home rows with it. These cover the two conversions that would fail quietly: the score scale,
/// and which season a date falls in.
final class MALOfficialDiscoveryTests: XCTestCase {

    private func node(json: String) throws -> MALOfficialDiscoveryService.Node {
        try JSONDecoder().decode(MALOfficialDiscoveryService.Node.self, from: Data(json.utf8))
    }

    // MARK: - Score scale

    /// MyAnimeList scores out of ten; the app and AniList use a hundred. Passing `mean` straight
    /// through would show a 8.58-rated show as 9%.
    func testScoreIsConvertedToTheAppsScale() throws {
        let n = try node(json: #"{"id":16498,"title":"Shingeki no Kyojin","mean":8.58}"#)
        XCTAssertEqual(MALOfficialDiscoveryService.shared.mapToMedia(n).averageScore, 86)
    }

    func testUnratedTitleHasNoScore() throws {
        let n = try node(json: #"{"id":1,"title":"X"}"#)
        XCTAssertNil(MALOfficialDiscoveryService.shared.mapToMedia(n).averageScore)
    }

    // MARK: - Mapping

    func testGenresAndPicturesMapAcross() throws {
        let n = try node(json: #"""
        {"id":16498,"title":"Shingeki no Kyojin",
         "main_picture":{"medium":"https://cdn/small.jpg","large":"https://cdn/large.jpg"},
         "genres":[{"id":1,"name":"Action"},{"id":38,"name":"Military"}],
         "num_episodes":25,"status":"finished_airing"}
        """#)
        let media = MALOfficialDiscoveryService.shared.mapToMedia(n)
        XCTAssertEqual(media.genres, ["Action", "Military"])
        XCTAssertEqual(media.episodes, 25)
        XCTAssertEqual(media.coverImage.large, "https://cdn/small.jpg")
        XCTAssertEqual(media.coverImage.extraLarge, "https://cdn/large.jpg")
        XCTAssertEqual(media.provider, .mal)
        XCTAssertEqual(media.idMal, 16498)
    }

    /// An unaired title reports zero episodes; that's "unknown", not "a show with no episodes",
    /// and a literal 0 drives the same 0/0 progress bug fixed elsewhere.
    func testZeroEpisodesIsTreatedAsUnknown() throws {
        let n = try node(json: #"{"id":1,"title":"X","num_episodes":0}"#)
        XCTAssertNil(MALOfficialDiscoveryService.shared.mapToMedia(n).episodes)
    }

    /// English titles are optional and often empty strings rather than absent.
    func testEmptyEnglishTitleIsNotUsed() throws {
        let n = try node(json: #"{"id":1,"title":"Romaji","alternative_titles":{"en":"","ja":"日本語"}}"#)
        let title = MALOfficialDiscoveryService.shared.mapToMedia(n).title
        XCTAssertNil(title.english)
        XCTAssertEqual(title.romaji, "Romaji")
        XCTAssertEqual(title.native, "日本語")
    }

    // MARK: - Season

    /// The season endpoint is addressed by name, so the boundaries have to be right or the
    /// "This Season" row shows the wrong three months.
    func testSeasonBoundaries() {
        func season(month: Int) -> String {
            let date = Calendar.current.date(from: DateComponents(year: 2026, month: month, day: 15))!
            return MALOfficialDiscoveryService.currentSeason(now: date).season
        }
        XCTAssertEqual(season(month: 1), "winter")
        XCTAssertEqual(season(month: 3), "winter")
        XCTAssertEqual(season(month: 4), "spring")
        XCTAssertEqual(season(month: 6), "spring")
        XCTAssertEqual(season(month: 7), "summer")
        XCTAssertEqual(season(month: 9), "summer")
        XCTAssertEqual(season(month: 10), "fall")
        XCTAssertEqual(season(month: 12), "fall")
    }

    func testSeasonYearMatchesTheDate() {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 2))!
        XCTAssertEqual(MALOfficialDiscoveryService.currentSeason(now: date).year, 2026)
    }
}

/// Tests for turning MyAnimeList's weekly broadcast slot into a real instant.
///
/// MyAnimeList gives a weekday and a time, always in Japan Standard Time — never a timestamp.
/// Resolving that against the wrong zone would put every show hours out for everyone outside
/// Japan, and silently: the times would look plausible, just wrong.
final class MALBroadcastScheduleTests: XCTestCase {

    private func jstCalendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }

    func testResolvesToTheNextMatchingSlotInJST() throws {
        let cal = jstCalendar()
        // A Monday in JST.
        let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 7, hour: 12))!
        let airs = try XCTUnwrap(
            MALOfficialDiscoveryService.nextAiring(dayOfWeek: "wednesday", startTime: "22:00", from: now))

        XCTAssertEqual(cal.component(.weekday, from: airs), 4, "must land on a Wednesday in JST")
        XCTAssertEqual(cal.component(.hour, from: airs), 22)
        XCTAssertEqual(cal.component(.minute, from: airs), 0)
        XCTAssertGreaterThan(airs, now)
    }

    /// The slot for today that has already passed belongs to next week, not to the past.
    func testSlotEarlierTodayRollsToNextWeek() throws {
        let cal = jstCalendar()
        let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 7, hour: 23))!
        let airs = try XCTUnwrap(
            MALOfficialDiscoveryService.nextAiring(dayOfWeek: "monday", startTime: "22:00", from: now))
        XCTAssertGreaterThan(airs, now)
        XCTAssertGreaterThan(airs.timeIntervalSince(now), 6 * 24 * 3600)
    }

    /// The instant is absolute, so a viewer elsewhere sees their own local time for it — this is
    /// the whole reason the conversion is anchored to Tokyo rather than the device.
    func testInstantIsAbsoluteNotDeviceLocal() throws {
        let cal = jstCalendar()
        let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 7, hour: 12))!
        let airs = try XCTUnwrap(
            MALOfficialDiscoveryService.nextAiring(dayOfWeek: "wednesday", startTime: "22:00", from: now))

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        // 22:00 JST is 13:00 UTC — JST is UTC+9 with no daylight saving.
        XCTAssertEqual(utc.component(.hour, from: airs), 13)
    }

    // MARK: - Malformed input

    func testUnknownWeekdayIsRejected() {
        XCTAssertNil(MALOfficialDiscoveryService.nextAiring(dayOfWeek: "someday", startTime: "22:00"))
    }

    func testMalformedTimeIsRejected() {
        XCTAssertNil(MALOfficialDiscoveryService.nextAiring(dayOfWeek: "monday", startTime: "22"))
        XCTAssertNil(MALOfficialDiscoveryService.nextAiring(dayOfWeek: "monday", startTime: ""))
        XCTAssertNil(MALOfficialDiscoveryService.nextAiring(dayOfWeek: "monday", startTime: "25:00"))
        XCTAssertNil(MALOfficialDiscoveryService.nextAiring(dayOfWeek: "monday", startTime: "12:99"))
    }

    /// Casing varies in the feed and shouldn't decide whether a show appears.
    func testWeekdayCasingIsIgnored() {
        XCTAssertNotNil(MALOfficialDiscoveryService.nextAiring(dayOfWeek: "Wednesday", startTime: "22:00"))
        XCTAssertNotNil(MALOfficialDiscoveryService.nextAiring(dayOfWeek: "SATURDAY", startTime: "01:30"))
    }

    /// A show with no published slot must be skipped, not placed arbitrarily.
    func testBroadcastIsOptionalInTheFeed() throws {
        let json = #"{"id":1,"title":"X","broadcast":null}"#
        let node = try JSONDecoder().decode(MALOfficialDiscoveryService.Node.self, from: Data(json.utf8))
        XCTAssertNil(node.broadcast?.day_of_the_week)
    }
}
