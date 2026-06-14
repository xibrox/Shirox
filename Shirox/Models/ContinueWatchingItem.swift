import Foundation

struct StoredStream: Codable, Hashable {
    let title: String
    let url: String
    let headers: [String: String]
    let subtitle: String?
    var subtitleHeaders: [String: String]?

    var asStreamResult: StreamResult? {
        guard let url = URL(string: url) else { return nil }
        return StreamResult(title: title, url: url, headers: headers,
                            subtitle: subtitle, subtitleHeaders: subtitleHeaders ?? [:])
    }
}

struct ContinueWatchingItem: Identifiable, Codable, Hashable {
    let id: UUID
    let mediaTitle: String
    let episodeNumber: Int
    let episodeTitle: String?
    let imageUrl: String
    let streamUrl: String
    let headers: [String: String]?
    let subtitle: String?
    var subtitleHeaders: [String: String]?
    var allSubtitles: [SubtitleTrack]?
    let streamTitle: String?  // the selected stream's title (e.g., "SUB", "DUB", "pahe")
    var allStreams: [StoredStream]?
    let aniListID: Int?
    let malID: Int?
    let moduleId: String?
    let detailHref: String?
    var watchedSeconds: Double
    var totalSeconds: Double
    var totalEpisodes: Int?
    /// Number of episodes currently aired/available (may be less than totalEpisodes for ongoing shows).
    var availableEpisodes: Int?
    var isAiring: Bool?
    var lastWatchedAt: Date
    var thumbnailUrl: String?
    var aniListUpdatedAt: Int?
}
