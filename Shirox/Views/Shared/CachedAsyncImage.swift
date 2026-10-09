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
/// headers, solved Cloudflare sessions, base64 and `file://` fast paths.
struct CachedAsyncImage: View {
    let urlString: String
    var base64String: String? = nil
    /// `.fill` (the default) crops to fill its frame — what every thumbnail and
    /// hero wants. `.fit` shows the whole image uncropped, for the full-poster viewer.
    var contentMode: SwiftUI.ContentMode = .fill
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

    /// `resetCache`, returning once the files are gone. Kingfisher deletes them in the
    /// background, so Settings measured the cache straight after a reset, before anything was
    /// deleted, and showed the same size as if the reset had done nothing.
    static func resetCacheAndWait() async {
        ImageCache.default.clearMemoryCache()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ImageCache.default.clearDiskCache { continuation.resume() }
        }
        URLCache.shared.removeAllCachedResponses()
        NotificationCenter.default.post(name: NSNotification.Name("ClearImageCache"), object: nil)
    }

    /// The one place that bridges `PlatformImage` into SwiftUI's `Image`.
    private static func image(from platformImage: PlatformImage) -> Image {
        #if os(macOS)
        Image(nsImage: platformImage)
        #else
        Image(uiImage: platformImage)
        #endif
    }

    var body: some View {
        Group {
            if let displayImage = platformImage {
                if contentMode == .fill {
                    Self.image(from: displayImage)
                        .resizable()
                        .scaledToFill()
                        .frame(minWidth: 0, minHeight: 0)
                        .clipped()
                } else {
                    Self.image(from: displayImage)
                        .resizable()
                        .scaledToFit()
                }
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
        // Clear the previous image when the key changes so a recycled row (e.g. a
        // LazyVStack/LazyVGrid cell reused for a different item) can't keep showing
        // the old thumbnail while the new one loads. The sync fast paths below
        // (base64/file/in-memory) overwrite this before SwiftUI renders, so warm
        // hits still paint with no blank frame; only the async network path shows
        // the placeholder instead of a stale image.
        platformImage = nil

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
        // (an HTML body that won't decode). Retry with any solved session for the
        // host, then back-fill Kingfisher's cache so later loads are warm.
        if let recovered = await loadViaCloudflareFallback(url: url) {
            platformImage = recovered
        } else {
            loadFailed = true
        }
    }

    /// Direct fetch of one image URL with any solved Cloudflare session for its host. Returns
    /// the decoded image on success and seeds Kingfisher's cache so later loads are warm.
    /// Returns nil on failure (offline, 4xx, undecodable, or still walled).
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

        // Walled by Cloudflare. An image never opens the challenge window itself: posters load
        // on their own (Home at launch, list rows), so the window popped up unprompted, and the
        // load was usually cancelled by a re-layout a moment later, closing it again — a flash
        // that never solved anything. Show the placeholder instead; `.cloudflareBypassSolved`
        // retries it once the user clears this host somewhere they asked to.
        if JSEngine.isTurnstileResponse(status: httpStatus, body: responseText) {
            let cfHost = finalURL.host ?? ""
            // We sent this host's cached cookie and got walled anyway, so it's dead.
            if cookieHeader != nil { CloudflareBypassManager.shared.invalidateCookie(for: cfHost) }
            Logger.shared.log("[Image] CF challenge, not loading host=\(cfHost) status=\(httpStatus)", type: "Debug")
            return nil
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
    var contentMode: SwiftUI.ContentMode = .fill
    // Only used for AniList async TVDB lookup
    @State private var tvdbURL: String?

    enum TVDBArtworkType {
        case poster, fanart, textlessPoster, logo
    }

    private var providerFallback: String {
        switch type {
        case .fanart:
            return media.bannerImage ?? media.coverImage.extraLarge ?? media.coverImage.large ?? ""
        case .poster, .textlessPoster:
            return media.coverImage.extraLarge ?? media.coverImage.large ?? ""
        case .logo:
            return ""
        }
    }

    /// Immediate URL — TVDB cache if available, otherwise provider's native image.
    private var immediateURL: String {
        guard media.usesTVDBArtwork else { return providerFallback }
        let cached = TVDBMappingService.shared.getCachedArtwork(for: media.id, provider: media.provider)
        let cachedURL: String?
        switch type {
        case .poster: cachedURL = cached.poster
        case .fanart: cachedURL = cached.fanart
        case .textlessPoster: cachedURL = cached.textlessPoster ?? cached.poster
        case .logo: cachedURL = cached.logo
        }
        return cachedURL ?? providerFallback
    }

    init(media: Media, type: TVDBArtworkType = .poster, contentMode: SwiftUI.ContentMode = .fill) {
        self.media = media
        self.type = type
        self.contentMode = contentMode
    }

    var body: some View {
        CachedAsyncImage(urlString: tvdbURL ?? immediateURL, contentMode: contentMode)
            .task(id: media.uniqueId) {
                guard media.usesTVDBArtwork else { return }
                if let url = tvdbURL, !url.isEmpty { return }
                let artwork = await TVDBMappingService.shared.getArtwork(for: media.id, provider: media.provider)
                let resolvedURL: String?
                switch type {
                case .poster: resolvedURL = artwork.poster
                case .fanart: resolvedURL = artwork.fanart
                case .textlessPoster: resolvedURL = artwork.textlessPoster ?? artwork.poster
                case .logo: resolvedURL = artwork.logo
                }
                guard let resolvedURL, !resolvedURL.isEmpty, resolvedURL != immediateURL else { return }
                tvdbURL = resolvedURL
            }
    }
}

// MARK: - TVDB Title Logo View (Image Title with Text Fallback)

struct TVDBTitleLogoView: View {
    let media: Media
    var maxHeight: CGFloat = 135
    var maxWidth: CGFloat = 360
    var alignment: Alignment = .center

    @State private var tvdbLogoURL: String?

    private var immediateLogoURL: String? {
        if media.simklTitleKind != nil { return SimklTitleLogo.cached(for: media) }
        guard media.usesTVDBArtwork else { return nil }
        let direct = TVDBMappingService.shared.getCachedArtwork(for: media.id, provider: media.provider).logo
        if let direct, !direct.isEmpty { return direct }
        if let parentId = media.parentAnimeId {
            let parentCached = TVDBMappingService.shared.getCachedArtwork(for: parentId, provider: media.provider).logo
            if let parentCached, !parentCached.isEmpty { return parentCached }
        }
        return nil
    }

    private var resolvedURL: String? {
        tvdbLogoURL ?? immediateLogoURL
    }

    var body: some View {
        Group {
            if let url = resolvedURL, !url.isEmpty {
                CachedAsyncImage(urlString: url, contentMode: .fit)
                    .frame(maxWidth: maxWidth, maxHeight: maxHeight, alignment: alignment)
                    .shadow(color: .black.opacity(0.6), radius: 8, x: 0, y: 3)
            } else {
                Text(media.title.displayTitle)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(alignment == .leading ? .leading : .center)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.4), radius: 4, x: 0, y: 1)
            }
        }
        .allowsHitTesting(false)
        .task(id: media.uniqueId) {
            tvdbLogoURL = immediateLogoURL
            if media.simklTitleKind != nil {
                if let logo = await SimklTitleLogo.find(for: media) { tvdbLogoURL = logo }
                return
            }
            guard media.usesTVDBArtwork else { return }
            let artwork = await TVDBMappingService.shared.getArtwork(for: media.id, provider: media.provider)
            if let logo = artwork.logo, !logo.isEmpty {
                tvdbLogoURL = logo
            } else {
                let parentId: Int?
                if let directParent = media.parentAnimeId {
                    parentId = directParent
                } else {
                    parentId = await TVDBMappingService.shared.getParentAnimeId(for: media.id, provider: media.provider)
                }
                if let parentId {
                    let parentArt = await TVDBMappingService.shared.getArtwork(for: parentId, provider: media.provider)
                    if let parentLogo = parentArt.logo, !parentLogo.isEmpty {
                        tvdbLogoURL = parentLogo
                    }
                }
            }
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
            // A Mac sheet has no detents, and a List or Form in one has no size of its own.
            return AnyView(self.macSheetFrame())
            #endif
        } else {
            return AnyView(self)
        }
    }
}
