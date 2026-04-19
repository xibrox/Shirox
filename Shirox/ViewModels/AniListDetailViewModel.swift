import Foundation
import UIKit

@MainActor
final class AniListDetailViewModel: ObservableObject {
    @Published var media: AniListMedia?
    @Published var isLoading = true
    @Published var error: String?

    // Stream picker state
    @Published var showStreamPicker = false
    @Published var selectedEpisodeNumber: Int?

    // Stream results that bubble up from ModuleStreamPickerView
    @Published var pendingStreams: [StreamResult] = []
    @Published var showFinalStreamPicker = false
    @Published var selectedStream: StreamResult?
    @Published var showPlayer = false

    // Download stream picker state
    @Published var pendingDownloadStreams: [StreamResult] = []
    @Published var pendingDownloadEpisode: (EpisodeLink, Int)?
    @Published var pendingDownloadModule: ModuleDefinition?
    @Published var pendingDownloadMedia: AniListMedia?
    @Published var showDownloadStreamPicker = false

    /// Deferred streams waiting to be presented after a sheet fully dismisses.
    var pendingModuleStream: StreamResult?   // single-stream from ModuleStreamPickerView
    var pendingModuleStreamEpisodeHref: String?  // episode href for Next Episode
    var pendingModuleStreamAvailableCount: Int?  // episode count from module search result
    var pendingFinalStream: StreamResult?    // chosen stream from AniListStreamResultSheet
    var pendingFinalStreamEpisodeHref: String?  // episode href when selecting from final picker
    var pendingFinalStreamAvailableCount: Int?   // saved count for final picker

    /// Resume position if navigated from Continue Watching
    var resumeWatchedSeconds: Double?

