import Foundation
import AuthenticationServices

@MainActor
final class AniListProvider: MediaProvider {
    static let shared = AniListProvider()
    private init() {}

    let providerType: ProviderType = .anilist
    let displayName = "AniList"

    var isAuthenticated: Bool { AniListAuthManager.shared.isLoggedIn }

    // MARK: - Auth

    func login(presentationAnchor: AnyObject) async throws {
        guard let anchor = presentationAnchor as? ASPresentationAnchor else { return }
        AniListAuthManager.shared.login(presentationAnchor: anchor)
    }

    func logout() {
        AniListAuthManager.shared.logout()
    }

    // MARK: - Discovery

    func trending() async throws -> [Media] {
        try await AniListService.shared.trending().map { mapMedia($0) }
    }

    func seasonal() async throws -> [Media] {
        try await AniListService.shared.seasonal().map { mapMedia($0) }
    }

    func popular() async throws -> [Media] {
        try await AniListService.shared.popular().map { mapMedia($0) }
    }

    func topRated() async throws -> [Media] {
        try await AniListService.shared.topRated().map { mapMedia($0) }
    }

    func search(_ query: String) async throws -> [Media] {
        try await AniListService.shared.search(keyword: query).map { mapMedia($0) }
    }

    func detail(id: Int) async throws -> Media {
        mapMedia(try await AniListService.shared.detail(id: id))
    }

    // MARK: - Library

    func fetchLibrary() async throws -> [LibraryEntry] {
        if AniListAuthManager.shared.userId == nil {
            await AniListAuthManager.shared.fetchViewer()
        }
        guard let userId = AniListAuthManager.shared.userId else {
            throw ProviderError.unauthenticated
        }
        return try await AniListLibraryService.shared.fetchAllLists(userId: userId).map { mapEntry($0) }
    }

    func fetchEntry(mediaId: Int) async throws -> LibraryEntry? {
        guard let raw = try await AniListLibraryService.shared.fetchEntry(mediaId: mediaId) else { return nil }
        return mapEntry(raw)
    }

    func updateEntry(mediaId: Int, status: MediaListStatus, progress: Int, score: Double) async throws {
        try await AniListLibraryService.shared.updateEntry(mediaId: mediaId, status: status,
                                                           progress: progress, score: score)
    }

    // MARK: - Profile

    func fetchCurrentUser() async throws -> UserProfile {
        await AniListAuthManager.shared.fetchViewer()
        guard let userId = AniListAuthManager.shared.userId else { throw ProviderError.unauthenticated }
        return try await fetchProfile(userId: userId)
    }

    func fetchProfile(userId: Int) async throws -> UserProfile {
        mapUser(try await AniListSocialService.shared.fetchProfile(userId: userId))
    }

    // MARK: - Social

    func fetchActivity(filter: ActivityFeed, userId: Int, page: Int) async throws -> [UserActivity] {
        let result = try await AniListSocialService.shared.fetchActivity(feed: filter, userId: userId, page: page)
        return result.activities.map { mapActivity($0) }
    }

    func fetchNotifications() async throws -> [ProviderNotification] {
        try await AniListSocialService.shared.fetchNotifications(filter: .all).map { mapNotification($0) }
    }

    func postStatus(_ text: String) async throws {
        try await AniListSocialService.shared.postStatus(text: text)
    }

    func toggleLike(id: Int, type: LikeableType) async throws -> Bool {
        switch type {
        case .activity:
            let result = try await AniListSocialService.shared.toggleActivityLike(id: id)
            return result.isLiked
        case .activityReply:
            let result = try await AniListSocialService.shared.toggleReplyLike(id: id)
            return result.isLiked
        }
    }

    func toggleFollow(userId: Int) async throws -> Bool {
        try await AniListSocialService.shared.toggleFollow(userId: userId)
    }

    func postReply(activityId: Int, text: String) async throws {
        _ = try await AniListSocialService.shared.postReply(activityId: activityId, text: text)
    }

    func deleteActivity(id: Int) async throws {
        try await AniListSocialService.shared.deleteActivity(id: id)
    }

    func fetchFollowers(userId: Int, page: Int) async throws -> [UserProfile] {
        let result = try await AniListSocialService.shared.fetchFollowers(userId: userId, page: page)
        return result.users.map { mapUser($0) }
    }

    func fetchFollowing(userId: Int, page: Int) async throws -> [UserProfile] {
        let result = try await AniListSocialService.shared.fetchFollowing(userId: userId, page: page)
        return result.users.map { mapUser($0) }
    }

    // MARK: - Mapping

