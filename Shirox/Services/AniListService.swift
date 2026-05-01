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
            idMal
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

        Logger.shared.log("AniList Request: \(bodyDict)", type: "Network")

        let (data, response) = try await session.data(for: request)

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            Logger.shared.log("AniList Response: \(json)", type: "Network")
        }

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

@MainActor final class TVDBMappingService: ObservableObject {
    static let shared = TVDBMappingService()
    private let mappingEndpoint = "https://api.anira.dev/mappings/"
    private let tvdbEndpoint = "https://api4.thetvdb.com/v4"
    private let apiKey = "4cd66d53-3c21-45a7-9dd2-e4a9c2ed20a8"
    private let cacheKey = "tvdb_mappings_cache_v3"
    private let malCacheKey = "tvdb_mal_mappings_cache_v1"

    @Published private var token: String?
    private var tokenExpiry: Date?

    // Cache: AniListID or MALID -> (TVDB_ID, SeasonNumber, PosterPath?, FanartPath?)
    struct CachedData: Codable {
        let tid: Int
        var season: Int?
        var posterPath: String?
        var fanartPath: String?
    }
    private var cache: [Int: CachedData] = [:]       // keyed by AniList ID
    private var malCache: [Int: CachedData] = [:]     // keyed by MAL ID
    private var episodeCache: [Int: [AniMapEpisode]] = [:]
    private var malEpisodeCache: [Int: [AniMapEpisode]] = [:]

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 20
        return URLSession(configuration: cfg)
    }()

    private init() {
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let decoded = try? JSONDecoder().decode([Int: CachedData].self, from: data) {
            self.cache = decoded
        }
        if let data = UserDefaults.standard.data(forKey: malCacheKey),
           let decoded = try? JSONDecoder().decode([Int: CachedData].self, from: data) {
            self.malCache = decoded
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

        let (data, _) = try await Self.session.data(for: request)
        let res = try JSONDecoder().decode(LoginResponse.self, from: data)
        self.token = res.data.token
        self.tokenExpiry = Date().addingTimeInterval(3600 * 24 * 25) // Token usually lasts 1 month
        return res.data.token
    }

    private func mappingKey(for provider: ProviderType) -> String {
        provider == .mal ? "myanimelist" : "anilist"
    }

    private func tvdbCache(for provider: ProviderType) -> [Int: CachedData] {
        provider == .mal ? malCache : cache
    }

    private func setTVDBCache(_ data: CachedData, id: Int, provider: ProviderType) {
        if provider == .mal { malCache[id] = data } else { cache[id] = data }
    }

    func getTVDBId(for id: Int, provider: ProviderType = .anilist) async -> (id: Int, season: Int?)? {
        let cached = tvdbCache(for: provider)[id]
        if let cached { return cached.tid > 0 ? (cached.tid, cached.season) : nil }
        do {
            let key = mappingKey(for: provider)
            guard let url = URL(string: "\(mappingEndpoint)\(id)?mapping_key=\(key)") else { return nil }
            let (data, _) = try await Self.session.data(for: URLRequest(url: url))
            struct Mapping: Decodable { let tvdb_id: Int?; let tvdb_season: Int? }
            let results = try JSONDecoder().decode([Mapping].self, from: data)
            if let first = results.first, let tid = first.tvdb_id {
                setTVDBCache(CachedData(tid: tid, season: first.tvdb_season), id: id, provider: provider)
                provider == .mal ? saveMALCache() : saveCache()
                return (tid, first.tvdb_season)
            } else {
                setTVDBCache(CachedData(tid: -1, season: nil), id: id, provider: provider)
                provider == .mal ? saveMALCache() : saveCache()
            }
        } catch where (error as? URLError)?.code == .cancelled || error is CancellationError {
        } catch {
            Logger.shared.log("TVDB mapping error (\(provider.rawValue)): \(error)", type: "Error")
        }
        return nil
    }

    /// Returns true if we've already checked TVDB for this ID (result may be positive or negative).
    func hasMappingResolved(for id: Int, provider: ProviderType = .anilist) -> Bool {
        tvdbCache(for: provider)[id] != nil
    }

    func getCachedArtwork(for id: Int, provider: ProviderType = .anilist) -> (poster: String?, fanart: String?) {
        if let c = tvdbCache(for: provider)[id] {
            return (formatURL(c.posterPath), formatURL(c.fanartPath))
        }
        return (nil, nil)
    }

    func getArtwork(for id: Int, provider: ProviderType = .anilist) async -> (poster: String?, fanart: String?) {
        if let c = tvdbCache(for: provider)[id], c.posterPath != nil || c.fanartPath != nil {
            return (formatURL(c.posterPath), formatURL(c.fanartPath))
        }
        guard let mapping = await getTVDBId(for: id, provider: provider), mapping.id > 0 else {
            return (nil, nil)
        }
        let artwork = await fetchTVDBIdArtwork(tid: mapping.id, targetSeason: mapping.season)
        if provider == .mal {
            malCache[id]?.posterPath = artwork.poster
            malCache[id]?.fanartPath = artwork.fanart
            saveMALCache()
        } else {
            cache[id]?.posterPath = artwork.poster
            cache[id]?.fanartPath = artwork.fanart
            saveCache()
        }
        return (formatURL(artwork.poster), formatURL(artwork.fanart))
    }


    private func getEpisodesAniList(_ aniListId: Int) async -> [AniMapEpisode] {
        if let cached = episodeCache[aniListId] {
            return cached
        }
        
        // 1. Try the AniMap media episodes endpoint first (highly detailed)
        var aniMapResults: [AniMapEpisode] = []
        do {
            let urlString = "https://api.anira.dev/media/\(aniListId)/episodes?mapping_key=anilist"
            guard let url = URL(string: urlString) else { throw URLError(.badURL) }
            let (data, _) = try await Self.session.data(for: URLRequest(url: url))
            aniMapResults = try JSONDecoder().decode([AniMapEpisode].self, from: data)
        } catch where (error as? URLError)?.code == .cancelled || error is CancellationError {
            return []
        } catch {
            Logger.shared.log("AniMap Media EP Error: \(error)", type: "Error")
        }

        if !aniMapResults.isEmpty {
            // If any episode is missing a thumbnail, merge in TVDB images
            let missingThumbnails = aniMapResults.contains { $0.thumbnail == nil }
            if missingThumbnails, let mapping = await getTVDBId(for: aniListId), mapping.id > 0 {
                let tvdbEps = await fetchTVDBEpisodes(tid: mapping.id, season: mapping.season ?? 1)
                if !tvdbEps.isEmpty {
                    let tvdbByNumber = Dictionary(uniqueKeysWithValues: tvdbEps.map { ($0.number, $0.image) })
                    let merged = aniMapResults.map { ep -> AniMapEpisode in
                        guard ep.thumbnail == nil, let img = tvdbByNumber[ep.episode] ?? tvdbByNumber[ep.absolute ?? -1] else { return ep }
                        return AniMapEpisode(absolute: ep.absolute, airdate: ep.airdate, description: ep.description,
                                            episode: ep.episode, filler_type: ep.filler_type, mal_id: ep.mal_id,
                                            season: ep.season, thumbnail: formatURL(img), title: ep.title)
                    }
                    episodeCache[aniListId] = merged
                    return merged
                }
            }
            episodeCache[aniListId] = aniMapResults
            return aniMapResults
        }
        
        // 2. Fallback to TVDB extended series data (direct API access)
        if let mapping = await getTVDBId(for: aniListId), mapping.id > 0 {
            let tvdbEps = await fetchTVDBEpisodes(tid: mapping.id, season: mapping.season ?? 1)
            if !tvdbEps.isEmpty {
                let mapped = tvdbEps.map { te in
                    AniMapEpisode(absolute: te.number, airdate: nil, description: te.overview,
                                  episode: te.number, filler_type: nil, mal_id: nil,
                                  season: te.seasonNumber, thumbnail: formatURL(te.image), title: te.name)
                }
                episodeCache[aniListId] = mapped
                return mapped
            }
        }
        
        // 3. Last resort fallback to legacy mapping episode endpoint
        do {
            let urlString = "\(mappingEndpoint)\(aniListId)/episodes?mapping_key=anilist"
            guard let url = URL(string: urlString) else { return [] }
            let (data, _) = try await Self.session.data(for: URLRequest(url: url))
            let results = try JSONDecoder().decode([AniMapEpisode].self, from: data)
            episodeCache[aniListId] = results
            return results
        } catch where (error as? URLError)?.code == .cancelled || error is CancellationError {
            return []
        } catch {
            Logger.shared.log("AniMap Mapping EP Error: \(error)", type: "Error")
        }
        
        return []
    }

    private struct TVDBRawEpisode {
        let number: Int
        let seasonNumber: Int
        let image: String?
        let name: String?
        let overview: String?
    }

    private func fetchTVDBEpisodes(tid: Int, season: Int) async -> [TVDBRawEpisode] {
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
        do {
            let token = try await authenticate()
            let url = URL(string: "\(tvdbEndpoint)/series/\(tid)/extended")!
            var req = URLRequest(url: url)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, _) = try await Self.session.data(for: req)
            let res = try JSONDecoder().decode(TVDBExtendedResponse.self, from: data)
            return (res.data.episodes ?? [])
                .filter { $0.seasonNumber == season }
                .map { TVDBRawEpisode(number: $0.number, seasonNumber: $0.seasonNumber,
                                     image: $0.image, name: $0.name, overview: $0.overview) }
        } catch where (error as? URLError)?.code == .cancelled || error is CancellationError {
            return []
        } catch {
            Logger.shared.log("TVDB EP fetch error: \(error)", type: "Error")
            return []
        }
    }

    func getCachedEpisode(for id: Int, provider: ProviderType = .anilist, episodeNumber: Int) -> AniMapEpisode? {
        let eps = provider == .mal ? malEpisodeCache[id] : episodeCache[id]
        return eps?.first(where: { $0.episode == episodeNumber })
            ?? eps?.first(where: { $0.absolute == episodeNumber })
    }

    func getEpisodes(for id: Int, provider: ProviderType = .anilist) async -> [AniMapEpisode] {
        if provider != .mal { return await getEpisodesAniList(id) }
        if let cached = malEpisodeCache[id] { return cached }

        // 1. Try TVDB first using the MAL ID mapping
        if let mapping = await getTVDBId(for: id, provider: ProviderType.mal), mapping.id > 0 {
            let tvdbEps = await fetchTVDBEpisodes(tid: mapping.id, season: mapping.season ?? 1)
            if !tvdbEps.isEmpty {
                let mapped = tvdbEps.map { te in
                    AniMapEpisode(absolute: te.number, airdate: nil, description: te.overview,
                                  episode: te.number, filler_type: nil, mal_id: nil,
                                  season: te.seasonNumber, thumbnail: formatURL(te.image), title: te.name)
                }
                malEpisodeCache[id] = mapped
                return mapped
            }
        }

        // 2. Fall back to anira MAL episodes endpoint
        do {
            guard let url = URL(string: "https://api.anira.dev/media/\(id)/episodes?mapping_key=myanimelist") else { return [] }
            let (data, _) = try await Self.session.data(for: URLRequest(url: url))
            var results = try JSONDecoder().decode([AniMapEpisode].self, from: data)
            results = results.map { ep in
                guard let thumb = ep.thumbnail, !thumb.contains("mapping_key") else { return ep }
                return AniMapEpisode(absolute: ep.absolute, airdate: ep.airdate, description: ep.description,
                                    episode: ep.episode, filler_type: ep.filler_type, mal_id: ep.mal_id,
                                    season: ep.season, thumbnail: thumb + "?mapping_key=myanimelist", title: ep.title)
            }
            // If all titles are generic ("Episode N" or nil), fetch real titles from Jikan
            let allGeneric = results.allSatisfy { ep in
                guard let t = ep.title else { return true }
                return t.range(of: #"^Episode \d+$"#, options: .regularExpression) != nil
            }
            if allGeneric && !results.isEmpty {
                let jikanEps = (try? await MALDiscoveryService.shared.episodes(malId: id)) ?? []
                let titleByNumber = Dictionary(jikanEps.map { ($0.mal_id, $0.title) }, uniquingKeysWith: { $1 })
                results = results.map { ep in
                    let title = titleByNumber[ep.episode] ?? ep.title
                    guard title != ep.title else { return ep }
                    return AniMapEpisode(absolute: ep.absolute, airdate: ep.airdate, description: ep.description,
                                        episode: ep.episode, filler_type: ep.filler_type, mal_id: ep.mal_id,
                                        season: ep.season, thumbnail: ep.thumbnail, title: title)
                }
            }
            malEpisodeCache[id] = results
            return results
        } catch where (error as? URLError)?.code == .cancelled || error is CancellationError {
            return []
        } catch {
            Logger.shared.log("Anira MAL episodes error: \(error)", type: "Error")
            return []
        }
    }

    private func formatURL(_ path: String?) -> String? {
        guard let p = path else { return nil }
        if p.hasPrefix("http") { return p }
        return "https://artworks.thetvdb.com/banners/\(p)"
    }

    private func saveCache() {
        let snapshot = cache
        let key = cacheKey
        Task.detached(priority: .background) {
            guard let encoded = try? JSONEncoder().encode(snapshot) else { return }
            UserDefaults.standard.set(encoded, forKey: key)
        }
    }

    private func saveMALCache() {
        let snapshot = malCache
        let key = malCacheKey
        Task.detached(priority: .background) {
            guard let encoded = try? JSONEncoder().encode(snapshot) else { return }
            UserDefaults.standard.set(encoded, forKey: key)
        }
    }

    /// Shared TVDB artwork fetch used by both AniList and MAL paths.
    private func fetchTVDBIdArtwork(tid: Int, targetSeason: Int?) async -> (poster: String?, fanart: String?) {
        struct Artwork: Decodable {
            let image: String
            let type: Int
            let width: Int?
            let height: Int?
        }
        struct SeasonType: Decodable { let id: Int; let type: String? }
        struct Season: Decodable { let id: Int; let number: Int; let type: SeasonType? }
        struct SeriesExtended: Decodable {
            struct Data: Decodable { let artworks: [Artwork]?; let seasons: [Season]? }
            let data: Data
        }
        struct SeasonExtended: Decodable {
            struct Data: Decodable { let artwork: [Artwork]? }
            let data: Data
        }
        do {
            let token = try await authenticate()

            func fetchSeriesExtended() async -> SeriesExtended.Data? {
                let url = URL(string: "\(tvdbEndpoint)/series/\(tid)/extended")!
                var req = URLRequest(url: url)
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                guard let (data, _) = try? await Self.session.data(for: req),
                      let res = try? JSONDecoder().decode(SeriesExtended.self, from: data) else { return nil }
                return res.data
            }
            func fetchSeasonArtwork(seasonId: Int) async -> [Artwork] {
                let url = URL(string: "\(tvdbEndpoint)/seasons/\(seasonId)/extended")!
                var req = URLRequest(url: url)
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                guard let (data, _) = try? await Self.session.data(for: req),
                      let res = try? JSONDecoder().decode(SeasonExtended.self, from: data) else { return [] }
                return res.data.artwork ?? []
            }

            guard let seriesData = await fetchSeriesExtended() else { return (nil, nil) }
            let artworks = seriesData.artworks ?? []
            let bySize: (Artwork, Artwork) -> Bool = { ($0.width ?? 0) * ($0.height ?? 0) > ($1.width ?? 0) * ($1.height ?? 0) }
            let fanart = artworks.filter { $0.type == 3 }.sorted(by: bySize).first?.image

            var poster: String?
            if let targetSeason {
                let officialSeasons = seriesData.seasons?.filter { $0.type?.type == "official" || $0.type?.id == 1 }
                if let seasonId = officialSeasons?.first(where: { $0.number == targetSeason })?.id {
                    let seasonArtworks = await fetchSeasonArtwork(seasonId: seasonId)
                    poster = seasonArtworks.filter { $0.type == 7 }.sorted(by: bySize).first?.image
                        ?? seasonArtworks.sorted(by: bySize).first?.image
                }
            }
            if poster == nil {
                poster = artworks.filter { $0.type == 2 }.sorted(by: bySize).first?.image
            }
            return (poster, fanart)
        } catch {
            Logger.shared.log("TVDB artwork fetch error: \(error)", type: "Error")
            return (nil, nil)
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