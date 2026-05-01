import SwiftUI

#if os(iOS)
import UIKit
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformImage = NSImage
#endif

/// Cross-platform image loader with in-memory NSCache + disk cache.
struct CachedAsyncImage: View {
    let urlString: String
    var base64String: String? = nil
    @State private var platformImage: PlatformImage?
    @State private var loadFailed = false

    private static let memCache: NSCache<NSString, PlatformImage> = {
        let c = NSCache<NSString, PlatformImage>()
        c.countLimit = 350
        return c
    }()

    private static let diskCacheDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ImageCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = 15
        return URLSession(configuration: cfg)
    }()

    private static func diskKey(for urlString: String) -> URL {
        // Safe filename from URL string
        let safe = urlString.data(using: .utf8).map { Data($0).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
        } ?? urlString.hash.description
        let ext = (urlString as NSString).pathExtension.lowercased()
        let filename = safe.prefix(180) + (["jpg","jpeg","png","webp"].contains(ext) ? ".\(ext)" : ".img")
        return diskCacheDir.appendingPathComponent(String(filename))
    }

    private static func loadFromDisk(urlString: String) -> PlatformImage? {
        let path = diskKey(for: urlString)
        guard let data = try? Data(contentsOf: path) else { return nil }
        return PlatformImage(data: data)
    }

    private static func saveToDisk(urlString: String, data: Data) {
        let path = diskKey(for: urlString)
        try? data.write(to: path, options: .atomic)
    }

    static var diskCacheBytes: Int {
        let dir = diskCacheDir
        let keys: [URLResourceKey] = [.fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys) else { return 0 }
        var total = 0
        for case let file as URL in enumerator {
            total += (try? file.resourceValues(forKeys: Set(keys)).fileSize) ?? 0
        }
        return total
    }

    static func resetCache() {
        memCache.removeAllObjects()
        if let contents = try? FileManager.default.contentsOfDirectory(at: diskCacheDir, includingPropertiesForKeys: nil) {
            for file in contents { try? FileManager.default.removeItem(at: file) }
        }
        URLCache.shared.removeAllCachedResponses()
        NotificationCenter.default.post(name: NSNotification.Name("ClearImageCache"), object: nil)
    }

    private var cachedImage: PlatformImage? {
        guard !urlString.isEmpty else { return nil }
        return Self.memCache.object(forKey: urlString as NSString)
    }

    var body: some View {
        Group {
            if let displayImage = platformImage ?? cachedImage {
                #if os(iOS)
                Image(uiImage: displayImage)
                    .resizable()
                    .scaledToFill()
                    .frame(minWidth: 0, minHeight: 0)
                    .clipped()
                #else
                Image(nsImage: displayImage)
                    .resizable()
                    .scaledToFill()
                    .frame(minWidth: 0, minHeight: 0)
                    .clipped()
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
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ClearImageCache"))) { _ in
            platformImage = nil
        }
        .task(id: urlString + (base64String ?? "")) {
            loadFailed = false

            if let base64 = base64String, !base64.isEmpty,
               let data = Data(base64Encoded: base64),
               let loaded = PlatformImage(data: data) {
                platformImage = loaded
                return
            }

            guard !urlString.isEmpty, let url = URL(string: urlString) else {
                loadFailed = true
                return
            }

            if let cached = Self.memCache.object(forKey: urlString as NSString) {
                platformImage = cached
                return
            }

            // Try disk cache before network
            if let diskImage = Self.loadFromDisk(urlString: urlString) {
                Self.memCache.setObject(diskImage, forKey: urlString as NSString)
                platformImage = diskImage
                return
            }

            platformImage = nil

            guard let (data, _) = try? await Self.session.data(from: url),
                  let loaded = PlatformImage(data: data) else {
                loadFailed = true
                return
            }

            Self.memCache.setObject(loaded, forKey: urlString as NSString)
            Self.saveToDisk(urlString: urlString, data: data)
            platformImage = loaded
        }
    }
}

// MARK: - TVDB Poster Image Wrapper

struct TVDBPosterImage: View {
    let media: Media
    var type: TVDBArtworkType = .poster
    // Only used for AniList async TVDB lookup
    @State private var tvdbURL: String?

    enum TVDBArtworkType {
        case poster, fanart
    }

    private var providerFallback: String {
        type == .fanart
            ? (media.bannerImage ?? media.coverImage.extraLarge ?? media.coverImage.large ?? "")
            : (media.coverImage.extraLarge ?? media.coverImage.large ?? "")
    }

    /// Immediate URL — TVDB cache if available, otherwise provider's native image.
    private var immediateURL: String {
        let cached = TVDBMappingService.shared.getCachedArtwork(for: media.id, provider: media.provider)
        let cachedURL = (type == .poster) ? cached.poster : cached.fanart
        return cachedURL ?? providerFallback
    }

    init(media: Media, type: TVDBArtworkType = .poster) {
        self.media = media
        self.type = type
    }

    var body: some View {
        CachedAsyncImage(urlString: tvdbURL ?? immediateURL)
            .task(id: media.uniqueId) {
                if let url = tvdbURL, !url.isEmpty { return }
                let artwork = await TVDBMappingService.shared.getArtwork(for: media.id, provider: media.provider)
                let url = (type == .poster) ? artwork.poster : artwork.fanart
                guard let url, !url.isEmpty, url != immediateURL else { return }
                tvdbURL = url
            }
    }
}
