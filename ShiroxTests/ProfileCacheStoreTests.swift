import XCTest
@testable import Shirox

@MainActor
final class ProfileCacheStoreTests: XCTestCase {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeProfile(id: Int, name: String, provider: ProviderType = .anilist) -> UserProfile {
        UserProfile(id: id, provider: provider, name: name, about: nil,
                    avatarURL: nil, bannerImage: nil, isFollowing: nil,
                    statistics: nil, favourites: nil)
    }

    private func makeActivity(id: Int) -> UserActivity {
        UserActivity(id: id, kind: .text("a\(id)"), createdAt: id,
                     user: nil, likeCount: 0, replyCount: 0, isLiked: false)
    }

    func testSaveProfileThenReopenRoundTrips() {
        let dir = tempDir()
        let store = ProfileCacheStore(directory: dir)
        store.saveProfile(makeProfile(id: 5, name: "Ada"), provider: .anilist, userId: 5)

        let reopened = ProfileCacheStore(directory: dir)
        let snap = reopened.snapshot(provider: .anilist, userId: 5)
        XCTAssertEqual(snap?.profile?.name, "Ada")
        XCTAssertNotNil(snap?.syncedAt)
    }

    func testSaversMergeIntoSameKeyWithoutClobbering() {
        let dir = tempDir()
        let store = ProfileCacheStore(directory: dir)
        store.saveProfile(makeProfile(id: 5, name: "Ada"), provider: .anilist, userId: 5)
        store.saveActivity([makeActivity(id: 1), makeActivity(id: 2)], provider: .anilist, userId: 5)
        store.saveFollowers([makeProfile(id: 9, name: "F")], provider: .anilist, userId: 5)

        let snap = store.snapshot(provider: .anilist, userId: 5)
        XCTAssertEqual(snap?.profile?.name, "Ada")            // not wiped by saveActivity
        XCTAssertEqual(snap?.activity.map(\.id), [1, 2])
        XCTAssertEqual(snap?.followers.map(\.id), [9])
    }

    func testKeysAreIsolatedByProviderAndUser() {
        let dir = tempDir()
        let store = ProfileCacheStore(directory: dir)
        store.saveProfile(makeProfile(id: 1, name: "AniA", provider: .anilist), provider: .anilist, userId: 1)
        store.saveProfile(makeProfile(id: 1, name: "MalA", provider: .mal), provider: .mal, userId: 1)
        store.saveProfile(makeProfile(id: 2, name: "AniB", provider: .anilist), provider: .anilist, userId: 2)

        XCTAssertEqual(store.snapshot(provider: .anilist, userId: 1)?.profile?.name, "AniA")
        XCTAssertEqual(store.snapshot(provider: .mal, userId: 1)?.profile?.name, "MalA")
        XCTAssertEqual(store.snapshot(provider: .anilist, userId: 2)?.profile?.name, "AniB")
        XCTAssertNil(store.snapshot(provider: .mal, userId: 2))
    }

    func testCapEvictsOldestSyncedKey() {
        let dir = tempDir()
        let store = ProfileCacheStore(directory: dir)
        for i in 1...21 {                         // cap is 20
            store.saveProfile(makeProfile(id: i, name: "U\(i)"), provider: .anilist, userId: i)
        }
        XCTAssertNil(store.snapshot(provider: .anilist, userId: 1))   // oldest evicted
        XCTAssertNotNil(store.snapshot(provider: .anilist, userId: 21))
    }

    func testCorruptFileLoadsAsEmpty() throws {
        let dir = tempDir()
        try "not json".data(using: .utf8)!.write(to: dir.appendingPathComponent("profile-cache.json"))
        let store = ProfileCacheStore(directory: dir)
        XCTAssertNil(store.snapshot(provider: .anilist, userId: 1))
    }

    func testClearAllEmptiesStore() {
        let dir = tempDir()
        let store = ProfileCacheStore(directory: dir)
        store.saveProfile(makeProfile(id: 5, name: "Ada"), provider: .anilist, userId: 5)
        store.clearAll()
        XCTAssertNil(store.snapshot(provider: .anilist, userId: 5))
        XCTAssertEqual(store.diskByteSize(), 0)
    }
}
