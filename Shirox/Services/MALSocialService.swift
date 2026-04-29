import Foundation

final class MALSocialService {
    static let shared = MALSocialService()
    private let jikanBase = URL(string: "https://api.jikan.moe/v4")!
    private let malBase = URL(string: "https://api.myanimelist.net/v2")!
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        return URLSession(configuration: cfg)
    }()
    private init() {}

    // MARK: - Current user profile (official MAL API)

    func fetchCurrentUserProfile() async throws -> UserProfile {
        var components = URLComponents(url: malBase.appendingPathComponent("users/@me"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "fields", value: "anime_statistics,picture")]
        let request = try await MALAuthManager.shared.authorizedRequest(url: components.url!)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            throw ProviderError.unauthenticated
        }

        struct MALUser: Decodable {
            let id: Int; let name: String; let picture: String?
            let anime_statistics: MALAnimeStatistics?
        }
        struct MALAnimeStatistics: Decodable {
            let num_items_watching: Int?; let num_items_completed: Int?
            let num_items_on_hold: Int?; let num_items_dropped: Int?
            let num_items_plan_to_watch: Int?; let num_episodes: Int?
            let mean_score: Double?
        }

        let user = try JSONDecoder().decode(MALUser.self, from: data)
        let stats = user.anime_statistics.map { s -> ProfileStatistics in
            let total = (s.num_items_watching ?? 0) + (s.num_items_completed ?? 0) +
                        (s.num_items_on_hold ?? 0) + (s.num_items_dropped ?? 0) +
                        (s.num_items_plan_to_watch ?? 0)
            return ProfileStatistics(anime: ProfileAnimeStats(
                count: total,
                episodesWatched: s.num_episodes ?? 0,
                meanScore: s.mean_score ?? 0,
                minutesWatched: 0,
                statuses: nil, formats: nil, genres: nil, scores: nil
            ))
        }
        return UserProfile(id: user.id, provider: .mal, name: user.name,
                           avatarURL: user.picture, bannerImage: nil,
                           isFollowing: nil, statistics: stats)
    }

    // MARK: - Public profile (Jikan)

    func fetchProfile(username: String) async throws -> UserProfile {
        struct JikanUserImages: Decodable {
            let jpg: JikanUserImageSet?
            struct JikanUserImageSet: Decodable { let image_url: String? }
        }
        struct JikanAnimeStats: Decodable {
            let total_entries: Int?; let episodes_watched: Int?; let mean_score: Double?
        }
        struct JikanUserStats: Decodable { let anime: JikanAnimeStats? }
        struct JikanUser: Decodable {
            let mal_id: Int; let username: String
            let images: JikanUserImages?; let statistics: JikanUserStats?
        }
        struct Wrapper: Decodable { let data: JikanUser }

        let url = jikanBase.appendingPathComponent("users/\(username)")
        let (data, _) = try await session.data(from: url)
        let user = try JSONDecoder().decode(Wrapper.self, from: data).data
        let stats = user.statistics?.anime.map { a -> ProfileStatistics in
            ProfileStatistics(anime: ProfileAnimeStats(
                count: a.total_entries ?? 0,
                episodesWatched: a.episodes_watched ?? 0,
                meanScore: a.mean_score ?? 0,
                minutesWatched: 0,
                statuses: nil, formats: nil, genres: nil, scores: nil
            ))
        }
        return UserProfile(id: user.mal_id, provider: .mal, name: user.username,
                           avatarURL: user.images?.jpg?.image_url, bannerImage: nil,
                           isFollowing: nil, statistics: stats ?? nil)
    }

    // MARK: - History as activity (Jikan)

    func fetchHistory(username: String, page: Int) async throws -> [UserActivity] {
        struct JikanHistoryMedia: Decodable { let mal_id: Int; let title: String? }
        struct JikanHistoryEntry: Decodable {
            let entry: JikanHistoryMedia
            let episodes_seen: Int?; let date: String?
        }
        struct JikanHistoryPage: Decodable { let data: [JikanHistoryEntry] }

        var components = URLComponents(url: jikanBase.appendingPathComponent("users/\(username)/history/anime"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "page", value: "\(page)")]
        let (data, _) = try await session.data(from: components.url!)
        let result = try JSONDecoder().decode(JikanHistoryPage.self, from: data)

        return result.data.enumerated().map { index, entry in
            let media = ActivityMedia(
                id: entry.entry.mal_id,
                title: AniListTitle(romaji: entry.entry.title, english: nil, native: nil),
                coverImage: nil
            )
            return UserActivity(
                id: entry.entry.mal_id * 1000 + index,
                kind: .list(status: "watched", progress: entry.episodes_seen.map { "\($0)" }, media: media),
                createdAt: parseDate(entry.date),
                user: nil,
                likeCount: 0,
                replyCount: 0,
                isLiked: false
            )
        }
    }

    // MARK: - Friends as followers (Jikan)

    func fetchFriends(username: String, page: Int) async throws -> [UserProfile] {
        struct JikanUserImageSet: Decodable { let image_url: String? }
        struct JikanUserImages: Decodable { let jpg: JikanUserImageSet? }
        struct JikanFriendUser: Decodable { let username: String; let images: JikanUserImages? }
        struct JikanFriend: Decodable { let user: JikanFriendUser }
        struct JikanFriendsPage: Decodable { let data: [JikanFriend] }

        var components = URLComponents(url: jikanBase.appendingPathComponent("users/\(username)/friends"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "page", value: "\(page)")]
        let (data, _) = try await session.data(from: components.url!)
        let friends = try JSONDecoder().decode(JikanFriendsPage.self, from: data)
        return friends.data.map { f in
            UserProfile(id: 0, provider: .mal, name: f.user.username,
                        avatarURL: f.user.images?.jpg?.image_url,
                        bannerImage: nil, isFollowing: nil, statistics: nil)
        }
    }

    private func parseDate(_ dateString: String?) -> Int {
        guard let s = dateString,
              let date = ISO8601DateFormatter().date(from: s) else { return 0 }
        return Int(date.timeIntervalSince1970)
    }
}
