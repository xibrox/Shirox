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
    }

    func onStreamsLoaded(_ streams: [StreamResult]) {
        showStreamPicker = false
        let sorted = streams.sorted { $0.title < $1.title }
        if sorted.count == 1 {
            selectStream(sorted[0])
        } else {
            pendingStreams = sorted
            showFinalStreamPicker = true
        }
    }

    func selectStream(_ stream: StreamResult, from sourceView: UIView? = nil) {
        selectedStream = stream
        guard let media else { return }
        let context = PlayerContext(
            mediaTitle: media.title.english ?? media.title.romaji ?? "",
            episodeNumber: selectedEpisodeNumber ?? 1,
            episodeTitle: nil,
            imageUrl: media.coverImage.extraLarge ?? media.coverImage.large ?? "",
            aniListID: media.id,
            moduleId: nil,
            totalEpisodes: media.episodes,
            resumeFrom: nil,
            detailHref: nil
        )
        PlayerPresenter.shared.presentPlayer(stream: stream, context: context, from: sourceView)
    }
}
