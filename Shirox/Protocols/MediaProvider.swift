import Foundation

// MARK: - Errors

enum ProviderError: Error, LocalizedError {
    case unauthenticated
    case notFound
    case serverError(Int)
    case networkError(Error)
    case unsupported
    case decodingError(Error)
    /// Every signed-in provider failed, in the order they were tried. Carries all of them so
    /// the message can name the one the user chose alongside whatever was tried after it.
    case allProvidersFailed([(provider: ProviderType, error: Error)])

    var isFallbackEligible: Bool {
        switch self {
        case .networkError, .serverError: return true
        // Already exhausted every provider — there is nothing left to fall back to.
        case .allProvidersFailed: return false
        default: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .allProvidersFailed(let failures):
            guard !failures.isEmpty else { return "No tracker is available." }
            // Lead with which services were tried, then each one's own explanation — a service
            // that says why it's down beats a bare status code.
            let names = ListFormatter.localizedString(byJoining: failures.map(\.provider.displayName))
            let verb = failures.count == 1 ? "is" : "are"
            let reasons = failures
                .map { "\($0.provider.displayName): \($0.error.localizedDescription)" }
                .joined(separator: "\n")
            return "\(names) \(verb) unavailable.\n\n\(reasons)"
        case .unauthenticated: return "Not logged in."
        case .notFound: return "Content not found."
        case .serverError(let code):
            // 5xx and 429 from a free public API are load, not breakage — say something the
            // reader can act on instead of a bare status code.
            switch code {
            case 429: return "Too many requests just now. Try again in a moment."
            case 500...599: return "The service is busy. Try again in a moment."
            default: return "Server error (\(code))."
            }
        case .networkError(let e): return e.localizedDescription
        case .unsupported: return "This feature is not supported by the current provider."
        case .decodingError(let e): return "Data error: \(e.localizedDescription)"
        }
    }
}

// MARK: - Supporting enums

enum LikeableType: String {
    case activity = "ACTIVITY"
    case activityReply = "ACTIVITY_REPLY"
}

enum ActivityFeed: String, CaseIterable, Identifiable {
    case mine, following, global
    var id: String { rawValue }
    var label: String {
        switch self {
        case .mine: return "My Feed"
        case .following: return "Following"
        case .global: return "Global"
        }
    }
    var icon: String {
        switch self {
        case .mine: return "person.circle"
        case .following: return "person.2.circle"
        case .global: return "globe"
        }
    }
}


/// Sort orders offered by the Search tab's browse grid.
///
/// A deliberately short list: these are the four questions people actually arrive with — what's
/// big, what's hot, what's best, what's new — not a mirror of either service's full sort enum,
/// which have dozens of options nobody browses by.
enum DiscoverSort: String, CaseIterable, Identifiable {
    case popular, trending, topRated, newest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .popular:  return "Popular"
        case .trending: return "Trending"
        case .topRated: return "Top Rated"
        case .newest:   return "Newest"
        }
    }

    /// AniList `MediaSort`.
    var aniListValue: String {
        switch self {
        case .popular:  return "POPULARITY_DESC"
        case .trending: return "TRENDING_DESC"
        case .topRated: return "SCORE_DESC"
        case .newest:   return "START_DATE_DESC"
        }
    }

    /// Jikan `order_by`, paired with the direction below.
    var jikanOrderBy: String {
        switch self {
        case .popular:  return "popularity"
        case .trending: return "members"
        case .topRated: return "score"
        case .newest:   return "start_date"
        }
    }

    /// Jikan ranks popularity ascending (rank 1 is the most popular); everything else descends.
    var jikanDirection: String { self == .popular ? "asc" : "desc" }

    /// The `/top/anime` ranking that matches this sort, if one does.
    ///
    /// Doubly optional on purpose: `nil` means that endpoint can't express this sort at all
    /// (only "Newest"), while `.some(nil)` means it can — as its default score ranking — with
    /// no `filter` parameter. `/top/anime` is far more reliable than Jikan's search endpoint,
    /// so an unfiltered browse should prefer it.
    var jikanTopFilter: String?? {
        switch self {
        case .popular:  return .some("bypopularity")
        case .trending: return .some("airing")
        case .topRated: return .some(nil)
        case .newest:   return nil
        }
    }
}

