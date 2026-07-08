import Foundation

struct PlayerContext {
    let mediaTitle: String
    let episodeNumber: Int
    let episodeTitle: String?
    let imageUrl: String
    let aniListID: Int?
    let malID: Int?
    let moduleId: String?
    let totalEpisodes: Int?
    /// Number of episodes currently aired/available (may be less than totalEpisodes for ongoing shows).
    let availableEpisodes: Int?
    let isAiring: Bool?
    var resumeFrom: Double?           // seconds to seek to on start (nil = from beginning)
    let detailHref: String?           // module detail page URL, used for Up Next navigation
    var episodeHref: String?          // the playing episode's own href; anchors next-episode resolution on resume
    let streamTitle: String?          // the selected stream's title (e.g., "SUB", "DUB", "pahe", "Episode 1")
    let workingDetailHref: String?    // actual working search result href that has full episode data
    let thumbnailUrl: String?         // episode thumbnail (16:9), nil falls back to cover art
    var isLocalPlayback: Bool = false // true when playing a user-picked local file
    var jellyfinItemId: String? = nil // set when streaming from a Jellyfin server
}
