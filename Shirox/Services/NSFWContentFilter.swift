import Foundation

/// Layer A: removes NSFW module search results. A tight static keyword list is the
/// always-available floor; an AniList `isAdult` cross-check does the heavy lifting for
/// real anime titles.
@MainActor
final class NSFWContentFilter: ObservableObject {
    static let shared = NSFWContentFilter()
    private init() {}

    /// In-memory per-keyword cache of AniList adult-title sets for this session.
    private var adultSetCache: [String: Set<String>] = [:]

    // MARK: - Keyword floor (explicit-only, whole-token; tunable)
    // Matching is WHOLE-TOKEN (a title token must equal an entry), so explicit words are
    // safe — "anal" never matches "analog", "cock" never matches "peacock". Deliberately
    // EXCLUDED to avoid false-flagging legitimate titles:
    //   • genre words that aren't 18+: ecchi, yaoi, yuri, harem, oppai
    //   • words that collide with real titles: "eromanga" (Eromanga Sensei),
    //     "sexy" (Sexy Commando), "dick" (Hakugei: Legend of the Moby Dick, character
    //     names), "uncensored"/"mature"/"adult" (legit uncut releases)
    // The AniList cross-check catches innocuously-named hentai this list can't.
    nonisolated static let blockedKeywords: Set<String> = [
        // Adult-industry / genre markers
        "hentai", "hentais", "porn", "porno", "pornography",
        "xxx", "nsfw", "r18", "rule34", "jav", "smut", "eroge",
        // Explicit descriptors
        "erotic", "erotica", "nude", "nudes", "naked", "sex",
        // Acts / anatomy (explicit)
        "creampie", "ahegao", "futanari", "bukkake", "gangbang", "milf",
        "boobs", "tits", "pussy", "cock", "anal", "cum",
        "blowjob", "handjob", "threesome", "orgy", "orgasm",
        "fetish", "bdsm", "incest", "nympho", "slut", "whore",
        "fuck", "fucking"
    ]

    // MARK: - Pure decision logic (testable, actor-independent)

    nonisolated static func normalize(_ title: String) -> String {
        var s = title.lowercased()
        s = s.replacingOccurrences(of: #"\b\d+(st|nd|rd|th)\s+season\b"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\b(season|part|cour)\s*\d+\b"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
        return s.split(separator: " ").joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    nonisolated static func containsBlockedKeyword(_ normalizedTitle: String) -> Bool {
        let tokens = Set(normalizedTitle.split(separator: " ").map(String.init))
        return !tokens.isDisjoint(with: blockedKeywords)
    }

    /// Adult if the normalized title exactly matches a variant, or shares a multi-token
    /// (≥2) subset with one. Single-token variants match only exactly, so common words
    /// don't over-block.
    nonisolated static func isAdultTitle(_ normalizedItemTitle: String, adultSet: Set<String>) -> Bool {
        if adultSet.contains(normalizedItemTitle) { return true }
        let itemTokens = Set(normalizedItemTitle.split(separator: " ").map(String.init))
        guard !itemTokens.isEmpty else { return false }
        for variant in adultSet {
            let vTokens = Set(variant.split(separator: " ").map(String.init))
            if vTokens.isEmpty { continue }
            if vTokens.count >= 2, vTokens.isSubset(of: itemTokens) { return true }
            if itemTokens.count >= 2, itemTokens.isSubset(of: vTokens) { return true }
        }
        return false
    }

    // MARK: - Main entry

    func filter(_ items: [SearchItem], keyword: String) async -> [SearchItem] {
        // Layer 1: keyword floor (offline, always runs).
        let afterKeyword = items.filter { !Self.containsBlockedKeyword(Self.normalize($0.title)) }

        // Layer 2: AniList adult cross-check (best-effort; fail-open on error).
        let normKeyword = Self.normalize(keyword)
        let adultSet: Set<String>
        if let cached = adultSetCache[normKeyword] {
            adultSet = cached
        } else if let fetched = try? await AniListService.shared.searchAdultTitles(keyword: keyword) {
            adultSetCache[normKeyword] = fetched
            adultSet = fetched
        } else {
            return afterKeyword   // cross-check unavailable → keyword-filtered results
        }
        guard !adultSet.isEmpty else { return afterKeyword }
        return afterKeyword.filter { !Self.isAdultTitle(Self.normalize($0.title), adultSet: adultSet) }
    }
}
