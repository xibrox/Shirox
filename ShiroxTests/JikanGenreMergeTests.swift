import XCTest
@testable import Shirox

/// Tests that MyAnimeList's themes reach the app alongside its genres.
///
/// MAL splits its taxonomy: Mecha, Music, Psychological and Mahou Shoujo are *themes*, not
/// genres, and arrive in a separate field. The client only decoded `genres`, so Evangelion
/// listed "Avant Garde, Award Winning, Drama, Sci-Fi, Suspense" and not that it was mecha or
/// psychological — while the browse grid happily offered both as filters. The payload below is
/// trimmed from the real response for Evangelion.
final class JikanGenreMergeTests: XCTestCase {

    private func anime(genres: [String], themes: [String]) throws -> MALDiscoveryService.JikanAnime {
        func list(_ names: [String]) -> String {
            names.map { #"{"name":"\#($0)"}"# }.joined(separator: ",")
        }
        let json = """
        {"mal_id":30,"title":"Shinseiki Evangelion",
         "genres":[\(list(genres))],"themes":[\(list(themes))]}
        """
        return try JSONDecoder().decode(MALDiscoveryService.JikanAnime.self, from: Data(json.utf8))
    }

    func testThemesAreMergedIntoGenres() throws {
        let a = try anime(genres: ["Drama", "Sci-Fi", "Suspense"], themes: ["Mecha", "Psychological"])
        let merged = MALDiscoveryService.combinedGenres(a)
        XCTAssertEqual(merged, ["Drama", "Sci-Fi", "Suspense", "Mecha", "Psychological"])
    }

    /// The four browse genres that are themes on MAL must be visible on the titles they filter,
    /// or picking "Mecha" returns shows that never say they're mecha.
    func testThemeOnlyGenresSurvive() throws {
        for theme in ["Mecha", "Music", "Psychological", "Mahou Shoujo"] {
            let a = try anime(genres: ["Drama"], themes: [theme])
            XCTAssertEqual(MALDiscoveryService.combinedGenres(a), ["Drama", theme])
        }
    }

    func testGenresAloneStillWork() throws {
        let a = try anime(genres: ["Action", "Comedy"], themes: [])
        XCTAssertEqual(MALDiscoveryService.combinedGenres(a), ["Action", "Comedy"])
    }

    /// A name appearing in both fields shouldn't be listed twice.
    func testDuplicatesAreDropped() throws {
        let a = try anime(genres: ["Drama", "Music"], themes: ["Music"])
        XCTAssertEqual(MALDiscoveryService.combinedGenres(a), ["Drama", "Music"])
    }

    /// Nothing to show is nil, not an empty array — the detail view hides the row on nil.
    func testNoTaxonomyIsNil() throws {
        let a = try anime(genres: [], themes: [])
        XCTAssertNil(MALDiscoveryService.combinedGenres(a))
    }

    /// Both fields are optional in the API and absent on some records.
    func testMissingFieldsDecodeAndResolveToNil() throws {
        let json = #"{"mal_id":30,"title":"X"}"#
        let a = try JSONDecoder().decode(MALDiscoveryService.JikanAnime.self, from: Data(json.utf8))
        XCTAssertNil(MALDiscoveryService.combinedGenres(a))
    }

    /// Every host must keep Jikan's `/v4` prefix — the mirror 404s without it.
    func testEveryHostKeepsVersionPrefix() {
        for host in JikanAPI.allHosts {
            XCTAssertTrue(host.absoluteString.hasSuffix("/v4"),
                          "\(host) must keep the /v4 prefix — unprefixed paths 404")
        }
    }

    /// A single host means no failover at all, which is the state that prompted this.
    func testThereIsAFallbackHost() {
        XCTAssertGreaterThan(JikanAPI.allHosts.count, 1)
    }

    /// Whichever host last answered is tried first — a fixed order costs three retries against
    /// a dead host on every request once one goes down.
    func testRememberedHostIsTriedFirst() {
        let second = JikanAPI.allHosts[1]
        JikanAPI.remember(second)
        XCTAssertEqual(JikanAPI.hosts.first, second)
        XCTAssertEqual(JikanAPI.hosts.count, JikanAPI.allHosts.count, "no host may be dropped")
        XCTAssertEqual(Set(JikanAPI.hosts), Set(JikanAPI.allHosts))

        JikanAPI.remember(JikanAPI.allHosts[0])
        XCTAssertEqual(JikanAPI.hosts.first, JikanAPI.allHosts[0])
    }

    /// `base` follows the preference rather than pinning one host.
    func testBaseFollowsThePreferredHost() {
        JikanAPI.remember(JikanAPI.allHosts[1])
        XCTAssertEqual(JikanAPI.base, JikanAPI.allHosts[1])
    }
}
