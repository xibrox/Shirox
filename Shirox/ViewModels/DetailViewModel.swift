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

    // Player state
    @Published var selectedStream: StreamResult?
    @Published var showPlayer = false

    private(set) var detailHref: String?

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

        Task {
            do {
                let streams = try await JSEngine.shared.fetchStreams(episodeUrl: episode.href)
                streamOptions = streams.sorted { $0.title < $1.title }
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoadingStreams = false
        }
    }

    func selectStream(_ stream: StreamResult, from sourceView: UIView? = nil) {
        selectedStream = stream
        let context = PlayerContext(
            mediaTitle: detail?.title ?? "",
            episodeNumber: Int(selectedEpisode?.number ?? 1),
            episodeTitle: nil,
            imageUrl: detail?.image ?? "",
            aniListID: nil,
            moduleId: ModuleManager.shared.activeModule?.id,
            totalEpisodes: detail?.episodes.count,
            resumeFrom: nil,
            detailHref: detailHref
        )
        PlayerPresenter.shared.presentPlayer(stream: stream, context: context, from: sourceView)
    }
}
