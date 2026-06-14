import Foundation

final class IDMappingService: @unchecked Sendable {
    static let shared = IDMappingService()
    private let cacheKey = "id_mappings_cache"
    private let prefetchedKey = "id_mappings_prefetched_v2"
    private let mediaCacheKey = "id_media_mappings_cache"
    private let mediaPrefetchedKey = "id_media_mappings_prefetched_v1"
    private let tvdbGroupsCacheKey = "id_tvdb_groups_cache"
    private var cache: [String: Int] = [:]
    private var mediaCache: [Int: MediaMapping] = [:]
    private var anilistToTvdb: [Int: Int] = [:]
    private var malToTvdb: [Int: Int] = [:]
    private var tvdbGroups: [Int: [SiblingSeason]] = [:]

    struct MediaMapping: Codable {
        let imdbId: String?
        let tmdbShowId: Int?
        let tmdbMovieId: Int?
        let mediaType: String?
    }

    private init() {
        cache = (UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: Int]) ?? [:]
        if let data = UserDefaults.standard.data(forKey: mediaCacheKey),
           let decoded = try? JSONDecoder().decode([Int: MediaMapping].self, from: data) {
            mediaCache = decoded
        }
        if let data = UserDefaults.standard.data(forKey: tvdbGroupsCacheKey),
           let decoded = try? JSONDecoder().decode([Int: [SiblingSeason]].self, from: data) {
            tvdbGroups = decoded
            for (tvdb, sibs) in decoded {
                for s in sibs {
                    if let a = s.aniListID { anilistToTvdb[a] = tvdb }
                    if let m = s.malID { malToTvdb[m] = tvdb }
                }
            }
        }
    }

    private struct AniraMapping: Decodable {
        let anilist_id: Int?
        let mal_id: Int?
        let imdb_id: String?
        let tmdb_show_id: Int?
        let tmdb_movie_id: Int?
        let media_type: String?
        let tvdb_id: Int?
        let tvdb_season: Int?
        let tvdb_epoffset: Int?
    }

    private typealias AniraBulkMapping = AniraMapping

    // MARK: - Bulk prefetch

    func prefetchAllMappingsIfNeeded() {
        let needsBasic = !UserDefaults.standard.bool(forKey: prefetchedKey)
        let needsMedia = !UserDefaults.standard.bool(forKey: mediaPrefetchedKey)
        guard needsBasic || needsMedia else { return }
        Task.detached(priority: .background) {
            guard let url = URL(string: "https://api.anira.dev/mappings/all"),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let mappings = try? JSONDecoder().decode([AniraBulkMapping].self, from: data)
            else { return }

            if needsBasic {
                var newCache = self.cache
                for m in mappings {
                    if let aid = m.anilist_id, let mid = m.mal_id {
                        newCache["anilist-\(aid)"] = mid
                        newCache["mal-\(mid)"] = aid
                    }
                }
                self.cache = newCache
                UserDefaults.standard.set(newCache, forKey: self.cacheKey)

                // Build tvdb sibling groups (used by SeasonChainMapper to remap continuous
                // module episode numbers onto the correct AniList/MAL season entry).
                var newGroups: [Int: [SiblingSeason]] = [:]
                for m in mappings {
                    guard let tvdb = m.tvdb_id, let season = m.tvdb_season else { continue }
                    // Only TV entries participate in continuous episode numbering.
                    if let mt = m.media_type, mt.uppercased() != "TV" { continue }
                    let sib = SiblingSeason(
                        aniListID: m.anilist_id, malID: m.mal_id,
                        tvdbSeason: season, tvdbEpoffset: m.tvdb_epoffset ?? 0,
                        episodeCount: nil)
                    newGroups[tvdb, default: []].append(sib)
                }
                self.tvdbGroups = newGroups
                self.anilistToTvdb = [:]
                self.malToTvdb = [:]
                for (tvdb, sibs) in newGroups {
                    for s in sibs {
                        if let a = s.aniListID { self.anilistToTvdb[a] = tvdb }
                        if let mid = s.malID { self.malToTvdb[mid] = tvdb }
                    }
                }
                if let encoded = try? JSONEncoder().encode(newGroups) {
                    UserDefaults.standard.set(encoded, forKey: self.tvdbGroupsCacheKey)
                }
                Logger.shared.log("[Tracking] tvdb groups built: \(newGroups.count) shows", type: "Debug")

                UserDefaults.standard.set(true, forKey: self.prefetchedKey)
            }

            if needsMedia {
                var newMediaCache = self.mediaCache
                for m in mappings {
                    if let aid = m.anilist_id {
                        newMediaCache[aid] = MediaMapping(
                            imdbId: m.imdb_id,
                            tmdbShowId: m.tmdb_show_id,
                            tmdbMovieId: m.tmdb_movie_id,
                            mediaType: m.media_type
                        )
                    }
                }
                self.mediaCache = newMediaCache
                if let encoded = try? JSONEncoder().encode(newMediaCache) {
                    UserDefaults.standard.set(encoded, forKey: self.mediaCacheKey)
                }
                UserDefaults.standard.set(true, forKey: self.mediaPrefetchedKey)
            }
        }
    }

    // MARK: - Lookups

    func cachedAnilistId(forMALId malId: Int) -> Int? {
        cache["mal-\(malId)"]
    }

    func cachedMalId(forAnilistId anilistId: Int) -> Int? {
        cache["anilist-\(anilistId)"]
    }

    func tvdbId(forAnilistId anilistId: Int) -> Int? { anilistToTvdb[anilistId] }
    func tvdbId(forMALId malId: Int) -> Int? { malToTvdb[malId] }

    /// Sibling seasons/cours sharing a tvdb_id. episodeCount is always nil here
    /// (the bulk feed has no counts); the caller fills counts in where needed.
    func siblings(forTvdbId tvdbId: Int) -> [SiblingSeason] { tvdbGroups[tvdbId] ?? [] }

    func anilistId(forMALId malId: Int) async -> Int? {
        let key = "mal-\(malId)"
        if let cached = cache[key] { return cached }
        guard let url = URL(string: "https://api.anira.dev/mappings/\(malId)?mapping_key=myanimelist"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let mappings = try? JSONDecoder().decode([AniraMapping].self, from: data),
              let id = mappings.first?.anilist_id else { return nil }
        cache[key] = id
        UserDefaults.standard.set(cache, forKey: cacheKey)
        return id
    }

    func malId(forAnilistId anilistId: Int) async -> Int? {
        let key = "anilist-\(anilistId)"
        if let cached = cache[key] { return cached }
        guard let url = URL(string: "https://api.anira.dev/mappings/\(anilistId)?mapping_key=anilist"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let mappings = try? JSONDecoder().decode([AniraMapping].self, from: data),
              let id = mappings.first?.mal_id else { return nil }
        cache[key] = id
        UserDefaults.standard.set(cache, forKey: cacheKey)
        return id
    }

    func imdbId(forAnilistId anilistId: Int) async -> String? {
        if let cached = mediaCache[anilistId], let id = cached.imdbId { return id }
        await fetchMediaMapping(forAnilistId: anilistId)
        return mediaCache[anilistId]?.imdbId
    }

    func tmdbId(forAnilistId anilistId: Int) async -> (id: Int, isMovie: Bool)? {
        if let cached = mediaCache[anilistId] {
            if let showId = cached.tmdbShowId { return (showId, false) }
            if let movieId = cached.tmdbMovieId { return (movieId, true) }
            if cached.imdbId != nil { return nil }
        }
        await fetchMediaMapping(forAnilistId: anilistId)
        guard let cached = mediaCache[anilistId] else { return nil }
        if let showId = cached.tmdbShowId { return (showId, false) }
        if let movieId = cached.tmdbMovieId { return (movieId, true) }
        return nil
    }

    private func fetchMediaMapping(forAnilistId anilistId: Int) async {
        guard let url = URL(string: "https://api.anira.dev/mappings/\(anilistId)?mapping_key=anilist"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let mappings = try? JSONDecoder().decode([AniraMapping].self, from: data),
              let m = mappings.first
        else { return }
        let mapping = MediaMapping(imdbId: m.imdb_id, tmdbShowId: m.tmdb_show_id,
                                   tmdbMovieId: m.tmdb_movie_id, mediaType: m.media_type)
        mediaCache[anilistId] = mapping
        if let encoded = try? JSONEncoder().encode(mediaCache) {
            UserDefaults.standard.set(encoded, forKey: mediaCacheKey)
        }
    }

    func clearCache() {
        cache = [:]
        mediaCache = [:]
        tvdbGroups = [:]
        anilistToTvdb = [:]
        malToTvdb = [:]
        UserDefaults.standard.removeObject(forKey: cacheKey)
        UserDefaults.standard.removeObject(forKey: prefetchedKey)
        UserDefaults.standard.removeObject(forKey: mediaCacheKey)
        UserDefaults.standard.removeObject(forKey: mediaPrefetchedKey)
        UserDefaults.standard.removeObject(forKey: tvdbGroupsCacheKey)
    }
}
