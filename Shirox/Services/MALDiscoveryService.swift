import Foundation

/// Where the unofficial MyAnimeList API is served from.
///
/// Two hosts, tried in order, because each has been observed failing in a different way and
/// neither is dependable alone:
///
/// * `api.jikan.moe` is the real thing and serves everything except the `genres` filter, which
///   it answers with 504. It also goes through spells of returning 504 more widely.
/// * The community mirror stays up when Jikan doesn't and handles search fine, but returns an
///   empty set for `/top/anime` — the endpoint behind the Home rows — so it cannot be primary.
///
/// Upstream leads and the mirror covers its outages. Both are third-party as far as this app is
/// concerned: MyAnimeList *discovery* traffic passes through whichever answers. Library reads
/// and writes are unaffected — those go to `api.myanimelist.net` directly.
enum JikanAPI {
    static let allHosts = [
        URL(string: "https://api.jikan.moe/v4")!,
        URL(string: "https://jikan.simplepostrequest.workers.dev/v4")!
    ]

    private static let preferredKey = "jikanPreferredHost"

    /// Hosts in the order they should be tried, most-recently-successful first.
    ///
    /// A fixed order costs real time once a host goes down: three retries against a dead
    /// primary before the working one is even attempted, on every request. Both hosts have now
    /// been observed both healthy and failing, so neither deserves to be permanently first —
    /// whichever last answered leads, and the order corrects itself as they recover.
    static var hosts: [URL] {
        guard let remembered = UserDefaults.standard.string(forKey: preferredKey),
              let preferred = allHosts.first(where: { $0.absoluteString == remembered }) else {
            return allHosts
        }
        return [preferred] + allHosts.filter { $0 != preferred }
    }

    /// Records the host that just answered, so the next request starts there.
    static func remember(_ host: URL) {
        guard UserDefaults.standard.string(forKey: preferredKey) != host.absoluteString else { return }
        UserDefaults.standard.set(host.absoluteString, forKey: preferredKey)
        Logger.shared.log("[MAL] Preferring \(host.host ?? "host") for subsequent requests", type: "Provider")
    }

    /// The host used when no failover is involved.
    static var base: URL { hosts[0] }
}

final class MALDiscoveryService {
    nonisolated(unsafe) static let shared = MALDiscoveryService()
    private let base = JikanAPI.base
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
        /// MyAnimeList files Mecha, Music, Psychological and Mahou Shoujo as *themes* rather
        /// than genres. They're filterable through the same `genres` query parameter, but they
        /// come back in their own field — so without this a mecha series listed everything
        /// about itself except that it was mecha.
        let themes: [JikanGenre]?
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

    /// Statuses worth another attempt.
    ///
    /// Jikan is a free, heavily loaded public API. Its rate limit (429) and gateway errors —
    /// 502/503/504 — are routine and usually clear within a second or two. Only 429 was retried
    /// before, so a single 504 surfaced as a hard "Couldn't load" for what is almost always a
    /// blip. Genuine 4xx responses are left alone: they don't fix themselves.
    static func isRetryable(_ status: Int) -> Bool {
        status == 429 || status == 500 || status == 502 || status == 503 || status == 504
    }

    static let maxAttempts = 3

    /// A rate limit needs its full window; a gateway error usually clears sooner. Doubles each
    /// time so a struggling server isn't hammered.
    static func backoffNanos(status: Int, attempt: Int) -> UInt64 {
        let base = status == 429 ? 1.0 : 0.6
        return UInt64(base * pow(2.0, Double(attempt - 1)) * 1_000_000_000)
    }

    /// Tries each host in turn, moving on when one fails.
    ///
    /// `isAcceptable` exists because one host answers `200` with an empty array instead of an
    /// error. Failing over on HTTP status alone stopped there and rendered the empty result as
    /// though the catalogue really were empty. Callers that know an empty answer is impossible —
    /// the ranked list is never empty on its first page — say so and the next host is tried.
    /// Callers where empty is a real answer (a genre nobody matches) leave it alone, so those
    /// requests aren't doubled for nothing.
    private func withFailover<T>(
        isAcceptable: (T) -> Bool = { _ in true },
        _ work: (URL) async throws -> T
    ) async throws -> T {
        var lastError: Error?
        var rejected: T?
        for host in JikanAPI.hosts {
            do {
                let result = try await work(host)
                if isAcceptable(result) {
                    JikanAPI.remember(host)
                    return result
                }
                Logger.shared.log("[MAL] \(host.host ?? "host") returned an empty result where one isn't possible", type: "Provider")
                rejected = result
            } catch {
                Logger.shared.log("[MAL] \(host.host ?? "host") failed: \(error)", type: "Provider")
                lastError = error
            }
        }
        // Every host answered emptily rather than erroring: hand that back rather than inventing
        // a failure, but an error from any host is the more useful thing to report.
        if let lastError { throw lastError }
        if let rejected { return rejected }
        throw ProviderError.serverError(0)
    }

