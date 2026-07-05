import XCTest
@testable import Shirox

@MainActor
final class LibraryCacheStoreTests: XCTestCase {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeEntry(id: Int, title: String) -> LibraryEntry {
        let media = Media(
            id: id, idMal: nil, provider: .anilist,
            title: MediaTitle(romaji: title, english: title, native: nil),
            coverImage: MediaCoverImage(large: nil, extraLarge: nil),
            bannerImage: nil, description: nil, episodes: 12,
            status: nil, averageScore: nil, genres: nil,
            season: nil, seasonYear: nil, nextAiringEpisode: nil,
            relations: nil, type: nil, format: nil)
        return LibraryEntry(
            id: id, media: media, status: .current, progress: 3, score: 8,
            updatedAt: nil, customListName: nil, timesRewatched: nil)
    }

    func testSaveThenLoadRoundTrips() {
        let dir = tempDir()
        let store = LibraryCacheStore(directory: dir)
        store.save(entries: [makeEntry(id: 1, title: "A"), makeEntry(id: 2, title: "B")],
                   provider: .anilist, mediaType: .anime)

        // A fresh instance over the same directory must read the persisted snapshot back.
        let reopened = LibraryCacheStore(directory: dir)
        let snap = reopened.snapshot(provider: .anilist, mediaType: .anime)
        XCTAssertEqual(snap?.entries.map(\.id), [1, 2])
        XCTAssertNotNil(snap?.syncedAt)
    }

    func testKeysAreIsolatedByProviderAndMediaType() {
        let dir = tempDir()
        let store = LibraryCacheStore(directory: dir)
        store.save(entries: [makeEntry(id: 1, title: "AniAnime")], provider: .anilist, mediaType: .anime)
        store.save(entries: [makeEntry(id: 2, title: "MalAnime")], provider: .mal, mediaType: .anime)
        store.save(entries: [makeEntry(id: 3, title: "AniManga")], provider: .anilist, mediaType: .manga)

        XCTAssertEqual(store.snapshot(provider: .anilist, mediaType: .anime)?.entries.map(\.id), [1])
        XCTAssertEqual(store.snapshot(provider: .mal, mediaType: .anime)?.entries.map(\.id), [2])
        XCTAssertEqual(store.snapshot(provider: .anilist, mediaType: .manga)?.entries.map(\.id), [3])
        XCTAssertNil(store.snapshot(provider: .mal, mediaType: .manga))
    }

    func testCorruptFileLoadsAsEmpty() throws {
        let dir = tempDir()
        try "not json".data(using: .utf8)!.write(to: dir.appendingPathComponent("library-cache.json"))
        let store = LibraryCacheStore(directory: dir)
        XCTAssertNil(store.snapshot(provider: .anilist, mediaType: .anime))
    }
}
