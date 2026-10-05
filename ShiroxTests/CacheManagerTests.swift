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

    /// The HTTP response cache is in the total and emptied by its reset.
    func testTheNetworkCacheIsCleared() {
        let url = URL(string: "https://cache-test.example/answer")!
        let response = CachedURLResponse(
            response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                      headerFields: ["Cache-Control": "max-age=3600"])!,
            data: Data(count: 10_000))
        URLCache.shared.storeCachedResponse(response, for: URLRequest(url: url))
        XCTAssertNotNil(URLCache.shared.cachedResponse(for: URLRequest(url: url)))

        CacheManager.shared.clearNetworkCache()
        XCTAssertNil(URLCache.shared.cachedResponse(for: URLRequest(url: url)))
    }
}
