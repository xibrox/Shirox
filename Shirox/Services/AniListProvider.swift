import Foundation
import AuthenticationServices

/// AniList answered in a way that leaves the signed-in user unknown, without ever rejecting the
/// token. Distinct from `ProviderError.unauthenticated` so callers don't tell somebody to sign in
/// again over a rate limit.
enum AniListUnreachable: LocalizedError {
    case viewerUnresolved
    var errorDescription: String? {
        "AniList didn't respond. It may be rate-limiting — try again in a minute."
    }
}

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

    /// One request for all five Home rows. See `AniListService.homeFeed()`.
    func homeFeed() async throws -> HomeFeed {
        let raw = try await AniListService.shared.homeFeed()
        return HomeFeed(
            trending: raw.trending.map { mapMedia($0) },
            seasonal: raw.seasonal.map { mapMedia($0) },
            lastSeason: raw.lastSeason.map { mapMedia($0) },
            popular: raw.popular.map { mapMedia($0) },
            topRated: raw.topRated.map { mapMedia($0) }
        )
    }

    func trending() async throws -> [Media] {
        try await AniListService.shared.trending().map { mapMedia($0) }
    }

    func seasonal() async throws -> [Media] {
        try await AniListService.shared.seasonal().map { mapMedia($0) }
    }

    func lastSeasonCompleted() async throws -> [Media] {
        try await AniListService.shared.lastSeasonCompleted().map { mapMedia($0) }
    }

    func discover(genre: String?, sort: DiscoverSort, page: Int) async throws -> [Media] {
        try await AniListService.shared.discover(genre: genre, sort: sort, page: page).map { mapMedia($0) }
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

    func browse(category: BrowseCategory, page: Int) async throws -> [Media] {
        try await AniListService.shared.browse(category: category, page: page).map { mapMedia($0) }
    }

    // MARK: - Library

    func fetchLibrary() async throws -> [LibraryEntry] {
        if AniListAuthManager.shared.authenticatedUserId == nil,
           await AniListAuthManager.shared.fetchViewer() == false {
            // One retry: `AniListThrottle` widens the gap after a 429, so a second attempt
            // usually lands where the first was turned away.
            _ = await AniListAuthManager.shared.fetchViewer()
        }
        guard let userId = AniListAuthManager.shared.authenticatedUserId else {
            // Still holding a token means the session is intact and AniList simply couldn't be
            // reached — a rate limit or an outage. Reporting that as "you're not signed in"
            // sends people off to re-authenticate over a problem that isn't theirs.
            throw AniListAuthManager.shared.accessToken == nil
                ? ProviderError.unauthenticated
                : ProviderError.networkError(AniListUnreachable.viewerUnresolved)
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

    func deleteEntry(entryId: Int) async throws {
        try await AniListLibraryService.shared.deleteEntry(entryId: entryId)
    }

    // MARK: - Profile

    func fetchCurrentUser() async throws -> UserProfile {
        await AniListAuthManager.shared.fetchViewer()
        guard let userId = AniListAuthManager.shared.authenticatedUserId else { throw ProviderError.unauthenticated }
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
            idMal: m.idMal,
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

    /// Manga variant of `mapMedia`: AniList returns `chapters` (not `episodes`)
    /// for manga, so put the chapter total in the `episodes` slot the editor
    /// stepper and hero read, and force `type = "MANGA"` so `Media.isManga` holds.
    func mapMangaMedia(_ m: AniListMedia) -> Media {
        Media(
            id: m.id,
            idMal: m.idMal,
            provider: .anilist,
            title: MediaTitle(romaji: m.title.romaji, english: m.title.english, native: m.title.native),
            coverImage: MediaCoverImage(large: m.coverImage.large, extraLarge: m.coverImage.extraLarge),
            bannerImage: m.bannerImage,
            description: m.description,
            episodes: m.chapters,
            status: m.status,
            averageScore: m.averageScore,
            genres: m.genres,
            season: m.season,
            seasonYear: m.seasonYear,
            nextAiringEpisode: nil,
            relations: m.relations.map { mapRelations($0) },
            type: "MANGA",
            format: m.format
        )
    }

    func mangaDetail(id: Int) async throws -> Media {
        mapMangaMedia(try await AniListService.shared.mangaDetail(id: id))
    }

    private func mapRelations(_ r: AniListRelations) -> MediaRelations {
        MediaRelations(edges: r.edges.map { e in
            MediaRelationEdge(relationType: e.relationType, node: mapMedia(e.node))
        })
    }

    func mapEntry(_ e: AniListRawEntry) -> LibraryEntry {
        LibraryEntry(id: e.id, media: mapMedia(e.media), status: e.status,
                     progress: e.progress, score: e.score, updatedAt: e.updatedAt,
                     customListName: e.customListName, timesRewatched: e.repeat,
                     isPrivate: e.isPrivate, notes: e.notes)
    }

    func mapUser(_ u: AniListUser) -> UserProfile {
        let favMedia = u.favourites?.anime?.nodes?.map { mapMedia($0) }
        return UserProfile(
            id: u.id,
            provider: .anilist,
            name: u.name,
            about: u.about,
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
                kind: .airing(episode: a.episode, mediaTitle: a.media?.displayTitle,
                              mediaId: a.media?.id ?? 0, coverImageURL: a.media?.coverImage?.large),
                createdAt: a.createdAt)
        case .following(let f):
            return ProviderNotification(id: f.id,
                kind: .following(userId: f.user?.id ?? 0, userName: f.user?.name,
                                 avatarURL: f.user?.avatar?.large),
                createdAt: f.createdAt)
        case .activityMessage(let n):
            return ProviderNotification(id: n.id,
                kind: .activityMessage(activityId: n.activityId, userName: n.user?.name, context: n.context,
                                       avatarURL: n.user?.avatar?.large),
                createdAt: n.createdAt)
        case .activityReply(let n), .activityReplySubscribed(let n):
            return ProviderNotification(id: n.id,
                kind: .activityReply(activityId: n.activityId, userName: n.user?.name, context: n.context,
                                     avatarURL: n.user?.avatar?.large),
                createdAt: n.createdAt)
        case .activityMention(let n):
            return ProviderNotification(id: n.id,
                kind: .activityMention(activityId: n.activityId, userName: n.user?.name, context: n.context,
                                       avatarURL: n.user?.avatar?.large),
                createdAt: n.createdAt)
        case .activityLike(let n), .activityReplyLike(let n):
            return ProviderNotification(id: n.id,
                kind: .activityLike(activityId: n.activityId, userName: n.user?.name, context: n.context,
                                    avatarURL: n.user?.avatar?.large),
                createdAt: n.createdAt)
        case .threadCommentMention(let n), .threadCommentReply(let n), .threadCommentSubscribed(let n):
            return ProviderNotification(id: n.id,
                kind: .threadComment(threadTitle: n.thread?.title, threadURL: n.thread?.siteUrl,
                                     userName: n.user?.name, context: n.context,
                                     avatarURL: n.user?.avatar?.large),
                createdAt: n.createdAt)
        case .threadCommentLike(let n), .threadLike(let n):
            return ProviderNotification(id: n.id,
                kind: .threadLike(threadTitle: n.thread?.title, threadURL: n.thread?.siteUrl,
                                  userName: n.user?.name, context: n.context,
                                  avatarURL: n.user?.avatar?.large),
                createdAt: n.createdAt)
        case .mediaDataChange(let n), .mediaMerge(let n), .mediaAddition(let n):
            return ProviderNotification(id: n.id,
                kind: .mediaChange(title: n.media?.displayTitle, context: n.context,
                                   coverURL: n.media?.coverImage?.large, mediaId: n.media?.id),
                createdAt: n.createdAt)
        case .mediaDeletion(let n):
            return ProviderNotification(id: n.id,
                kind: .mediaChange(title: n.deletedMediaTitle, context: n.context,
                                   coverURL: nil, mediaId: nil),
                createdAt: n.createdAt)
        default:
            return ProviderNotification(id: n.id, kind: .unknown(context: nil), createdAt: n.createdAt)
        }
    }
}
