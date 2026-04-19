import Foundation

// MARK: - Response wrappers with error handling

private struct GraphQLResponse<T: Decodable>: Decodable {
    let data: T?
    let errors: [GraphQLError]?
}

private struct GraphQLError: Decodable {
    let message: String
}

// MARK: - Page response structures

private struct PageData: Decodable {
    let Page: PageContent
}

private struct PageContent: Decodable {
    let media: [AniListMedia]
}

// MARK: - Media Data Wrapper

private struct MediaData: Decodable {
    let Media: AniListMedia
}

// MARK: - Service

final class AniListService {
    static let shared = AniListService()

    private let endpoint = URL(string: "https://graphql.anilist.co")!
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = [
            "Content-Type": "application/json",
            "Accept": "application/json"
        ]
        session = URLSession(configuration: config)
    }

    // MARK: - Public API

    func search(keyword: String) async throws -> [AniListMedia] {
        let query = """
        query ($search: String) {
          Page(page: 1, perPage: 25) {
            media(search: $search, type: ANIME, sort: SEARCH_MATCH, isAdult: false) {
              id
              title { romaji english native }
              coverImage { large extraLarge }
              averageScore
              genres
              description(asHtml: false)
            }
          }
        }
        """
        return try await fetchPage(query: query, variables: ["search": keyword])
    }

    func trending() async throws -> [AniListMedia] {
        let query = """
        query {
          Page(page: 1, perPage: 20) {
            media(type: ANIME, sort: TRENDING_DESC, isAdult: false) {
              id
              title { romaji english native }
              coverImage { large extraLarge }
              bannerImage
              averageScore
              genres
              description(asHtml: false)
            }
          }
        }
        """
        return try await fetchPage(query: query)
    }

    func seasonal() async throws -> [AniListMedia] {
        let (season, year) = AniListSeason.current()
        let query = """
        query ($season: MediaSeason, $year: Int) {
          Page(page: 1, perPage: 20) {
            media(season: $season, seasonYear: $year, type: ANIME, sort: POPULARITY_DESC, isAdult: false) {
              id
              title { romaji english native }
              coverImage { large extraLarge }
              bannerImage
              averageScore
              genres
              description(asHtml: false)
            }
          }
        }
        """
        return try await fetchPage(query: query, variables: ["season": season.rawValue, "year": year])
    }

    func popular() async throws -> [AniListMedia] {
        let query = """
        query {
          Page(page: 1, perPage: 20) {
            media(type: ANIME, sort: POPULARITY_DESC, isAdult: false) {
              id
              title { romaji english native }
              coverImage { large extraLarge }
              bannerImage
              averageScore
              genres
              description(asHtml: false)
            }
          }
        }
        """
        return try await fetchPage(query: query)
    }

    func topRated() async throws -> [AniListMedia] {
        let query = """
        query {
          Page(page: 1, perPage: 20) {
            media(type: ANIME, sort: SCORE_DESC, isAdult: false) {
              id
              title { romaji english native }
              coverImage { large extraLarge }
              bannerImage
              averageScore
              genres
              description(asHtml: false)
            }
          }
        }
        """
        return try await fetchPage(query: query)
    }

    func browse(category: BrowseCategory, page: Int) async throws -> [AniListMedia] {
        switch category {
        case .trending:
            let query = """
            query ($page: Int) {
              Page(page: $page, perPage: 20) {
                media(type: ANIME, sort: TRENDING_DESC, isAdult: false) {
                  id
                  title { romaji english native }
                  coverImage { large extraLarge }
                  bannerImage
                  averageScore
                  genres
                  description(asHtml: false)
                }
              }
            }
            """
            return try await fetchPage(query: query, variables: ["page": page])

        case .seasonal:
            let (season, year) = AniListSeason.current()
            let query = """
            query ($season: MediaSeason, $year: Int, $page: Int) {
              Page(page: $page, perPage: 20) {
                media(season: $season, seasonYear: $year, type: ANIME, sort: POPULARITY_DESC, isAdult: false) {
                  id
                  title { romaji english native }
                  coverImage { large extraLarge }
                  bannerImage
                  averageScore
                  genres
                  description(asHtml: false)
                }
              }
            }
            """
            return try await fetchPage(query: query, variables: ["season": season.rawValue, "year": year, "page": page])

        case .popular:
            let query = """
            query ($page: Int) {
              Page(page: $page, perPage: 20) {
                media(type: ANIME, sort: POPULARITY_DESC, isAdult: false) {
                  id
                  title { romaji english native }
                  coverImage { large extraLarge }
                  bannerImage
                  averageScore
                  genres
                  description(asHtml: false)
                }
              }
            }
            """
            return try await fetchPage(query: query, variables: ["page": page])

        case .topRated:
            let query = """
            query ($page: Int) {
              Page(page: $page, perPage: 20) {
                media(type: ANIME, sort: SCORE_DESC, isAdult: false) {
                  id
                  title { romaji english native }
                  coverImage { large extraLarge }
                  bannerImage
                  averageScore
                  genres
                  description(asHtml: false)
                }
              }
            }
            """
            return try await fetchPage(query: query, variables: ["page": page])
        }
    }

    func detail(id: Int) async throws -> AniListMedia {
        let query = """
        query ($id: Int) {
          Media(id: $id, type: ANIME, isAdult: false) {
            id
            title { romaji english native }
            coverImage { large extraLarge }
            bannerImage
            description(asHtml: false)
            episodes
            status
            nextAiringEpisode {
              episode
            }
            averageScore
            genres
            season
            seasonYear
            relations {
              edges {
                relationType
                node {
                  id
                  title { romaji english native }
                  coverImage { large extraLarge }
                  status
                  type
                  format
                }
              }
            }
          }
        }
        """
        let data = try await post(query: query, variables: ["id": id])
        let response = try JSONDecoder().decode(GraphQLResponse<MediaData>.self, from: data)
        if let errors = response.errors {
            throw AniListError.graphQL(errors.map(\.message).joined(separator: ", "))
        }
        guard let media = response.data?.Media else {
            throw AniListError.noData
        }
        return media
    }

    // MARK: - Private helpers

    private func fetchPage(query: String, variables: [String: Any] = [:]) async throws -> [AniListMedia] {
        let data = try await post(query: query, variables: variables)
        let response = try JSONDecoder().decode(GraphQLResponse<PageData>.self, from: data)
        if let errors = response.errors {
            throw AniListError.graphQL(errors.map(\.message).joined(separator: ", "))
        }
        return response.data?.Page.media ?? []
    }

    private func post(query: String, variables: [String: Any]) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let bodyDict: [String: Any] = ["query": query, "variables": variables]
        request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict, options: [])

        #if DEBUG
        print("AniList Request: \(bodyDict)")
        #endif

        let (data, response) = try await session.data(for: request)

        #if DEBUG
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            print("AniList Response:", json)
        }
        #endif

        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200:
                return data
            case 429:
                throw AniListError.rateLimited
            default:
                throw AniListError.httpError(http.statusCode)
            }
        }
        return data
    }
}