    func mapMedia(_ m: AniListMedia) -> Media {
        Media(
            id: m.id,
            provider: .anilist,
            title: MediaTitle(romaji: m.title.romaji, english: m.title.english, native: m.title.native),
            coverImage: MediaCoverImage(large: m.coverImage.large, extraLarge: m.coverImage.extraLarge),
            bannerImage: m.bannerImage,
            description: m.description,
            episodes: m.episodes,
            status: m.status,
            averageScore: m.averageScore,
            genres: m.genres,
            season: m.season,
            seasonYear: m.seasonYear,
            nextAiringEpisode: m.nextAiringEpisode.map { MediaAiringEpisode(episode: $0.episode) },
            relations: m.relations.map { mapRelations($0) },
            type: m.type,
            format: m.format
        )
    }

    private func mapRelations(_ r: AniListRelations) -> MediaRelations {
        MediaRelations(edges: r.edges.map { e in
            MediaRelationEdge(relationType: e.relationType, node: mapMedia(e.node))
        })
    }

    func mapEntry(_ e: AniListRawEntry) -> LibraryEntry {
        LibraryEntry(id: e.id, media: mapMedia(e.media), status: e.status,
                     progress: e.progress, score: e.score, updatedAt: e.updatedAt,
                     customListName: e.customListName)
    }

    func mapUser(_ u: AniListUser) -> UserProfile {
        let favMedia = u.favourites?.anime?.nodes?.map { mapMedia($0) }
        return UserProfile(
            id: u.id,
            provider: .anilist,
            name: u.name,
            avatarURL: u.avatar?.large,
            bannerImage: u.bannerImage,
            isFollowing: u.isFollowing,
            statistics: u.statistics.map { s in
                ProfileStatistics(anime: s.anime.map { a in
                    ProfileAnimeStats(
                        count: a.count,
                        episodesWatched: a.episodesWatched,
                        meanScore: a.meanScore,
                        minutesWatched: a.minutesWatched,
                        statuses: a.statuses?.map { ProfileStatusStat(status: $0.status, count: $0.count) },
                        formats: a.formats?.map { ProfileFormatStat(format: $0.format, count: $0.count) },
                        genres: a.genres?.map { ProfileGenreStat(genre: $0.genre, count: $0.count) },
                        scores: a.scores?.map { ProfileScoreStat(score: $0.score, count: $0.count) }
                    )
                })
            },
            favourites: favMedia
        )
    }

    private func mapActivity(_ a: AniListActivity) -> UserActivity {
        switch a {
        case .text(let t):
            return UserActivity(
                id: t.id,
                kind: .text(t.text ?? ""),
                createdAt: t.createdAt,
                user: t.user,
                likeCount: t.likeCount,
                replyCount: t.replyCount,
                isLiked: t.isLiked
            )
        case .list(let l):
            return UserActivity(
                id: l.id,
                kind: .list(status: l.status ?? "", progress: l.progress, media: l.media),
                createdAt: l.createdAt,
                user: l.user,
                likeCount: l.likeCount,
                replyCount: l.replyCount,
                isLiked: l.isLiked
            )
        }
    }

    private func mapNotification(_ n: AniListNotification) -> ProviderNotification {
        switch n {
        case .airing(let a):
            return ProviderNotification(id: a.id,
                kind: .airing(episode: a.episode, mediaTitle: a.media?.displayTitle, mediaId: a.media?.id ?? 0),
                createdAt: a.createdAt)
        case .following(let f):
            return ProviderNotification(id: f.id,
                kind: .following(userId: f.user?.id ?? 0, userName: f.user?.name),
                createdAt: f.createdAt)
        case .activityMessage(let n):
            return ProviderNotification(id: n.id,
                kind: .activityMessage(activityId: n.activityId, context: n.context),
                createdAt: n.createdAt)
        case .activityReply(let n), .activityReplySubscribed(let n):
            return ProviderNotification(id: n.id,
                kind: .activityReply(activityId: n.activityId, context: n.context),
                createdAt: n.createdAt)
        case .activityMention(let n):
            return ProviderNotification(id: n.id,
                kind: .activityMention(activityId: n.activityId, context: n.context),
                createdAt: n.createdAt)
        case .activityLike(let n), .activityReplyLike(let n):
            return ProviderNotification(id: n.id,
                kind: .activityLike(activityId: n.activityId, context: n.context),
                createdAt: n.createdAt)
        case .mediaDataChange(let n), .mediaMerge(let n), .mediaAddition(let n):
            return ProviderNotification(id: n.id,
                kind: .mediaChange(context: n.context),
                createdAt: n.createdAt)
        case .mediaDeletion(let n):
            return ProviderNotification(id: n.id,
                kind: .mediaChange(context: n.context),
                createdAt: n.createdAt)
        default:
            return ProviderNotification(id: n.id, kind: .unknown(context: nil), createdAt: n.createdAt)
        }
    }
}
