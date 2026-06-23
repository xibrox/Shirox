import Foundation

/// Result of mapping a module's global episode number onto a specific season entry.
struct SeasonMapping: Equatable {
    let aniListID: Int?
    let malID: Int?
    let relativeEpisode: Int
    let seasonEpisodeCount: Int?
}

/// One season/cour of a show, as grouped from the anira bulk mappings.
struct SiblingSeason: Equatable, Codable {
    let aniListID: Int?
    let malID: Int?
    let tvdbSeason: Int
    let tvdbEpoffset: Int
    /// Season-relative episode count, if known. May be nil (anira/AniList count missing).
    let episodeCount: Int?
}

/// Pure boundary math — no app dependencies, fully unit-testable.
enum SeasonChainMath {

    /// Maps a module episode number to the correct sibling season and its season-relative
    /// episode number. The number is interpreted relative to `anchor` — the season/cour the
    /// user matched and is watching — so a per-cour number lands on that cour while a
    /// continuous number still flows forward across later cours. Returns nil when it can't
    /// resolve (fewer than 2 siblings, or a needed prior-season count is missing) — caller
    /// falls back.
    static func map(globalEpisode: Int,
                    anchorAniListID: Int? = nil,
                    anchorMALID: Int? = nil,
                    siblings: [SiblingSeason]) -> SeasonMapping? {
        guard globalEpisode > 0, siblings.count >= 2 else { return nil }

        // Cumulative episode base for each tvdb_season (sum of all earlier tvdb_seasons' totals).
        let bySeason = Dictionary(grouping: siblings, by: \.tvdbSeason)
        let seasonsAsc = bySeason.keys.sorted()
        var base: [Int: Int] = [:]
        var running = 0
        for (idx, s) in seasonsAsc.enumerated() {
            base[s] = running
            // The last tvdb_season's total is never needed for a base, so don't require its count.
            if idx < seasonsAsc.count - 1 {
                // total of a tvdb_season = max over its cours of (epoffset + count)
                let totals = bySeason[s]!.compactMap { c in c.episodeCount.map { $0 + c.tvdbEpoffset } }
                guard let total = totals.max() else { return nil } // missing count -> cannot sum
                running += total
            }
        }

        // Global start (0-based) of each sibling, sorted ascending.
        let withStart = siblings
            .map { (s: $0, start: (base[$0.tvdbSeason] ?? 0) + $0.tvdbEpoffset) }
            .sorted { $0.start < $1.start }

        // The module numbers episodes from 1 at the *anchor* entry (the season/cour the user
        // matched), not from the franchise's first season. Shift the incoming number by the
        // anchor's own global start so a per-cour number lands on the cour being watched and a
        // continuous number still flows forward. Unknown anchor → start 0 (legacy behavior).
        let anchorStart = withStart.first { e in
            (anchorAniListID != nil && e.s.aniListID == anchorAniListID) ||
            (anchorMALID != nil && e.s.malID == anchorMALID)
        }?.start ?? 0
        let effectiveEpisode = globalEpisode + anchorStart

        // Find the sibling whose (start, upper] range contains effectiveEpisode.
        // Upper bound = start + episodeCount when known, else the next sibling's start,
        // else +infinity (last sibling absorbs overflow).
        var chosen = withStart.last!
        for (i, e) in withStart.enumerated() {
            let upper: Int
            if let count = e.s.episodeCount {
                upper = e.start + count
            } else if i + 1 < withStart.count {
                upper = withStart[i + 1].start
            } else {
                upper = Int.max
            }
            if effectiveEpisode > e.start && effectiveEpisode <= upper {
                chosen = e
                break
            }
        }

        let relative = effectiveEpisode - chosen.start
        guard relative > 0 else { return nil }
        return SeasonMapping(aniListID: chosen.s.aniListID, malID: chosen.s.malID,
                             relativeEpisode: relative, seasonEpisodeCount: chosen.s.episodeCount)
    }
}
