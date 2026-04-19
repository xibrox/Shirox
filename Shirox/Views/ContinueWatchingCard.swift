import SwiftUI

// MARK: - ContinueWatchingSection

struct ContinueWatchingSection: View {
    let items: [ContinueWatchingItem]
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var cardWidth: CGFloat {
        sizeClass == .regular ? 260 : 210
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
                DetailView(item: SearchItem(title: item.mediaTitle, image: item.imageUrl, href: href), resumeEpisodeNumber: item.episodeNumber, resumeWatchedSeconds: item.watchedSeconds, moduleId: mid, aniListID: item.aniListID)
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
            availableEpisodes: item.availableEpisodes,
            isAiring: item.isAiring,
            resumeFrom: item.watchedSeconds,
            detailHref: item.detailHref,
            streamTitle: item.streamTitle,
            workingDetailHref: item.detailHref,
            thumbnailUrl: item.thumbnailUrl
        )

        // Setup Next Episode loader using ModuleJSRunner (if module) or JSEngine (if AniList)
        let onWatchNext: WatchNextLoader? = { currentEpNum in
            print("[ContinueWatching] onWatchNext called for episode \(currentEpNum), item.moduleId=\(item.moduleId ?? "nil"), item.detailHref=\(item.detailHref ?? "nil")")

            // For module-sourced items
            if let moduleId = item.moduleId, let module = ModuleManager.shared.modules.first(where: { $0.id == moduleId }) {
                print("[ContinueWatching] Using ModuleJSRunner path")
                do {
                    let runner = ModuleJSRunner()
                    try await runner.load(module: module)

                    // Fetch episodes via detailHref or search
                    var episodes: [EpisodeLink] = []
                    if let href = item.detailHref {
                        print("[ContinueWatching] Fetching episodes from detailHref: \(href)")
                        episodes = try await runner.fetchEpisodes(url: href)
                    } else {
                        print("[ContinueWatching] Searching for: \(item.mediaTitle)")
                        let results = try await runner.search(keyword: item.mediaTitle)
                        print("[ContinueWatching] Search returned \(results.count) results")
                        if let match = results.first {
                            print("[ContinueWatching] Fetching episodes from first search result")
                            episodes = try await runner.fetchEpisodes(url: match.href)
                        }
                    }

                    print("[ContinueWatching] Got \(episodes.count) episodes")
                    guard !episodes.isEmpty else {
                        print("[ContinueWatching] No episodes found")
                        return nil
                    }

                    // Find current episode
                    var idx = episodes.firstIndex(where: { Int($0.number) == currentEpNum })
                    if idx == nil {
                        print("[ContinueWatching] Exact episode not found, finding closest match")
                        idx = episodes.enumerated().min(by: {
                            abs(Int($0.element.number) - currentEpNum) < abs(Int($1.element.number) - currentEpNum)
                        })?.offset
                    }
                    print("[ContinueWatching] Current episode index: \(idx ?? -1)")

                    guard let currentIdx = idx, currentIdx + 1 < episodes.count else {
                        print("[ContinueWatching] No next episode found")
                        return nil
                    }

                    let nextEp = episodes[currentIdx + 1]
                    print("[ContinueWatching] Fetching streams for next episode \(nextEp.number)")
                    let streams = try await runner.fetchStreams(episodeUrl: nextEp.href).sorted { $0.title < $1.title }

                    print("[ContinueWatching] Got \(streams.count) streams for next episode")
                    guard !streams.isEmpty else { return nil }
                    return (streams: streams, episodeNumber: Int(nextEp.number))
                } catch {
                    print("[ContinueWatching] Next episode failed (module): \(error)")
                    return nil
                }
            }
            // For AniList-sourced items with detailHref
            else if let href = item.detailHref {
                print("[ContinueWatching] Using JSEngine path with detailHref")
                do {
                    print("[ContinueWatching] Fetching episodes from detailHref: \(href)")
                    let episodes = try await JSEngine.shared.fetchEpisodes(url: href)
                    print("[ContinueWatching] Got \(episodes.count) episodes")
                    guard let idx = episodes.firstIndex(where: { Int($0.number) == currentEpNum }),
                          idx + 1 < episodes.count else {
                        print("[ContinueWatching] No next episode found")
                        return nil
                    }

                    let nextEp = episodes[idx + 1]
                    print("[ContinueWatching] Fetching streams for next episode \(nextEp.number)")
                    let streams = try await JSEngine.shared.fetchStreams(episodeUrl: nextEp.href).sorted { $0.title < $1.title }
                    print("[ContinueWatching] Got \(streams.count) streams")
                    guard !streams.isEmpty else { return nil }
                    return (streams: streams, episodeNumber: Int(nextEp.number))
                } catch {
                    print("[ContinueWatching] Next episode failed (anilist): \(error)")
                    return nil
                }
            }
            // No way to fetch next episode
            else {
                print("[ContinueWatching] No moduleId or detailHref available")
                return nil
            }
        }

