import SwiftUI

// MARK: - ContinueWatchingSection

struct ContinueWatchingSection: View {
    let items: [ContinueWatchingItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: 3, height: 18)
                Text("Continue Watching")
                    .font(.title3.weight(.bold))
                Spacer()
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(items) { item in
                        itemView(for: item)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Per-item interaction (mirrors AnimeSection pattern)

    @ViewBuilder
    private func itemView(for item: ContinueWatchingItem) -> some View {
        if item.streamUrl.isEmpty, let aniListID = item.aniListID {
            // AniList Up Next — NavigationLink directly in ForEach, same as AnimeSection
            NavigationLink {
                AniListDetailView(mediaId: aniListID)
            } label: {
                ContinueWatchingCardDisplay(item: item)
            }
            .buttonStyle(.plain)
            .contextMenu { removeButton(for: item) }
        } else if item.streamUrl.isEmpty,
                  let href = item.detailHref,
                  item.moduleId != nil {
            // Module Up Next — NavigationLink directly in ForEach
            NavigationLink {
                DetailView(item: SearchItem(title: item.mediaTitle, image: item.imageUrl, href: href))
            } label: {
                ContinueWatchingCardDisplay(item: item)
            }
            .buttonStyle(.plain)
            .contextMenu { removeButton(for: item) }
        } else {
            Button { resume(item) } label: {
                ContinueWatchingCardDisplay(item: item)
            }
            .buttonStyle(.plain)
            .contextMenu { removeButton(for: item) }
        }
    }

    private func removeButton(for item: ContinueWatchingItem) -> some View {
        Button(role: .destructive) {
            ContinueWatchingManager.shared.remove(item)
        } label: {
            Label("Remove", systemImage: "xmark.circle")
        }
    }

    private func resume(_ item: ContinueWatchingItem) {
        guard !item.streamUrl.isEmpty, let url = URL(string: item.streamUrl) else { return }
        let stream = StreamResult(
            title: item.episodeTitle ?? "Episode \(item.episodeNumber)",
            url: url,
            headers: item.headers ?? [:],
            subtitle: item.subtitle
        )
        let context = PlayerContext(
            mediaTitle: item.mediaTitle,
            episodeNumber: item.episodeNumber,
            episodeTitle: item.episodeTitle,
            imageUrl: item.imageUrl,
            aniListID: item.aniListID,
            moduleId: item.moduleId,
            totalEpisodes: item.totalEpisodes,
            resumeFrom: item.watchedSeconds,
            detailHref: item.detailHref
        )
        #if os(iOS)
        PlayerPresenter.shared.presentPlayer(stream: stream, context: context)
        #endif
    }
}

// MARK: - Card Display (pure visual, no tap handling)

struct ContinueWatchingCardDisplay: View {
    let item: ContinueWatchingItem

    private var progress: Double {
        guard item.totalSeconds > 0 else { return 0 }
        return min(item.watchedSeconds / item.totalSeconds, 1.0)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Thumbnail — URLSession-based loader avoids AsyncImage identity issues
            CardThumbnail(urlString: item.imageUrl)
                .frame(width: 120, height: 175)
                .clipped()
                .cornerRadius(12)

            // Gradient + labels
            VStack(alignment: .leading, spacing: 2) {
                Spacer()
                Text(item.mediaTitle)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("Ep \(item.episodeNumber)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))

                if item.streamUrl.isEmpty {
                    Text("Up Next")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                } else {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.3))
                            Capsule().fill(Color.accentColor)
                                .frame(width: geo.size.width * progress)
                        }
                        .frame(height: 3)
                    }
                    .frame(height: 3)
                }
            }
            .padding(8)
            .frame(width: 120)
            .background(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.88)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .cornerRadius(12)
            )
        }
        .frame(width: 120, height: 175)
    }
}

// MARK: - Card Thumbnail

/// URLSession-based image loader. More reliable than AsyncImage in scrollable
/// containers — @State survives parent re-renders and the task only runs once
/// per URL, not re-firing on every SwiftUI update cycle.
private struct CardThumbnail: View {
    let urlString: String
    @State private var uiImage: UIImage?

    private static let cache = NSCache<NSString, UIImage>()

    var body: some View {
        Group {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.gray.opacity(0.3)
            }
        }
        .task(id: urlString) {
            guard !urlString.isEmpty, let url = URL(string: urlString) else { return }
            if let cached = Self.cache.object(forKey: urlString as NSString) {
                uiImage = cached
                return
            }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let loaded = UIImage(data: data) else { return }
            Self.cache.setObject(loaded, forKey: urlString as NSString)
            uiImage = loaded
        }
    }
}
