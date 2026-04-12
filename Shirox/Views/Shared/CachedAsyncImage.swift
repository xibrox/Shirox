import SwiftUI

#if os(iOS)
import UIKit
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformImage = NSImage
#endif

/// Cross-platform URLSession + NSCache image loader.
/// Uses a dedicated ephemeral session so images are NOT written to
/// URLCache.shared on disk — all caching is handled by NSCache in RAM.
struct CachedAsyncImage: View {
    let urlString: String
    var base64String: String? = nil
    @State private var platformImage: PlatformImage?
    @State private var loadFailed = false

    private static let cache: NSCache<NSString, PlatformImage> = {
        let c = NSCache<NSString, PlatformImage>()
        c.countLimit = 350
        return c
    }()

    /// Ephemeral session: no disk caching, no credential storage.
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil
        return URLSession(configuration: cfg)
    }()

    private var cachedImage: PlatformImage? {
        guard !urlString.isEmpty else { return nil }
        return Self.cache.object(forKey: urlString as NSString)
    }

    /// Disk bytes used by URLCache.shared (the main source of the ~100 MB).
    static var diskCacheBytes: Int { URLCache.shared.currentDiskUsage }

    /// Evicts in-memory NSCache + flushes URLCache.shared disk cache.
    static func resetCache() {
        cache.removeAllObjects()
        URLCache.shared.removeAllCachedResponses()
    }

    var body: some View {
        Group {
            if let displayImage = platformImage ?? cachedImage {
                #if os(iOS)
                Image(uiImage: displayImage)
                    .resizable()
                    .scaledToFill()
                #else
                Image(nsImage: displayImage)
                    .resizable()
                    .scaledToFill()
                #endif
            } else if loadFailed {
                Rectangle().fill(Color.gray.opacity(0.3))
                    .overlay(
                        Image(systemName: "photo")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                    )
            } else {
                Color.gray.opacity(0.15)
            }
        }
        .task(id: urlString + (base64String ?? "")) {
            platformImage = nil
            loadFailed = false
            
            // Check Base64 first
            if let base64 = base64String, !base64.isEmpty,
               let data = Data(base64Encoded: base64),
               let loaded = PlatformImage(data: data) {
                platformImage = loaded
                return
            }

            guard !urlString.isEmpty, let url = URL(string: urlString) else { return }
            
            if Self.cache.object(forKey: urlString as NSString) != nil {
                return
            }
            
            guard let (data, _) = try? await Self.session.data(from: url),
                  let loaded = PlatformImage(data: data) else {
                loadFailed = true
                return
            }

            Self.cache.setObject(loaded, forKey: urlString as NSString)
            platformImage = loaded
        }
    }
}
