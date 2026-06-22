import XCTest
import Kingfisher
@testable import Shirox

final class KingfisherImageCacheTests: XCTestCase {

    func testHeadersDefaultUserAgentAndRefererAndAccept() {
        let url = URL(string: "https://cdn.example.com/posters/a.jpg")!
        let h = KingfisherImageCache.headers(for: url, cookieHeader: nil, bypassUserAgent: nil)
        XCTAssertEqual(h["User-Agent"], KingfisherImageCache.defaultUserAgent)
        XCTAssertEqual(h["Referer"], "https://cdn.example.com/")
        XCTAssertEqual(h["Accept"], "image/avif,image/webp,image/png,image/jpeg,*/*")
        XCTAssertNil(h["Cookie"])
    }

    func testHeadersInjectCookieAndBypassUserAgent() {
        let url = URL(string: "https://cdn.example.com/a.jpg")!
        let h = KingfisherImageCache.headers(for: url, cookieHeader: "cf_clearance=abc", bypassUserAgent: "BypassUA/1.0")
        XCTAssertEqual(h["Cookie"], "cf_clearance=abc")
        XCTAssertEqual(h["User-Agent"], "BypassUA/1.0")
    }

    func testConfigureSetsDiskSizeLimit() {
        KingfisherImageCache.configure()
        XCTAssertEqual(ImageCache.default.diskStorage.config.sizeLimit, 500 * 1024 * 1024)
    }
}