// MARK: - Errors

enum AniListError: LocalizedError {
    case rateLimited
    case httpError(Int)
    case graphQL(String)
    case noData
    case decodingError(String)

    var errorDescription: String? {
        switch self {
        case .rateLimited:
            return "AniList rate limit reached. Please wait a moment."
        case .httpError(let code):
            return "HTTP error \(code). Please try again."
        case .graphQL(let message):
            return "AniList error: \(message)"
        case .noData:
            return "No data received from AniList."
        case .decodingError(let message):
            return "Failed to parse response: \(message)"
        }
    }
}

// MARK: - AniList Mapping Manager

/// Manages persistent mappings between standard module titles and AniList IDs.
final class AniListMappingManager {
    static let shared = AniListMappingManager()
    
    private let userDefaults = UserDefaults.standard
    private let storageKey = "com.shirox.anilist_mappings"
    
    // Dictionary of moduleTitle -> aniListID
    private var mappings: [String: Int] = [:]
    
    private init() {
        loadMappings()
    }
    
    func saveMapping(title: String, aniListID: Int) {
        mappings[title.lowercased()] = aniListID
        persist()
    }
    
    func getMapping(title: String) -> Int? {
        return mappings[title.lowercased()]
    }
    
    func removeMapping(title: String) {
        mappings.removeValue(forKey: title.lowercased())
        persist()
    }
    
