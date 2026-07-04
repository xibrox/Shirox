import Foundation

/// A module-scraped manga's link to tracking-service identity, resolved by title.
/// Persisted per stable `mangaHref` by `MangaMatchManager`. `malID` comes from the
/// AniList match's `idMal` (nil ⇒ MAL not tracked). `totalChapters` is nil for an
/// ongoing series, which suppresses auto-completion.
struct MangaMatch: Codable, Equatable {
    let mangaHref: String
    let title: String
    var aniListID: Int?
    var malID: Int?
    var coverImage: String?
    var totalChapters: Int?
    /// True only for exact or manually-chosen matches. Fuzzy auto-guesses are
    /// used in-session but not persisted, so a later manual fix isn't shadowed.
    var confident: Bool
}
