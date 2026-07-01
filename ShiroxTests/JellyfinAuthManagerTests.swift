import XCTest
@testable import Shirox

final class JellyfinAuthManagerTests: XCTestCase {
    func testNormalizeAddsSchemeAndStripsTrailingSlash() {
        XCTAssertEqual(JellyfinAuthManager.normalizeServerURL("jf.example.com:8096/")?.absoluteString,
                       "http://jf.example.com:8096")
    }
    func testNormalizeKeepsHTTPS() {
        XCTAssertEqual(JellyfinAuthManager.normalizeServerURL("https://jf.example.com")?.absoluteString,
                       "https://jf.example.com")
    }
    func testNormalizeEmptyIsNil() {
        XCTAssertNil(JellyfinAuthManager.normalizeServerURL("   "))
    }
}