    private func loadMappings() {
        if let data = userDefaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String: Int].self, from: data) {
            self.mappings = decoded
        }
    }
    
    private func persist() {
        if let encoded = try? JSONEncoder().encode(mappings) {
            userDefaults.set(encoded, forKey: storageKey)
        }
    }
}

// MARK: - Browse Category

enum BrowseCategory: String, CaseIterable, Hashable {
    case trending
    case seasonal
    case popular
    case topRated

    var title: String {
        switch self {
        case .trending: return "Trending Now"
        case .seasonal: return "This Season"
        case .popular:  return "All-Time Popular"
        case .topRated: return "Top Rated"
        }
    }
}

// MARK: - TVDB Mapping Service

final class TVDBMappingService: ObservableObject {
    static let shared = TVDBMappingService()
    private let mappingEndpoint = "https://animap.s0n1c.ca/mappings/"
    private let tvdbEndpoint = "https://api4.thetvdb.com/v4"
    private let apiKey = "4cd66d53-3c21-45a7-9dd2-e4a9c2ed20a8"
    private let cacheKey = "tvdb_mappings_cache_v3"

    @Published private var token: String?
    private var tokenExpiry: Date?

    // Cache: AniListID -> (TVDB_ID, SeasonNumber, PosterPath?, FanartPath?)
    struct CachedData: Codable {
        let tid: Int
        var season: Int?
        var posterPath: String?
        var fanartPath: String?
    }
    private var cache: [Int: CachedData] = [:]
    private var episodeCache: [Int: [AniMapEpisode]] = [:]

    private init() {

        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let decoded = try? JSONDecoder().decode([Int: CachedData].self, from: data) {
            self.cache = decoded
        }
    }

    private func authenticate() async throws -> String {
        if let t = token, let expiry = tokenExpiry, expiry > Date() {
            return t
        }

        struct LoginResponse: Decodable {
            struct Data: Decodable { let token: String }
            let data: Data
        }

        var request = URLRequest(url: URL(string: "\(tvdbEndpoint)/login")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["apikey": apiKey])

        let (data, _) = try await URLSession.shared.data(for: request)
        let res = try JSONDecoder().decode(LoginResponse.self, from: data)
        self.token = res.data.token
        self.tokenExpiry = Date().addingTimeInterval(3600 * 24 * 25) // Token usually lasts 1 month
        return res.data.token
    }

    func getTVDBId(for aniListId: Int) async -> (id: Int, season: Int?)? {
        if let cached = cache[aniListId] {
            return cached.tid > 0 ? (cached.tid, cached.season) : nil
        }
        
        do {
            let urlString = "\(mappingEndpoint)\(aniListId)?mapping_key=anilist"
            guard let url = URL(string: urlString) else { return nil }
            
            let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url))
            
            struct Mapping: Decodable {
                let tvdb_id: Int?
                let tvdb_season: Int?
            }
            
