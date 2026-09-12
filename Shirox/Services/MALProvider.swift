import Foundation
import AuthenticationServices
import Combine

@MainActor
final class MALProvider: MediaProvider {
    static let shared = MALProvider()
    private init() {}

    let providerType: ProviderType = .mal
    let displayName = "MyAnimeList"

    var isAuthenticated: Bool { MALAuthManager.shared.isLoggedIn }

    // MARK: - Auth

    func login(presentationAnchor: AnyObject) async throws {
        guard let anchor = presentationAnchor as? ASPresentationAnchor else { return }
        MALAuthManager.shared.login(presentationAnchor: anchor)
    }

    func logout() { MALAuthManager.shared.logout() }

    // MARK: - Discovery

    // Discovery goes through MyAnimeList's own API. Jikan served these historically and still
    // stands in if the official one fails, but it is no longer the only route: when Jikan went
    // down, the rankings behind three Home rows had nothing to fall back to.

    func trending() async throws -> [Media] {
        try await officialOrJikan(
            official: { try await MALOfficialDiscoveryService.shared.ranking(.airing, limit: DataSaver.rowLength(20)) },
            jikan: { try await MALDiscoveryService.shared.trending() }
        )
    }

    func seasonal() async throws -> [Media] {
        let current = MALOfficialDiscoveryService.currentSeason()
        return try await officialOrJikan(
            official: {
                try await MALOfficialDiscoveryService.shared.season(
                    year: current.year, season: current.season, limit: DataSaver.rowLength(20))
            },
            jikan: { try await MALDiscoveryService.shared.seasonal() }
        )
    }

    func popular() async throws -> [Media] {
        try await officialOrJikan(
            official: { try await MALOfficialDiscoveryService.shared.ranking(.byPopularity, limit: DataSaver.rowLength(20)) },
            jikan: { try await MALDiscoveryService.shared.popular() }
        )
    }

    func topRated() async throws -> [Media] {
        try await officialOrJikan(
            official: { try await MALOfficialDiscoveryService.shared.ranking(.all, limit: DataSaver.rowLength(20)) },
            jikan: { try await MALDiscoveryService.shared.topRated() }
        )
    }

    /// Sequenced rather than concurrent: unlike AniList's single combined request, MyAnimeList
    /// still needs one call per row, and Jikan — which these can still fall back to — enforces
    /// ~3 req/s. Firing them at once risked a 429 on exactly the rows that have nowhere else to
    /// go. Moved here unchanged from `HomeViewModel`, which used to special-case MAL inline.
    func homeFeed() async throws -> HomeFeed {
        let t = try await trending()
        try await Task.sleep(nanoseconds: 400_000_000)
        let s = try await seasonal()
        try await Task.sleep(nanoseconds: 400_000_000)
        let l = try await lastSeasonCompleted()
        try await Task.sleep(nanoseconds: 400_000_000)
        let p = try await popular()
        try await Task.sleep(nanoseconds: 400_000_000)
        let r = try await topRated()
        return HomeFeed(trending: t, seasonal: s, lastSeason: l, popular: p, topRated: r)
    }

    func search(_ query: String) async throws -> [Media] {
        try await officialOrJikan(
            official: { try await MALOfficialDiscoveryService.shared.search(query, limit: 25) },
            jikan: { try await MALDiscoveryService.shared.search(query) }
        )
    }

    /// Prefers MyAnimeList's own API, standing Jikan in if it fails or answers emptily.
    ///
    /// An empty ranking or season is never a real answer, so it is treated as a failure here for
    /// the same reason it is inside the Jikan client — one of its hosts returns `200` with an
    /// empty array rather than an error, which rendered as simply having no content.
    private func officialOrJikan(
        official: () async throws -> [MALOfficialDiscoveryService.Node],
        jikan: () async throws -> [MALDiscoveryService.JikanAnime]
    ) async throws -> [Media] {
        do {
            let nodes = try await official()
            if !nodes.isEmpty {
                return nodes.map { MALOfficialDiscoveryService.shared.mapToMedia($0) }
            }
            Logger.shared.log("[MAL] Official API returned nothing — trying Jikan", type: "Provider")
        } catch {
            Logger.shared.log("[MAL] Official API failed (\(error)) — trying Jikan", type: "Provider")
        }
        return try await jikan().map { MALDiscoveryService.shared.mapToMedia($0) }
    }

    func detail(id: Int) async throws -> Media {
        MALDiscoveryService.shared.mapToMedia(try await MALDiscoveryService.shared.detail(malId: id))
    }

