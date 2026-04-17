import Foundation

struct AniListUser: Identifiable, Codable {
    let id: Int
    let name: String
    let avatar: AniListUserAvatar?
    let statistics: AniListUserStatistics?
    let favourites: AniListFavourites?
}

struct AniListUserAvatar: Codable {
    let large: String?
}

struct AniListUserStatistics: Codable {
    let anime: AniListAnimeStats?
}

struct AniListAnimeStats: Codable {
    let count: Int
    let episodesWatched: Int
    let meanScore: Double
    let minutesWatched: Int
}

struct AniListFavourites: Codable {
    let anime: AniListFavouriteConnection?
}

struct AniListFavouriteConnection: Codable {
    let nodes: [AniListMedia]?
}
