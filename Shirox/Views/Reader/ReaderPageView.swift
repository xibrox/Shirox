#if os(iOS)
import SwiftUI
import Kingfisher

/// A single manga page: Kingfisher-loaded, aspect-fit, with a placeholder
/// while loading and a tap-to-retry error state. `referer` is the SOURCE
/// SITE's origin (not the image host) — manga CDNs hotlink-protect against it.
struct ReaderPageView: View {
    let urlString: String
    let referer: String
    let pageNumber: Int

    @State private var image: UIImage?
    @State private var failed = false
    @State private var attempt = 0

    /// Shared Kingfisher pipeline for reader pages (also used by the
    /// next-chapter prefetch warmer — MUST stay identical or the cache keys
    /// won't match). Downsamples to screen width and decodes off-main:
    /// manga pages are often 2-3x larger than needed, and decoding them
    /// full-size on the main thread stutters fast/auto scrolling.
    static func imageOptions(referer: String, for url: URL) -> KingfisherOptionsInfo {
        let cookieHeader = url.host.flatMap { CloudflareBypassManager.shared.fullCookieHeader(for: $0) }
        let bypassUA = url.host.flatMap { CloudflareBypassManager.shared.bypassUserAgent(for: $0) }
        let reqHeaders = KingfisherImageCache.headers(
            for: url, cookieHeader: cookieHeader, bypassUserAgent: bypassUA,
            refererOverride: referer)
        let modifier = AnyModifier { request in
            var mutable = request
            for (key, value) in reqHeaders { mutable.setValue(value, forHTTPHeaderField: key) }
            return mutable
        }
        let screen = UIScreen.main.bounds
        // Generous height headroom so tall webtoon strips keep their detail.
        let target = CGSize(width: screen.width, height: screen.width * 6)
        return [
            .requestModifier(modifier),
            .processor(DownsamplingImageProcessor(size: target)),
            .scaleFactor(UIScreen.main.scale),
            .backgroundDecode,
            .cacheOriginalImage,
        ]
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if failed {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.7))
                    Text("Page \(pageNumber) failed to load")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                    Text("Tap to retry")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.45))
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(2/3, contentMode: .fit)
                .contentShape(Rectangle())
                .onTapGesture {
                    failed = false
                    attempt += 1
                }
            } else {
                ZStack {
                    Color.white.opacity(0.06)
                    ProgressView()
                        .tint(.white.opacity(0.6))
                }
                .aspectRatio(2/3, contentMode: .fit)
            }
        }
        .task(id: "\(urlString)#\(attempt)") { await load() }
    }

    @MainActor
    private func load() async {
        guard let url = URL(string: urlString) else {
            failed = true
            return
        }
        let options = Self.imageOptions(referer: referer, for: url)
        // Options-aware lookup: the downsampling processor is part of the key.
        if let cached = ImageCache.default.retrieveImageInMemoryCache(forKey: urlString, options: options) {
            image = cached
            return
        }
        let resource = Kingfisher.ImageResource(downloadURL: url, cacheKey: urlString)
        let result: UIImage? = await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
            KingfisherManager.shared.retrieveImage(with: resource, options: options) {
                cont.resume(returning: try? $0.get().image)
            }
        }
        if let result {
            image = result
        } else {
            failed = true
        }
    }
}
#endif
