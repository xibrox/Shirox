import Foundation

@MainActor
final class SkipTimestampsService {
    static let shared = SkipTimestampsService()

    private struct CacheKey: Hashable {
        let aniListID: Int
        let episodeNumber: Int
    }

    private var cache: [CacheKey: SkipSegments] = [:]

    private init() {}

    func fetchSegments(aniListID: Int, episodeNumber: Int) async -> SkipSegments? {
        let key = CacheKey(aniListID: aniListID, episodeNumber: episodeNumber)
        if let cached = cache[key] { return cached }

        let imdbID = await IDMappingService.shared.imdbId(forAnilistId: aniListID)
        let tmdb = await IDMappingService.shared.tmdbId(forAnilistId: aniListID)
        let isMovie = tmdb?.isMovie ?? false

        let season: Int
        if let s = TVDBMappingService.shared.cachedSeason(for: aniListID), s > 0 {
            season = s
        } else {
            season = 1
        }

        async let introDBResult = fetchIntroDB(imdbID: imdbID, season: season, episode: episodeNumber, isMovie: isMovie)
        async let theIntroDBResult = fetchTheIntroDB(tmdbID: tmdb?.id, season: season, episode: episodeNumber, isMovie: isMovie)

        let (introDB, theIntroDB) = await (introDBResult, theIntroDBResult)
        let segments = merge(introdb: introDB, theintrodb: theIntroDB)
        cache[key] = segments
        return segments
    }

    func clearCache() {
        cache.removeAll()
    }

    // MARK: - Private fetches

    private func fetchIntroDB(imdbID: String?, season: Int, episode: Int, isMovie: Bool) async -> IntroDBResponse? {
        guard let imdbID else { return nil }
        var urlString = "https://api.introdb.app/segments?imdb_id=\(imdbID)"
        if !isMovie { urlString += "&season=\(season)&episode=\(episode)" }
        guard let url = URL(string: urlString),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return try? JSONDecoder().decode(IntroDBResponse.self, from: data)
    }

    private func fetchTheIntroDB(tmdbID: Int?, season: Int, episode: Int, isMovie: Bool) async -> TheIntroDBResponse? {
        guard let tmdbID else { return nil }
        var urlString = "https://api.theintrodb.org/v2/media?tmdb_id=\(tmdbID)"
        if !isMovie { urlString += "&season=\(season)&episode=\(episode)" }
        guard let url = URL(string: urlString),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return try? JSONDecoder().decode(TheIntroDBResponse.self, from: data)
    }

    // MARK: - Merge

    private func merge(introdb: IntroDBResponse?, theintrodb: TheIntroDBResponse?) -> SkipSegments {
        var result = SkipSegments()

        if let seg = introdb?.intro {
            result.intro = SkipSegments.Segment(startMs: seg.start_ms, endMs: seg.end_ms)
        } else if let seg = theintrodb?.intro?.first, let endMs = seg.end_ms {
            result.intro = SkipSegments.Segment(startMs: seg.start_ms, endMs: endMs)
        }

        if let seg = introdb?.recap {
            result.recap = SkipSegments.Segment(startMs: seg.start_ms, endMs: seg.end_ms)
        } else if let seg = theintrodb?.recap?.first, let endMs = seg.end_ms {
            result.recap = SkipSegments.Segment(startMs: seg.start_ms, endMs: endMs)
        }

        if let seg = introdb?.outro {
            result.credits = SkipSegments.Segment(startMs: seg.start_ms, endMs: seg.end_ms)
        } else if let seg = theintrodb?.credits?.first, let endMs = seg.end_ms {
            result.credits = SkipSegments.Segment(startMs: seg.start_ms, endMs: endMs)
        }

        if let seg = theintrodb?.preview?.first, let endMs = seg.end_ms {
            result.preview = SkipSegments.Segment(startMs: seg.start_ms, endMs: endMs)
        }

        return result
    }
}

// MARK: - Response decodables (private to this file)

private struct IntroDBResponse: Decodable {
    struct Segment: Decodable {
        let start_ms: Double?
        let end_ms: Double
    }
    let intro: Segment?
    let recap: Segment?
    let outro: Segment?
}

private struct TheIntroDBResponse: Decodable {
    struct Segment: Decodable {
        let start_ms: Double?
        let end_ms: Double?
    }
    let intro: [Segment]?
    let recap: [Segment]?
    let credits: [Segment]?
    let preview: [Segment]?
}
