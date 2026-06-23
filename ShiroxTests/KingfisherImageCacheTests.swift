import XCTest
import Kingfisher
@testable import Shirox

final class KingfisherImageCacheTests: XCTestCase {

    func testHeadersDefaultUserAgentAndRefererAndAccept() {
        let url = URL(string: "https://cdn.example.com/posters/a.jpg")!
        let h = KingfisherImageCache.headers(for: url, cookieHeader: nil, bypassUserAgent: nil)
        XCTAssertEqual(h["User-Agent"], KingfisherImageCache.defaultUserAgent)
        XCTAssertEqual(h["Referer"], "https://cdn.example.com/")
        XCTAssertEqual(h["Accept"], "image/avif,image/webp,image/png,image/jpeg,*/*")
        XCTAssertNil(h["Cookie"])
    }

    func testHeadersInjectCookieAndBypassUserAgent() {
        let url = URL(string: "https://cdn.example.com/a.jpg")!
        let h = KingfisherImageCache.headers(for: url, cookieHeader: "cf_clearance=abc", bypassUserAgent: "BypassUA/1.0")
        XCTAssertEqual(h["Cookie"], "cf_clearance=abc")
        XCTAssertEqual(h["User-Agent"], "BypassUA/1.0")
    }

    func testConfigureSetsDiskSizeLimit() {
        KingfisherImageCache.configure()
        XCTAssertEqual(ImageCache.default.diskStorage.config.sizeLimit, 500 * 1024 * 1024)
    }

    // MARK: - CachedAsyncImage cache helpers (Kingfisher-backed)

    /// 1×1 opaque PNG bytes for round-trip tests.
    private func makePNGData() -> Data {
        let size = CGSize(width: 1, height: 1)
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        return img.pngData()!
    }

    private func store(_ data: Data, forKey key: String) async {
        let image = KFCrossPlatformImage(data: data)!
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            KingfisherManager.shared.cache.store(image, original: data, forKey: key, toDisk: true) { _ in
                c.resume()
            }
        }
    }

    func testCachedImageDataRoundTrip() async {
        let key = "https://test.example/roundtrip-\(UUID().uuidString).png"
        let data = makePNGData()
        await store(data, forKey: key)
        let got = CachedAsyncImage.cachedImageData(for: key)
        XCTAssertNotNil(got, "expected disk-cached bytes for stored key")
        XCTAssertNotNil(KFCrossPlatformImage(data: got!), "cached bytes should decode to an image")
    }

    func testDiskCacheBytesPositiveAfterStore() async {
        await store(makePNGData(), forKey: "https://test.example/size-\(UUID().uuidString).png")
        let bytes = await CachedAsyncImage.diskCacheBytes
        XCTAssertGreaterThan(bytes, 0)
    }

    func testResetCacheClearsMemory() {
        let key = "https://test.example/mem-\(UUID().uuidString).png"
        let image = KFCrossPlatformImage(data: makePNGData())!
        ImageCache.default.store(image, forKey: key, toDisk: false)
        XCTAssertNotNil(ImageCache.default.retrieveImageInMemoryCache(forKey: key))
        CachedAsyncImage.resetCache()
        XCTAssertNil(ImageCache.default.retrieveImageInMemoryCache(forKey: key))
    }

    @MainActor
    func testCacheManagerImageSizeNonNegative() async {
        let size = await CacheManager.shared.imageCacheSize
        XCTAssertGreaterThanOrEqual(size, 0)
    }

    /// Kingfisher owns the image cache now; `URLCache.shared` is the general
    /// HTTP/API response cache. `imageCacheSize` must reflect only Kingfisher's
    /// disk store, otherwise the figure double-counts and blows past the 500 MB cap.
    @MainActor
    func testImageSizeExcludesSharedURLCache() async {
        let original = URLCache.shared
        defer { URLCache.shared = original }

        // memoryCapacity 0 forces the response onto disk so currentDiskUsage > 0.
        let probe = URLCache(memoryCapacity: 0, diskCapacity: 50 * 1024 * 1024, diskPath: "imgcache-test")
        URLCache.shared = probe
        let url = URL(string: "https://test.example/urlcache-\(UUID().uuidString).json")!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        probe.storeCachedResponse(
            CachedURLResponse(response: response, data: Data(count: 1 * 1024 * 1024)),
            for: URLRequest(url: url)
        )

        let kingfisherBytes = await CachedAsyncImage.diskCacheBytes
        let reported = await CacheManager.shared.imageCacheSize
        XCTAssertEqual(reported, kingfisherBytes,
            "imageCacheSize must reflect only Kingfisher's disk store, not URLCache.shared (probe disk usage: \(probe.currentDiskUsage))")
    }
}
