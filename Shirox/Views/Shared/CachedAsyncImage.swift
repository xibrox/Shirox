import SwiftUI

#if os(iOS)
import UIKit
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformImage = NSImage
#endif

/// Cross-platform URLSession + NSCache image loader.
struct CachedAsyncImage: View {
    let urlString: String
    @State private var platformImage: PlatformImage?
    @State private var loadFailed = false

    private static let cache: NSCache<NSString, PlatformImage> = {
        let c = NSCache<NSString, PlatformImage>()
        // Increased limit for better coverage of new posters
        c.countLimit = 350
        return c
    }()

    /// Total compressed bytes currently stored in the shared cache.
    private(set) static var totalBytes: Int = 0

    /// Evicts all cached images and resets the size counter.
    static func resetCache() {
        cache.removeAllObjects()
        totalBytes = 0
    }

    var body: some View {
        Group {
            if let platformImage {
                #if os(iOS)
                Image(uiImage: platformImage)
                    .resizable()
                    .scaledToFill()
                #else
                Image(nsImage: platformImage)
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
        .task(id: urlString) {
            loadFailed = false
            guard !urlString.isEmpty, let url = URL(string: urlString) else { return }
            
            if let cached = Self.cache.object(forKey: urlString as NSString) {
                platformImage = cached
                return
            }
            
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let loaded = PlatformImage(data: data) else {
                loadFailed = true
                return
            }
            
            Self.cache.setObject(loaded, forKey: urlString as NSString)
            Self.totalBytes += data.count
            platformImage = loaded
        }
    }
}
