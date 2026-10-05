import Foundation

/// Picks the AniList entry a module page is, when no title matches exactly.
///
/// The page used to take AniList's top search result, and AniList ranks the best-known entry
/// first: "Dr. Stone Science Future Part 3" matched the original Dr. STONE, and watching its
/// episode 12 marked episode 12 there. A title naming a season, part or cour now only matches an
/// entry carrying the same number, and one that shares too few words with the title matches
/// nothing — no match leaves the page untracked, which the user can fix, rather than tracking
/// the wrong show.
enum AniListTitleMatcher {
    struct Candidate: Equatable {
        let id: Int
        let titles: [String]
    }

    /// The candidate to use, in search order among equally good ones; nil when none fits.
    static func bestMatch(for title: String, among candidates: [Candidate]) -> Int? {
        let wanted = sequelNumbers(in: title)
        let words = significantWords(in: title)
        var best: (id: Int, score: Double)?
        var sharesAnyWord = false
        var firstOfSameSeason: Int?
        for candidate in candidates {
            let titles = candidate.titles.filter { !$0.isEmpty }
            guard !titles.isEmpty else { continue }
            let score = titles.map { overlap(words, significantWords(in: $0)) }.max() ?? 0
            if score > 0 { sharesAnyWord = true }
            guard titles.contains(where: { sameSeason(wanted, sequelNumbers(in: $0)) }) else { continue }
            if firstOfSameSeason == nil { firstOfSameSeason = candidate.id }
            guard score >= 0.5 else { continue }
            if best == nil || score > best!.score { best = (candidate.id, score) }
        }
        if let best { return best.id }
        // A title in another script shares no words with AniList's romaji and English ones;
        // AniList's own ranking is all there is to go on, still kept to the same season.
        return sharesAnyWord ? nil : firstOfSameSeason
    }

    /// Whether a page and an entry are the same season by their numbers. A title with none is the
    /// first season; "Season 4 Part 3" and "Cour 3" agree on 3.
    static func sameSeason(_ page: Set<Int>, _ entry: Set<Int>) -> Bool {
        let pageSequel = page.filter { $0 > 1 }
        let entrySequel = entry.filter { $0 > 1 }
        if pageSequel.isEmpty { return entrySequel.isEmpty }
        return !pageSequel.isDisjoint(with: entrySequel)
    }

    /// The numbers a title gives its season by: "Season 2", "2nd Season", "Part 3", "Cour 2",
    /// a trailing "II", or a trailing small number ("Title 2"). Years and episode counts aren't.
    static func sequelNumbers(in title: String) -> Set<Int> {
        let lower = title.lowercased()
        func numbers(_ patterns: [String]) -> Set<Int> {
            var found = Set<Int>()
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                for match in regex.matches(in: lower, range: NSRange(lower.startIndex..., in: lower)) {
                    if let r = Range(match.range(at: 1), in: lower), let n = Int(lower[r]) { found.insert(n) }
                }
            }
            return found
        }
        var named = numbers([
            #"(?:season|part|cour|arc|series|сезон|часть)\s*(\d{1,2})\b"#,
            #"\b(\d{1,2})(?:st|nd|rd|th)?\s+(?:season|part|cour|сезон|часть)"#,
            #"\bs(\d{1,2})\b"#,
        ])
        let romans = ["ii": 2, "iii": 3, "iv": 4, "v": 5, "vi": 6]
        if let last = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).last,
           let n = romans[String(last)] {
            named.insert(n)
        }
        // A bare trailing number only when the title names no season: "Kaiju No. 8 Season 2" is
        // season 2, not 8.
        return named.isEmpty ? numbers([#"[\s:\-]+(\d{1,2})\s*$"#]) : named
    }

    /// Lowercased words, without numbers and the words seasons are named with.
    static func significantWords(in title: String) -> Set<String> {
        let ignored: Set<String> = ["the", "a", "an", "of", "no", "season", "part", "cour", "arc", "series",
                                    "nd", "st", "rd", "th", "tv", "ii", "iii", "iv"]
        let words = title.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !ignored.contains($0) && $0.range(of: #"^\d+(st|nd|rd|th)?$"#, options: .regularExpression) == nil }
        return Set(words)
    }

    /// The share of the page's words the entry has, against the larger title, so a short entry
    /// title doesn't match a long page title on one word.
    static func overlap(_ page: Set<String>, _ entry: Set<String>) -> Double {
        guard !page.isEmpty, !entry.isEmpty else { return 0 }
        return Double(page.intersection(entry).count) / Double(max(page.count, entry.count))
    }
}
