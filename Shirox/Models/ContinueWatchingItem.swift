import Foundation

struct ContinueWatchingItem: Identifiable, Codable {
    let id: UUID
    let mediaTitle: String
    let episodeNumber: Int
    let episodeTitle: String?
    let imageUrl: String
    let streamUrl: String
    let headers: [String: String]?
    let subtitle: String?
    let streamTitle: String?  // the selected stream's title (e.g., "SUB", "DUB", "pahe")
    let aniListID: Int?
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
}
