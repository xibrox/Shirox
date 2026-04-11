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

    /// Deferred streams waiting to be presented after a sheet fully dismisses.
    var pendingModuleStream: StreamResult?   // single-stream from ModuleStreamPickerView
    var pendingModuleStreamEpisodeHref: String?  // episode href for Next Episode
    var pendingFinalStream: StreamResult?    // chosen stream from AniListStreamResultSheet

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

    func onStreamsLoaded(_ streams: [StreamResult], episodeHref: String? = nil) {
        let sorted = streams.sorted { $0.title < $1.title }
        if sorted.count == 1 {
            // Store and let onDismiss present after the sheet fully clears.
            pendingModuleStream = sorted[0]
            pendingModuleStreamEpisodeHref = episodeHref
        } else {
            pendingStreams = sorted
            showFinalStreamPicker = true
        }
        showStreamPicker = false
    }

    func selectStream(_ stream: StreamResult, from sourceView: UIView? = nil, searchResultHref: String? = nil) {
        selectedStream = stream
        guard let media else { return }
        let currentEpNum = selectedEpisodeNumber ?? 1
        let mediaTitle = media.title.displayTitle
        let totalEpisodes = media.episodes ?? (media.nextAiringEpisode != nil ? media.nextAiringEpisode!.episode - 1 : 0)
        let context = PlayerContext(
            mediaTitle: mediaTitle,
            episodeNumber: currentEpNum,
            episodeTitle: nil,
            imageUrl: media.coverImage.extraLarge ?? media.coverImage.large ?? "",
            aniListID: media.id,
            moduleId: nil,
            totalEpisodes: media.episodes,
            resumeFrom: resumeWatchedSeconds,
            detailHref: nil
        )

        // Build next-episode loader using ModuleJSRunner (same path as ModuleStreamPickerView)
        // Capture whether the initial stream is sub or dub so we can pick the matching
        // search result when AnimePahe (and similar) lists sub and dub as separate entries.
        let streamIsDub = stream.subtitle == nil && stream.title.localizedCaseInsensitiveContains("dub")
        let onWatchNext: WatchNextLoader? = {
            print("[AniListDetailVM] selectStream building onWatchNext, searchResultHref=\(searchResultHref ?? "nil")")
            guard let module = ModuleManager.shared.activeModule else {
                print("[AniListDetailVM] No active module")
                return nil
            }
            let searchTitle = media.title.searchTitle
            let total = totalEpisodes
            // Use provided searchResultHref if available (from ModuleStreamPickerView), otherwise search
            let resultHref = searchResultHref
            return { currentEpNum in
                print("[AniListDetailVM] onWatchNext called for episode \(currentEpNum), resultHref=\(resultHref ?? "nil")")
                let nextEpNum = currentEpNum + 1
                if total > 0, nextEpNum > total { return nil }
                let runner = ModuleJSRunner()
                try await runner.load(module: module)

                var episodes: [EpisodeLink] = []
                var targetHref = ""

                // Try provided resultHref first, but fall back to search if it doesn't work
                if let resultHref {
                    print("[AniListDetailVM] Using provided resultHref: \(resultHref)")
                    targetHref = resultHref
                    episodes = try await runner.fetchEpisodes(url: targetHref)
                    print("[AniListDetailVM] Got \(episodes.count) episodes from resultHref")

                    // If resultHref didn't have episodes (might be movie or incomplete), fall back to search
                    if episodes.isEmpty || !episodes.contains(where: { $0.number == Double(nextEpNum) }) {
                        print("[AniListDetailVM] ResultHref didn't have episode \(nextEpNum), trying search")
                        episodes = []
                    }
                }

                // If we still don't have episodes, search
                if episodes.isEmpty {
                    print("[AniListDetailVM] Searching for: \(searchTitle)")
                    let results = try await runner.search(keyword: searchTitle)
                    print("[AniListDetailVM] Search returned \(results.count) results")

                    // Try multiple results to find one with the episode we need
                    for result in results.prefix(5) {
                        let candidateEpisodes = try await runner.fetchEpisodes(url: result.href)
                        print("[AniListDetailVM] Result '\(result.title)' has \(candidateEpisodes.count) episodes")

                        if candidateEpisodes.contains(where: { $0.number == Double(nextEpNum) }) {
                            episodes = candidateEpisodes
                            targetHref = result.href
                            print("[AniListDetailVM] Using '\(result.title)' as it has episode \(nextEpNum)")
                            break
                        }
                    }

                    // If no result had the exact episode, use first with multiple episodes
                    if episodes.isEmpty {
                        for result in results.prefix(5) {
                            let candidateEpisodes = try await runner.fetchEpisodes(url: result.href)
                            if candidateEpisodes.count > 1 {
                                episodes = candidateEpisodes
                                targetHref = result.href
                                print("[AniListDetailVM] Using '\(result.title)' as fallback")
                                break
                            }
                        }
                    }
                }

                guard !episodes.isEmpty else {
                    print("[AniListDetailVM] No episodes found from any source")
                    return nil
                }

                guard let ep = episodes.first(where: { $0.number == Double(nextEpNum) }) else {
                    print("[AniListDetailVM] Episode \(nextEpNum) not found in episodes")
                    return nil
                }
                print("[AniListDetailVM] Fetching streams for episode \(nextEpNum)")
                let streams = try await runner.fetchStreams(episodeUrl: ep.href)
                    .sorted { $0.title < $1.title }
                print("[AniListDetailVM] Got \(streams.count) streams")
                guard !streams.isEmpty else { return nil }
                return (streams: streams, episodeNumber: nextEpNum)
            }
        }()

        PlayerPresenter.shared.presentPlayer(stream: stream, context: context, onWatchNext: onWatchNext, from: sourceView)
        selectedEpisodeNumber = nil
    }
}
