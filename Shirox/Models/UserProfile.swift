import Foundation

struct UserProfile: Identifiable, Codable, Sendable {
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

/// Axis marks for the profile score-distribution chart.
///
/// These used to come from the app's local score-format setting, which describes how *this
/// device* displays scores — not the format the account's stats actually arrive in. When the
/// two disagreed (a 1–10 setting against a 0–100 account) the chart drew marks at 1…10 while
/// the data spanned to 100, crushing every label into the left edge over an empty plot.
/// Reading the marks off the data itself can't drift out of sync with it.
enum ScoreChartAxis {
    /// At most this many labels before they start colliding on a phone-width chart.
    static let maxLabels = 10

    static func values(for scores: [Int]) -> [Int] {
        let sorted = scores.sorted()
        guard sorted.count > maxLabels else { return sorted }
        // Too many buckets to label individually — keep an evenly spaced subset, always
        // including the last so the axis reaches the end of the data.
        let step = Int((Double(sorted.count) / Double(maxLabels)).rounded(.up))
        var picked = stride(from: 0, to: sorted.count, by: step).map { sorted[$0] }
        if let last = sorted.last, picked.last != last { picked.append(last) }
        return picked
    }
}
