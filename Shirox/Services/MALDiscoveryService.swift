import Foundation

final class MALDiscoveryService {
    nonisolated(unsafe) static let shared = MALDiscoveryService()
    private let base = URL(string: "https://api.jikan.moe/v4")!
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        return URLSession(configuration: cfg)
    }()
    private init() {}

    // MARK: - Jikan models

    struct JikanAnime: Decodable {
        let mal_id: Int
        let title: String?
        let title_english: String?
        let title_japanese: String?
        let images: JikanImages?
        let synopsis: String?
        let episodes: Int?
        let status: String?
        let score: Double?
        let genres: [JikanGenre]?
        let season: String?
        let year: Int?
        let type: String?
        let source: String?
        let relations: [JikanRelation]?
    }

    struct JikanImages: Decodable {
        let jpg: JikanImageSet?
        let webp: JikanImageSet?
    }

    struct JikanImageSet: Decodable {
        let image_url: String?
        let large_image_url: String?
    }

    struct JikanGenre: Decodable {
        let name: String
    }

    struct JikanRelation: Decodable {
        let relation: String
        let entry: [JikanRelationEntry]
    }

    struct JikanRelationEntry: Decodable {
        let mal_id: Int
        let name: String
        let type: String
    }

    private struct JikanPage<T: Decodable>: Decodable {
        let data: [T]
    }

    private struct JikanSingle<T: Decodable>: Decodable {
        let data: T
    }

    // MARK: - Fetch helpers

    private func fetchList(_ path: String, queryItems: [URLQueryItem] = [], retrying: Bool = false) async throws -> [JikanAnime] {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "sfw", value: "true")] + queryItems
        let (data, response) = try await session.data(from: components.url!)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 429 {
                if retrying { throw ProviderError.serverError(429) }
                try await Task.sleep(nanoseconds: 1_000_000_000)
                return try await fetchList(path, queryItems: queryItems, retrying: true)
            }
            if http.statusCode >= 500 { throw ProviderError.serverError(http.statusCode) }
        }
        var seen = Set<Int>()
        return try JSONDecoder().decode(JikanPage<JikanAnime>.self, from: data).data.filter {
            guard $0.mal_id > 0 else { return false }
            guard let imgUrl = $0.images?.jpg?.image_url, !imgUrl.isEmpty, !imgUrl.contains("qm_50") else { return false }
            return seen.insert($0.mal_id).inserted
        }
    }

    private func fetchSingle(_ path: String, retrying: Bool = false) async throws -> JikanAnime {
        let url = base.appendingPathComponent(path)
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 429 {
                if retrying { throw ProviderError.serverError(429) }
                try await Task.sleep(nanoseconds: 1_000_000_000)
                return try await fetchSingle(path, retrying: true)
            }
            if http.statusCode >= 500 { throw ProviderError.serverError(http.statusCode) }
        }
        return try JSONDecoder().decode(JikanSingle<JikanAnime>.self, from: data).data
    }

    // MARK: - Public API

    func trending(page: Int = 1) async throws -> [JikanAnime] {
        try await fetchList("top/anime", queryItems: [
            URLQueryItem(name: "filter", value: "airing"),
            URLQueryItem(name: "limit", value: "20"),
            URLQueryItem(name: "page", value: "\(page)")
        ])
    }

    func seasonal(page: Int = 1) async throws -> [JikanAnime] {
        try await fetchList("seasons/now", queryItems: [
            URLQueryItem(name: "limit", value: "20"),
            URLQueryItem(name: "page", value: "\(page)")
        ])
    }

    func popular(page: Int = 1) async throws -> [JikanAnime] {
        try await fetchList("top/anime", queryItems: [
            URLQueryItem(name: "filter", value: "bypopularity"),
            URLQueryItem(name: "limit", value: "20"),
            URLQueryItem(name: "page", value: "\(page)")
        ])
    }

    func topRated(page: Int = 1) async throws -> [JikanAnime] {
        try await fetchList("top/anime", queryItems: [
            URLQueryItem(name: "filter", value: "favorite"),
            URLQueryItem(name: "limit", value: "20"),
            URLQueryItem(name: "page", value: "\(page)")
        ])
    }

    func browse(category: BrowseCategory, page: Int) async throws -> [JikanAnime] {
        switch category {
        case .trending: return try await trending(page: page)
        case .seasonal: return try await seasonal(page: page)
        case .popular:  return try await popular(page: page)
        case .topRated: return try await topRated(page: page)
        }
    }

    func search(_ query: String) async throws -> [JikanAnime] {
        try await fetchList("anime", queryItems: [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: "25")
        ])
    }

    func detail(malId: Int) async throws -> JikanAnime {
        try await fetchSingle("anime/\(malId)/full")
    }

    struct JikanEpisode: Decodable {
        let mal_id: Int
        let title: String?
    }

    /// Fetches episode titles from Jikan (up to 100 per page).
    func episodes(malId: Int, page: Int = 1) async throws -> [JikanEpisode] {
        var components = URLComponents(url: base.appendingPathComponent("anime/\(malId)/episodes"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "page", value: "\(page)")]
        let (data, response) = try await session.data(from: components.url!)
        if let http = response as? HTTPURLResponse, http.statusCode == 429 { throw ProviderError.serverError(429) }
        return try JSONDecoder().decode(JikanPage<JikanEpisode>.self, from: data).data
    }

    // MARK: - Mapping to shared Media

    func mapToMedia(_ a: JikanAnime) -> Media {
        Media(
            id: a.mal_id,
            idMal: a.mal_id,
            provider: .mal,
            title: MediaTitle(romaji: a.title, english: a.title_english, native: a.title_japanese),
            coverImage: MediaCoverImage(
                large: a.images?.jpg?.image_url,
                extraLarge: a.images?.jpg?.large_image_url
            ),
            bannerImage: nil,
            description: a.synopsis,
            episodes: a.episodes,
            status: a.status,
            averageScore: a.score.map { Int($0 * 10) },
            genres: a.genres?.map { $0.name },
            season: a.season?.uppercased(),
            seasonYear: a.year,
            nextAiringEpisode: nil,
            relations: {
                guard let jikanRelations = a.relations else { return nil }
                // Map the meaningful Jikan relation labels to the app's relationType
                // strings. Sequel handling is preserved so next-episode chaining works.
                func relationType(for label: String) -> String? {
                    switch label {
                    case "Sequel":              return "SEQUEL"
                    case "Prequel":             return "PREQUEL"
                    case "Side story":          return "SIDE_STORY"
                    case "Parent story":        return "PARENT"
                    case "Alternative version",
                         "Alternative setting": return "ALTERNATIVE"
                    default:                    return nil
                    }
                }
                let edges: [MediaRelationEdge] = jikanRelations
                    .compactMap { rel -> [MediaRelationEdge]? in
                        guard let type = relationType(for: rel.relation) else { return nil }
                        return rel.entry
                            .filter { $0.type == "anime" }
                            .map { entry in
                                MediaRelationEdge(
                                    relationType: type,
                                    node: Media(
                                        id: entry.mal_id,
                                        idMal: entry.mal_id,
                                        provider: .mal,
                                        title: MediaTitle(romaji: entry.name, english: nil, native: nil),
                                        coverImage: MediaCoverImage(large: nil, extraLarge: nil),
                                        bannerImage: nil,
                                        description: nil,
                                        episodes: nil,
                                        status: nil,
                                        averageScore: nil,
                                        genres: nil,
                                        season: nil,
                                        seasonYear: nil,
                                        nextAiringEpisode: nil,
                                        relations: nil,
                                        type: "TV",
                                        format: nil
                                    )
                                )
                            }
                    }
                    .flatMap { $0 }
                return edges.isEmpty ? nil : MediaRelations(edges: edges)
            }(),
            type: a.type,
            format: a.source
        )
    }
}
