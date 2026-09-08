import XCTest
@testable import Shirox

/// Tests for resolving a saved quality preference against a source's HLS ladder.
///
/// The report: a module that always started at the lowest rendition, forcing a trip to the
/// quality menu before every cast/AirPlay session. The preference removes that, but only if
/// it degrades sensibly on sources that don't offer the exact rung requested.
final class HLSQualityPreferenceTests: XCTestCase {

    private func ladder() -> [HLSQualityLevel] {
        [
            HLSQualityLevel(label: "1080p", bandwidth: 5_000_000, resolution: "1920x1080"),
            HLSQualityLevel(label: "720p",  bandwidth: 2_500_000, resolution: "1280x720"),
            HLSQualityLevel(label: "480p",  bandwidth: 1_000_000, resolution: "854x480"),
        ]
    }

    func testAutoLeavesPlayerAdaptive() {
        XCTAssertNil(HLSQualityParser.select(from: ladder(), preference: "auto"))
    }

    func testHighestPicksTopBandwidth() {
        XCTAssertEqual(HLSQualityParser.select(from: ladder(), preference: "highest")?.label, "1080p")
    }

    func testLowestPicksBottomBandwidth() {
        XCTAssertEqual(HLSQualityParser.select(from: ladder(), preference: "lowest")?.label, "480p")
    }

    func testExactHeightMatch() {
        XCTAssertEqual(HLSQualityParser.select(from: ladder(), preference: "720")?.label, "720p")
    }

    /// Asking for 1080p on a source that tops out at 720p plays 720p — not adaptive, which is
    /// what let it drift back down to the lowest rung in the first place.
    func testFallsBackToBestBelowTarget() {
        let capped = Array(ladder().dropFirst())   // 720p, 480p
        XCTAssertEqual(HLSQualityParser.select(from: capped, preference: "1080")?.label, "720p")
    }

    /// Every rung is above the request: the smallest is the closest honest answer.
    func testFallsBackToSmallestWhenAllExceedTarget() {
        let high = [HLSQualityLevel(label: "1440p", bandwidth: 9_000_000, resolution: "2560x1440"),
                    HLSQualityLevel(label: "2160p", bandwidth: 16_000_000, resolution: "3840x2160")]
        XCTAssertEqual(HLSQualityParser.select(from: high, preference: "480")?.label, "1440p")
    }

    func testEmptyLadderResolvesToNil() {
        XCTAssertNil(HLSQualityParser.select(from: [], preference: "highest"))
    }

    /// Height is read from the label when the manifest omitted RESOLUTION.
    func testHeightFallsBackToLabelDigits() {
        let level = HLSQualityLevel(label: "720p", bandwidth: 1, resolution: "")
        XCTAssertEqual(HLSQualityParser.height(of: level), 720)
    }
}
