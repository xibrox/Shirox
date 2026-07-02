import XCTest
@testable import Shirox

final class HostBlocklistTests: XCTestCase {

    func testParseHandlesHostsFileAndBareLinesAndComments() {
        let contents = """
        # a comment
        127.0.0.1 badporn.com
        0.0.0.0 evil-hentai.net
        another-adult.org

        127.0.0.1 localhost
        """
        let set = HostBlocklist.parse(contents)
        XCTAssertTrue(set.contains("badporn.com"))
        XCTAssertTrue(set.contains("evil-hentai.net"))
        XCTAssertTrue(set.contains("another-adult.org"))
        XCTAssertFalse(set.contains("localhost"))   // skipped
        XCTAssertFalse(set.contains(""))            // blank line skipped
    }

    func testParseLowercasesHosts() {
        XCTAssertTrue(HostBlocklist.parse("0.0.0.0 BadPorn.COM").contains("badporn.com"))
    }

    func testExactHostBlocked() {
        let set: Set<String> = ["badporn.com"]
        XCTAssertTrue(HostBlocklist.isHostBlocked("badporn.com", in: set))
    }

    func testSubdomainBlocked() {
        let set: Set<String> = ["badporn.com"]
        XCTAssertTrue(HostBlocklist.isHostBlocked("cdn.videos.badporn.com", in: set))
    }

    func testLookalikeNotBlocked() {
        let set: Set<String> = ["porn.com"]
        XCTAssertFalse(HostBlocklist.isHostBlocked("notporn.com", in: set))
        XCTAssertFalse(HostBlocklist.isHostBlocked("pornial.com", in: set))
    }

    func testUnrelatedHostNotBlocked() {
        let set: Set<String> = ["badporn.com"]
        XCTAssertFalse(HostBlocklist.isHostBlocked("anilist.co", in: set))
    }

    func testCaseInsensitiveMatch() {
        let set: Set<String> = ["badporn.com"]
        XCTAssertTrue(HostBlocklist.isHostBlocked("CDN.BadPorn.Com", in: set))
    }

    func testDoesNotBlockBareTLD() {
        let set: Set<String> = ["com"]   // pathological entry must not nuke everything
        XCTAssertFalse(HostBlocklist.isHostBlocked("anilist.com", in: set))
    }

    func testLoadForTestingPopulatesIsBlocked() {
        HostBlocklist.loadForTesting(["badporn.com"])
        XCTAssertTrue(HostBlocklist.shared.isBlocked(URL(string: "https://cdn.badporn.com/a.m3u8")!))
        XCTAssertFalse(HostBlocklist.shared.isBlocked(URL(string: "https://anilist.co")!))
    }
}
