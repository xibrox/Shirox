import Foundation

struct MarkContext {
    let aniListID: Int?
    let malID: Int?
    let moduleId: String?
    let mediaTitle: String
    let imageUrl: String?
    let totalEpisodes: Int?
    let availableEpisodes: Int?
    let detailHref: String?
    /// The tapped episode's own unique href — records a season-unique watched marker so a flat
    /// multi-season list doesn't show another season's same-numbered episode as watched.
    var episodeHref: String? = nil
    var isAiring: Bool? = nil
    var currentAniListProgress: Int? = nil
    var currentMALProgress: Int? = nil
    var currentAniListStatus: MediaListStatus? = nil
    var currentMALStatus: MediaListStatus? = nil
}

enum MarkResult {
    case applied
    case needsConfirmation(RemoteDowngrade)
}

struct RemoteDowngrade {
    let newProgress: Int
    let anilistFrom: Int?
    let malFrom: Int?
    let confirm: () async -> Void
    let localOnly: () -> Void
}