    func load(id: Int, preloaded: AniListMedia? = nil) async {
        guard media == nil else { return }
        if let preloaded {
            media = preloaded
        }
        isLoading = true
        error = nil
        do {
            media = try await AniListService.shared.detail(id: id)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func watchEpisode(_ number: Int) {
        selectedEpisodeNumber = number
        showStreamPicker = true
    }

    func dismissModulePicker() {
        showStreamPicker = false
        selectedEpisodeNumber = nil
    }

    func dismissFinalPicker() {
        showFinalStreamPicker = false
        pendingStreams = []
        selectedEpisodeNumber = nil
    }

    func onStreamsLoaded(_ streams: [StreamResult], selectedStream: StreamResult? = nil, episodeHref: String? = nil, availableCount: Int? = nil) {
        let sorted = streams.sorted { $0.title < $1.title }
        if let selected = selectedStream {
            // User already picked from quality picker — auto-play, but keep all streams for in-player switching
            pendingStreams = sorted
            pendingModuleStream = selected
            pendingModuleStreamEpisodeHref = episodeHref
            pendingModuleStreamAvailableCount = availableCount
        } else if sorted.count == 1 {
            // Store and let onDismiss present after the sheet fully clears.
            pendingStreams = sorted
            pendingModuleStream = sorted[0]
            pendingModuleStreamEpisodeHref = episodeHref
            pendingModuleStreamAvailableCount = availableCount
        } else {
            pendingStreams = sorted
            pendingFinalStreamEpisodeHref = episodeHref
            pendingFinalStreamAvailableCount = availableCount
            showFinalStreamPicker = true
        }
        showStreamPicker = false
    }

    func selectStream(_ stream: StreamResult, from sourceView: UIView? = nil, searchResultHref: String? = nil, availableEpisodes: Int? = nil) {
        selectedStream = stream
        guard let media else { return }
        let currentEpNum = selectedEpisodeNumber ?? 1
        let mediaTitle = media.title.displayTitle
        // availableEpisodes = how many are currently aired (may be < series total for ongoing shows)
        // Order of precedence:
        // 1. AniList's nextAiringEpisode (fallback airing count)
        // 2. The count passed from the module (best for accurate "caught up" tracking on a specific provider)
        // 3. AniList's total episodes (general fallback)
        let anilistAiring = media.nextAiringEpisode != nil ? (media.nextAiringEpisode!.episode - 1) : nil
        let availEps: Int? = anilistAiring ?? availableEpisodes ?? media.episodes
        // totalEpisodes = full series count (nil if unknown)
        let totalEpisodes: Int? = media.episodes
        let episodeThumbnail = TVDBMappingService.shared.getCachedEpisode(for: media.id, episodeNumber: currentEpNum)?.thumbnail
        let context = PlayerContext(
            mediaTitle: mediaTitle,
            episodeNumber: currentEpNum,
            episodeTitle: nil,
            imageUrl: media.coverImage.extraLarge ?? media.coverImage.large ?? "",
            aniListID: media.id,
            moduleId: ModuleManager.shared.activeModule?.id,
            totalEpisodes: totalEpisodes,
            availableEpisodes: availEps,
            isAiring: media.status == "RELEASING",
            resumeFrom: resumeWatchedSeconds,
            detailHref: searchResultHref,
            streamTitle: stream.title,
            workingDetailHref: searchResultHref,
            thumbnailUrl: episodeThumbnail
        )

        // Build next-episode loader using ModuleJSRunner (same path as ModuleStreamPickerView)
        let onWatchNext: WatchNextLoader? = {
            guard let module = ModuleManager.shared.activeModule, let resultHref = searchResultHref else {
                print("[AniListDetailVM] No module or working href available")
                return nil
            }
            let total = availEps ?? 0
            // If we are at the end of what's available, don't even create the loader
            if total > 0 && currentEpNum >= total {
                return nil
            }

            return { currentEpNum in
                print("[AniListDetailVM] onWatchNext called for episode \(currentEpNum) using stored href: \(resultHref)")
                let nextEpNum = currentEpNum + 1
                if total > 0, nextEpNum > total { return nil }

                do {
                    let runner = ModuleJSRunner()
                    try await runner.load(module: module)

                    // Use the stored working href - this is the search result that was proven to work
                    let episodes = try await runner.fetchEpisodes(url: resultHref)
                    print("[AniListDetailVM] Got \(episodes.count) episodes from stored href")

                    guard let ep = episodes.first(where: { $0.number == Double(nextEpNum) }) else {
                        print("[AniListDetailVM] Episode \(nextEpNum) not found")
                        return nil
                    }

                    let streams = try await runner.fetchStreams(episodeUrl: ep.href)
                        .sorted { $0.title < $1.title }
                    print("[AniListDetailVM] Got \(streams.count) streams for episode \(nextEpNum)")

                    guard !streams.isEmpty else { return nil }
                    return (streams: streams, episodeNumber: nextEpNum)
                } catch {
                    print("[AniListDetailVM] Error loading next episode: \(error)")
                    return nil
                }
            }
        }()

        PlayerPresenter.shared.presentPlayer(stream: stream, streams: pendingStreams, context: context, onWatchNext: onWatchNext, from: sourceView)
        selectedEpisodeNumber = nil
    }

    func downloadWithSelectedStream(_ stream: StreamResult) {
        guard let (episodeLink, epNum) = pendingDownloadEpisode,
              let module = pendingDownloadModule,
              let media = pendingDownloadMedia else { return }

        let ctx = DownloadContext(
            mediaTitle: media.title.displayTitle,
            episodeNumber: epNum,
            episodeTitle: nil,
            imageUrl: media.coverImage.extraLarge ?? media.coverImage.large ?? "",
            aniListID: media.id,
            moduleId: module.id,
            detailHref: "https://anilist.co/anime/\(media.id)",
            episodeHref: episodeLink.href,
            streamTitle: stream.title,
            totalEpisodes: media.episodes
        )
        DownloadManager.shared.download(stream: stream, episodeHref: episodeLink.href, context: ctx)

        // Clear pending state
        showDownloadStreamPicker = false
        pendingDownloadStreams = []
        pendingDownloadEpisode = nil
        pendingDownloadModule = nil
        pendingDownloadMedia = nil
    }
}
