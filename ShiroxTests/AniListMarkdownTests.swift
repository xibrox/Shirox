import XCTest
@testable import Shirox

/// Tests for AniList's `~!spoiler!~` markup.
///
/// The bug these exist for: the old implementation replaced each spoiler in turn and tracked a
/// running offset computed as `replacement.count - match.range.length` — Swift's *Character*
/// count measured against NSString's *UTF-16* length. Those two agree only while every
/// character occupies a single UTF-16 unit, so one emoji in a revealed spoiler pushed every
/// later replacement to the wrong position and corrupted the rest of the bio. AniList profiles
/// are full of emoji, so this was not an edge case.
final class AniListMarkdownTests: XCTestCase {

    private let spoilerLink = "[⬛ spoiler](spoiler://"

    // MARK: - Hidden

    func testSpoilerBecomesATappableLink() {
        let out = AniListSpoilerMarkup.apply(to: "before ~!secret!~ after", revealed: [])
        XCTAssertTrue(out.hasPrefix("before "))
        XCTAssertTrue(out.hasSuffix(" after"))
        // The content rides along inside the spoiler:// URL — that is how tapping reveals it —
        // so what matters is that the *visible* label is the placeholder, not the secret.
        XCTAssertTrue(out.contains("[⬛ spoiler](spoiler://secret)"))
        XCTAssertFalse(out.contains("before secret"), "the secret must not be shown inline")
    }

    func testTextWithoutSpoilersIsUntouched() {
        let raw = "Just a bio with **bold** and a [link](https://example.com)."
        XCTAssertEqual(AniListSpoilerMarkup.apply(to: raw, revealed: []), raw)
    }

    // MARK: - Revealed

    func testRevealedSpoilerShowsItsContent() {
        let out = AniListSpoilerMarkup.apply(to: "a ~!shown!~ b", revealed: ["shown"])
        XCTAssertEqual(out, "a shown b")
    }

    // MARK: - The regression

    /// THE BUG: an emoji in a revealed spoiler used to shift everything after it.
    func testEmojiInRevealedSpoilerDoesNotCorruptLaterText() {
        let out = AniListSpoilerMarkup.apply(to: "one ~!🎉!~ two ~!party!~ three",
                                             revealed: ["🎉", "party"])
        XCTAssertEqual(out, "one 🎉 two party three")
    }

    /// Several multi-unit characters compound the drift, so the tail is where it showed up.
    func testMultipleEmojiKeepTrailingTextIntact() {
        let out = AniListSpoilerMarkup.apply(to: "~!🎉🎊!~ mid ~!👍🏽!~ tail",
                                             revealed: ["🎉🎊", "👍🏽"])
        XCTAssertEqual(out, "🎉🎊 mid 👍🏽 tail")
    }

    /// A family emoji is a single Character but many UTF-16 units — the widest gap between the
    /// two measures, and the case the old arithmetic failed hardest on.
    func testZWJSequenceIsHandled() {
        let out = AniListSpoilerMarkup.apply(to: "start ~!👨‍👩‍👧‍👦!~ end", revealed: ["👨‍👩‍👧‍👦"])
        XCTAssertEqual(out, "start 👨‍👩‍👧‍👦 end")
    }

    /// Emoji outside the spoilers must survive too — they shift the match positions themselves.
    func testEmojiSurroundingSpoilersIsPreserved() {
        let out = AniListSpoilerMarkup.apply(to: "🌸 ~!a!~ 🌸 ~!b!~ 🌸", revealed: ["a", "b"])
        XCTAssertEqual(out, "🌸 a 🌸 b 🌸")
    }

    // MARK: - Mixed and awkward input

    func testMixedRevealedAndHiddenSpoilers() {
        let out = AniListSpoilerMarkup.apply(to: "~!open!~ and ~!closed!~", revealed: ["open"])
        XCTAssertTrue(out.hasPrefix("open and "))
        // Revealed content is inlined; hidden content appears only as the link's target.
        XCTAssertTrue(out.contains("[⬛ spoiler](spoiler://closed)"))
        XCTAssertFalse(out.contains("and closed"), "the hidden one must not be shown inline")
    }

    func testSpoilerSpanningNewlinesIsMatched() {
        let out = AniListSpoilerMarkup.apply(to: "~!line one\nline two!~", revealed: ["line one\nline two"])
        XCTAssertEqual(out, "line one\nline two")
    }

    func testEmptySpoilerDoesNotCrash() {
        let out = AniListSpoilerMarkup.apply(to: "a ~!!~ b", revealed: [])
        XCTAssertTrue(out.contains(spoilerLink))
    }

    /// An unterminated marker is ordinary text, not a spoiler.
    func testUnclosedSpoilerIsLeftAlone() {
        let raw = "dangling ~! marker"
        XCTAssertEqual(AniListSpoilerMarkup.apply(to: raw, revealed: []), raw)
    }
}
