import Foundation
import UIKit

@MainActor
final class DetailViewModel: ObservableObject {
    @Published var detail: MediaDetail?
    @Published var isLoadingDetail = false
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

    var aniListID: Int? // Added this

    /// Stream selected by user in the picker — presented after the sheet fully dismisses.
    var pendingStream: StreamResult?

    /// Resume position if navigated from Continue Watching
    var resumeWatchedSeconds: Double?

    private(set) var detailHref: String?
    private var streamsTask: Task<Void, Never>?

    // MARK: - Load

    func load(item: SearchItem) {
        guard detail == nil && !isLoadingDetail else { return }
        detailHref = item.href
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
    }

    func selectStream(_ stream: StreamResult, from sourceView: UIView? = nil) {
        selectedStream = stream

        let context = PlayerContext(
            mediaTitle: detail?.title ?? "",
            episodeNumber: Int(selectedEpisode?.number ?? 1),
            episodeTitle: nil,
            imageUrl: detail?.image ?? "",
            aniListID: aniListID, // Added this
            moduleId: ModuleManager.shared.activeModule?.id,
            totalEpisodes: detail?.episodes.count,
            resumeFrom: resumeWatchedSeconds,
            detailHref: detailHref,
            streamTitle: stream.title,
            workingDetailHref: detailHref
        )

        // Build a WatchNextLoader that dynamically finds the next episode by current episode number
        let episodes = detail?.episodes ?? []
        let watchNextLoader: WatchNextLoader? = episodes.isEmpty ? nil : { [weak self] currentEpNum in
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

        PlayerPresenter.shared.presentPlayer(stream: stream, context: context, onWatchNext: watchNextLoader, from: sourceView)
    }
}
