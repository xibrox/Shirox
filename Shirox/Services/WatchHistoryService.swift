import Foundation

struct WatchProgress: Codable, Identifiable {
    let mediaId: Int
    let title: String
    let coverImage: String?
    var lastEpisode: Int
    let totalEpisodes: Int?
    var watchedAt: Date
    var id: Int { mediaId }
}

@MainActor
final class WatchHistoryService: ObservableObject {
    static let shared = WatchHistoryService()
    @Published var history: [WatchProgress] = []
    private let storageKey = "watchHistory"

    private init() { loadFromStorage() }

    func record(media: AniListMedia, episode: Int) {
        history.removeAll { $0.mediaId == media.id }
        history.insert(WatchProgress(
            mediaId: media.id,
            title: media.title.displayTitle,
            coverImage: media.coverImage.best,
            lastEpisode: episode,
            totalEpisodes: media.episodes,
            watchedAt: Date()
        ), at: 0)
        saveToStorage()
    }

    func progress(for mediaId: Int) -> WatchProgress? {
        history.first { $0.mediaId == mediaId }
    }

    private func saveToStorage() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func loadFromStorage() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode([WatchProgress].self, from: data)
        else { return }
        history = saved
    }
}
