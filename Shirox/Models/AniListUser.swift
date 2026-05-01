import Foundation

struct AniListUser: Identifiable, Codable {
    let id: Int
    let name: String
    let about: String?
    let avatar: AniListUserAvatar?
    let bannerImage: String?
    var isFollowing: Bool?
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
    let statuses: [StatusStatistic]?
    let formats: [FormatStatistic]?
    let genres: [GenreStatistic]?
    let scores: [ScoreStatistic]?
}

struct StatusStatistic: Codable {
    let status: String
    let count: Int
}

struct FormatStatistic: Codable {
    let format: String
    let count: Int
}

struct GenreStatistic: Codable {
    let genre: String
    let count: Int
}

struct ScoreStatistic: Codable {
    let score: Int
    let count: Int
}

struct AniListFavourites: Codable {
    let anime: AniListFavouriteConnection?
}

struct AniListFavouriteConnection: Codable {
    let nodes: [AniListMedia]?
}
