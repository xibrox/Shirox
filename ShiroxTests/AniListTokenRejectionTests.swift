import XCTest
@testable import Shirox

/// Tests for how a refused AniList access token is classified.
///
/// AniList rejects a token with **HTTP 400 and "Invalid token"** — never 401. Verified against
/// the live endpoint: any `Authorization` header it won't accept answers
/// `{"errors":[{"message":"Invalid token","status":400}]}` for *any* query, public ones
/// included, and it answers that ahead of every other gate (unauthenticated traffic during an
/// announced outage gets a 403, but a bad token gets the 400).
///
/// The `case 401` branches the services used to hang "genuine auth failure" on were therefore
/// dead code, and a refused token fell through to the transient bucket instead: the app kept
/// the token, kept `isLoggedIn` true and re-sent it from every authenticated screen, so one bad
/// token surfaced as a bare "HTTP error 400" on the library, profile, social feed and
/// notifications at once with no route back to a sign-in prompt.
final class AniListTokenRejectionTests: XCTestCase {

    func testInvalidTokenOn400IsATokenRejection() {
        XCTAssertTrue(AniListService.isTokenRejection(status: 400, message: "Invalid token"))
    }

    /// The wording is AniList's, so match it without depending on its casing.
    func testMatchIsCaseInsensitive() {
        XCTAssertTrue(AniListService.isTokenRejection(status: 400, message: "invalid token"))
        XCTAssertTrue(AniListService.isTokenRejection(status: 400, message: "INVALID TOKEN"))
    }

    /// A 400 AniList explains some other way stays transient. This app cannot tell a genuinely
    /// revoked token from AniList's auth layer failing valid ones mid-incident, so only the
    /// token wording itself may point the user at signing in again.
    func testOther400sAreNotTokenRejections() {
        XCTAssertFalse(AniListService.isTokenRejection(status: 400, message: "Validation error"))
        XCTAssertFalse(AniListService.isTokenRejection(
            status: 400,
            message: "The AniList API has been temporarily disabled due to severe stability issues."))
        XCTAssertFalse(AniListService.isTokenRejection(status: 400, message: nil))
    }

    /// Narrow on purpose: 403 is already claimed by the outage and rate-limit handling, and a
    /// 5xx is transient by definition. Neither may be read as a refused token.
    func testOnlyStatus400Counts() {
        XCTAssertFalse(AniListService.isTokenRejection(status: 403, message: "Invalid token"))
        XCTAssertFalse(AniListService.isTokenRejection(status: 401, message: "Invalid token"))
        XCTAssertFalse(AniListService.isTokenRejection(status: 500, message: "Invalid token"))
    }

    /// The two classifiers must not overlap: a refused token is not an announced outage, and
    /// the outage message must not be mistaken for a token problem.
    func testTokenRejectionAndAnnouncedOutageAreDisjoint() {
        XCTAssertFalse(AniListService.isAnnouncedOutage("Invalid token"))
        let outage = "The AniList API has been temporarily disabled due to severe stability issues."
        XCTAssertTrue(AniListService.isAnnouncedOutage(outage))
        XCTAssertFalse(AniListService.isTokenRejection(status: 400, message: outage))
    }

    /// The whole point of the fix: the user gets told what to do, not a status code. "400" was
    /// exactly what they saw on every authenticated screen.
    func testTokenRejectedReadsAsASignInPromptNotAStatusCode() {
        let message = AniListError.tokenRejected.errorDescription ?? ""
        XCTAssertFalse(message.contains("400"))
        XCTAssertTrue(message.lowercased().contains("sign in"))
    }
}
