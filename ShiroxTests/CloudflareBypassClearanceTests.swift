import XCTest
@testable import Shirox

/// Cloudflare hands out a `cf_clearance` cookie the moment it *serves* a managed challenge,
/// before the user has solved anything — so the bypass manager can't treat the cookie's
/// presence as proof of clearance. These cover the probe that tells the two apart.
final class CloudflareBypassClearanceTests: XCTestCase {

    func testMitigatedChallengeIsNotClearance() {
        XCTAssertFalse(CloudflareBypassManager.probeIndicatesClearance(
            .init(status: 403, cfMitigated: "challenge")))
    }

    func testForbiddenWithoutMitigationHeaderIsNotClearance() {
        XCTAssertFalse(CloudflareBypassManager.probeIndicatesClearance(
            .init(status: 403, cfMitigated: nil)))
    }

    func testServiceUnavailableIsNotClearance() {
        XCTAssertFalse(CloudflareBypassManager.probeIndicatesClearance(
            .init(status: 503, cfMitigated: nil)))
    }

    func testOKWithoutMitigationIsClearance() {
        XCTAssertTrue(CloudflareBypassManager.probeIndicatesClearance(
            .init(status: 200, cfMitigated: nil)))
    }

    func testEmptyMitigationHeaderCountsAsAbsent() {
        XCTAssertTrue(CloudflareBypassManager.probeIndicatesClearance(
            .init(status: 200, cfMitigated: "")))
    }

    /// A cleared host that 404s the exact poster path is still past the wall — the
    /// clearance works, the path just doesn't exist.
    func testOriginNotFoundCountsAsPastTheWall() {
        XCTAssertTrue(CloudflareBypassManager.probeIndicatesClearance(
            .init(status: 404, cfMitigated: nil)))
    }

    @MainActor
    func testInvalidateCookieDropsBypassWithoutArmingVerificationPrompt() {
        let manager = CloudflareBypassManager.shared
        manager.pendingVerificationURL = nil
        manager.store(cookie: "abc", cookieHeader: "cf_clearance=abc", userAgent: "UA", for: "i.example.pw")
        XCTAssertNotNil(manager.fullCookieHeader(for: "i.example.pw"))

        manager.invalidateCookie(for: "i.example.pw")

        XCTAssertNil(manager.cookie(for: "i.example.pw"))
        XCTAssertNil(manager.fullCookieHeader(for: "i.example.pw"))
        XCTAssertNil(manager.bypassUserAgent(for: "i.example.pw"))
        // Unlike flagPendingVerification, this must not hijack the stream picker's
        // "Verify Cloudflare" affordance — a poster load is not a stream load.
        XCTAssertNil(manager.pendingVerificationURL)
    }

    /// Reported: a site that puts its challenge only on detail pages could never be verified,
    /// as the window opened the front page.
    func testTheChallengeIsSolvedOnTheWalledPage() {
        let detail = URL(string: "https://site.example/movie/123-title")!
        XCTAssertEqual(CloudflareBypassManager.challengePage(for: detail), detail)
        XCTAssertEqual(CloudflareBypassManager.challengePage(for: URL(string: "https://cdn.site.example/v/master.m3u8")!),
                       URL(string: "https://cdn.site.example/")!, "a stream can't show a challenge")
    }

    @MainActor
    func testAModuleCheckPassesOnlyOnAWebStream() {
        func stream(_ s: String) -> StreamResult { StreamResult(title: "x", url: URL(string: s)!, headers: [:]) }
        XCTAssertTrue(ModuleCheck.verdict([stream("about:blank"), stream("https://cdn.example/a.m3u8")]))
        XCTAssertFalse(ModuleCheck.verdict([stream("about:blank"), stream("file:///tmp/x.mp4")]))
        XCTAssertFalse(ModuleCheck.verdict([]))
    }
}
