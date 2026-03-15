#if os(iOS)
import SwiftUI

/// URLSession + NSCache image loader. Avoids AsyncImage's re-fetch-on-render
/// behavior in LazyHStack/LazyVGrid scroll containers.
struct CachedAsyncImage: View {
    let urlString: String
    @State private var uiImage: UIImage?
    @State private var loadFailed = false

    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 150
        return c
    }()

    var body: some View {
        Group {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
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
        .task(id: urlString) {
            loadFailed = false
            guard !urlString.isEmpty, let url = URL(string: urlString) else { return }
            if let cached = Self.cache.object(forKey: urlString as NSString) {
                uiImage = cached
                return
            }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let loaded = UIImage(data: data) else {
                loadFailed = true
                return
            }
            Self.cache.setObject(loaded, forKey: urlString as NSString)
            uiImage = loaded
        }
    }
}
#endif