        #if os(iOS)
        PlayerPresenter.shared.presentPlayer(stream: stream, context: context, onWatchNext: onWatchNext, onStreamExpired: nil)
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
    @State private var episodeThumbnail: String?

    private var progress: Double {
        guard item.totalSeconds > 0 else { return 0 }
        return min(item.watchedSeconds / item.totalSeconds, 1.0)
    }

    /// Builds the episode label, e.g.:
    ///   - "Ep 3"                   — no total known
    ///   - "Ep 3 / 24"             — completed series
    ///   - "Ep 3 / 5 • Ongoing"    — ongoing show (availableEpisodes < totalEpisodes or total unknown)
    private func episodeLabelText(item: ContinueWatchingItem, prefix: String?) -> String {
        let epPart: String
        let avail = item.availableEpisodes
        let total = item.totalEpisodes

        if let avail {
            let isOngoing = item.isAiring ?? (total == nil || avail < total!)
            if isOngoing {
                epPart = "Ep \(item.episodeNumber) / \(avail) • Ongoing"
            } else {
                // completed or single-season module show
                epPart = "Ep \(item.episodeNumber) / \(avail)"
            }
        } else if let total {
            epPart = "Ep \(item.episodeNumber) / \(total)"
        } else {
            epPart = "Ep \(item.episodeNumber)"
        }

        if let prefix {
            return "\(prefix) • \(epPart)"
        }
        return epPart
    }

    private var isWatched: Bool {
        ContinueWatchingManager.shared.isWatched(
            aniListID: item.aniListID,
            moduleId: item.moduleId,
            mediaTitle: item.mediaTitle,
            episodeNumber: item.episodeNumber
        )
    }

    private var displayImageUrl: String {
        episodeThumbnail ?? item.thumbnailUrl ?? item.imageUrl
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Thumbnail (16:9)
            Color.clear
                .aspectRatio(16/9, contentMode: .fit)
                .overlay(
                    CachedAsyncImage(urlString: displayImageUrl)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                )
                .overlay(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.5),
                            .init(color: .black.opacity(0.75), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 4) {
                        if !item.streamUrl.isEmpty && !isWatched {
                            Image(systemName: "play.fill")
                                .font(.system(size: 8, weight: .bold))
                            Text(episodeLabelText(item: item, prefix: nil))
                                .font(.caption2.weight(.medium))
                        } else {
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.system(size: 10, weight: .bold))
                            Text(episodeLabelText(item: item, prefix: "Up Next"))
                                .font(.caption2.weight(.bold))
                        }
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .overlay(alignment: .bottom) {
                    if !item.streamUrl.isEmpty && !isWatched {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Color.white.opacity(0.2)
                                Color.accentColor
                                    .frame(width: geo.size.width * progress)
                                    .shadow(color: Color.accentColor.opacity(0.5), radius: 3, x: 0, y: 0)
                            }
                        }
                        .frame(height: 3)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)

            // Title below thumbnail
            Text(item.mediaTitle)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .task(id: item.id) {
            guard let aid = item.aniListID else { return }
            // 1. Use cached episode thumbnail immediately if available
            if let cached = TVDBMappingService.shared.getCachedEpisode(for: aid, episodeNumber: item.episodeNumber)?.thumbnail {
                episodeThumbnail = cached
                return
            }
            // 2. Fetch from animap episodes endpoint
            let episodes = await TVDBMappingService.shared.getEpisodes(for: aid)
            if let thumb = episodes.first(where: { $0.episode == item.episodeNumber })?.thumbnail {
                episodeThumbnail = thumb
                return
            }
            // 3. Fall back to TVDB series banner/fanart
            let artwork = await TVDBMappingService.shared.getArtwork(for: aid)
            episodeThumbnail = artwork.fanart ?? artwork.poster
        }
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

