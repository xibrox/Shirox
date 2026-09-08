import XCTest
@testable import Shirox

/// Tests for the message shown when every tracker fails.
///
/// The fallback used to be a primary and exactly one spare, so a third provider could be signed
/// in, ordered and displayed while never actually being tried. Generalising it to a chain is a
/// prerequisite for adding Trakt — and the failure message has to name every service attempted,
/// because reporting only the last made it look as though the provider the user chose had never
/// been consulted at all.
final class ProviderFallbackChainTests: XCTestCase {

    private struct Down: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    private func message(_ failures: [(provider: ProviderType, error: Error)]) -> String {
        ProviderError.allProvidersFailed(failures).localizedDescription
    }

    func testNamesEveryProviderTried() {
        let text = message([
            (.mal, Down(text: "The service is busy.")),
            (.anilist, Down(text: "The AniList API has been temporarily disabled."))
        ])
        XCTAssertTrue(text.contains("MyAnimeList"), "the chosen provider must be named")
        XCTAssertTrue(text.contains("AniList"))
    }

    func testIncludesEachServicesOwnExplanation() {
        let text = message([
            (.mal, Down(text: "The service is busy.")),
            (.anilist, Down(text: "The AniList API has been temporarily disabled."))
        ])
        XCTAssertTrue(text.contains("The service is busy."))
        XCTAssertTrue(text.contains("The AniList API has been temporarily disabled."))
    }

    /// Three providers is the case this was generalised for.
    func testHandlesMoreThanTwoProviders() {
        let text = message([
            (.mal, Down(text: "busy")),
            (.anilist, Down(text: "disabled")),
            (.local, Down(text: "nothing stored"))
        ])
        for name in [ProviderType.mal, .anilist, .local].map(\.displayName) {
            XCTAssertTrue(text.contains(name), "\(name) was tried and must be named")
        }
    }

    /// One signed-in provider shouldn't read as though several were tried.
    func testSingleProviderReadsAsSingular() {
        let text = message([(.mal, Down(text: "busy"))])
        XCTAssertTrue(text.contains("is unavailable"), "got: \(text)")
        XCTAssertFalse(text.contains("are unavailable"))
    }

    func testTwoProvidersReadAsPlural() {
        let text = message([(.mal, Down(text: "a")), (.anilist, Down(text: "b"))])
        XCTAssertTrue(text.contains("are unavailable"), "got: \(text)")
    }

    /// Defensive: an empty chain must still say something usable rather than a bare fragment.
    func testEmptyChainStillReads() {
        XCTAssertEqual(message([]), "No tracker is available.")
    }
}

/// Tests for which failures are worth asking the next provider about.
///
/// THE BUG: AniList explains an outage in its response body, so "the API has been temporarily
/// disabled" arrives as a 403 carrying text. Adding a case for that message and leaving this
/// switch alone dropped it into `default`, and the app stopped falling back to MyAnimeList for
/// the one failure it matters most for. Reported simply as "it doesn't automatically switch".
@MainActor
final class ProviderFallbackEligibilityTests: XCTestCase {

    private var manager: ProviderManager { ProviderManager.shared }

    // MARK: - AniList outages must fall through to the other tracker

    func testServiceMessageOutageIsEligible() {
        let outage = AniListError.serviceMessage(
            code: 403, message: "The AniList API has been temporarily disabled.")
        XCTAssertTrue(manager.isFallbackEligible(outage))
    }

    func testServiceMessageServerErrorIsEligible() {
        XCTAssertTrue(manager.isFallbackEligible(
            AniListError.serviceMessage(code: 503, message: "Down for maintenance")))
    }

    /// A bare status and one carrying a message must be classified identically — the wording is
    /// for the reader, not for the routing.
    func testMessageAndBareStatusAgree() {
        for code in [403, 500, 503, 400, 404] {
            XCTAssertEqual(
                manager.isFallbackEligible(AniListError.httpError(code)),
                manager.isFallbackEligible(AniListError.serviceMessage(code: code, message: "x")),
                "status \(code) classified differently with and without a message"
            )
        }
    }

    func testHttpOutagesAreEligible() {
        XCTAssertTrue(manager.isFallbackEligible(AniListError.httpError(403)))
        XCTAssertTrue(manager.isFallbackEligible(AniListError.httpError(500)))
        XCTAssertTrue(manager.isFallbackEligible(AniListError.rateLimited))
    }

    // MARK: - Failures another provider can't fix

    /// A bad request stays bad on the next tracker; retrying it only delays the message.
    func testClientErrorsAreNotEligible() {
        XCTAssertFalse(manager.isFallbackEligible(AniListError.httpError(400)))
        XCTAssertFalse(manager.isFallbackEligible(AniListError.serviceMessage(code: 400, message: "Bad query")))
    }

    func testCancellationIsNotEligible() {
        XCTAssertFalse(manager.isFallbackEligible(CancellationError()))
        XCTAssertFalse(manager.isFallbackEligible(URLError(.cancelled)))
    }

    /// Having already exhausted every provider, there is nothing left to try.
    func testExhaustedChainIsNotEligible() {
        XCTAssertFalse(manager.isFallbackEligible(ProviderError.allProvidersFailed([])))
    }

    func testProviderServerErrorsAreEligible() {
        XCTAssertTrue(manager.isFallbackEligible(ProviderError.serverError(504)))
    }
}
