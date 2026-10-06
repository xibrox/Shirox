import XCTest
@testable import Shirox

/// Whether a recovered stream should play on: the viewer's intent, not the engine's state,
/// which a dead stream has already stopped.
final class ViewerPlayIntentTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testPlayingUntilTheStreamDiedCountsAsPlaying() {
        let intent = ViewerPlayIntent()
        intent.clockMovedAt = now.addingTimeInterval(-3)
        XCTAssertTrue(intent.wasPlaying(now: now))
    }

    func testAPauseBeforeTheFailureIsKept() {
        let intent = ViewerPlayIntent()
        intent.clockMovedAt = now.addingTimeInterval(-6)
        intent.pausedAt = now.addingTimeInterval(-5)
        XCTAssertFalse(intent.wasPlaying(now: now))
    }

    func testAClockThatStoppedLongAgoIsntPlaying() {
        let intent = ViewerPlayIntent()
        intent.clockMovedAt = now.addingTimeInterval(-60)
        XCTAssertFalse(intent.wasPlaying(now: now))
        XCTAssertFalse(ViewerPlayIntent().wasPlaying(now: now), "never played")
    }
}
