import Foundation

final class IDMappingService {
    static let shared = IDMappingService()
    private let cacheKey = "id_mappings_cache"
    private var cache: [String: Int] = [:]

    private init() {
        cache = (UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: Int]) ?? [:]
    }

    private struct AniraMapping: Decodable {
        let anilistId: Int?
        let malId: Int?
    }

    func cachedAnilistId(forMALId malId: Int) -> Int? {
        cache["mal-\(malId)"]
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
