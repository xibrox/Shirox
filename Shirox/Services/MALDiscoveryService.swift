import Foundation

final class MALDiscoveryService {
    static let shared = MALDiscoveryService()
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

    private func fetchList(_ path: String, queryItems: [URLQueryItem] = []) async throws -> [JikanAnime] {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "sfw", value: "true")] + queryItems
        let (data, response) = try await session.data(from: components.url!)
        if let http = response as? HTTPURLResponse, http.statusCode >= 500 {
            throw ProviderError.serverError(http.statusCode)
        }
        return try JSONDecoder().decode(JikanPage<JikanAnime>.self, from: data).data
    }

    private func fetchSingle(_ path: String) async throws -> JikanAnime {
        let url = base.appendingPathComponent(path)
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode >= 500 {
            throw ProviderError.serverError(http.statusCode)
        }
        return try JSONDecoder().decode(JikanSingle<JikanAnime>.self, from: data).data
    }

    // MARK: - Public API

    func trending() async throws -> [JikanAnime] {
        try await fetchList("top/anime", queryItems: [
            URLQueryItem(name: "filter", value: "airing"),
            URLQueryItem(name: "limit", value: "20")
        ])
    }

    func seasonal() async throws -> [JikanAnime] {
        try await fetchList("seasons/now", queryItems: [URLQueryItem(name: "limit", value: "20")])
    }

    func popular() async throws -> [JikanAnime] {
        try await fetchList("top/anime", queryItems: [
            URLQueryItem(name: "filter", value: "bypopularity"),
            URLQueryItem(name: "limit", value: "20")
        ])
    }

    func topRated() async throws -> [JikanAnime] {
        try await fetchList("top/anime", queryItems: [
            URLQueryItem(name: "filter", value: "favorite"),
            URLQueryItem(name: "limit", value: "20")
        ])
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

    // MARK: - Mapping to shared Media

    func mapToMedia(_ a: JikanAnime) -> Media {
        Media(
            id: a.mal_id,
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
            relations: nil,
            type: a.type,
            format: a.source
        )
    }
}
