import Foundation
import Combine

// MARK: - Response wrappers with error handling

private struct GraphQLResponse<T: Decodable>: Decodable {
    let data: T?
    let errors: [GraphQLError]?
}

private struct GraphQLError: Decodable {
    let message: String
    let status: Int?
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
    nonisolated(unsafe) static let shared = AniListService()

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

    /// Normalized set of adult (`isAdult: true`) anime title variants + synonyms
    /// matching `keyword`. Used by NSFWContentFilter to screen module results.
    func searchAdultTitles(keyword: String) async throws -> Set<String> {
        struct AdultPage: Decodable { let Page: AdultContent }
        struct AdultContent: Decodable { let media: [AdultMedia] }
        struct AdultMedia: Decodable {
            let title: AniListTitle
            let synonyms: [String]?
        }
        let query = """
        query ($search: String) {
          Page(page: 1, perPage: 25) {
            media(search: $search, type: ANIME, isAdult: true) {
              title { romaji english native }
              synonyms
            }
          }
        }
        """
        let data = try await post(query: query, variables: ["search": keyword])
        let response = try JSONDecoder().decode(GraphQLResponse<AdultPage>.self, from: data)
        var result = Set<String>()
        for media in response.data?.Page.media ?? [] {
            let variants: [String?] = [media.title.romaji, media.title.english, media.title.native]
                + (media.synonyms ?? []).map(Optional.some)
            for raw in variants {
                guard let raw, !raw.isEmpty else { continue }
                let norm = NSFWContentFilter.normalize(raw)
                if !norm.isEmpty { result.insert(norm) }
            }
        }
        return result
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
            if errors.contains(where: { $0.status == 403 }) { throw AniListError.httpError(403) }
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
            if errors.contains(where: { $0.status == 403 }) { throw AniListError.httpError(403) }
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
    nonisolated(unsafe) static let shared = AniListMappingManager()
    
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
    private let cacheKey = "tvdb_mappings_cache_v4"
    private let malCacheKey = "tvdb_mal_mappings_cache_v1"
    private let bulkFetchedAtKey = "anira_all_mappings_fetchedAt_v1"
    /// How long a cached /mappings/all snapshot is considered fresh before re-fetching.
    private let bulkTTL: TimeInterval = 60 * 60 * 24  // 1 day

    @Published private var token: String?
    private var tokenExpiry: Date?

    // Cache: AniListID or MALID -> (TVDB_ID, SeasonNumber, PosterPath?, FanartPath?)
    struct CachedData: Codable {
        let tid: Int
        var season: Int?
        var epOffset: Int?
        var epOffsetFetched: Bool?  // nil = old entry (pre-epOffset), true = fetched fresh
        var posterPath: String?
        var fanartPath: String?
    }
    private var cache: [Int: CachedData] = [:]       // keyed by AniList ID
    private var malCache: [Int: CachedData] = [:]     // keyed by MAL ID
    private var episodeCache: [Int: [AniMapEpisode]] = [:]
    private var malEpisodeCache: [Int: [AniMapEpisode]] = [:]
    private var aniraEpisodeCache: [String: AniraEpisodeResponse] = [:]
    private var watchOrderCache: [Int: [AniraMediaEntry]] = [:]

    // Bulk ID-mapping snapshot from anira's /mappings/all — resolved locally instead of
    // hitting the per-id endpoint once per show. Seeded from disk on first use, refreshed
    // over the network when stale (see loadAllMappings).
    private var anilistMappingIndex: [Int: BulkMapping] = [:]
    private var malMappingIndex: [Int: BulkMapping] = [:]
    private var bulkLoaded = false
    private var bulkLoadTask: Task<Void, Never>?

    /// Subset of an anira /mappings/all entry we actually consume for TVDB resolution.
    struct BulkMapping: Codable, Sendable {
        let mal_id: Int?
        let anilist_id: Int?
        let tvdb_id: Int?
        let tvdb_season: Int?
        let tvdb_epoffset: Int?
    }

    struct AniraEpisodeResponse: Decodable {
        struct Skip: Decodable {
            let type: String
            let start: Double
            let end: Double
        }
        let episode: Int
        let title: String?
        let description: String?
        let thumbnail: String?
        let skips: [Skip]?
    }

    /// One entry from Anira's `/watch_order` (and identically-shaped `/similar`) response.
    /// `mappings.anilist_id` can be null for entries that only exist on other databases.
    struct AniraMediaEntry: Decodable, Identifiable {
        let title: String?
        let cover: String?
        let mappings: Mappings

        struct Mappings: Decodable {
            let anilist_id: Int?
            let mal_id: Int?
            let media_type: String?
        }

        /// Stable list identity — prefers AniList id, then MAL id, then title.
        var id: String { "\(mappings.anilist_id ?? mappings.mal_id ?? 0)-\(title ?? "")" }
    }

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = nil
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
        // Only return from cache if we have a definitive result:
        // - tid < 0 means we already know there's no mapping
        // - epOffsetFetched == true means the entry was populated from a full fresh fetch
        if let cached, cached.tid < 0 { return nil }
        if let cached, cached.epOffsetFetched == true { return (cached.tid, cached.season) }

        // Primary: resolve from the bulk /mappings/all snapshot (one cached fetch, no per-id call).
        await loadAllMappings()
        let index = provider == .mal ? malMappingIndex : anilistMappingIndex
        if let m = index[id] {
            if let tid = m.tvdb_id {
                setTVDBCache(CachedData(tid: tid, season: m.tvdb_season, epOffset: m.tvdb_epoffset,
                                        epOffsetFetched: true,
                                        posterPath: cached?.posterPath, fanartPath: cached?.fanartPath),
                             id: id, provider: provider)
                provider == .mal ? saveMALCache() : saveCache()
                return (tid, m.tvdb_season)
            }
            // Present in the snapshot but no TVDB id → definitively no TVDB mapping.
            setTVDBCache(CachedData(tid: -1, season: nil, epOffsetFetched: true), id: id, provider: provider)
            provider == .mal ? saveMALCache() : saveCache()
            return nil
        }

        // Fallback: id absent from the snapshot (e.g. added after the last refresh) — one per-id lookup.
        do {
            let key = mappingKey(for: provider)
            guard let url = URL(string: "\(mappingEndpoint)\(id)?mapping_key=\(key)") else { return nil }
            let (data, _) = try await Self.session.data(for: URLRequest(url: url))
            struct Mapping: Decodable { let tvdb_id: Int?; let tvdb_season: Int?; let tvdb_epoffset: Int? }
            let results = try JSONDecoder().decode([Mapping].self, from: data)
            if let first = results.first, let tid = first.tvdb_id {
                setTVDBCache(CachedData(tid: tid, season: first.tvdb_season, epOffset: first.tvdb_epoffset, epOffsetFetched: true), id: id, provider: provider)
                provider == .mal ? saveMALCache() : saveCache()
                return (tid, first.tvdb_season)
            } else {
                setTVDBCache(CachedData(tid: -1, season: nil, epOffsetFetched: true), id: id, provider: provider)
                provider == .mal ? saveMALCache() : saveCache()
            }
        } catch where (error as? URLError)?.code == .cancelled || error is CancellationError {
        } catch {
            Logger.shared.log("TVDB mapping error (\(provider.rawValue)): \(error)", type: "Error")
        }
        return nil
    }