/// The genre vocabulary the browse grid offers, using AniList's names.
///
/// MyAnimeList publishes the same set under its own numeric ids — 17 of the 18 match by name
/// exactly, including Mecha, Music, Psychological and Mahou Shoujo. Only Thriller differs,
/// which MAL calls Suspense. Verified against `GET /v4/genres/anime`.
enum DiscoverGenre {
    static let all = [
        "Action", "Adventure", "Comedy", "Drama", "Ecchi", "Fantasy", "Horror",
        "Mahou Shoujo", "Mecha", "Music", "Mystery", "Psychological", "Romance",
        "Sci-Fi", "Slice of Life", "Sports", "Supernatural", "Thriller"
    ]

    /// Jikan's id for a genre named the AniList way.
    static func malID(for genre: String) -> Int? {
        switch genre {
        case "Action":        return 1
        case "Adventure":     return 2
        case "Comedy":        return 4
        case "Drama":         return 8
        case "Ecchi":         return 9
        case "Fantasy":       return 10
        case "Horror":        return 14
        case "Mahou Shoujo":  return 66
        case "Mecha":         return 18
        case "Music":         return 19
        case "Mystery":       return 7
        case "Psychological": return 40
        case "Romance":       return 22
        case "Sci-Fi":        return 24
        case "Slice of Life": return 36
        case "Sports":        return 30
        case "Supernatural":  return 37
        // MAL files AniList's "Thriller" under "Suspense".
        case "Thriller":      return 41
        default:              return nil
        }
    }
}

// MARK: - Protocol

@MainActor
protocol MediaProvider: AnyObject {
    var providerType: ProviderType { get }
    var displayName: String { get }
    var isAuthenticated: Bool { get }

    // Auth
    func login(presentationAnchor: AnyObject) async throws
    func logout()

    // Discovery
    func trending() async throws -> [Media]
    func seasonal() async throws -> [Media]
    /// Browsable anime for the Search tab, optionally narrowed to one genre.
    func discover(genre: String?, sort: DiscoverSort, page: Int) async throws -> [Media]
    /// Last season's finished shows. Optional: a provider without a way to filter by both
    /// season and airing status returns an empty list and the home row simply doesn't appear.
    func lastSeasonCompleted() async throws -> [Media]
    func popular() async throws -> [Media]
    func topRated() async throws -> [Media]
    func search(_ query: String) async throws -> [Media]
    func detail(id: Int) async throws -> Media
    func browse(category: BrowseCategory, page: Int) async throws -> [Media]

    // Library
    func fetchLibrary() async throws -> [LibraryEntry]
    func fetchEntry(mediaId: Int) async throws -> LibraryEntry?
    func updateEntry(mediaId: Int, status: MediaListStatus, progress: Int, score: Double) async throws
    func deleteEntry(entryId: Int) async throws

    // Profile
    func fetchCurrentUser() async throws -> UserProfile
    func fetchProfile(userId: Int) async throws -> UserProfile

    // Social
    func fetchActivity(filter: ActivityFeed, userId: Int, page: Int) async throws -> [UserActivity]
    func fetchNotifications() async throws -> [ProviderNotification]

    /// Whether this provider actually has a notifications endpoint.
    ///
    /// A provider that can't serve them must say so rather than answering with an empty list:
    /// routed through `ProviderManager.call`, an empty answer from a fallback provider is
    /// indistinguishable from "you have no notifications", which is how the screen came to
    /// look permanently empty after any transient AniList error.
    var supportsNotifications: Bool { get }
    func postStatus(_ text: String) async throws
    func toggleLike(id: Int, type: LikeableType) async throws -> Bool
    func toggleFollow(userId: Int) async throws -> Bool
    func postReply(activityId: Int, text: String) async throws
    func deleteActivity(id: Int) async throws
    func fetchFollowers(userId: Int, page: Int) async throws -> [UserProfile]
    func fetchFollowing(userId: Int, page: Int) async throws -> [UserProfile]
}


extension MediaProvider {
    /// Providers serve notifications unless they opt out.
    var supportsNotifications: Bool { true }

    /// No last-season row unless a provider can actually answer the query.
    func lastSeasonCompleted() async throws -> [Media] { [] }

    /// No browse grid unless a provider implements one.
    func discover(genre: String?, sort: DiscoverSort, page: Int) async throws -> [Media] { [] }
}
