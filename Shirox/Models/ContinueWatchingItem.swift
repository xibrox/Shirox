struct ContinueWatchingItem: Identifiable, Codable {
    let id: UUID
    let mediaTitle: String
    let episodeNumber: Int
    let episodeTitle: String?
    let imageUrl: String
    let streamUrl: String
    let headers: [String: String]?
    let subtitle: String?
    let aniListID: Int?
    let moduleId: String?
    var watchedSeconds: Double
    var totalSeconds: Double
    let totalEpisodes: Int?
    var lastWatchedAt: Date
}
