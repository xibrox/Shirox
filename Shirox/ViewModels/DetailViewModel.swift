import Foundation
import Combine

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
    @Published var needsCloudflareVerification = false

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

    /// The AniList match is AniList's top search result for a title that matched nothing — a guess.
    @Published private(set) var aniListMatchIsGuess = false
    /// The page's AniList match has settled: known up front, found, guessed, or none.
    @Published private(set) var aniListMatchSettled = false

    /// A match the user chose, or cleared. The poster and synopsis borrowed for a module that
    /// sends none follow it.
    func setAniListMatch(_ id: Int?) {
        aniListID = id
        aniListMatchIsGuess = false
        if let id {
            fetchAniListMetadata(id: id)
        } else if let moduleDetail {
            aniListMedia = nil
            detail = moduleDetail
        }
    }

    /// The detail as the module sent it, before anything is borrowed from the AniList match.
    private var moduleDetail: MediaDetail?

    /// Shows the module's detail, with the poster and synopsis it lacks taken from the match.
    private func show(_ fetched: MediaDetail) {
        moduleDetail = fetched
        detail = fetched.borrowing(from: aniListMedia)
    }

    /// Set by loadOffline. Tells load() to treat snapshot data as authoritative for
    /// text fields (synopsis/aliases/airdate) and to only accept the fetched episode
    /// list when it is plausibly real.
    private(set) var hydratedFromSnapshot = false

    /// Stream selected by user in the picker — presented after the sheet fully dismisses.
    var pendingStream: StreamResult?

    /// Resume position if navigated from Continue Watching (only applies to the specific episode)
    var resumeWatchedSeconds: Double?
    var resumeEpisodeNumber: Int?

    private(set) var detailHref: String?
    private var streamsTask: Task<Void, Never>?

    func load(item: SearchItem) {
        guard !isMatchingAniList else { return }
        guard !item.href.isEmpty else { return }
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
            aniListMatchSettled = true
            fetchAniListMetadata(id: aid)
        }

        Task {
            isLoadingDetail = true
            errorMessage = nil
            CloudflareBypassManager.shared.pendingVerificationURL = nil
            await fetchPage(item: item)
            // A site that walls its detail pages behind Cloudflare: solve it on the walled page
            // and load once more, as search does. The page had no way to verify before, and a
            // module swallowing the wall often shows an empty page rather than an error.
            if !Task.isCancelled, let walled = CloudflareBypassManager.shared.pendingVerificationURL {
                try? await CloudflareBypassManager.shared.triggerBypass(for: walled)
                CloudflareBypassManager.shared.pendingVerificationURL = nil
                if !Task.isCancelled {
                    errorMessage = nil
                    isLoadingDetail = detail == nil
                    await fetchPage(item: item)
                }
            }
            isLoadingDetail = false
            isLoadingEpisodes = false
        }
    }

    /// The module's detail and episodes for `item`, shown as they come.
    private func fetchPage(item: SearchItem) async {
        do {
            var d = try await JSEngine.shared.fetchDetails(
                url: item.href,
                title: item.title,
                image: item.image
            )
            // Snapshot is authoritative for text fields: AniList synopsis/year are
            // higher-quality than the module's, and an offline JS module that swallows
            // its own network errors often returns the error string as `description`.
            // We never let that overwrite a hydrated snapshot.
            if hydratedFromSnapshot, let existing = detail {
                d = MediaDetail(
                    title: existing.title,
                    image: existing.image,
                    description: existing.description,
                    aliases: existing.aliases,
                    airdate: existing.airdate,
                    episodes: existing.episodes
                )
            } else if let existing = detail, d.episodes.isEmpty {
                d.episodes = existing.episodes
            }
            show(d)
            isLoadingDetail = false

            isLoadingEpisodes = true
            let fetched = try await JSEngine.shared.fetchEpisodes(url: item.href)
            // Only overwrite the existing episode list when the fetched one looks
            // strictly real. Modules that swallow their own network errors often
            // return [] or [{href: "stub"}] which parses to episode-0 entries —
            // the snapshot's actual download list survives that.
            let looksValid = !fetched.isEmpty
                && fetched.allSatisfy { !$0.href.isEmpty }
                && (!hydratedFromSnapshot || fetched.allSatisfy { $0.number > 0 })
            if looksValid {
                d.episodes = fetched
                show(d)
            }
        } catch {
            // If we already rendered something (e.g. from an offline snapshot),
            // silently keep that view instead of replacing it with an error screen.
            if detail == nil {
                errorMessage = error.localizedDescription
            }
        }
    }

    #if os(iOS)
    /// Offline mode: hydrate from a persisted snapshot. No network calls are issued.
    /// Episodes are emitted as `EpisodeLink` with empty href (offline mode never resolves them).
    func loadOffline(snapshot: DownloadedMediaSnapshot) {
        let poster: String
        if let file = snapshot.posterFile {
            poster = DownloadedMediaSnapshotStore.shared
                .localFileURL(in: snapshot, relative: file)
                .absoluteString
        } else {
            poster = ""
        }

        let episodeLinks: [EpisodeLink] = snapshot.episodes
            .values
            .sorted(by: { $0.number < $1.number })
            .map { EpisodeLink(number: Double($0.number), href: "") }

        self.detail = MediaDetail(
            title: snapshot.mediaTitle,
            image: poster,
            description: snapshot.synopsis ?? "",
            aliases: snapshot.aliases ?? "",
            airdate: snapshot.airdate ?? (snapshot.seasonYear.map { String($0) } ?? ""),
            episodes: episodeLinks
        )

        let bannerURLString: String? = snapshot.bannerFile.map {
            DownloadedMediaSnapshotStore.shared.localFileURL(in: snapshot, relative: $0).absoluteString
        }
        self.aniListMedia = Media(
            id: snapshot.aniListID ?? 0,
            idMal: nil,
            provider: .anilist,
            title: MediaTitle(romaji: snapshot.mediaTitle, english: snapshot.mediaTitle, native: nil),
            coverImage: MediaCoverImage(large: poster, extraLarge: poster),
            bannerImage: bannerURLString,
            description: snapshot.synopsis,
            episodes: snapshot.episodes.keys.max(),
            status: snapshot.statusDisplay.flatMap(Self.aniListStatusRaw),
            averageScore: snapshot.averageScore,
            genres: snapshot.genres,
            season: nil,
            seasonYear: snapshot.seasonYear,
            nextAiringEpisode: nil,
            relations: nil,
            type: nil,
            format: snapshot.format
        )

        self.aniListID = snapshot.aniListID
        self.detailHref = nil
        self.isLoadingDetail = false
        self.isLoadingEpisodes = false
        self.isLoadingAniListMedia = false
        self.hydratedFromSnapshot = true
    }

    /// `Media.statusDisplay` is computed from raw status codes (e.g. "RELEASING" → "Airing").
    /// We stored the display string, so reverse-map for round-trip consistency.
    private static func aniListStatusRaw(from display: String) -> String? {
        switch display {
        case "Airing": return "RELEASING"
        case "Finished": return "FINISHED"
        case "Upcoming": return "NOT_YET_RELEASED"
        case "Cancelled": return "CANCELLED"
        case "Hiatus": return "HIATUS"
        default: return display
        }
    }
    #endif

    private func fetchAniListMetadata(id: Int) {
        Task {
            isLoadingAniListMedia = true
            // A newer match may have been chosen while this one loaded.
            if let raw = try? await AniListService.shared.detail(id: id), aniListID == id {
                self.aniListMedia = AniListProvider.shared.mapMedia(raw)
                if let moduleDetail { detail = moduleDetail.borrowing(from: aniListMedia) }
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

            // Without an exact match, the closest result of the same season (see
            // AniListTitleMatcher). AniList's top result was taken before, and that's the
            // best-known entry: a later cour's episodes were tracked on the first season.
            let guessedID = perfectMatch == nil
                ? AniListTitleMatcher.bestMatch(for: title, among: results.map {
                    AniListTitleMatcher.Candidate(id: $0.id, titles: [$0.title.english, $0.title.romaji,
                                                                      $0.title.native].compactMap { $0 })
                })
                : nil
            let match = perfectMatch ?? results.first { $0.id == guessedID }
            if let match {
                aniListID = match.id
                aniListMatchIsGuess = perfectMatch == nil
                // Only persist confident (exact) matches. A fuzzy fallback is used for this
                // session but not cached as ground truth, so an occasional wrong guess doesn't
                // stick permanently with no way to correct it.
                if perfectMatch != nil {
                    AniListMappingManager.shared.saveMapping(title: title, aniListID: match.id)
                }
                fetchAniListMetadata(id: match.id)
            }
        } catch {
            Logger.shared.log("[DetailVM] Auto-match failed: \(error)", type: "Error")
        }
        isMatchingAniList = false
        aniListMatchSettled = true
    }

    // MARK: - Streams

    func loadStreams(for episode: EpisodeLink) {
        selectedEpisode = episode
        streamOptions = []
        needsCloudflareVerification = false
        CloudflareBypassManager.shared.pendingVerificationURL = nil
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
            // A CF wall during the fetch leaves no streams but a flagged host — offer
            // a user-initiated "Verify Cloudflare" button instead of "No Streams Found".
            needsCloudflareVerification = streamOptions.isEmpty
                && CloudflareBypassManager.shared.pendingVerificationURL != nil
            isLoadingStreams = false
        }
    }

    /// Runs the user-initiated Cloudflare challenge for the flagged host, then reloads
    /// streams (the cached cookie lets the fetch's inline retry succeed).
    func verifyCloudflare() {
        guard let url = CloudflareBypassManager.shared.pendingVerificationURL,
              let episode = selectedEpisode else { return }
        Task {
            try? await CloudflareBypassManager.shared.triggerBypass(for: url)
            needsCloudflareVerification = false
            loadStreams(for: episode)
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
                let sorted = streams.sorted { $0.title < $1.title }
                isLoadingStreams = false

                let autoPickLastStream = UserDefaults.standard.bool(forKey: "autoPickLastStream")
                let moduleId = ModuleManager.shared.activeModule?.id ?? ""
                let savedTitle = ModuleSearchAliasManager.shared.getLastStreamTitle(moduleId: moduleId)

                if sorted.count == 1 {
                    pendingStreams = sorted
                    downloadWithSelectedStream(sorted[0])
                } else if autoPickLastStream,
                          let title = savedTitle,
                          let match = sorted.first(where: { $0.title == title }) {
                    pendingStreams = sorted
                    downloadWithSelectedStream(match)
                } else {
                    pendingStreams = sorted
                    showDownloadStreamPicker = true
                }
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
            aniListID: aniListID,
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

    func selectStream(_ stream: StreamResult, onSequelAdvanced: ((SequelNavigation) -> Void)? = nil, onFinished: ((PlayerContext) -> Void)? = nil) {
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
            totalEpisodes: aniListMedia?.episodes ?? episodeCount,
            availableEpisodes: episodeCount,
            isAiring: aniListMedia.map { $0.status == "RELEASING" },
            resumeFrom: resumeEpisodeNumber == Int(selectedEpisode?.number ?? 1)
                ? resumeWatchedSeconds
                // Anchor on the episode's unique href: on a flat multi-season list the numbers
                // repeat, so a number-only lookup would resume S2 E5 from S1 E5's position.
                : ContinueWatchingManager.shared.items.first(where: { $0.moduleId == ModuleManager.shared.activeModule?.id && $0.mediaTitle == (detail?.title ?? "") && $0.matchesEpisode(number: Int(selectedEpisode?.number ?? 1), href: selectedEpisode?.href) })?.watchedSeconds,
            detailHref: detailHref,
            episodeHref: selectedEpisode?.href,
            streamTitle: stream.title,
            workingDetailHref: detailHref,
            thumbnailUrl: nil
        )

        // Build a WatchNextLoader that advances through the flat episode list by position.
        // Episode numbers repeat across seasons (S1 1…12, S2 1…4), so we anchor on the
        // selected episode's unique href and track a forward-only index — otherwise
        // "next after S2 E1" resolves to S1 E2 (the first occurrence of number 2).
        let episodes = detail?.episodes ?? []
        let watchNextLoader: WatchNextLoader? = {
            guard !episodes.isEmpty else { return nil }

            let startAnchor = episodes.firstIndex(where: { $0.href == selectedEpisode?.href })
                ?? episodes.firstIndex(where: { Int($0.number) == Int(selectedEpisode?.number ?? 1) })
                ?? 0
            // If the selected episode is the last one, don't create the loader.
            guard startAnchor + 1 < episodes.count else { return nil }

            var anchor = startAnchor
            return { [weak self] currentEpNum in
                guard let self, let episodes = self.detail?.episodes,
                      let step = EpisodeNavigator.next(currentNumber: currentEpNum, anchor: anchor, in: episodes)
                else { return nil }
                let streams = try await self.fetchStreams(for: step.episode)
                guard !streams.isEmpty else { return nil }
                // Commit the cursor only on success, so a failed/empty fetch leaves it untouched
                // and the next call (e.g. a prefetch-failure retry) resolves the same episode
                // rather than skipping one.
                anchor = step.current
                return (streams: streams, episodeNumber: Int(step.episode.number), episodeHref: step.episode.href)
            }
        }()

        let onSequelNeeded: SequelLoader? = {
            guard
                let sequelNode = aniListMedia?.relations?.edges.first(where: { $0.relationType == "SEQUEL" && $0.node.type == "ANIME" })?.node,
                let module = ModuleManager.shared.activeModule
            else { return nil }
            let sequelTitle = sequelNode.title.displayTitle
            let sequelID = sequelNode.id
            return {
                let runner = ModuleJSRunner()
                try await runner.load(module: module)
                let items = try await SequelResolver.searchResults(title: sequelTitle, module: module, runner: runner)
                return (items: items, mediaID: sequelID)
            }
        }()

        // A fresh link for the episode on screen when the one playing dies mid-episode (an
        // expired CDN token after a phone call, a seek back into segments no longer served).
        // Playing from this page passed none, so the player had nothing to recover with: it
        // froze where the stream died. The Continue button and the AniList page already did.
        let onStreamExpired: StreamRefetchLoader = { [weak self] episodeNumber, episodeHref in
            guard let self, let episodes = self.detail?.episodes,
                  let episode = EpisodeNavigator.resolve(href: episodeHref, orNumber: episodeNumber, in: episodes)
            else { return [] }
            return try await self.fetchStreams(for: episode)
        }

        #if os(iOS)
        PlayerPresenter.shared.presentPlayer(stream: stream, streams: streamOptions, context: context, onWatchNext: watchNextLoader, onStreamExpired: onStreamExpired, onSequelNeeded: onSequelNeeded, onSequelAdvanced: onSequelAdvanced, onFinished: onFinished)
        #elseif os(macOS)
        MacPlayerWindowManager.shared.open(stream: stream, streams: streamOptions, context: context, onWatchNext: watchNextLoader, onSequelNeeded: onSequelNeeded, onSequelAdvanced: onSequelAdvanced, onFinished: onFinished)
        #endif
    }
}
