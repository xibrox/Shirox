import XCTest
@testable import Shirox

final class NSFWContentFilterTests: XCTestCase {

    // normalize
    func testNormalizeLowercasesAndStripsPunctuation() {
        XCTAssertEqual(NSFWContentFilter.normalize("Re:ZERO -Starting Life-"), "re zero starting life")
    }
    func testNormalizeStripsSeasonSuffix() {
        XCTAssertEqual(NSFWContentFilter.normalize("Overflow Season 2"), "overflow")
        XCTAssertEqual(NSFWContentFilter.normalize("Kaguya-sama 3rd Season"), "kaguya sama")
    }

    // keyword layer — whole-token, no false positives
    func testKeywordFlagsExplicitTerms() {
        XCTAssertTrue(NSFWContentFilter.containsBlockedKeyword(NSFWContentFilter.normalize("Some Hentai OVA")))
        XCTAssertTrue(NSFWContentFilter.containsBlockedKeyword(NSFWContentFilter.normalize("XXX Holic Uncut")))
    }
    func testKeywordFlagsExpandedTerms() {
        for title in ["Futanari World", "Eroge H mo Game", "The Erotic Night",
                      "Milf Apartment", "Threesome OVA", "Incest Diary"] {
            XCTAssertTrue(NSFWContentFilter.containsBlockedKeyword(NSFWContentFilter.normalize(title)),
                          "expected \(title) to be flagged")
        }
    }
    func testKeywordDoesNotFalseFlagInnocentTitles() {
        XCTAssertFalse(NSFWContentFilter.containsBlockedKeyword(NSFWContentFilter.normalize("Assassination Classroom")))
        XCTAssertFalse(NSFWContentFilter.containsBlockedKeyword(NSFWContentFilter.normalize("Prison School")))
        XCTAssertFalse(NSFWContentFilter.containsBlockedKeyword(NSFWContentFilter.normalize("Cassandra")))
    }
    // Whole-token safety + deliberate exclusions must stay unflagged.
    func testKeywordDoesNotFalseFlagLookalikesOrGenreTitles() {
        for title in ["Analog Memory", "Peacock King", "Cumulus", "Moby Dick Anime",
                      "Eromanga Sensei", "Sexy Commando Gaiden", "High School DxD (Ecchi)",
                      "Yuri on Ice", "Given (Yaoi Romance)"] {
            XCTAssertFalse(NSFWContentFilter.containsBlockedKeyword(NSFWContentFilter.normalize(title)),
                           "did not expect \(title) to be flagged")
        }
    }

    // adult-set cross-check layer
    func testAdultExactMatch() {
        let set: Set<String> = ["overflow"]
        XCTAssertTrue(NSFWContentFilter.isAdultTitle("overflow", adultSet: set))
    }
    func testAdultMultiTokenSubsetMatch() {
        let set: Set<String> = ["boku no pico"]
        XCTAssertTrue(NSFWContentFilter.isAdultTitle("boku no pico uncensored", adultSet: set))
    }
    func testAdultSingleTokenDoesNotOverMatch() {
        // A single-token adult variant must only match exactly, not every title sharing the word.
        let set: Set<String> = ["school"]
        XCTAssertFalse(NSFWContentFilter.isAdultTitle("prison school", adultSet: set))
    }
    func testNonAdultTitleNotFlagged() {
        let set: Set<String> = ["overflow"]
        XCTAssertFalse(NSFWContentFilter.isAdultTitle("fullmetal alchemist", adultSet: set))
    }
}
