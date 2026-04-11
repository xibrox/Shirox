import Foundation

struct PlayerContext {
    let mediaTitle: String
    let episodeNumber: Int
    let episodeTitle: String?
    let imageUrl: String
    let aniListID: Int?
    let moduleId: String?
    let totalEpisodes: Int?
    let resumeFrom: Double?           // seconds to seek to on start (nil = from beginning)
    let detailHref: String?           // module detail page URL, used for Up Next navigation
    let streamTitle: String?          // the selected stream's title (e.g., "SUB", "DUB", "pahe", "Episode 1")
    let workingDetailHref: String?    // actual working search result href that has full episode data
}
