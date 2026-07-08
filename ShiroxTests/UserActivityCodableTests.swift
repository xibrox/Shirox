import XCTest
@testable import Shirox

final class UserActivityCodableTests: XCTestCase {

    private func roundTrip(_ value: UserActivity) throws -> UserActivity {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(UserActivity.self, from: data)
    }

    func testTextActivityRoundTrips() throws {
        let original = UserActivity(
            id: 1, kind: .text("hello world"), createdAt: 1_700_000_000,
            user: nil, likeCount: 3, replyCount: 1, isLiked: true)
        let decoded = try roundTrip(original)
        XCTAssertEqual(decoded.id, 1)
        XCTAssertEqual(decoded.createdAt, 1_700_000_000)
        XCTAssertEqual(decoded.likeCount, 3)
        XCTAssertEqual(decoded.replyCount, 1)
        XCTAssertTrue(decoded.isLiked)
        guard case .text(let t) = decoded.kind else { return XCTFail("expected .text") }
        XCTAssertEqual(t, "hello world")
    }

    func testListActivityRoundTripsWithNilProgressAndMedia() throws {
        let original = UserActivity(
            id: 2, kind: .list(status: "watched episode", progress: nil, media: nil),
            createdAt: 42, user: nil, likeCount: 0, replyCount: 0, isLiked: false)
        let decoded = try roundTrip(original)
        guard case .list(let status, let progress, let media) = decoded.kind else {
            return XCTFail("expected .list")
        }
        XCTAssertEqual(status, "watched episode")
        XCTAssertNil(progress)
        XCTAssertNil(media)
    }
}
