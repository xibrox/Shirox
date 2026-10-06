import XCTest
@testable import Shirox

/// What Storage & Cache counts is what its resets clear.
@MainActor
final class CacheManagerTests: XCTestCase {

    /// Simkl's lists and catalog pages and the TVDB episode mappings were neither counted nor
    /// cleared: Clear Everything left them, and its figure didn't include them.
    func testTheSimklAndMappingCachesAreCountedAndCleared() throws {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let feed = caches.appendingPathComponent("simkl-feed", isDirectory: true)
        try FileManager.default.createDirectory(at: feed, withIntermediateDirectories: true)
        try Data(count: 50_000).write(to: feed.appendingPathComponent("cache-test.json"))
        let before = CacheManager.shared.dataCacheSize
        XCTAssertGreaterThanOrEqual(before, 50_000)

        CacheManager.shared.clearDataCaches()
        XCTAssertFalse(FileManager.default.fileExists(atPath: feed.path))
        XCTAssertLessThan(CacheManager.shared.dataCacheSize, 50_000)
    }

    /// The HTTP response cache is counted, and its reset frees what it holds on disk. (Whether a
    /// cleared entry still answers from memory for a moment is URLCache's own business.)
    func testTheNetworkCacheIsCountedAndFreed() async throws {
        let cache = URLCache.shared
        for i in 0..<20 {
            let url = URL(string: "https://cache-test.example/answer/\(i)")!
            let response = CachedURLResponse(
                response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                          headerFields: ["Cache-Control": "max-age=3600"])!,
                data: Data(repeating: UInt8(i), count: 100_000))
            cache.storeCachedResponse(response, for: URLRequest(url: url))
        }
        // Written to disk on the cache's own queue.
        var stored = 0
        for _ in 0..<40 {
            stored = CacheManager.shared.networkCacheSize
            if stored >= 1_000_000 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertGreaterThanOrEqual(stored, 1_000_000, "counted")

        CacheManager.shared.clearNetworkCache()
        var after = stored
        for _ in 0..<40 {
            after = CacheManager.shared.networkCacheSize
            if after < stored / 2 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertLessThan(after, stored / 2, "freed")
    }
}
