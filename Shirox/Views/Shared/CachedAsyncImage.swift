import SwiftUI
import Kingfisher

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

/// Cross-platform image loader backed by Kingfisher's memory + disk cache.
/// Keeps the app's domain logic that a stock loader doesn't handle: hotlink
/// headers, Cloudflare-bypass recovery, base64 and `file://` fast paths.
struct CachedAsyncImage: View {
    let urlString: String
    var base64String: String? = nil
    @State private var platformImage: PlatformImage?
    @State private var loadFailed = false
    @State private var reloadToken = 0

    /// URLSession used *only* by the Cloudflare fallback path. Kingfisher owns
    /// all normal downloads + caching.
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = 15
        return URLSession(configuration: cfg)
    }()

    /// Build a fallback image-fetch request with browser-like headers (+ CF
    /// cookie/UA when supplied). Shares the header set with the Kingfisher path.
    private static func makeImageRequest(for url: URL, cookieHeader: String? = nil, bypassUserAgent: String? = nil) -> URLRequest {
        var req = URLRequest(url: url)
        for (key, value) in KingfisherImageCache.headers(for: url, cookieHeader: cookieHeader, bypassUserAgent: bypassUserAgent) {
            req.setValue(value, forHTTPHeaderField: key)
        }
        return req
    }

    /// Read the raw bytes Kingfisher holds on disk for `urlString`, if any.
    /// Lets other subsystems (e.g. the snapshot store, provider banner) reuse
    /// already-downloaded images instead of re-fetching from the network.
    static func cachedImageData(for urlString: String) -> Data? {
        try? KingfisherManager.shared.cache.diskStorage.value(forKey: urlString)
    }

    static var diskCacheBytes: Int {
        get async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
                ImageCache.default.calculateDiskStorageSize { result in
                    continuation.resume(returning: Int((try? result.get()) ?? 0))
                }
            }
        }
    }

    static func resetCache() {
        ImageCache.default.clearMemoryCache()
        ImageCache.default.clearDiskCache()
        URLCache.shared.removeAllCachedResponses()
        NotificationCenter.default.post(name: NSNotification.Name("ClearImageCache"), object: nil)
    }

    var body: some View {
        Group {
            if let displayImage = platformImage {
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
            await load()
        }
    }

    @MainActor
    private func load() async {
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

        // Local file fast path: read bytes directly. Avoids running the CF
        // pipeline and avoids writing a duplicate copy into Kingfisher's cache
        // for an image already sitting on local disk.
        if url.isFileURL {
            if let loaded = PlatformImage(contentsOfFile: url.path) {
                platformImage = loaded
            } else {
                loadFailed = true
            }
            return
        }

        // Instant paint if Kingfisher already has it in memory (no flicker).
        if let memoryImage = ImageCache.default.retrieveImageInMemoryCache(forKey: urlString) {
            platformImage = memoryImage
            return
        }

        // Resolve CF cookie/UA on the MainActor, then hand Kingfisher a
        // value-type request modifier (its downloader runs off-main).
        let cookieHeader = url.host.flatMap { CloudflareBypassManager.shared.fullCookieHeader(for: $0) }
        let bypassUA = url.host.flatMap { CloudflareBypassManager.shared.bypassUserAgent(for: $0) }
        let reqHeaders = KingfisherImageCache.headers(for: url, cookieHeader: cookieHeader, bypassUserAgent: bypassUA)
        let modifier = AnyModifier { request in
            var mutable = request
            for (key, value) in reqHeaders { mutable.setValue(value, forHTTPHeaderField: key) }
            return mutable
        }
        // Key on `urlString` so `cachedImageData(for:)` and the snapshot store
        // find the same entry the display path wrote.
        let resource = Kingfisher.ImageResource(downloadURL: url, cacheKey: urlString)

        let kfImage: PlatformImage? = await withCheckedContinuation { (continuation: CheckedContinuation<PlatformImage?, Never>) in
            KingfisherManager.shared.retrieveImage(
                with: resource,
                options: [.requestModifier(modifier)]
            ) { result in
                continuation.resume(returning: try? result.get().image)
            }
        }

        if let kfImage {
            platformImage = kfImage
            return
        }

        // Kingfisher couldn't load it — most often a cold Cloudflare challenge
        // (an HTML body that won't decode). Fall back to the manual solve+retry,
        // then back-fill Kingfisher's cache so later loads are warm.
        if let recovered = await loadViaCloudflareFallback(url: url) {
            platformImage = recovered
        } else {
            loadFailed = true
        }
    }

    /// Manual Cloudflare-challenge recovery for a single image URL. Returns the
    /// decoded image on success and seeds Kingfisher's cache so later loads are
    /// warm. Returns nil on genuine failure (offline, 4xx, undecodable).
    private func loadViaCloudflareFallback(url: URL) async -> PlatformImage? {
        let cookieHeader = url.host.flatMap { CloudflareBypassManager.shared.fullCookieHeader(for: $0) }
        let bypassUA = url.host.flatMap { CloudflareBypassManager.shared.bypassUserAgent(for: $0) }
        var imageRequest = Self.makeImageRequest(for: url, cookieHeader: cookieHeader, bypassUserAgent: bypassUA)
        // If this host was CF-bypassed, use the WebView's UA + cookies so the
        // cf_clearance binding (UA + IP + cookie) matches.
        if let host = url.host,
           let info = await CloudflareBypassManager.shared.bypassSessionInfo(for: host) {
            imageRequest.setValue(info.cookieHeader, forHTTPHeaderField: "Cookie")
            if !info.userAgent.isEmpty {
                imageRequest.setValue(info.userAgent, forHTTPHeaderField: "User-Agent")
            }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: imageRequest)
        } catch {
            // Silent for true offline failures and cancellations (routine when a
            // cell scrolls offscreen). Everything else surfaces for debugging.
            let isCancelled = (error as? URLError)?.code == .cancelled || error is CancellationError
            if !ProviderManager.isOfflineError(error) && !isCancelled {
                Logger.shared.log("[Image] network error for \(url.host ?? url.absoluteString): \(error.localizedDescription)", type: "Error")
            }
            return nil
        }

        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 200
        let finalURL = (response as? HTTPURLResponse)?.url ?? url
        let isImageContentType = ((response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type") ?? "")
            .lowercased().hasPrefix("image/")
        let responseText = isImageContentType ? "" : (String(data: data, encoding: .utf8) ?? "")

        // If CF blocked the image CDN, solve the challenge for that host then
        // retry with the fresh cookie.
        if JSEngine.isTurnstileResponse(status: httpStatus, body: responseText) {
            Logger.shared.log("[Image] CF challenge detected status=\(httpStatus) host=\(finalURL.host ?? "?")", type: "Debug")
            let cfTarget = finalURL
            let cfHostStr = cfTarget.host ?? ""

            if CloudflareBypassManager.shared.fullCookieHeader(for: cfHostStr) == nil {
                try? await CloudflareBypassManager.shared.triggerBypass(for: cfTarget)
            }

            var retryRequest = Self.makeImageRequest(for: cfTarget)
            // cf_clearance is bound to the UA that solved the challenge — use the
            // bypass WebView's actual UA + full cookie header, not our default.
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
                return nil
            }
            guard let loaded = PlatformImage(data: retryData) else {
                let st = (retryResponse as? HTTPURLResponse)?.statusCode ?? -1
                let snippet = (String(data: retryData, encoding: .utf8) ?? "").prefix(120)
                Logger.shared.log("[Image] CF retry decode failed host=\(cfHostStr) status=\(st) body=\(snippet)", type: "Error")
                return nil
            }
            KingfisherManager.shared.cache.store(loaded, original: retryData, forKey: urlString, toDisk: true) { _ in }
            return loaded
        }

        guard let loaded = PlatformImage(data: data) else {
            let snippet = responseText.prefix(160).replacingOccurrences(of: "\n", with: " ")
            Logger.shared.log("[Image] decode failed status=\(httpStatus) host=\(url.host ?? "?") len=\(data.count) body=\(snippet)", type: "Error")
            return nil
        }

        KingfisherManager.shared.cache.store(loaded, original: data, forKey: urlString, toDisk: true) { _ in }
        return loaded
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