    /// - Parameter emptyIsFailure: pass `true` for a listing that can never legitimately come
    ///   back empty — the ranked charts and the current season always have entries. One host
    ///   answers `200` with an empty array instead of an error, and without this the Home screen
    ///   rendered that as simply having no content, silently and with nothing to retry.
    /// A listing that can never legitimately be empty. See `fetchList(_:queryItems:emptyIsFailure:)`.
    private func fetchListNeverEmpty(_ path: String, queryItems: [URLQueryItem] = []) async throws -> [JikanAnime] {
        try await fetchList(path, queryItems: queryItems, emptyIsFailure: true)
    }

    private func fetchList(
        _ path: String,
        queryItems: [URLQueryItem] = [],
        emptyIsFailure: Bool = false
    ) async throws -> [JikanAnime] {
        try await withFailover(isAcceptable: { (items: [JikanAnime]) in
            !emptyIsFailure || !items.isEmpty
        }) { host in
            try await fetchList(host: host, path: path, queryItems: queryItems)
        }
    }

    private func fetchList(host: URL, path: String, queryItems: [URLQueryItem] = [], attempt: Int = 1) async throws -> [JikanAnime] {
        var components = URLComponents(url: host.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "sfw", value: "true")] + queryItems
        let (data, response) = try await session.data(from: components.url!)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let status = http.statusCode
            if Self.isRetryable(status), attempt < Self.maxAttempts {
                Logger.shared.log("[MAL] \(status) on \(path) — retrying (attempt \(attempt + 1))", type: "Provider")
                try await Task.sleep(nanoseconds: Self.backoffNanos(status: status, attempt: attempt))
                return try await fetchList(host: host, path: path, queryItems: queryItems, attempt: attempt + 1)
            }
            if status >= 500 || status == 429 { throw ProviderError.serverError(status) }
        }
        var seen = Set<Int>()
        return try JSONDecoder().decode(JikanPage<JikanAnime>.self, from: data).data.filter {
            guard $0.mal_id > 0 else { return false }
            guard let imgUrl = $0.images?.jpg?.image_url, !imgUrl.isEmpty, !imgUrl.contains("qm_50") else { return false }
            return seen.insert($0.mal_id).inserted
        }
    }

    private func fetchSingle(_ path: String) async throws -> JikanAnime {
        try await withFailover { host in try await fetchSingle(host: host, path: path) }
    }

    private func fetchSingle(host: URL, path: String, attempt: Int = 1) async throws -> JikanAnime {
        let url = host.appendingPathComponent(path)
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let status = http.statusCode
            if Self.isRetryable(status), attempt < Self.maxAttempts {
                Logger.shared.log("[MAL] \(status) on \(path) — retrying (attempt \(attempt + 1))", type: "Provider")
                try await Task.sleep(nanoseconds: Self.backoffNanos(status: status, attempt: attempt))
                return try await fetchSingle(host: host, path: path, attempt: attempt + 1)
            }
            if status >= 500 || status == 429 { throw ProviderError.serverError(status) }
        }
        return try JSONDecoder().decode(JikanSingle<JikanAnime>.self, from: data).data
    }

    // MARK: - Public API

    func trending(page: Int = 1) async throws -> [JikanAnime] {
        try await fetchListNeverEmpty("top/anime", queryItems: [
            URLQueryItem(name: "filter", value: "airing"),
            URLQueryItem(name: "limit", value: "\(DataSaver.rowLength(20))"),
            URLQueryItem(name: "page", value: "\(page)")
        ])
    }

    func seasonal(page: Int = 1) async throws -> [JikanAnime] {
        try await fetchListNeverEmpty("seasons/now", queryItems: [
            URLQueryItem(name: "limit", value: "\(DataSaver.rowLength(20))"),
            URLQueryItem(name: "page", value: "\(page)")
        ])
    }

    func popular(page: Int = 1) async throws -> [JikanAnime] {
        try await fetchListNeverEmpty("top/anime", queryItems: [
            URLQueryItem(name: "filter", value: "bypopularity"),
            URLQueryItem(name: "limit", value: "\(DataSaver.rowLength(20))"),
            URLQueryItem(name: "page", value: "\(page)")
        ])
    }

    func topRated(page: Int = 1) async throws -> [JikanAnime] {
        try await fetchListNeverEmpty("top/anime", queryItems: [
            URLQueryItem(name: "filter", value: "favorite"),
            URLQueryItem(name: "limit", value: "\(DataSaver.rowLength(20))"),
            URLQueryItem(name: "page", value: "\(page)")
        ])
    }

    /// How many ranked pages one filtered batch scans.
    ///
    /// A genre appearing in roughly a fifth of top anime fills a screen from four pages of 25.
    /// Rarer ones return less per batch and fill in as you scroll, which is preferable to
    /// firing a dozen requests at a rate-limited API for one screenful.
    private static let genreScanDepth = 4
    private static let rankedPageSize = 25

    /// One page of anime in the requested order, ignoring genre.
    ///
    /// `/top/anime` covers three of the four sorts and is the dependable endpoint; only
    /// "Newest" has no ranked equivalent and needs `/anime`, whose `order_by` works fine.
    private func rankedPage(sort: DiscoverSort, page: Int) async throws -> [JikanAnime] {
        // The catalogue's first page is never legitimately empty, so an empty answer there means
        // the host is unwell — try the next one rather than showing an empty grid.
        try await withFailover(isAcceptable: { (items: [JikanAnime]) in page > 1 || !items.isEmpty }) { host in
            try await rankedPage(host: host, sort: sort, page: page)
        }
    }

    private func rankedPage(host: URL, sort: DiscoverSort, page: Int) async throws -> [JikanAnime] {
        if let filter = sort.jikanTopFilter {
            var items = [
                URLQueryItem(name: "limit", value: "\(Self.rankedPageSize)"),
                URLQueryItem(name: "page", value: "\(page)")
            ]
            if let value = filter { items.append(URLQueryItem(name: "filter", value: value)) }
            return try await fetchList(host: host, path: "top/anime", queryItems: items)
        }
        return try await fetchList(host: host, path: "anime", queryItems: [
            URLQueryItem(name: "order_by", value: sort.jikanOrderBy),
            URLQueryItem(name: "sort", value: sort.jikanDirection),
            URLQueryItem(name: "limit", value: "\(Self.rankedPageSize)"),
            URLQueryItem(name: "page", value: "\(page)")
        ])
    }

    /// Genre-filtered, ordered browse for the Search tab.
    ///
    /// The genre match happens here rather than in the query. Jikan's `genres` parameter on
    /// `/anime` does not work: upstream returns 504 for it while the mirror answers 200 with an
    /// empty set, both regardless of which genre is asked for — so a filtered browse came back
    /// blank whichever host it used. Ordering and search on the same endpoint are unaffected.
    ///
    /// Scanning a window of ranked pages and matching locally gives a working genre browse that
    /// doesn't depend on that parameter being fixed. Matching runs over genres *and* themes,
    /// since MyAnimeList files Mecha, Music, Psychological and Mahou Shoujo as themes.
    func discover(genre: String?, sort: DiscoverSort, page: Int) async throws -> [JikanAnime] {
        guard let genre else { return try await rankedPage(sort: sort, page: page) }

        var matches: [JikanAnime] = []
        let firstPage = (page - 1) * Self.genreScanDepth + 1
        for sourcePage in firstPage..<(firstPage + Self.genreScanDepth) {
            let batch = try await rankedPage(sort: sort, page: sourcePage)
            if batch.isEmpty { break }
            matches += batch.filter { Self.combinedGenres($0)?.contains(genre) == true }
        }
        return matches
    }

    func browse(category: BrowseCategory, page: Int) async throws -> [JikanAnime] {
        switch category {
        case .trending: return try await trending(page: page)
        case .seasonal: return try await seasonal(page: page)
        case .popular:  return try await popular(page: page)
        case .topRated: return try await topRated(page: page)
        // Jikan can't filter a season by airing status in one query, so there's no honest
        // MAL answer here. The home row is hidden when empty, and `MediaProvider`'s default
        // `lastSeasonCompleted()` returns empty for the same reason.
        case .lastSeason: return []
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

    /// Lightweight poster lookup by MAL id. The Jikan history feed carries no cover
    /// art, so the activity list fetches posters per row on demand.
    func posterURL(malId: Int) async throws -> String? {
        let anime = try await fetchSingle("anime/\(malId)")
        return anime.images?.jpg?.large_image_url ?? anime.images?.jpg?.image_url
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

    /// Genres and themes as one list, matching how AniList presents them, with order kept and
    /// duplicates dropped.
    static func combinedGenres(_ a: JikanAnime) -> [String]? {
        let names = (a.genres ?? []).map(\.name) + (a.themes ?? []).map(\.name)
        guard !names.isEmpty else { return nil }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

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
            genres: Self.combinedGenres(a),
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
