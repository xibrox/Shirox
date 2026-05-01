import Foundation

final class IDMappingService {
    static let shared = IDMappingService()
    private let cacheKey = "id_mappings_cache"
    private let prefetchedKey = "id_mappings_prefetched"
    private var cache: [String: Int] = [:]

    private init() {
        cache = (UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: Int]) ?? [:]
    }

    private struct AniraMapping: Decodable {
        let anilistId: Int?
        let malId: Int?
    }

    private struct AniraBulkMapping: Decodable {
        let anilist_id: Int?
        let mal_id: Int?
    }

    // MARK: - Bulk prefetch

    func prefetchAllMappingsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: prefetchedKey) else { return }
        Task.detached(priority: .background) {
            guard let url = URL(string: "https://api.anira.dev/mappings/all"),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let mappings = try? JSONDecoder().decode([AniraBulkMapping].self, from: data)
            else { return }

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
}
