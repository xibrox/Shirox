import Foundation

struct PlayerContext {
    let mediaTitle: String
    let episodeNumber: Int
    let episodeTitle: String?
    let imageUrl: String
    let aniListID: Int?
    let moduleId: String?
    let totalEpisodes: Int?
    let resumeFrom: Double?        // seconds to seek to on start (nil = from beginning)
}
