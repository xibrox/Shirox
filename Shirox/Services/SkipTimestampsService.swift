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

        let tvdbSeason: Int
        let epoffset: Int
        if let mapping = await TVDBMappingService.shared.getTVDBId(for: aniListID) {
            tvdbSeason = mapping.season.flatMap { $0 > 0 ? $0 : nil } ?? 1
            epoffset = TVDBMappingService.shared.cachedEpOffset(for: aniListID) ?? 0
        } else {
            tvdbSeason = 1
            epoffset = 0
        }
        // If episodeNumber > epoffset the module uses absolute/TVDB numbering —
        // convert to AniList-relative for Anira and use the value directly as tvdbEpisode.
        let isAbsolute = epoffset > 0 && episodeNumber > epoffset
        let aniListEpisode = isAbsolute ? episodeNumber - epoffset : episodeNumber
        let tvdbEpisode = isAbsolute ? episodeNumber : episodeNumber + epoffset

        // 1. Try Anira per-episode endpoint first (has intro/outro in seconds)
        let aniraEp = await TVDBMappingService.shared.fetchAniraEpisode(id: aniListID, episodeNumber: aniListEpisode)
        if let skips = aniraEp?.skips, !skips.isEmpty {
            var result = SkipSegments()
            for skip in skips {
                let seg = SkipSegments.Segment(startMs: skip.start * 1000, endMs: skip.end * 1000)
                switch skip.type {
                case "op", "mixed-op": result.intro = seg
                case "ed", "mixed-ed": result.credits = seg
                case "recap": result.recap = seg
                default: break
                }
            }
            cache[key] = result
            return result
        }

        // 2. Fall back to introdb / theIntroDB
        let imdbID = await IDMappingService.shared.imdbId(forAnilistId: aniListID)
        let tmdb = await IDMappingService.shared.tmdbId(forAnilistId: aniListID)
        let isMovie = tmdb?.isMovie ?? false

        async let introDBResult = fetchIntroDB(imdbID: imdbID, season: tvdbSeason, episode: tvdbEpisode, isMovie: isMovie)
        async let theIntroDBResult = fetchTheIntroDB(tmdbID: tmdb?.id, season: tvdbSeason, episode: tvdbEpisode, isMovie: isMovie)

        var (introDB, theIntroDB) = await (introDBResult, theIntroDBResult)

        // If tvdbEpisode returned nothing and differs from the raw episode number, retry with the raw number
        if introDB?.hasSegments != true && tvdbEpisode != episodeNumber {
            introDB = await fetchIntroDB(imdbID: imdbID, season: tvdbSeason, episode: episodeNumber, isMovie: isMovie)
        }
        if theIntroDB == nil && tvdbEpisode != episodeNumber {
            theIntroDB = await fetchTheIntroDB(tmdbID: tmdb?.id, season: tvdbSeason, episode: episodeNumber, isMovie: isMovie)
        }
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
    var hasSegments: Bool { intro != nil || recap != nil || outro != nil }
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
