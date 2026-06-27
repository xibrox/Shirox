import Foundation

/// Resolves a module's global episode number to the correct AniList/MAL season entry
/// and season-relative episode number, using the offline tvdb sibling groups plus
/// (only when crossing tvdb_seasons) per-season episode counts.
final class SeasonChainMapper {
    static let shared = SeasonChainMapper()
    private init() {}

    func resolve(globalEpisode: Int, anchorAniListID: Int?, anchorMALID: Int?) async -> SeasonMapping? {
        // 1. anchor -> tvdb_id
        let tvdb: Int?
        if let a = anchorAniListID, let t = IDMappingService.shared.tvdbId(forAnilistId: a) {
            tvdb = t
        } else if let m = anchorMALID, let t = IDMappingService.shared.tvdbId(forMALId: m) {
            tvdb = t
        } else {
            tvdb = nil
        }
        guard let tvdbId = tvdb else { return nil }

        // 2. siblings (TV only, from bulk feed — counts nil)
        let rawSiblings = IDMappingService.shared.siblings(forTvdbId: tvdbId)
        guard rawSiblings.count >= 2 else { return nil }

        // 3. Fill episode counts ONLY when more than one tvdb_season is present
        //    (within a single tvdb_season, sorted epoffsets delimit cours without counts).
        let multiSeason = Set(rawSiblings.map(\.tvdbSeason)).count > 1
        var siblings = rawSiblings
        if multiSeason {
            siblings = await withCounts(rawSiblings)
        }

        // 4. Pure mapping (anchor-relative — the module numbers from 1 at the matched entry)
        guard let mapping = SeasonChainMath.map(globalEpisode: globalEpisode,
                                                anchorAniListID: anchorAniListID,
                                                anchorMALID: anchorMALID,
                                                siblings: siblings) else {
            return nil
        }
        Logger.shared.log(
            "[Tracking] season map: global \(globalEpisode) -> anilist \(mapping.aniListID.map(String.init) ?? "nil") mal \(mapping.malID.map(String.init) ?? "nil") relative \(mapping.relativeEpisode)",
            type: "Debug")
        return mapping
    }

    /// Forward offset for episode *selection*: how many franchise episodes precede the anchor
    /// season. Adding a per-season episode number gives the franchise-absolute episode, used to
    /// pick the right entry from a module that concatenates every season (e.g. AniWorld).
    /// nil when the chain can't be resolved (no tvdb mapping, single entry, or missing counts) —
    /// caller then applies no offset.
    func resolveOffset(anchorAniListID: Int?, anchorMALID: Int?) async -> Int? {
        let tvdb: Int?
        if let a = anchorAniListID, let t = IDMappingService.shared.tvdbId(forAnilistId: a) {
            tvdb = t
        } else if let m = anchorMALID, let t = IDMappingService.shared.tvdbId(forMALId: m) {
            tvdb = t
        } else {
            tvdb = nil
        }
        guard let tvdbId = tvdb else { return nil }

        let rawSiblings = IDMappingService.shared.siblings(forTvdbId: tvdbId)
        guard rawSiblings.count >= 2 else { return nil } // single entry → nothing precedes it

        // Counts are only needed to sum across distinct tvdb_seasons; within one season the
        // sorted epoffsets already delimit cours.
        let multiSeason = Set(rawSiblings.map(\.tvdbSeason)).count > 1
        let siblings = multiSeason ? await withCounts(rawSiblings) : rawSiblings

        return SeasonChainMath.priorEpisodeCount(anchorAniListID: anchorAniListID,
                                                 anchorMALID: anchorMALID,
                                                 siblings: siblings)
    }

    /// Returns the siblings with episodeCount populated from anira episode lists (cached).
    private func withCounts(_ siblings: [SiblingSeason]) async -> [SiblingSeason] {
        var out: [SiblingSeason] = []
        out.reserveCapacity(siblings.count)
        for s in siblings {
            var count = s.episodeCount
            if count == nil, let aid = s.aniListID {
                let eps = await TVDBMappingService.shared.getEpisodes(for: aid, provider: .anilist)
                if !eps.isEmpty { count = eps.count }
            }
            out.append(SiblingSeason(aniListID: s.aniListID, malID: s.malID,
                                     tvdbSeason: s.tvdbSeason, tvdbEpoffset: s.tvdbEpoffset,
                                     episodeCount: count))
        }
        return out
    }
}
