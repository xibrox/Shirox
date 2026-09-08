import Foundation

/// Discovery through MyAnimeList's own API rather than Jikan.
///
/// The app has always split its MyAnimeList access: the library reads and writes go to
/// `api.myanimelist.net` under OAuth, while everything a person browses — trending, the season,
/// the rankings, search — came from Jikan, the unofficial mirror of the same data. That was
/// invisible until Jikan went down, at which point the rankings behind three of the five Home
/// rows returned 504 from one host and an empty list from the other, and there was nothing to
/// fall back to.
///
/// The official API serves all of it, and needs only the client id the app already ships for
/// sign-in — no user token, so it works signed out exactly as Jikan did. Its ranking types line
/// up one-for-one with the Jikan filters that were being used, and it returns genres and themes
/// in a single list, which Jikan splits and the app had to reassemble.
///
/// Jikan is still needed for episode listings, which MyAnimeList's own API does not expose.
final class MALOfficialDiscoveryService {
    nonisolated(unsafe) static let shared = MALOfficialDiscoveryService()
    private init() {}

    private let base = URL(string: "https://api.myanimelist.net/v2")!

    /// The fields worth asking for. The API returns almost nothing by default, and every field
    /// is opt-in, so this list is what populates a card.
    private static let fields =
        "id,title,main_picture,synopsis,mean,genres,num_episodes,status,start_season,alternative_titles,broadcast"

    /// Ranking types, named as MyAnimeList names them.
    enum Ranking: String {
        case airing
        case byPopularity = "bypopularity"
        case all
    }

    // MARK: - Wire format

    private struct Page: Decodable {
        struct Item: Decodable { let node: Node }
        let data: [Item]
    }

    struct Node: Decodable {
        struct Picture: Decodable { let medium: String?; let large: String? }
        struct Named: Decodable { let name: String }
        struct AlternativeTitles: Decodable { let en: String?; let ja: String? }
        struct Season: Decodable { let year: Int?; let season: String? }

        let id: Int
        let title: String
        let main_picture: Picture?
        let synopsis: String?
        let mean: Double?
        let genres: [Named]?
        let num_episodes: Int?
        let status: String?
        let start_season: Season?
        let alternative_titles: AlternativeTitles?
        let broadcast: Broadcast?

        struct Broadcast: Decodable {
            let day_of_the_week: String?
            let start_time: String?
        }
    }

    // MARK: - Requests

    private func get(_ path: String, query: [URLQueryItem]) async throws -> [Node] {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query + [URLQueryItem(name: "fields", value: Self.fields)]
        var request = URLRequest(url: components.url!)
        // The public client id is enough for discovery; a user token is only needed for a
        // library. Sending it unconditionally keeps these rows working signed out.
        request.setValue(MALAuthManager.shared.clientId, forHTTPHeaderField: "X-MAL-CLIENT-ID")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ProviderError.serverError(http.statusCode)
        }
        return try JSONDecoder().decode(Page.self, from: data).data.map(\.node)
    }

    func ranking(_ type: Ranking, limit: Int, offset: Int = 0) async throws -> [Node] {
        try await get("anime/ranking", query: [
            URLQueryItem(name: "ranking_type", value: type.rawValue),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "offset", value: "\(offset)")
        ])
    }

    func season(year: Int, season: String, limit: Int, offset: Int = 0) async throws -> [Node] {
        try await get("anime/season/\(year)/\(season)", query: [
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "offset", value: "\(offset)")
        ])
    }

    func search(_ query: String, limit: Int) async throws -> [Node] {
        try await get("anime", query: [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: "\(limit)")
        ])
    }

    /// The next time a show broadcasts, from MyAnimeList's weekday-and-time pair.
    ///
    /// MyAnimeList doesn't publish per-episode timestamps the way AniList does — it gives a
    /// recurring slot, always in Japan Standard Time. Resolving it against JST and returning an
    /// absolute instant lets the calendar show it in the viewer's own timezone, which is the
    /// part that would otherwise be quietly wrong for everyone outside Japan.
    static func nextAiring(dayOfWeek: String, startTime: String, from now: Date = Date()) -> Date? {
        let weekdays = ["sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4,
                        "thursday": 5, "friday": 6, "saturday": 7]
        guard let weekday = weekdays[dayOfWeek.lowercased()],
              let tokyo = TimeZone(identifier: "Asia/Tokyo") else { return nil }

        let parts = startTime.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tokyo
        var components = DateComponents()
        components.weekday = weekday
        components.hour = hour
        components.minute = minute
        return calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime)
    }

    /// Currently-airing shows with a known broadcast slot, as scheduled instants.
    func airingSchedule(within days: Int, limit: Int = 100) async throws -> [(node: Node, airsAt: Date)] {
        let airing = try await ranking(.airing, limit: limit)
        let now = Date()
        guard let horizon = Calendar.current.date(byAdding: .day, value: days, to: now) else { return [] }
        return airing.compactMap { node in
            guard let day = node.broadcast?.day_of_the_week,
                  let time = node.broadcast?.start_time,
                  let airsAt = Self.nextAiring(dayOfWeek: day, startTime: time, from: now),
                  airsAt <= horizon else { return nil }
            return (node, airsAt)
        }
        .sorted { $0.airsAt < $1.airsAt }
    }

    /// The season MyAnimeList is currently in, in the form its URLs expect.
    static func currentSeason(now: Date = Date()) -> (year: Int, season: String) {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: now)
        switch calendar.component(.month, from: now) {
        case 1...3:  return (year, "winter")
        case 4...6:  return (year, "spring")
        case 7...9:  return (year, "summer")
        default:     return (year, "fall")
        }
    }

    // MARK: - Mapping

    func mapToMedia(_ node: Node) -> Media {
        Media(
            id: node.id,
            idMal: node.id,
            provider: .mal,
            title: MediaTitle(
                romaji: node.title,
                english: node.alternative_titles?.en?.isEmpty == false ? node.alternative_titles?.en : nil,
                native: node.alternative_titles?.ja
            ),
            coverImage: MediaCoverImage(
                large: node.main_picture?.medium,
                extraLarge: node.main_picture?.large
            ),
            bannerImage: nil,
            description: node.synopsis,
            episodes: node.num_episodes.flatMap { $0 > 0 ? $0 : nil },
            status: node.status,
            // `mean` is out of ten; the app's scale — and AniList's — is out of a hundred.
            averageScore: node.mean.map { Int(($0 * 10).rounded()) },
            genres: node.genres?.map(\.name),
            season: node.start_season?.season,
            seasonYear: node.start_season?.year,
            nextAiringEpisode: nil,
            relations: nil,
            type: "ANIME",
            format: nil
        )
    }
}
