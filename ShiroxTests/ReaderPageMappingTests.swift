import XCTest
@testable import Shirox

final class ReaderPageMappingTests: XCTestCase {

    // MARK: - Exact in-page position (vertical resume)

    func testInPageFraction() {
        XCTAssertEqual(ReaderPageMapping.inPageFraction(minY: 0, height: 1000), 0)
        XCTAssertEqual(ReaderPageMapping.inPageFraction(minY: -500, height: 1000), 0.5, accuracy: 0.0001)
        XCTAssertEqual(ReaderPageMapping.inPageFraction(minY: -1500, height: 1000), 1.0) // clamped
        XCTAssertEqual(ReaderPageMapping.inPageFraction(minY: 200, height: 1000), 0)     // page below top
        XCTAssertEqual(ReaderPageMapping.inPageFraction(minY: -500, height: 0), 0)       // no height yet
    }

    func testOffsetDelta() {
        // Page top at viewport top, want 50% into a 1000pt page -> scroll down 500.
        XCTAssertEqual(ReaderPageMapping.offsetDelta(currentMinY: 0, height: 1000, fraction: 0.5), 500)
        // Already at the exact position -> no adjustment.
        XCTAssertEqual(ReaderPageMapping.offsetDelta(currentMinY: -500, height: 1000, fraction: 0.5), 0)
        // Overshot (at 80%, want 50%) -> scroll back up 300.
        XCTAssertEqual(ReaderPageMapping.offsetDelta(currentMinY: -800, height: 1000, fraction: 0.5), -300)
    }
}
