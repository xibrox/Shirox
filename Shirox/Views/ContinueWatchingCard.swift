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
        if item.streamUrl.isEmpty, let aniListID = item.aniListID {
            // AniList Up Next — navigate to detail to pick episode
            NavigationLink {
                AniListDetailView(mediaId: aniListID, preloadedMedia: nil, resumeEpisodeNumber: item.episodeNumber, resumeWatchedSeconds: item.watchedSeconds)
            } label: {
                ContinueWatchingCardDisplay(item: item)
            }
            .buttonStyle(.plain)
            .contextMenu { removeButton(for: item) }
        } else if item.streamUrl.isEmpty, let href = item.detailHref, let mid = item.moduleId {
            // Module Up Next — navigate to detail, activating the correct module first
            NavigationLink {
                DetailView(item: SearchItem(title: item.mediaTitle, image: item.imageUrl, href: href), resumeEpisodeNumber: item.episodeNumber, resumeWatchedSeconds: item.watchedSeconds, moduleId: mid)
            } label: {
                ContinueWatchingCardDisplay(item: item)
            }
            .buttonStyle(.plain)
            .contextMenu { removeButton(for: item) }
        } else {
            // In-progress item — resume directly with stored URL; PlayerView re-fetches if expired
            Button { resume(item) } label: {
                ContinueWatchingCardDisplay(item: item)
            }
            .buttonStyle(.plain)
            .contextMenu { removeButton(for: item) }
        }
    }

    private func resume(_ item: ContinueWatchingItem) {
        guard !item.streamUrl.isEmpty, let url = URL(string: item.streamUrl) else { return }
        
        // Ensure the correct module is active
        if let mid = item.moduleId, let module = ModuleManager.shared.modules.first(where: { $0.id == mid }) {
            ModuleManager.shared.selectModule(module)
        }
        
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
        let epNum = item.episodeNumber
        let detailHref = item.detailHref
        let mediaTitle = item.mediaTitle
        let mid = item.moduleId

        // Helper to get episodes list (either via href or search fallback)
        let fetchEpisodes: () async throws -> [EpisodeLink] = {
            if let href = detailHref {
                return try await JSEngine.shared.fetchEpisodes(url: href)
            } else if item.moduleId != nil {
                // AniList fallback: find the item in the module by title
                let results = try await JSEngine.shared.search(keyword: mediaTitle)
                // Try exact match then fuzzy
                let match = results.first { $0.title.lowercased() == mediaTitle.lowercased() } ?? results.first
                if let href = match?.href {
                    return try await JSEngine.shared.fetchEpisodes(url: href)
                }
            }
            return []
        }

        // Re-fetch current episode streams when stored URL expires
        let onExpired: StreamRefetchLoader? = {
            return {
                let episodes = try await fetchEpisodes()
                guard let episode = episodes.first(where: { Int($0.number) == epNum }) else { return [] }
                return try await JSEngine.shared.fetchStreams(episodeUrl: episode.href).sorted { $0.title < $1.title }
            }
        }()

        // Load next episode streams (enables the Next Episode button)
        let onWatchNext: WatchNextLoader? = {
            return { currentEpNum in
                let episodes = try await fetchEpisodes()
                guard let idx = episodes.firstIndex(where: { Int($0.number) == currentEpNum }),
                      idx + 1 < episodes.count else { return nil }
                let nextEp = episodes[idx + 1]
                let streams = try await JSEngine.shared.fetchStreams(episodeUrl: nextEp.href).sorted { $0.title < $1.title }
                guard !streams.isEmpty else { return nil }
                return (streams: streams, episodeNumber: Int(nextEp.number))
            }
        }()

        #if os(iOS)
        PlayerPresenter.shared.presentPlayer(stream: stream, context: context, onWatchNext: onWatchNext, onStreamExpired: onExpired)
        #endif
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
                CachedAsyncImage(urlString: item.imageUrl)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            )
            .overlay(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.5),
                        .init(color: .black.opacity(0.92), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.mediaTitle)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    
                    HStack(spacing: 4) {
                        if !item.streamUrl.isEmpty {
                            Image(systemName: "play.fill")
                                .font(.system(size: 8, weight: .bold))
                            
                            Text(item.totalEpisodes != nil ? "Ep \(item.episodeNumber) / \(item.totalEpisodes!)" : "Ep \(item.episodeNumber)")
                                .font(.caption2.weight(.medium))
                        } else {
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.system(size: 10, weight: .bold))
                            
                            Text("Up Next")
                                .font(.caption2.weight(.bold))
                        }
                    }
                    .foregroundStyle(.white.opacity(0.85))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, item.streamUrl.isEmpty ? 12 : 16)
            }
            .overlay(alignment: .bottom) {
                if !item.streamUrl.isEmpty {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Color.white.opacity(0.2)
                            Color.accentColor
                                .frame(width: geo.size.width * progress)
                                .shadow(color: Color.accentColor.opacity(0.5), radius: 3, x: 0, y: 0)
                        }
                    }
                    .frame(height: 4)
                }
            }
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
