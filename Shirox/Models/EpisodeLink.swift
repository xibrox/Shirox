import Foundation
import Combine

struct EpisodeLink: Identifiable, Equatable {
    let id = UUID()
    let number: Double
    let href: String

    var displayNumber: String {
        number.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(number))
            : String(number)
    }

    static func == (lhs: EpisodeLink, rhs: EpisodeLink) -> Bool {
        lhs.number == rhs.number && lhs.href == rhs.href
    }
}

/// Pure navigation over a flat episode list that may concatenate multiple seasons.
///
/// Modules frequently return one list for a whole franchise, so episode *numbers*
/// repeat across seasons (e.g. S1 1…12 followed by S2 1…4 → 1…12,1…4). Resolving the
/// "next" episode by number alone is therefore ambiguous: it always finds season 1's
/// occurrence. We instead match the playing episode at or after `anchor` — the furthest
/// index the player has reached — so "next after S2 E1" is S2 E2, not S1 E2.
enum EpisodeNavigator {
    /// The episode following the currently-playing one.
    ///
    /// - Parameters:
    ///   - currentNumber: the playing episode's (possibly repeated) number.
    ///   - anchor: the index the current episode was last known to occupy. The search
    ///     for `currentNumber` starts here and only falls back to a global search if no
    ///     match exists at or after it. Pass the selected episode's index to start.
    ///   - episodes: the flat episode list in display order.
    /// - Returns: the resolved index of the current episode and the next episode, or
    ///   `nil` if the current episode is the last one (or cannot be located).
    static func next(currentNumber: Int, anchor: Int, in episodes: [EpisodeLink])
        -> (current: Int, episode: EpisodeLink)? {
        let resolved: Int? = {
            if anchor >= 0, anchor < episodes.count,
               let i = episodes[anchor...].firstIndex(where: { Int($0.number) == currentNumber }) {
                return i
            }
            return episodes.firstIndex(where: { Int($0.number) == currentNumber })
        }()
        guard let current = resolved, current + 1 < episodes.count else { return nil }
        return (current, episodes[current + 1])
    }

    /// The episode following the one with `href`, matched purely by that unique identifier.
    ///
    /// Use this when the playing episode's exact href is known (e.g. the AniList path,
    /// where the module's episode *numbers* may be offset — S2 = 25…48 — or restart per
    /// season, so number-based matching is unreliable). Returns the resolved current index
    /// and the next episode, or `nil` at the end of the list / if `href` isn't found.
    static func next(afterHref href: String?, in episodes: [EpisodeLink])
        -> (current: Int, episode: EpisodeLink)? {
        guard let href, let current = episodes.firstIndex(where: { $0.href == href }),
              current + 1 < episodes.count else { return nil }
        return (current, episodes[current + 1])
    }

    /// The currently-playing episode *itself* (not its successor): anchor on the unique
    /// `href` when known, else fall back to an exact `number` match.
    ///
    /// Stream-refetch / recovery must re-resolve *the episode on screen*. After an in-player
    /// auto-advance the launch episode number is stale, and on a flat multi-season list the
    /// numbers repeat, so a fixed-number lookup returns the wrong episode (playing ep 8 but
    /// refetching ep 7). The saved href is unique, so it disambiguates. Returns `nil` when
    /// neither matches — a refetch that can't identify the episode must abort rather than
    /// resurrect a nearest-but-wrong one.
    ///
    /// The number fallback (no href / unmatched href — e.g. legacy Continue-Watching items, or a
    /// module that changed its URL format) only fires when the number is *unambiguous*. On a flat
    /// multi-season list the number repeats and a first-match lookup always lands on season 1 —
    /// the "leave the app, come back on season 1" bug. When the number is ambiguous we can't tell
    /// which season is on screen, so we abort (nil) rather than silently swap in season 1.
    static func resolve(href: String?, orNumber number: Int, in episodes: [EpisodeLink]) -> EpisodeLink? {
        if let href, let ep = episodes.first(where: { $0.href == href }) { return ep }
        let numberMatches = episodes.filter { Int($0.number) == number }
        return numberMatches.count == 1 ? numberMatches.first : nil
    }

    /// Converts a module's own episode number back to the season-relative number the app tracks.
    ///
    /// The inverse of `ModuleStreamPickerView.matchEpisode`, which picks the module row for a
    /// season-relative episode two different ways. Going the other way matters because the two
    /// halves of playback disagreed otherwise: the AniList flow *launches* with the
    /// season-relative number the user tapped, but the next-episode loaders reported the
    /// module's own number straight back into the same field. On a sequel the display jumped
    /// (S2 E1 → "13"), and `pushRemoteProgress` then re-applied the anchor offset to a number
    /// that already carried it, writing progress to the wrong season entry.
    ///
    /// - Parameters:
    ///   - moduleNumber: the number the module gives this episode.
    ///   - index: its position in `episodes`.
    ///   - episodes: the module's flat list for the resolved detail page.
    ///   - seasonOffset: franchise episodes preceding this season (`SeasonChainMapper
    ///     .resolveOffset`), or 0 when the chain couldn't be resolved.
    static func seasonRelativeNumber(moduleNumber: Int,
                                     index: Int,
                                     in episodes: [EpisodeLink],
                                     seasonOffset: Int) -> Int {
        // Combined franchise list (S1+S2 in one list, numbered from 1): position is the only
        // reliable signal, mirroring matchEpisode's `seasonOffset + target - 1`.
        if seasonOffset > 0, index >= seasonOffset {
            return index - seasonOffset + 1
        }
        // Season-specific page numbered with an absolute offset (S2 = 25…48), mirroring
        // matchEpisode's `minEp + target - 1` branch.
        if let minEp = episodes.map(\.number).min(), minEp > 1 {
            return moduleNumber - Int(minEp) + 1
        }
        // Module already numbers this season from 1 — nothing to convert.
        return moduleNumber
    }

    /// Convenience for the resume paths: anchor on the unique `href` when one was saved,
    /// otherwise fall back to `number` — but only when it names exactly one episode (legacy
    /// items predate the stored href). Returns just the next episode, or `nil` at the end of
    /// the list, when the href is unknown and the number is ambiguous or absent.
    static func next(afterHref href: String?, orNumber number: Int, in episodes: [EpisodeLink]) -> EpisodeLink? {
        if let step = next(afterHref: href, in: episodes) { return step.episode }
        // No usable href — fall back to the number, but only when it identifies exactly one
        // episode. This previously picked the *nearest* number when no exact match existed,
        // which silently advanced into the wrong season on any list the app tracks
        // season-relative while the module numbers it continuously (a sequel listed as 13…24):
        // "next" after S2 E1 searched a list containing no episode 1 at all and landed wherever
        // the arithmetic pointed, then wrote that number through to AniList/MAL. `resolve`
        // above already declines ambiguous number matches for this exact reason; guessing here
        // contradicted it. Returning nil lets the player fall through to its downloaded-episode
        // and sequel paths instead of playing and syncing something wrong.
        let matches = episodes.enumerated().filter { Int($0.element.number) == number }
        guard matches.count == 1, let i = matches.first?.offset, i + 1 < episodes.count else { return nil }
        return episodes[i + 1]
    }
}
