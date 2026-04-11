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
        // Determine stream type (SUB or DUB)
        let streamType = stream.subtitle == nil && stream.title.localizedCaseInsensitiveContains("dub") ? "DUB" : "SUB"

        let context = PlayerContext(
            mediaTitle: mediaTitle,
            episodeNumber: currentEpNum,
            episodeTitle: nil,
            imageUrl: media.coverImage.extraLarge ?? media.coverImage.large ?? "",
            aniListID: media.id,
            moduleId: nil,
            totalEpisodes: media.episodes,
            resumeFrom: resumeWatchedSeconds,
            detailHref: nil,
            streamSubtitle: streamType,
            workingDetailHref: searchResultHref  // Store the working search result href
        )

        // Build next-episode loader using ModuleJSRunner (same path as ModuleStreamPickerView)
        // Capture whether the initial stream is sub or dub so we can pick the matching
        // search result when AnimePahe (and similar) lists sub and dub as separate entries.
        let streamIsDub = stream.subtitle == nil && stream.title.localizedCaseInsensitiveContains("dub")
        let onWatchNext: WatchNextLoader? = {
            guard let module = ModuleManager.shared.activeModule, let resultHref = searchResultHref else {
                print("[AniListDetailVM] No module or working href available")
                return nil
            }
            let total = totalEpisodes
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

        PlayerPresenter.shared.presentPlayer(stream: stream, context: context, onWatchNext: onWatchNext, from: sourceView)
        selectedEpisodeNumber = nil
    }
}
