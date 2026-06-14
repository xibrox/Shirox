import SwiftUI

#if os(iOS)
import UIKit
typealias PlatformImage = UIImage
#elseif os(tvOS)
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
    @State private var reloadToken = 0

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

    private static let defaultUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    /// Build an image-fetch request with browser-like headers. Many anime CDNs
    /// hotlink-protect with a Referer requirement and reject the default
    /// URLSession UA — sending these by default is harmless for hosts that don't.
    private static func makeImageRequest(for url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue(defaultUserAgent, forHTTPHeaderField: "User-Agent")
        if let scheme = url.scheme, let host = url.host {
            req.setValue("\(scheme)://\(host)/", forHTTPHeaderField: "Referer")
        }
        req.setValue("image/avif,image/webp,image/png,image/jpeg,*/*", forHTTPHeaderField: "Accept")
        return req
    }

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

    /// Read the raw bytes that disk-cache holds for `urlString`, if any.
    /// Lets other subsystems (e.g. the snapshot store) reuse already-downloaded images
    /// instead of re-fetching from the network.
    static func cachedImageData(for urlString: String) -> Data? {
        let path = diskKey(for: urlString)
        return try? Data(contentsOf: path)
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
                #elseif os(tvOS)
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
        .onReceive(NotificationCenter.default.publisher(for: .cloudflareBypassSolved)) { _ in
            // A challenge was just solved — retry images that are showing a placeholder.
            if platformImage == nil { reloadToken += 1 }
        }
        .task(id: urlString + (base64String ?? "") + "#\(reloadToken)") {
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

            // Local file fast path: read bytes directly. The URLSession pipeline below
            // does technically support file:// URLs, but it also runs the CF-bypass
            // logic and writes a duplicate copy into the disk-cache folder under a
            // base64-encoded key — neither of which makes sense for an image already
            // sitting on local disk. Reading directly also makes it obvious in logs
            // whether a snapshot file is the source of a render.
            if url.isFileURL {
                if let loaded = PlatformImage(contentsOfFile: url.path) {
                    Self.memCache.setObject(loaded, forKey: urlString as NSString)
                    platformImage = loaded
                } else {
                    loadFailed = true
                }
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

            var imageRequest = Self.makeImageRequest(for: url)
            // If this host was CF-bypassed, use the WebView's UA + cookies so the
            // cf_clearance binding (UA + IP + cookie) matches.
            if let host = url.host,
               let info = await CloudflareBypassManager.shared.bypassSessionInfo(for: host) {
                imageRequest.setValue(info.cookieHeader, forHTTPHeaderField: "Cookie")
                if !info.userAgent.isEmpty {
                    imageRequest.setValue(info.userAgent, forHTTPHeaderField: "User-Agent")
                }
            } else if let host = url.host,
                      let cfHeader = CloudflareBypassManager.shared.fullCookieHeader(for: host) {
                imageRequest.setValue(cfHeader, forHTTPHeaderField: "Cookie")
                if let ua = CloudflareBypassManager.shared.bypassUserAgent(for: host) {
                    imageRequest.setValue(ua, forHTTPHeaderField: "User-Agent")
                }
            }

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await Self.session.data(for: imageRequest)
            } catch {
                // Silent for true offline failures — that's expected when the device
                // has no network. Also silent for cancellations, which happen routinely
                // when a cell scrolls offscreen before its image finishes loading.
                // Everything else (DNS failure on a single host, server errors, etc.)
                // still surfaces so we can debug it.
                let isCancelled = (error as? URLError)?.code == .cancelled || error is CancellationError
                if !ProviderManager.isOfflineError(error) && !isCancelled {
                    Logger.shared.log("[Image] network error for \(url.host ?? urlString): \(error.localizedDescription)", type: "Error")
                }
                loadFailed = true
                return
            }

            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 200
            let finalURL = (response as? HTTPURLResponse)?.url ?? url
            let isImageContentType = ((response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Content-Type") ?? "")
                .lowercased().hasPrefix("image/")
            let responseText = isImageContentType ? "" : (String(data: data, encoding: .utf8) ?? "")

            // If CF blocked the image CDN, solve the challenge for that host (deduped across a
            // grid of posters so only one sheet appears) then retry with the fresh cookie.
            if JSEngine.isTurnstileResponse(status: httpStatus, body: responseText) {
                Logger.shared.log("[Image] CF challenge detected status=\(httpStatus) host=\(finalURL.host ?? "?")", type: "Debug")
                let cfTarget = finalURL
                let cfHostStr = cfTarget.host ?? ""

                if CloudflareBypassManager.shared.fullCookieHeader(for: cfHostStr) == nil {
                    try? await CloudflareBypassManager.shared.triggerBypass(for: cfTarget)
                }

                var retryRequest = Self.makeImageRequest(for: cfTarget)
                // cf_clearance is bound to the UA that solved the challenge —
                // use the bypass WebView's actual UA + full cookie header, not our default.
                if let info = await CloudflareBypassManager.shared.bypassSessionInfo(for: cfHostStr) {
                    retryRequest.setValue(info.cookieHeader, forHTTPHeaderField: "Cookie")
                    if !info.userAgent.isEmpty {
                        retryRequest.setValue(info.userAgent, forHTTPHeaderField: "User-Agent")
                    }
                } else if let cfHeader = CloudflareBypassManager.shared.fullCookieHeader(for: cfHostStr) {
                    retryRequest.setValue(cfHeader, forHTTPHeaderField: "Cookie")
                    if let ua = CloudflareBypassManager.shared.bypassUserAgent(for: cfHostStr) {
                        retryRequest.setValue(ua, forHTTPHeaderField: "User-Agent")
                    }
                }
                guard let (retryData, retryResponse) = try? await Self.session.data(for: retryRequest) else {
                    Logger.shared.log("[Image] CF retry network error host=\(cfHostStr)", type: "Error")
                    loadFailed = true
                    return
                }
                guard let loaded = PlatformImage(data: retryData) else {
                    let st = (retryResponse as? HTTPURLResponse)?.statusCode ?? -1
                    let snippet = (String(data: retryData, encoding: .utf8) ?? "").prefix(120)
                    Logger.shared.log("[Image] CF retry decode failed host=\(cfHostStr) status=\(st) body=\(snippet)", type: "Error")
                    loadFailed = true
                    return
                }
                Self.memCache.setObject(loaded, forKey: urlString as NSString)
                Self.saveToDisk(urlString: urlString, data: retryData)
                platformImage = loaded
                return
            }

            guard let loaded = PlatformImage(data: data) else {
                let snippet = responseText.prefix(160).replacingOccurrences(of: "\n", with: " ")
                Logger.shared.log("[Image] decode failed status=\(httpStatus) host=\(url.host ?? "?") len=\(data.count) body=\(snippet)", type: "Error")
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

extension View {
    func adaptivePresentationDetents(_ detents: Set<PresentationDetent>) -> some View {
        if #available(iOS 16, *) {
            let system = Set(detents.map { $0.asSystemDetent })
            #if os(iOS)
            return AnyView(self.presentationDetents(UIDevice.current.userInterfaceIdiom == .pad ? [SwiftUI.PresentationDetent.large] : system))
            #elseif os(tvOS)
            return AnyView(self.presentationDetents(system))
            #else
            return AnyView(self.presentationDetents(system))
            #endif
        } else {
            return AnyView(self)
        }
    }
}
