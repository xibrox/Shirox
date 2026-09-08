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
