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
        // else +infinity (a last sibling with *unknown* count absorbs continuous overflow).
        // No range matches → the episode lies beyond the known chain (e.g. the newest cour
        // isn't in the offline data yet). Decline so the caller falls back to the anchor the
        // user matched, rather than dumping the episode onto the last known cour as an
        // impossible number (the "ep 13 of a 12-episode cour" bug).
        var chosen: (s: SiblingSeason, start: Int)?
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
        guard let chosen else { return nil }

        let relative = effectiveEpisode - chosen.start
        guard relative > 0 else { return nil }
        return SeasonMapping(aniListID: chosen.s.aniListID, malID: chosen.s.malID,
                             relativeEpisode: relative, seasonEpisodeCount: chosen.s.episodeCount)
    }

    /// Forward complement of `map`: the number of franchise episodes that precede the anchor
    /// season/cour (its 0-based global start). Adding a per-season episode number to this gives
    /// the franchise-absolute episode, used to pick the right entry from a module that
    /// concatenates every season into one list (e.g. AniWorld). Returns 0 when the anchor is
    /// the first season, or nil when a needed prior-season count is missing or the anchor isn't
    /// in the chain — caller then applies no offset.
    static func priorEpisodeCount(anchorAniListID: Int? = nil,
                                  anchorMALID: Int? = nil,
                                  siblings: [SiblingSeason]) -> Int? {
        guard !siblings.isEmpty else { return nil }

        // Cumulative episode base for each tvdb_season (mirrors `map`).
        let bySeason = Dictionary(grouping: siblings, by: \.tvdbSeason)
        let seasonsAsc = bySeason.keys.sorted()
        var base: [Int: Int] = [:]
        var running = 0
        for (idx, s) in seasonsAsc.enumerated() {
            base[s] = running
            if idx < seasonsAsc.count - 1 {
                let totals = bySeason[s]!.compactMap { c in c.episodeCount.map { $0 + c.tvdbEpoffset } }
                guard let total = totals.max() else { return nil } // missing count -> can't sum
                running += total
            }
        }

        guard let anchor = siblings.first(where: {
            (anchorAniListID != nil && $0.aniListID == anchorAniListID) ||
            (anchorMALID != nil && $0.malID == anchorMALID)
        }) else { return nil }

        // If the anchor sits in a non-last tvdb_season, base already counts every earlier
        // season. Within its own season, tvdbEpoffset delimits the cour (no count needed).
        return (base[anchor.tvdbSeason] ?? 0) + anchor.tvdbEpoffset
    }
}

/// Season-aware ordering of a module's search results against an AniList title.
///
/// AniList lists each season as its own entry ("Frieren: Beyond Journey's End Season 2"), while a
/// module's search returns many similarly-named entries in an arbitrary order — so the right
/// season can be buried (e.g. "3rd Season" first, "Season 2" second, base "…" later). This ranks
/// the results so the entry whose base title *and* season number match the query comes first,
/// making the correct season the obvious choice. Pure + unit-testable.
enum SearchResultMatcher {
    struct Parsed: Equatable { let base: String; let season: Int }

    /// Stable-sorts `items` so the best season match leads. Score: base+season match (3) >
    /// same base, other season (2) > one base contains the other (1) > unrelated (0). Ties keep
    /// the module's original order.
    static func ranked<T>(query: String, items: [T], title: (T) -> String) -> [T] {
        let q = parse(query)
        func score(_ raw: String) -> Int {
            let c = parse(raw)
            if c.base == q.base && c.season == q.season { return 3 }
            if c.base == q.base { return 2 }
            if !q.base.isEmpty, c.base.contains(q.base) || q.base.contains(c.base) { return 1 }
            return 0
        }
        return items.enumerated()
            .sorted { a, b in
                let sa = score(title(a.element)), sb = score(title(b.element))
                return sa != sb ? sa > sb : a.offset < b.offset
            }
            .map(\.element)
    }

    /// Splits a title into a normalized base and its season number (1 when none is stated).
    /// Handles "… Season N" and "… Nth Season"; leaves other forms (roman numerals,
    /// spelled-out) in the base, which simply keeps them out of season matching.
    static func parse(_ raw: String) -> Parsed {
        let tokens = normalize(raw).split(separator: " ").map(String.init)
        var season = 1
        var base: [String] = []
        var i = 0
        while i < tokens.count {
            let tok = tokens[i]
            if tok == "season", i + 1 < tokens.count, let n = Int(tokens[i + 1]) {
                season = n; i += 2; continue
            }
            if let n = ordinal(tok), i + 1 < tokens.count, tokens[i + 1] == "season" {
                season = n; i += 2; continue
            }
            base.append(tok); i += 1
        }
        return Parsed(base: base.joined(separator: " "), season: season)
    }

    private static func normalize(_ s: String) -> String {
        var t = s
        for (entity, char) in ["&#039;": "'", "&#39;": "'", "&amp;": "&", "&quot;": "\""] {
            t = t.replacingOccurrences(of: entity, with: char)
        }
        t = t.folding(options: .diacriticInsensitive, locale: nil).lowercased()
        t = t.replacingOccurrences(of: "'", with: "") // "journey's" == "journeys"
        let cleaned = t.map { ($0.isLetter || $0.isNumber) ? $0 : Character(" ") }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }

    /// "2nd" -> 2, "3rd" -> 3, "21st" -> 21; nil when `tok` isn't an ordinal.
    private static func ordinal(_ tok: String) -> Int? {
        guard let suffix = ["st", "nd", "rd", "th"].first(where: { tok.hasSuffix($0) }) else { return nil }
        return Int(tok.dropLast(suffix.count))
    }
}
