import Foundation

struct UserProfile: Identifiable, Codable {
    let id: Int
    let provider: ProviderType
    let name: String
    let about: String?
    let avatarURL: String?
    let bannerImage: String?
    var isFollowing: Bool?
    let statistics: ProfileStatistics?
    let favourites: [Media]?

    init(id: Int, provider: ProviderType, name: String, about: String? = nil, avatarURL: String?,
         bannerImage: String?, isFollowing: Bool?, statistics: ProfileStatistics?,
         favourites: [Media]? = nil) {
        self.id = id
        self.provider = provider
        self.name = name
        self.about = about
        self.avatarURL = avatarURL
        self.bannerImage = bannerImage
        self.isFollowing = isFollowing
        self.statistics = statistics
        self.favourites = favourites
    }
}

struct ProfileStatistics: Codable {
    let anime: ProfileAnimeStats?
}

struct ProfileAnimeStats: Codable {
    let count: Int
    let episodesWatched: Int
    let meanScore: Double
    let minutesWatched: Int
    let statuses: [ProfileStatusStat]?
    let formats: [ProfileFormatStat]?
    let genres: [ProfileGenreStat]?
    let scores: [ProfileScoreStat]?
}

struct ProfileStatusStat: Codable {
    let status: String
    let count: Int
}

struct ProfileFormatStat: Codable {
    let format: String
    let count: Int
}

struct ProfileGenreStat: Codable {
    let genre: String
    let count: Int
}

struct ProfileScoreStat: Codable {
    let score: Int
    let count: Int
}
