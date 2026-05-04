import Foundation

@MainActor
final class DetailViewModel: ObservableObject {
    @Published var detail: MediaDetail?
    @Published var aniListMedia: Media?
    @Published var isLoadingDetail = false
    @Published var isLoadingAniListMedia = false
    @Published var isLoadingEpisodes = false
    @Published var isLoadingStreams = false
    @Published var errorMessage: String?

    // Stream picker state
    @Published var streamOptions: [StreamResult] = []
    @Published var selectedEpisode: EpisodeLink?
    @Published var showStreamPicker = false

    // Download stream picker state
    @Published var pendingStreams: [StreamResult] = []
    @Published var pendingEpisode: EpisodeLink?
    @Published var pendingEpisodeTitle: String?
    @Published var showDownloadStreamPicker = false

    // Player state
    @Published var selectedStream: StreamResult?
    @Published var showPlayer = false

    @Published var aniListID: Int?
    @Published var isMatchingAniList = false

    /// Stream selected by user in the picker — presented after the sheet fully dismisses.
    var pendingStream: StreamResult?

    /// Resume position if navigated from Continue Watching
    var resumeWatchedSeconds: Double?

    private(set) var detailHref: String?
    private var streamsTask: Task<Void, Never>?

    func load(item: SearchItem) {
        guard detail == nil && !isMatchingAniList else { return }
        detailHref = item.href
        
        // Check if we have a saved mapping first
        if aniListID == nil {
            if let savedID = AniListMappingManager.shared.getMapping(title: item.title) {
                aniListID = savedID
            }
        }
        
        // If still no ID, try auto-matching
        if aniListID == nil {
            Task {
                await autoMatch(title: item.title)
            }
        } else if let aid = aniListID {
            // Already have ID (passed in or from mapping), fetch metadata
            fetchAniListMetadata(id: aid)
        }

        Task {
            isLoadingDetail = true
            errorMessage = nil
            do {
                var d = try await JSEngine.shared.fetchDetails(
                    url: item.href,
                    title: item.title,
                    image: item.image
                )
                detail = d
                isLoadingDetail = false

                isLoadingEpisodes = true
                d.episodes = try await JSEngine.shared.fetchEpisodes(url: item.href)
                detail = d
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoadingDetail = false
            isLoadingEpisodes = false
        }
    }

    private func fetchAniListMetadata(id: Int) {
        Task {
            isLoadingAniListMedia = true
            if let raw = try? await AniListService.shared.detail(id: id) {
                self.aniListMedia = AniListProvider.shared.mapMedia(raw)
            }
            isLoadingAniListMedia = false
        }
    }

    private func autoMatch(title: String) async {
        isMatchingAniList = true
        do {
            let results = try await AniListService.shared.search(keyword: title)
            // Look for a perfect match (case-insensitive) in the top 3 results
            let perfectMatch = results.prefix(3).first { media in
                media.title.displayTitle.lowercased() == title.lowercased() ||
                media.title.english?.lowercased() == title.lowercased() ||
                media.title.romaji?.lowercased() == title.lowercased()
            }
            
            if let match = perfectMatch {
                aniListID = match.id
                AniListMappingManager.shared.saveMapping(title: title, aniListID: match.id)
                fetchAniListMetadata(id: match.id)
            }
        } catch {
            Logger.shared.log("[DetailVM] Auto-match failed: \(error)", type: "Error")
        }
        isMatchingAniList = false
    }

    // MARK: - Streams

    func loadStreams(for episode: EpisodeLink) {
        selectedEpisode = episode
        streamOptions = []
        showStreamPicker = true
        isLoadingStreams = true

        streamsTask = Task {
            do {
                let streams = try await JSEngine.shared.fetchStreams(episodeUrl: episode.href)
                guard !Task.isCancelled else { return }
                let sorted = streams.sorted { $0.title < $1.title }
                if sorted.count == 1 {
                    pendingStream = sorted[0]
                    showStreamPicker = false
                } else if UserDefaults.standard.bool(forKey: "autoPickLastStream"),
                          let moduleId = ModuleManager.shared.activeModule?.id,
                          let savedTitle = ModuleSearchAliasManager.shared.getLastStreamTitle(moduleId: moduleId),
                          let match = sorted.first(where: { $0.title == savedTitle }) {
                    pendingStream = match
                    showStreamPicker = false
                } else {
                    streamOptions = sorted
                }
            } catch {
                if !Task.isCancelled {
                    errorMessage = error.localizedDescription
                }
            }
            isLoadingStreams = false
        }
    }

    /// Fetches streams for the given episode and returns them sorted by title.
    /// Unlike loadStreams(for:), this does not affect UI state — safe to call from onWatchNext.
    func fetchStreams(for episode: EpisodeLink) async throws -> [StreamResult] {
        let streams = try await JSEngine.shared.fetchStreams(episodeUrl: episode.href)
        return streams.sorted { $0.title < $1.title }
    }

    func pickStream(_ stream: StreamResult) {
        if let moduleId = ModuleManager.shared.activeModule?.id {
            ModuleSearchAliasManager.shared.setLastStreamTitle(moduleId: moduleId, title: stream.title)
        }
        pendingStream = stream
        showStreamPicker = false
    }

    func cancelStreamLoading() {
        streamsTask?.cancel()
        streamsTask = nil
        isLoadingStreams = false
        showStreamPicker = false
        streamOptions = []
    }

    func loadDownloadStreams(for episode: EpisodeLink) {
        pendingEpisode = episode
        pendingEpisodeTitle = nil
        pendingStreams = []
        showDownloadStreamPicker = false
        isLoadingStreams = true
        streamsTask = Task {
            do {
                let streams = try await JSEngine.shared.fetchStreams(episodeUrl: episode.href)
                pendingStreams = streams.sorted { $0.title < $1.title }
                isLoadingStreams = false
                showDownloadStreamPicker = true
            } catch {
                if (error as? CancellationError) != nil { return }
                isLoadingStreams = false
            }
        }
    }

    func downloadWithSelectedStream(_ stream: StreamResult) {
        #if os(iOS)
        guard let episode = pendingEpisode, let detail = detail else { return }

        let ctx = DownloadContext(
            mediaTitle: detail.title,
            episodeNumber: Int(episode.number),
            episodeTitle: pendingEpisodeTitle,
            imageUrl: detail.image,
            aniListID: nil,
            moduleId: ModuleManager.shared.activeModule?.id,
            detailHref: detailHref,
            episodeHref: episode.href,
            streamTitle: stream.title,
            totalEpisodes: detail.episodes.isEmpty ? nil : detail.episodes.count
        )
        DownloadManager.shared.download(stream: stream, episodeHref: episode.href, context: ctx)

        // Clear pending state
        showDownloadStreamPicker = false
        pendingStreams = []
        pendingEpisode = nil
        pendingEpisodeTitle = nil
        #endif
    }

    func selectStream(_ stream: StreamResult) {
        selectedStream = stream

        // For module shows, availableEpisodes == totalEpisodes (the fetched episode list).
        let episodeCount = detail?.episodes.isEmpty == false ? detail?.episodes.count : nil
        let context = PlayerContext(
            mediaTitle: detail?.title ?? "",
            episodeNumber: Int(selectedEpisode?.number ?? 1),
            episodeTitle: nil,
            imageUrl: detail?.image ?? "",
            aniListID: aniListID,
            malID: aniListID.flatMap { IDMappingService.shared.cachedMalId(forAnilistId: $0) },
            moduleId: ModuleManager.shared.activeModule?.id,
            totalEpisodes: episodeCount,
            availableEpisodes: episodeCount,
            isAiring: nil,
            resumeFrom: resumeWatchedSeconds,
            detailHref: detailHref,
            streamTitle: stream.title,
            workingDetailHref: detailHref,
            thumbnailUrl: nil
        )

        // Build a WatchNextLoader that dynamically finds the next episode by current episode number
        let episodes = detail?.episodes ?? []
        let watchNextLoader: WatchNextLoader? = {
            guard !episodes.isEmpty else { return nil }
            
            // If current episode is the last one, don't create the loader
            let currentEpNum = Int(selectedEpisode?.number ?? 1)
            if let idx = episodes.firstIndex(where: { Int($0.number) == currentEpNum }),
               idx + 1 >= episodes.count {
                return nil
            }
            
            return { [weak self] currentEpNum in
                guard let self,
                      let idx = self.detail?.episodes.firstIndex(where: { Int($0.number) == currentEpNum }),
                      let episodes = self.detail?.episodes,
                      idx + 1 < episodes.count
                else { return nil }
                let nextEp = episodes[idx + 1]
                let streams = try await self.fetchStreams(for: nextEp)
                guard !streams.isEmpty else { return nil }
                return (streams: streams, episodeNumber: Int(nextEp.number))
            }
        }()

        #if os(iOS)
        PlayerPresenter.shared.presentPlayer(stream: stream, streams: streamOptions, context: context, onWatchNext: watchNextLoader)
        #elseif os(macOS)
        MacPlayerWindowManager.shared.open(stream: stream, streams: streamOptions, context: context, onWatchNext: watchNextLoader)
        #endif
    }
}
