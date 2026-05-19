import Foundation

final class IDMappingService {
    static let shared = IDMappingService()
    private let cacheKey = "id_mappings_cache"
    private let prefetchedKey = "id_mappings_prefetched"
    private let mediaCacheKey = "id_media_mappings_cache"
    private let mediaPrefetchedKey = "id_media_mappings_prefetched_v1"
    private var cache: [String: Int] = [:]
    private var mediaCache: [Int: MediaMapping] = [:]

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
    }

    private struct AniraMapping: Decodable {
        let anilistId: Int?
        let malId: Int?
        let imdb_id: String?
        let tmdb_show_id: Int?
        let tmdb_movie_id: Int?
        let media_type: String?
    }

    private struct AniraBulkMapping: Decodable {
        let anilist_id: Int?
        let mal_id: Int?
        let imdb_id: String?
        let tmdb_show_id: Int?
        let tmdb_movie_id: Int?
        let media_type: String?
    }

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

    func anilistId(forMALId malId: Int) async -> Int? {
        let key = "mal-\(malId)"
        if let cached = cache[key] { return cached }
        guard let url = URL(string: "https://api.anira.dev/mappings/mal/\(malId)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let mapping = try? JSONDecoder().decode(AniraMapping.self, from: data),
              let id = mapping.anilistId else { return nil }
        cache[key] = id
        UserDefaults.standard.set(cache, forKey: cacheKey)
        return id
    }

    func malId(forAnilistId anilistId: Int) async -> Int? {
        let key = "anilist-\(anilistId)"
        if let cached = cache[key] { return cached }
        guard let url = URL(string: "https://api.anira.dev/mappings/\(anilistId)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let mapping = try? JSONDecoder().decode(AniraMapping.self, from: data),
              let id = mapping.malId else { return nil }
        cache[key] = id
        UserDefaults.standard.set(cache, forKey: cacheKey)
        return id
    }

    func imdbId(forAnilistId anilistId: Int) async -> String? {
        if let cached = mediaCache[anilistId] { return cached.imdbId }
        await fetchMediaMapping(forAnilistId: anilistId)
        return mediaCache[anilistId]?.imdbId
    }

    func tmdbId(forAnilistId anilistId: Int) async -> (id: Int, isMovie: Bool)? {
        if let cached = mediaCache[anilistId] {
            if let showId = cached.tmdbShowId { return (showId, false) }
            if let movieId = cached.tmdbMovieId { return (movieId, true) }
            return nil
        }
        await fetchMediaMapping(forAnilistId: anilistId)
        guard let cached = mediaCache[anilistId] else { return nil }
        if let showId = cached.tmdbShowId { return (showId, false) }
        if let movieId = cached.tmdbMovieId { return (movieId, true) }
        return nil
    }

    private func fetchMediaMapping(forAnilistId anilistId: Int) async {
        guard let url = URL(string: "https://api.anira.dev/mappings/\(anilistId)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let m = try? JSONDecoder().decode(AniraMapping.self, from: data)
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
        UserDefaults.standard.removeObject(forKey: cacheKey)
        UserDefaults.standard.removeObject(forKey: prefetchedKey)
        UserDefaults.standard.removeObject(forKey: mediaCacheKey)
        UserDefaults.standard.removeObject(forKey: mediaPrefetchedKey)
    }
}
