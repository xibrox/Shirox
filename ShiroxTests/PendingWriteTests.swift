import XCTest
@testable import Shirox

final class PendingWriteTests: XCTestCase {

    private func update(provider: ProviderType, type: MediaKind, mediaId: Int) -> PendingWrite {
        PendingWrite(id: UUID(), provider: provider, mediaType: type, kind: .update,
                     mediaId: mediaId, entryId: nil, status: .current, progress: 1,
                     score: 0, repeatCount: nil, updatedAt: Date(), attempts: 0)
    }

    func testDedupKeyDistinguishesProviderTypeAndTarget() {
        XCTAssertEqual(update(provider: .anilist, type: .anime, mediaId: 5).dedupKey, "anilist|update|anime|5")
        XCTAssertEqual(update(provider: .mal, type: .manga, mediaId: 5).dedupKey, "mal|update|manga|5")
        // Same provider+type+media collapses (last-write-wins target identity).
        XCTAssertEqual(update(provider: .anilist, type: .anime, mediaId: 5).dedupKey,
                       update(provider: .anilist, type: .anime, mediaId: 5).dedupKey)
        // Different media does not.
        XCTAssertNotEqual(update(provider: .anilist, type: .anime, mediaId: 5).dedupKey,
                          update(provider: .anilist, type: .anime, mediaId: 6).dedupKey)
    }

    func testAniListDeleteKeyedByEntryId() {
        let del = PendingWrite(id: UUID(), provider: .anilist, mediaType: nil, kind: .delete,
                               mediaId: nil, entryId: 42, status: nil, progress: nil,
                               score: nil, repeatCount: nil, updatedAt: Date(), attempts: 0)
        XCTAssertEqual(del.dedupKey, "anilist|delete|42")
    }
}
