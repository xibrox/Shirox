import Foundation
import Kingfisher

/// Central configuration for the Kingfisher-backed image pipeline and the
/// per-request headers anime CDNs require (browser UA + Referer, plus
/// Cloudflare cookie/UA when a host has been bypassed).
enum KingfisherImageCache {

    static let defaultUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    /// Configure the shared Kingfisher cache. Call once at app launch.
    static func configure() {
        let cache = ImageCache.default
        cache.diskStorage.config.sizeLimit = 500 * 1024 * 1024   // 500 MB
        cache.diskStorage.config.expiration = .days(7)
        // Keep original bytes on disk so `CachedAsyncImage.cachedImageData(for:)`
        // can hand decodable data to the snapshot store / provider banner.
        KingfisherManager.shared.defaultOptions = [.cacheOriginalImage]
    }

    /// Browser-like headers for an image fetch. Many anime CDNs hotlink-protect
    /// with a Referer requirement and reject the default URLSession UA. When a
    /// host has been Cloudflare-bypassed, pass its cookie header + the WebView's
    /// UA so the `cf_clearance` binding (UA + cookie) matches.
    /// `refererOverride` replaces the default own-origin Referer — manga CDNs
    /// require the SOURCE SITE's origin, not the image host's.
    static func headers(for url: URL, cookieHeader: String?, bypassUserAgent: String?,
                        refererOverride: String? = nil) -> [String: String] {
        var h: [String: String] = [
            "User-Agent": bypassUserAgent ?? defaultUserAgent,
            "Accept": "image/avif,image/webp,image/png,image/jpeg,*/*",
        ]
        if let refererOverride, !refererOverride.isEmpty {
            h["Referer"] = refererOverride
        } else if let scheme = url.scheme, let host = url.host {
            h["Referer"] = "\(scheme)://\(host)/"
        }
        if let cookieHeader, !cookieHeader.isEmpty {
            h["Cookie"] = cookieHeader
        }
        return h
    }
}