    // MARK: - Bulk /mappings/all

    /// Ensures the bulk mapping snapshot is loaded (deduping concurrent callers).
    private func loadAllMappings() async {
        if bulkLoaded { return }
        if let task = bulkLoadTask { await task.value; return }
        let task = Task { await performLoadAllMappings() }
        bulkLoadTask = task
        await task.value
        bulkLoadTask = nil
    }

    private func performLoadAllMappings() async {
        // 1. Seed from disk (any age) for instant availability.
        if anilistMappingIndex.isEmpty, let disk = await loadBulkFromDisk() {
            buildMappingIndices(from: disk)
        }
        // 2. Refresh from the network when we have nothing yet or the snapshot is stale.
        let fetchedAt = UserDefaults.standard.double(forKey: bulkFetchedAtKey)
        let isStale = Date().timeIntervalSince1970 - fetchedAt > bulkTTL
        if anilistMappingIndex.isEmpty || isStale {
            if let entries = await fetchAllMappings(), !entries.isEmpty {
                buildMappingIndices(from: entries)
                saveBulkToDisk(entries)
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: bulkFetchedAtKey)
            }
        }
        // Only latch as "loaded" once we actually have data, so a failed cold start retries later.
        bulkLoaded = !anilistMappingIndex.isEmpty
    }

    private func fetchAllMappings() async -> [BulkMapping]? {
        guard let url = URL(string: "\(mappingEndpoint)all") else { return nil }
        do {
            let (data, resp) = try await Self.session.data(for: URLRequest(url: url))
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            // Decode the ~7MB payload off the main actor to avoid a UI hitch.
            return try await Task.detached(priority: .utility) {
                try JSONDecoder().decode([BulkMapping].self, from: data)
            }.value
        } catch where (error as? URLError)?.code == .cancelled || error is CancellationError {
            return nil
        } catch {
            Logger.shared.log("anira /mappings/all fetch failed: \(error)", type: "Error")
            return nil
        }
    }

    private func buildMappingIndices(from entries: [BulkMapping]) {
        var ani: [Int: BulkMapping] = [:]
        var mal: [Int: BulkMapping] = [:]
        ani.reserveCapacity(entries.count)
        mal.reserveCapacity(entries.count)
        for e in entries {
            if let a = e.anilist_id { ani[a] = e }
            if let m = e.mal_id { mal[m] = e }
        }
        anilistMappingIndex = ani
        malMappingIndex = mal
    }

    private var bulkFileURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("anira_all_mappings_v1.json")
    }

    private func saveBulkToDisk(_ entries: [BulkMapping]) {
        guard let url = bulkFileURL else { return }
        Task.detached(priority: .background) {
            guard let data = try? JSONEncoder().encode(entries) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private func loadBulkFromDisk() async -> [BulkMapping]? {
        guard let url = bulkFileURL else { return nil }
        return await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode([BulkMapping].self, from: data)
        }.value
    }

    /// Returns true if we've already checked TVDB for this ID (result may be positive or negative).
    func hasMappingResolved(for id: Int, provider: ProviderType = .anilist) -> Bool {
        tvdbCache(for: provider)[id] != nil
    }

    func cachedSeason(for id: Int, provider: ProviderType = .anilist) -> Int? {
        tvdbCache(for: provider)[id]?.season
    }

    func cachedEpOffset(for id: Int, provider: ProviderType = .anilist) -> Int? {
        tvdbCache(for: provider)[id]?.epOffset
    }

    func fetchAniraEpisode(id: Int, episodeNumber: Int, mappingKey: String = "anilist") async -> AniraEpisodeResponse? {
        let key = "\(id)-\(episodeNumber)-\(mappingKey)"
        if let cached = aniraEpisodeCache[key] { return cached }
        guard let url = URL(string: "https://api.anira.dev/media/\(id)/episodes/\(episodeNumber)?mapping_key=\(mappingKey)"),
              let (data, _) = try? await Self.session.data(for: URLRequest(url: url)),
              let result = try? JSONDecoder().decode(AniraEpisodeResponse.self, from: data)
        else { return nil }
        aniraEpisodeCache[key] = result
        return result
    }

    /// Anira's recommended franchise watch order for a title. Returns [] when Anira has no
    /// data or returns a non-array error body for an unmapped id (mirrors the defensive
    /// decoding used for episodes). Cached in-memory per id.
    func fetchWatchOrder(id: Int, provider: ProviderType = .anilist) async -> [AniraMediaEntry] {
        if let cached = watchOrderCache[id] { return cached }
        let key = mappingKey(for: provider)
        guard let url = URL(string: "https://api.anira.dev/media/\(id)/watch_order?mapping_key=\(key)"),
              let (data, _) = try? await Self.session.data(for: URLRequest(url: url)),
              let results = try? JSONDecoder().decode([AniraMediaEntry].self, from: data)
        else { return [] }
        watchOrderCache[id] = results
        return results
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
        } catch is DecodingError {
            // anira returns a non-array body ("Not Found"/error object) for titles it
            // has no mapping for. Expected — fall through to the TVDB/legacy fallbacks.
            Logger.shared.log("AniMap media episodes: no anira mapping for \(aniListId)", type: "Debug")
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
        } catch is DecodingError {
            // Legacy mapping endpoint also returns a non-JSON body when it has no data
            // for this title. Expected — return the empty list below.
            Logger.shared.log("AniMap mapping episodes: no legacy mapping for \(aniListId)", type: "Debug")
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

    /// Resolves episode metadata for a given episode number, handling absolute/relative
    /// numbering mismatches via a four-step waterfall.
    func getEpisode(for id: Int, episodeNumber: Int, provider: ProviderType = .anilist) async -> AniMapEpisode? {
        // 1. In-memory cache (checks both .episode and .absolute fields)
        if let hit = getCachedEpisode(for: id, provider: provider, episodeNumber: episodeNumber) {
            return hit
        }

        // 2. Fresh network fetch + check both fields
        let eps = await getEpisodes(for: id, provider: provider)
        if let hit = eps.first(where: { $0.episode == episodeNumber })
                     ?? eps.first(where: { $0.absolute == episodeNumber }) {
            return hit
        }

        // 3. Offset fallback — ensures epOffset is cached, then tries ±offset variants
        _ = await getTVDBId(for: id, provider: provider)
        let offset = cachedEpOffset(for: id, provider: provider) ?? 0
        guard offset > 0 else { return nil }

        // Module absolute → AniList-relative (e.g. 25 − 24 = 1)
        let relative = episodeNumber - offset
        if relative > 0, let hit = eps.first(where: { $0.episode == relative }) {
            return hit
        }

        // AniList-relative → absolute (e.g. 1 + 24 = 25)
        let absolute = episodeNumber + offset
        if let hit = eps.first(where: { $0.episode == absolute }) {
            return hit
        }

        return nil
    }

    func getEpisodes(for id: Int, provider: ProviderType = .anilist) async -> [AniMapEpisode] {
        if provider != .mal { return await getEpisodesAniList(id) }
        if let cached = malEpisodeCache[id] { return cached }

        // 1. Try Anira MAL episodes endpoint first
        do {
            guard let url = URL(string: "https://api.anira.dev/media/\(id)/episodes?mapping_key=myanimelist") else { throw URLError(.badURL) }
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
            if !results.isEmpty {
                malEpisodeCache[id] = results
                return results
            }
        } catch where (error as? URLError)?.code == .cancelled || error is CancellationError {
            return []
        } catch is DecodingError {
            // anira returns a non-array body for MAL ids it has no mapping for.
            // Expected — fall through to the TVDB fallback below.
            Logger.shared.log("Anira MAL episodes: no mapping for malId \(id)", type: "Debug")
        } catch {
            Logger.shared.log("Anira MAL episodes error: \(error)", type: "Error")
        }

        // 2. Fall back to TVDB
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

        return []
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
