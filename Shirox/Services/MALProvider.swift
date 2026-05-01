import Foundation
import AuthenticationServices

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

    func trending() async throws -> [Media] {
        try await MALDiscoveryService.shared.trending().map { MALDiscoveryService.shared.mapToMedia($0) }
    }

    func seasonal() async throws -> [Media] {
        try await MALDiscoveryService.shared.seasonal().map { MALDiscoveryService.shared.mapToMedia($0) }
    }

    func popular() async throws -> [Media] {
        try await MALDiscoveryService.shared.popular().map { MALDiscoveryService.shared.mapToMedia($0) }
    }

    func topRated() async throws -> [Media] {
        try await MALDiscoveryService.shared.topRated().map { MALDiscoveryService.shared.mapToMedia($0) }
    }

    func search(_ query: String) async throws -> [Media] {
        try await MALDiscoveryService.shared.search(query).map { MALDiscoveryService.shared.mapToMedia($0) }
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

    // MARK: - Profile

    func fetchCurrentUser() async throws -> UserProfile {
        try await MALSocialService.shared.fetchCurrentUserProfile()
    }

    func fetchProfile(userId: Int) async throws -> UserProfile {
        guard let username = MALAuthManager.shared.username else { throw ProviderError.unauthenticated }
        return try await MALSocialService.shared.fetchProfile(username: username)
    }

    // MARK: - Social

    func fetchActivity(filter: ActivityFeed, userId: Int, page: Int) async throws -> [UserActivity] {
        guard let username = MALAuthManager.shared.username else { return [] }
        return try await MALSocialService.shared.fetchHistory(username: username, page: page)
    }

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
            customListName: nil
        )
    }
}
