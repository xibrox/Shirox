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
