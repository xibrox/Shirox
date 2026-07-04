import Foundation
import Combine

/// Resolves and persists a module-scraped manga's tracking identity (AniList + MAL
/// ids) by title. Mirrors AniListMappingManager, but stores the whole match keyed
/// by the stable `mangaHref`. One AniList MANGA search yields both ids (via idMal).
@MainActor final class MangaMatchManager: ObservableObject {
    static let shared = MangaMatchManager()

    private enum Keys { static let matches = "mangaMatches" }

    @Published private(set) var matches: [String: MangaMatch] = [:]

    private init() { load() }

    // MARK: - Pure core (tested)

    /// Chooses a result: an exact case-insensitive title hit within the top 3 is
    /// confident; otherwise the top (most-relevant) result is used but not
    /// confident. nil when there are no results.
    nonisolated static func selectMatch(title: String,
                                        results: [AniListMedia]) -> (media: AniListMedia, confident: Bool)? {
        guard !results.isEmpty else { return nil }
        let needle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let exact = results.prefix(3).first { m in
            [m.title.english, m.title.romaji, m.title.native]
                .compactMap { $0?.lowercased() }
                .contains(needle)
        }
        if let exact { return (exact, true) }
        return (results[0], false)
    }

    /// Builds a MangaMatch from a chosen AniList result.
    nonisolated static func buildMatch(mangaHref: String, title: String,
                                       from media: AniListMedia, confident: Bool) -> MangaMatch {
        MangaMatch(
            mangaHref: mangaHref, title: title,
            aniListID: media.id, malID: media.idMal,
            coverImage: media.coverImage.best, totalChapters: media.chapters,
            confident: confident)
    }

    // MARK: - Public API

    func cachedMatch(mangaHref: String) -> MangaMatch? { matches[mangaHref] }

    /// Returns a cached match if present; otherwise searches AniList and, for a
    /// confident (exact) match, persists it. A fuzzy fallback is returned for the
    /// session but NOT persisted.
    func match(mangaHref: String, title: String) async -> MangaMatch? {
        if let cached = matches[mangaHref] { return cached }
        let results = (try? await AniListService.shared.searchManga(keyword: title)) ?? []
        guard let picked = Self.selectMatch(title: title, results: results) else { return nil }
        let match = Self.buildMatch(mangaHref: mangaHref, title: title,
                                    from: picked.media, confident: picked.confident)
        if picked.confident { saveMatch(match) }
        return match
    }

    func saveMatch(_ match: MangaMatch) {
        matches[match.mangaHref] = match
        persist()
    }

    func clearMatch(mangaHref: String) {
        matches[mangaHref] = nil
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        if let data = try? JSONEncoder().encode(matches) {
            UserDefaults.standard.set(data, forKey: Keys.matches)
        }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Keys.matches),
           let decoded = try? JSONDecoder().decode([String: MangaMatch].self, from: data) {
            matches = decoded
        }
    }
}
