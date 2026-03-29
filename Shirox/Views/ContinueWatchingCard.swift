import SwiftUI

// MARK: - ContinueWatchingSection

struct ContinueWatchingSection: View {
    let items: [ContinueWatchingItem]
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var cardWidth: CGFloat {
        sizeClass == .regular ? 190 : 155
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Continue Watching")
                        .font(.title2.weight(.heavy))
                        .tracking(0.3)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor.opacity(0.9))
                        .frame(width: 36, height: 3)
                }
                Spacer()
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(items) { item in
                        itemView(for: item)
                            .frame(width: cardWidth)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Per-item interaction (mirrors AnimeSection pattern)

    @ViewBuilder
    private func itemView(for item: ContinueWatchingItem) -> some View {
        if let aniListID = item.aniListID {
            // AniList item (Up Next or in-progress) — fetch fresh streams via detail view
            NavigationLink {
                AniListDetailView(mediaId: aniListID, resumeEpisodeNumber: item.episodeNumber, resumeWatchedSeconds: item.watchedSeconds)
            } label: {
                ContinueWatchingCardDisplay(item: item)
            }
            .buttonStyle(.plain)
            .contextMenu { removeButton(for: item) }
        } else if let href = item.detailHref, item.moduleId != nil {
            // Module item (Up Next or in-progress) — fetch fresh streams via detail view
            NavigationLink {
                DetailView(item: SearchItem(title: item.mediaTitle, image: item.imageUrl, href: href), resumeEpisodeNumber: item.episodeNumber, resumeWatchedSeconds: item.watchedSeconds)
            } label: {
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
}

// MARK: - Card Display (pure visual, no tap handling)

struct ContinueWatchingCardDisplay: View {
    let item: ContinueWatchingItem

    private var progress: Double {
        guard item.totalSeconds > 0 else { return 0 }
        return min(item.watchedSeconds / item.totalSeconds, 1.0)
    }

    var body: some View {
        Color.clear
            .aspectRatio(2/3, contentMode: .fit)
            .overlay(
                ZStack(alignment: .bottom) {
                    CardThumbnail(urlString: item.imageUrl)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()

                    // Gradient + labels (same style as AniListCardView)
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.5),
                            .init(color: .black.opacity(0.92), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.mediaTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
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
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 4)
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