    func browse(category: BrowseCategory, page: Int) async throws -> [Media] {
        try await MALDiscoveryService.shared.browse(category: category, page: page).map { MALDiscoveryService.shared.mapToMedia($0) }
    }

    // MARK: - Library

    func fetchLibrary() async throws -> [LibraryEntry] {
        guard MALAuthManager.shared.isLoggedIn else { throw ProviderError.unauthenticated }
        return try await MALLibraryService.shared.fetchLibrary().compactMap { mapEntry($0) }
    }

    func fetchEntry(mediaId: Int) async throws -> LibraryEntry? {
        guard let raw = try await MALLibraryService.shared.fetchEntry(malId: mediaId) else { return nil }
        return mapEntry(raw)
    }

    func updateEntry(mediaId: Int, status: MediaListStatus, progress: Int, score: Double) async throws {
        try await MALLibraryService.shared.updateEntry(malId: mediaId, status: status,
                                                        progress: progress, score: score)
    }

    func deleteEntry(entryId: Int) async throws {
        try await MALLibraryService.shared.deleteEntry(malId: entryId)
    }

    // MARK: - Profile

    func fetchCurrentUser() async throws -> UserProfile {
        try await MALSocialService.shared.fetchCurrentUserProfile()
    }

    func fetchProfile(userId: Int) async throws -> UserProfile {
        // MAL only exposes the signed-in user's profile. The official API
        // (users/@me) returns real anime statistics; the Jikan users/{name}
        // endpoint does not, so use the official one for the profile/stats.
        return try await MALSocialService.shared.fetchCurrentUserProfile()
    }

    // MARK: - Social

    func fetchActivity(filter: ActivityFeed, userId: Int, page: Int) async throws -> [UserActivity] {
        guard let username = MALAuthManager.shared.username else { return [] }
        return try await MALSocialService.shared.fetchHistory(username: username, page: page)
    }

    func discover(genre: String?, sort: DiscoverSort, page: Int) async throws -> [Media] {
        // Genre names go through as-is: matching happens against the names MyAnimeList returns,
        // which are the same ones the picker offers.
        try await MALDiscoveryService.shared.discover(genre: genre, sort: sort, page: page)
            .map { MALDiscoveryService.shared.mapToMedia($0) }
    }

    /// MyAnimeList has no notifications API. Declaring that lets callers route around MAL
    /// instead of reading its empty answer as "no notifications".
    var supportsNotifications: Bool { false }
    func fetchNotifications() async throws -> [ProviderNotification] { [] }

    func postStatus(_ text: String) async throws { throw ProviderError.unsupported }
    func toggleLike(id: Int, type: LikeableType) async throws -> Bool { throw ProviderError.unsupported }
    func toggleFollow(userId: Int) async throws -> Bool { throw ProviderError.unsupported }
    func postReply(activityId: Int, text: String) async throws { throw ProviderError.unsupported }
    func deleteActivity(id: Int) async throws { throw ProviderError.unsupported }

    func fetchFollowers(userId: Int, page: Int) async throws -> [UserProfile] {
        guard let username = MALAuthManager.shared.username else { return [] }
        return try await MALSocialService.shared.fetchFriends(username: username, page: page)
    }

    func fetchFollowing(userId: Int, page: Int) async throws -> [UserProfile] {
        guard let username = MALAuthManager.shared.username else { return [] }
        return try await MALSocialService.shared.fetchFriends(username: username, page: page)
    }

    // MARK: - Mapping

    private func mapEntry(_ e: MALLibraryService.MALListEntry) -> LibraryEntry {
        let node = e.node
        let status = MALLibraryService.shared.mapStatusFromMAL(e.list_status.status)
        let media = Media(
            id: node.id,
            idMal: node.id,
            provider: .mal,
            title: MediaTitle(romaji: node.title, english: nil, native: nil),
            coverImage: MediaCoverImage(large: node.main_picture?.medium, extraLarge: node.main_picture?.large),
            bannerImage: nil,
            description: node.synopsis,
            episodes: node.num_episodes,
            status: node.status,
            averageScore: node.mean.map { Int($0 * 10) },
            genres: node.genres?.map { $0.name },
            season: node.start_season?.season.uppercased(),
            seasonYear: node.start_season?.year,
            nextAiringEpisode: nil,
            relations: nil,
            type: node.media_type,
            format: nil
        )
        return LibraryEntry(
            id: node.id,
            media: media,
            status: status,
            progress: e.list_status.num_episodes_watched ?? 0,
            score: Double(e.list_status.score ?? 0),
            updatedAt: nil,
            customListName: nil,
            timesRewatched: e.list_status.num_times_rewatched
        )
    }
}
