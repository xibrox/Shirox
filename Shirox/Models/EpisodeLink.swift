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

    /// Convenience for the resume paths: anchor on the unique `href` when one was saved,
    /// otherwise fall back to the episode closest to `number` (legacy items predate the
    /// stored href). Returns just the next episode, or `nil` at the end of the list.
    static func next(afterHref href: String?, orNumber number: Int, in episodes: [EpisodeLink]) -> EpisodeLink? {
        if let step = next(afterHref: href, in: episodes) { return step.episode }
        var idx = episodes.firstIndex(where: { Int($0.number) == number })
        if idx == nil {
            idx = episodes.enumerated().min(by: {
                abs(Int($0.element.number) - number) < abs(Int($1.element.number) - number)
            })?.offset
        }
        guard let i = idx, i + 1 < episodes.count else { return nil }
        return episodes[i + 1]
    }
}