            let results = try JSONDecoder().decode([Mapping].self, from: data)
            if let first = results.first, let tid = first.tvdb_id {
                let season = first.tvdb_season
                cache[aniListId] = CachedData(tid: tid, season: season)
                saveCache()
                return (tid, season)
            } else {
                cache[aniListId] = CachedData(tid: -1, season: nil)
                saveCache()
            }
        } catch {
            print("Failed to fetch TVDB mapping: \(error)")
        }
        
        return nil
    }
    
    func getCachedArtwork(for aniListId: Int) -> (poster: String?, fanart: String?) {
        if let c = cache[aniListId] {
            return (formatURL(c.posterPath), formatURL(c.fanartPath))
        }
        return (nil, nil)
    }
    
    func getArtwork(for aniListId: Int) async -> (poster: String?, fanart: String?) {
        guard let mapping = await getTVDBId(for: aniListId), mapping.id > 0 else { return (nil, nil) }
        let tid = mapping.id
        let targetSeason = mapping.season
        
        if let cached = cache[aniListId], cached.posterPath != nil || cached.fanartPath != nil {
            return (formatURL(cached.posterPath), formatURL(cached.fanartPath))
        }
        
        do {
            let token = try await authenticate()

            struct Artwork: Decodable {
                let image: String
                let type: Int
                let width: Int?
                let height: Int?
            }
            struct SeasonType: Decodable {
                let id: Int
                let type: String?
            }
            struct Season: Decodable {
                let id: Int
                let number: Int
                let type: SeasonType?
            }
            struct SeriesExtended: Decodable {
                struct Data: Decodable {
                    let artworks: [Artwork]?
                    let seasons: [Season]?
                }
                let data: Data
            }
            struct SeasonExtended: Decodable {
                struct Data: Decodable {
                    let artwork: [Artwork]?
                }
                let data: Data
            }

            func fetchSeriesExtended() async -> SeriesExtended.Data? {
                let url = URL(string: "\(tvdbEndpoint)/series/\(tid)/extended")!
                var req = URLRequest(url: url)
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                guard let (data, _) = try? await URLSession.shared.data(for: req),
                      let res = try? JSONDecoder().decode(SeriesExtended.self, from: data) else { return nil }
                return res.data
            }

            func fetchSeasonArtwork(seasonId: Int) async -> [Artwork] {
                let url = URL(string: "\(tvdbEndpoint)/seasons/\(seasonId)/extended")!
                var req = URLRequest(url: url)
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                guard let (data, _) = try? await URLSession.shared.data(for: req),
                      let res = try? JSONDecoder().decode(SeasonExtended.self, from: data) else { return [] }
                return res.data.artwork ?? []
            }

            guard let seriesData = await fetchSeriesExtended() else {
                return ("https://artworks.thetvdb.com/banners/posters/\(tid)-1.jpg", nil)
            }

            let artworks = seriesData.artworks ?? []

            // Fanart is series-wide (type 3), pick largest
            let fanart = artworks.filter { $0.type == 3 }
                .sorted { ($0.width ?? 0) * ($0.height ?? 0) > ($1.width ?? 0) * ($1.height ?? 0) }
                .first?.image

            // For poster: fetch season-specific artwork using official aired-order season
            var poster: String?
            if let targetSeason {
                // Filter to official aired-order seasons only (type "official" or id 1)
                let officialSeasons = seriesData.seasons?.filter {
                    $0.type?.type == "official" || $0.type?.id == 1
                }
                if let seasonId = officialSeasons?.first(where: { $0.number == targetSeason })?.id {
                    let seasonArtworks = await fetchSeasonArtwork(seasonId: seasonId)
                    // type 7 = season poster; fallback to any artwork if none typed 7
                    poster = seasonArtworks.filter { $0.type == 7 }
                        .sorted { ($0.width ?? 0) * ($0.height ?? 0) > ($1.width ?? 0) * ($1.height ?? 0) }
                        .first?.image
                        ?? seasonArtworks.sorted { ($0.width ?? 0) * ($0.height ?? 0) > ($1.width ?? 0) * ($1.height ?? 0) }
                        .first?.image
                }
            }

            // Fallback to series-level poster (type 2)
            if poster == nil {
                poster = artworks.filter { $0.type == 2 }
                    .sorted { ($0.width ?? 0) * ($0.height ?? 0) > ($1.width ?? 0) * ($1.height ?? 0) }
                    .first?.image
            }

            cache[aniListId]?.posterPath = poster
            cache[aniListId]?.fanartPath = fanart
            saveCache()
            return (formatURL(poster), formatURL(fanart))
        } catch {
            print("TVDB API Error: \(error)")
            return ("https://artworks.thetvdb.com/banners/posters/\(tid)-1.jpg", nil)
        }
    }


    func getEpisodes(for aniListId: Int) async -> [AniMapEpisode] {
        if let cached = episodeCache[aniListId] {
            return cached
        }
        
        // 1. Try the AniMap media episodes endpoint first (highly detailed)
        do {
            let urlString = "https://animap.s0n1c.ca/media/\(aniListId)/episodes?mapping_key=anilist"
            guard let url = URL(string: urlString) else { throw URLError(.badURL) }
            
            let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url))
            let results = try JSONDecoder().decode([AniMapEpisode].self, from: data)
            
            if !results.isEmpty {
                episodeCache[aniListId] = results
                return results
            }
        } catch {
            print("AniMap Media EP Error: \(error)")
        }
        
        // 2. Fallback to TVDB extended series data (direct API access)
        if let mapping = await getTVDBId(for: aniListId), mapping.id > 0 {
            let tid = mapping.id
            let targetSeason = mapping.season ?? 1
            
            do {
                let token = try await authenticate()
                let url = URL(string: "\(tvdbEndpoint)/series/\(tid)/extended")!
                var request = URLRequest(url: url)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                
                let (data, _) = try await URLSession.shared.data(for: request)
                
                struct TVDBEpisode: Decodable {
                    let number: Int
                    let seasonNumber: Int
                    let image: String?
                    let name: String?
                    let overview: String?
                }
                struct TVDBExtendedResponse: Decodable {
                    struct Data: Decodable { let episodes: [TVDBEpisode]? }
                    let data: Data
                }
                
                let res = try JSONDecoder().decode(TVDBExtendedResponse.self, from: data)
                let filtered = (res.data.episodes ?? []).filter { $0.seasonNumber == targetSeason }
                
                if !filtered.isEmpty {
                    let mapped = filtered.map { te in
                        AniMapEpisode(
                            absolute: te.number,
                            airdate: nil,
                            description: te.overview,
                            episode: te.number,
                            filler_type: nil,
                            mal_id: nil,
                            season: te.seasonNumber,
                            thumbnail: formatURL(te.image),
                            title: te.name
                        )
                    }
                    episodeCache[aniListId] = mapped
                    return mapped
                }
            } catch {
                print("TVDB Fallback EP Error: \(error)")
            }
        }
        
        // 3. Last resort fallback to legacy mapping episode endpoint
        do {
            let urlString = "\(mappingEndpoint)\(aniListId)/episodes?mapping_key=anilist"
            guard let url = URL(string: urlString) else { return [] }
            let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url))
            let results = try JSONDecoder().decode([AniMapEpisode].self, from: data)
            episodeCache[aniListId] = results
            return results
        } catch {
            print("AniMap Mapping EP Error: \(error)")
        }
        
        return []
    }

    func getCachedEpisode(for aniListId: Int, episodeNumber: Int) -> AniMapEpisode? {
        return episodeCache[aniListId]?.first(where: { $0.episode == episodeNumber })
    }

    private func formatURL(_ path: String?) -> String? {
        guard let p = path else { return nil }
        if p.hasPrefix("http") { return p }
        return "https://artworks.thetvdb.com/banners/\(p)"
    }

    private func saveCache() {
        if let encoded = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(encoded, forKey: cacheKey)
        }
    }
    }

    struct AniMapEpisode: Codable, Identifiable {
    var id: String { "\(episode)-\(season ?? 0)" }
    let absolute: Int?
    let airdate: String?
    let description: String?
    let episode: Int
    let filler_type: String?
    let mal_id: Int?
    let season: Int?
    let thumbnail: String?
    let title: String?
    }