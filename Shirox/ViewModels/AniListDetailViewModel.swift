import Foundation

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

    func onStreamsLoaded(_ streams: [StreamResult]) {
        showStreamPicker = false
        pendingStreams = streams.sorted { $0.title < $1.title }
        showFinalStreamPicker = true
    }

    func selectStream(_ stream: StreamResult) {
        selectedStream = stream
        showFinalStreamPicker = false
        showPlayer = true
    }
}
