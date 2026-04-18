import Foundation

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

@MainActor
final class AniListSocialService {
    static let shared = AniListSocialService()
    private let endpoint = URL(string: "https://graphql.anilist.co")!
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        return URLSession(configuration: cfg)
    }()

    private func performQuery<T: Decodable>(query: String, variables: [String: Any] = [:], auth: Bool = false) async throws -> T {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if auth, let token = AniListAuthManager.shared.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = ["query": query, "variables": variables]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await session.data(for: request)
        
        #if DEBUG
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            print("--- GraphQL Response ---\n\(json)")
        }
        #endif
        
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Profile

    func fetchProfile(userId: Int) async throws -> AniListUser {
        struct Response: Decodable {
            struct Data: Decodable { let User: AniListUser }
            let data: Data
        }
        let q = """
        query($id: Int) {
          User(id: $id) {
            id name
            avatar { large }
            bannerImage
            isFollowing
            statistics {
              anime {
                count episodesWatched meanScore minutesWatched
                statuses { status count }
                formats { format count }
                genres { genre count }
                scores { score count }
              }
            }
            favourites { anime { nodes { id title { romaji english native } coverImage { large extraLarge } } } }
          }
        }
        """
        let r: Response = try await performQuery(query: q, variables: ["id": userId], auth: true)
        return r.data.User
    }

    // MARK: - Activity

    func fetchActivity(feed: ActivityFeed, userId: Int, page: Int = 1) async throws -> (activities: [AniListActivity], hasNextPage: Bool) {
        struct Response: Decodable {
            struct Data: Decodable { let Page: PageData }
            let data: Data
        }
        struct PageData: Decodable {
            let pageInfo: PageInfo
            let activities: [ActivityUnion]
        }
        struct PageInfo: Decodable { let hasNextPage: Bool }
        struct ActivityUnion: Decodable {
            let __typename: String
            let id: Int?
            let text: String?
            let status: String?
            let progress: String?
            let createdAt: Int?
            let user: ActivityUser?
            let media: ActivityMedia?
            let likeCount: Int?
            let replyCount: Int?
            let isLiked: Bool?
        }

        var variables: [String: Any] = ["page": page]
        let filterFragment: String
        switch feed {
        case .mine:
            variables["userId"] = userId
            filterFragment = "userId: $userId, sort: ID_DESC"
        case .following:
            filterFragment = "isFollowing: true, sort: ID_DESC"
        case .global:
            filterFragment = "sort: ID_DESC"
        }
        let varDecl = feed == .mine ? "$userId: Int, $page: Int" : "$page: Int"

        let q = """
        query(\(varDecl)) {
          Page(page: $page, perPage: 25) {
            pageInfo { hasNextPage }
            activities(\(filterFragment)) {
              __typename
              ... on TextActivity { id text createdAt likeCount replyCount isLiked user { id name avatar { large } } }
              ... on ListActivity { id status progress createdAt likeCount replyCount isLiked
                user { id name avatar { large } }
                media { id title { romaji english } coverImage { large } } }
            }
          }
        }
        """
        let r: Response = try await performQuery(query: q, variables: variables, auth: true)
        let activities: [AniListActivity] = r.data.Page.activities.compactMap { raw in
            guard let id = raw.id, let createdAt = raw.createdAt else { return nil }
            switch raw.__typename {
            case "TextActivity":
                return .text(TextActivity(id: id, text: raw.text, createdAt: createdAt,
                    user: raw.user, likeCount: raw.likeCount ?? 0, replyCount: raw.replyCount ?? 0,
                    isLiked: raw.isLiked ?? false))
            case "ListActivity":
                return .list(ListActivity(id: id, status: raw.status, progress: raw.progress,
                    createdAt: createdAt, user: raw.user, media: raw.media,
                    likeCount: raw.likeCount ?? 0, replyCount: raw.replyCount ?? 0,
                    isLiked: raw.isLiked ?? false))
            default: return nil
            }
        }
        return (activities, r.data.Page.pageInfo.hasNextPage)
    }

    func fetchActivityById(id: Int) async throws -> AniListActivity? {
        struct Response: Decodable {
            struct Data: Decodable { let Activity: ActivityUnion? }
            let data: Data
        }
        struct ActivityUnion: Decodable {
            let __typename: String
            let id: Int?
            let text: String?
            let status: String?
            let progress: String?
            let createdAt: Int?
            let user: ActivityUser?
            let media: ActivityMedia?
            let likeCount: Int?
            let replyCount: Int?
            let isLiked: Bool?
        }
        let q = """
        query($id: Int) {
          Activity(id: $id) {
            __typename
            ... on TextActivity { id text createdAt likeCount replyCount isLiked user { id name avatar { large } } }
            ... on ListActivity { id status progress createdAt likeCount replyCount isLiked
              user { id name avatar { large } }
              media { id title { romaji english } coverImage { large } } }
          }
        }
        """
        let r: Response = try await performQuery(query: q, variables: ["id": id], auth: true)
        guard let raw = r.data.Activity, let aid = raw.id, let createdAt = raw.createdAt else { return nil }
        switch raw.__typename {
        case "TextActivity":
            return .text(TextActivity(id: aid, text: raw.text, createdAt: createdAt,
                user: raw.user, likeCount: raw.likeCount ?? 0, replyCount: raw.replyCount ?? 0,
                isLiked: raw.isLiked ?? false))
        case "ListActivity":
            return .list(ListActivity(id: aid, status: raw.status, progress: raw.progress,
                createdAt: createdAt, user: raw.user, media: raw.media,
                likeCount: raw.likeCount ?? 0, replyCount: raw.replyCount ?? 0,
                isLiked: raw.isLiked ?? false))
        default: return nil
        }
    }

    func toggleActivityLike(id: Int) async throws -> (likeCount: Int, isLiked: Bool) {
        struct LikeResult: Decodable { let likeCount: Int?; let isLiked: Bool? }
        struct Response: Decodable {
            struct Data: Decodable { let ToggleLikeV2: LikeResult? }
            let data: Data?
        }
        let q = """
        mutation($id: Int) {
          ToggleLikeV2(id: $id, type: ACTIVITY) {
            ... on TextActivity { likeCount isLiked }
            ... on ListActivity { likeCount isLiked }
          }
        }
        """
        let r: Response = try await performQuery(query: q, variables: ["id": id], auth: true)
        return (r.data?.ToggleLikeV2?.likeCount ?? 0, r.data?.ToggleLikeV2?.isLiked ?? false)
    }

    func toggleReplyLike(id: Int) async throws -> (likeCount: Int, isLiked: Bool) {
        struct LikeResult: Decodable { let likeCount: Int?; let isLiked: Bool? }
        struct Response: Decodable {
            struct Data: Decodable { let ToggleLikeV2: LikeResult? }
            let data: Data?
        }
        let q = """
        mutation($id: Int) {
          ToggleLikeV2(id: $id, type: ACTIVITY_REPLY) {
            ... on ActivityReply { likeCount isLiked }
          }
        }
        """
        let r: Response = try await performQuery(query: q, variables: ["id": id], auth: true)
        return (r.data?.ToggleLikeV2?.likeCount ?? 0, r.data?.ToggleLikeV2?.isLiked ?? false)
    }

    func fetchActivityReplies(activityId: Int) async throws -> [ActivityReply] {
        struct Response: Decodable {
            struct Data: Decodable { let Page: PageData }
            let data: Data
        }
        struct PageData: Decodable { let activityReplies: [ActivityReply] }
        let q = """
        query($id: Int) {
          Page(perPage: 50) {
            activityReplies(activityId: $id) {
              id text createdAt likeCount isLiked
              user { id name avatar { large } }
            }
          }
        }
        """
        let r: Response = try await performQuery(query: q, variables: ["id": activityId], auth: true)
        return r.data.Page.activityReplies
    }

    // MARK: - Social

    func fetchFollowers(userId: Int, page: Int = 1) async throws -> (users: [AniListUser], hasNextPage: Bool) {
        struct Response: Decodable {
            struct Data: Decodable { let Page: PageData }
            let data: Data
        }
        struct PageData: Decodable {
            let pageInfo: PageInfo
            let followers: [AniListUser]
        }
        struct PageInfo: Decodable { let hasNextPage: Bool }
        let q = """
        query($userId: Int!, $page: Int) {
          Page(page: $page, perPage: 50) {
            pageInfo { hasNextPage }
            followers(userId: $userId) { id name avatar { large } }
          }
        }
        """
        let r: Response = try await performQuery(query: q, variables: ["userId": userId, "page": page], auth: true)
        return (r.data.Page.followers, r.data.Page.pageInfo.hasNextPage)
    }

    func fetchFollowing(userId: Int, page: Int = 1) async throws -> (users: [AniListUser], hasNextPage: Bool) {
        struct Response: Decodable {
            struct Data: Decodable { let Page: PageData }
            let data: Data
        }
        struct PageData: Decodable {
            let pageInfo: PageInfo
            let following: [AniListUser]
        }
        struct PageInfo: Decodable { let hasNextPage: Bool }
        let q = """
        query($userId: Int!, $page: Int) {
          Page(page: $page, perPage: 50) {
            pageInfo { hasNextPage }
            following(userId: $userId) { id name avatar { large } }
          }
        }
        """
        let r: Response = try await performQuery(query: q, variables: ["userId": userId, "page": page], auth: true)
        return (r.data.Page.following, r.data.Page.pageInfo.hasNextPage)
    }

    // MARK: - Notifications

    func fetchNotifications(filter: AniListNotificationFilter = .all) async throws -> [AniListNotification] {
        struct Response: Decodable {
            struct Data: Decodable { let Page: PageData }
            let data: Data
        }
        struct PageData: Decodable { let notifications: [NotificationUnion] }
        struct NotificationUnion: Decodable {
            let __typename: String
            let id: Int?
            let context: String?
            let contexts: [String]?
            let reason: String?
            let episode: Int?
            let activityId: Int?
            let deletedMediaTitle: String?
            let user: ActivityUser?
            let media: ActivityMedia?
            let createdAt: Int?
        }

        var variables: [String: Any] = [:]
        let varDecl: String
        let filterFragment: String
        if let types = filter.typeList {
            variables["types"] = types
            varDecl = "$types: [NotificationType]"
            filterFragment = "type_in: $types, resetNotificationCount: true"
        } else {
            varDecl = ""
            filterFragment = "resetNotificationCount: true"
        }

        let q = """
        query\(varDecl.isEmpty ? "" : "(\(varDecl))") {
          Page(perPage: 50) {
            notifications(\(filterFragment)) {
              __typename
              ... on AiringNotification { id episode contexts createdAt media { id title { romaji english } coverImage { large } } }
              ... on FollowingNotification { id context createdAt user { id name avatar { large } } }
              ... on ActivityMessageNotification { id context activityId createdAt user { id name avatar { large } } }
              ... on ActivityReplyNotification { id context activityId createdAt user { id name avatar { large } } }
              ... on ActivityReplySubscribedNotification { id context activityId createdAt user { id name avatar { large } } }
              ... on ActivityMentionNotification { id context activityId createdAt user { id name avatar { large } } }
              ... on ActivityLikeNotification { id context activityId createdAt user { id name avatar { large } } }
              ... on ActivityReplyLikeNotification { id context activityId createdAt user { id name avatar { large } } }
              ... on ThreadCommentMentionNotification { id context createdAt user { id name avatar { large } } }
              ... on ThreadCommentReplyNotification { id context createdAt user { id name avatar { large } } }
              ... on ThreadCommentSubscribedNotification { id context createdAt user { id name avatar { large } } }
              ... on ThreadCommentLikeNotification { id context createdAt user { id name avatar { large } } }
              ... on ThreadLikeNotification { id context createdAt user { id name avatar { large } } }
              ... on RelatedMediaAdditionNotification { id context createdAt media { id title { romaji english } coverImage { large } } }
              ... on MediaDataChangeNotification { id context reason createdAt media { id title { romaji english } coverImage { large } } }
              ... on MediaMergeNotification { id context reason createdAt media { id title { romaji english } coverImage { large } } }
              ... on MediaDeletionNotification { id deletedMediaTitle context reason createdAt }
            }
          }
        }
        """
        let r: Response = try await performQuery(query: q, variables: variables, auth: true)
        return r.data.Page.notifications.compactMap { raw in
            guard let id = raw.id else { return nil }
            let createdAt = raw.createdAt ?? 0
            switch raw.__typename {
            case "AiringNotification":
                return .airing(AiringNotification(id: id, episode: raw.episode ?? 0,
                    contexts: raw.contexts, media: raw.media, createdAt: createdAt))
            case "FollowingNotification":
                return .following(FollowingNotification(id: id,
                    context: raw.context, user: raw.user, createdAt: createdAt))
            case "ActivityMessageNotification":
                return .activityMessage(ActivityGenericNotification(id: id, context: raw.context, activityId: raw.activityId, user: raw.user, createdAt: createdAt))
            case "ActivityReplyNotification":
                return .activityReply(ActivityGenericNotification(id: id, context: raw.context, activityId: raw.activityId, user: raw.user, createdAt: createdAt))
            case "ActivityReplySubscribedNotification":
                return .activityReplySubscribed(ActivityGenericNotification(id: id, context: raw.context, activityId: raw.activityId, user: raw.user, createdAt: createdAt))
            case "ActivityMentionNotification":
                return .activityMention(ActivityGenericNotification(id: id, context: raw.context, activityId: raw.activityId, user: raw.user, createdAt: createdAt))
            case "ActivityLikeNotification":
                return .activityLike(ActivityGenericNotification(id: id, context: raw.context, activityId: raw.activityId, user: raw.user, createdAt: createdAt))
            case "ActivityReplyLikeNotification":
                return .activityReplyLike(ActivityGenericNotification(id: id, context: raw.context, activityId: raw.activityId, user: raw.user, createdAt: createdAt))
            case "ThreadCommentMentionNotification":
                return .threadCommentMention(ThreadGenericNotification(id: id, context: raw.context, user: raw.user, createdAt: createdAt))
            case "ThreadCommentReplyNotification":
                return .threadCommentReply(ThreadGenericNotification(id: id, context: raw.context, user: raw.user, createdAt: createdAt))
            case "ThreadCommentSubscribedNotification":
                return .threadCommentSubscribed(ThreadGenericNotification(id: id, context: raw.context, user: raw.user, createdAt: createdAt))
            case "ThreadCommentLikeNotification":
                return .threadCommentLike(ThreadGenericNotification(id: id, context: raw.context, user: raw.user, createdAt: createdAt))
            case "ThreadLikeNotification":
                return .threadLike(ThreadGenericNotification(id: id, context: raw.context, user: raw.user, createdAt: createdAt))
            case "RelatedMediaAdditionNotification":
                return .mediaAddition(MediaGenericNotification(id: id,
                    context: raw.context, reason: nil, media: raw.media, createdAt: createdAt))
            case "MediaDataChangeNotification":
                return .mediaDataChange(MediaGenericNotification(id: id,
                    context: raw.context, reason: raw.reason, media: raw.media, createdAt: createdAt))
            case "MediaMergeNotification":
                return .mediaMerge(MediaGenericNotification(id: id,
                    context: raw.context, reason: raw.reason, media: raw.media, createdAt: createdAt))
            case "MediaDeletionNotification":
                return .mediaDeletion(MediaDeletionNotification(id: id,
                    deletedMediaTitle: raw.deletedMediaTitle,
                    context: raw.context, reason: raw.reason, createdAt: createdAt))
            default: return nil
            }
        }
    }

    // MARK: - Mutations

    func postStatus(text: String) async throws {
        struct Response: Decodable {
            struct Data: Decodable { let SaveTextActivity: TextActivity? }
            let data: Data?
        }
        let q = "mutation($text: String) { SaveTextActivity(text: $text) { id } }"
        let _: Response = try await performQuery(query: q, variables: ["text": text], auth: true)
    }

    func toggleFollow(userId: Int) async throws -> Bool {
        struct Response: Decodable {
            struct Data: Decodable { let ToggleFollow: FollowResult }
            struct FollowResult: Decodable { let isFollowing: Bool }
            let data: Data
        }
        let q = "mutation($id: Int) { ToggleFollow(userId: $id) { isFollowing } }"
        let r: Response = try await performQuery(query: q, variables: ["id": userId], auth: true)
        return r.data.ToggleFollow.isFollowing
    }

    func deleteActivity(id: Int) async throws {
        struct Response: Decodable {
            struct Data: Decodable { let DeleteActivity: Deleted? }
            struct Deleted: Decodable { let deleted: Bool? }
            let data: Data?
        }
        let q = "mutation($id: Int) { DeleteActivity(id: $id) { deleted } }"
        let _: Response = try await performQuery(query: q, variables: ["id": id], auth: true)
    }

    func deleteReply(id: Int) async throws {
        struct Response: Decodable {
            struct Data: Decodable { let DeleteActivityReply: Deleted? }
            struct Deleted: Decodable { let deleted: Bool? }
            let data: Data?
        }
        let q = "mutation($id: Int) { DeleteActivityReply(id: $id) { deleted } }"
        let _: Response = try await performQuery(query: q, variables: ["id": id], auth: true)
    }

    func fetchLikes(id: Int, type: LikeableType, page: Int = 1) async throws -> (users: [ActivityUser], hasNextPage: Bool) {
        struct Response: Decodable {
            struct Data: Decodable { let Page: PageData }
            let data: Data
        }
        struct PageData: Decodable {
            let pageInfo: PageInfo
            let likes: [ActivityUser]
        }
        struct PageInfo: Decodable { let hasNextPage: Bool }
        let q = """
        query($id: Int, $type: LikeableType, $page: Int) {
          Page(page: $page, perPage: 50) {
            pageInfo { hasNextPage }
            likes(likeableId: $id, type: $type) { id name avatar { large } }
          }
        }
        """
        let r: Response = try await performQuery(
            query: q, variables: ["id": id, "type": type.rawValue, "page": page], auth: true)
        return (r.data.Page.likes, r.data.Page.pageInfo.hasNextPage)
    }

    func postReply(activityId: Int, text: String) async throws -> ActivityReply {
        struct Response: Decodable {
            struct Data: Decodable { let SaveActivityReply: ActivityReply }
            let data: Data
        }
        let q = """
        mutation($activityId: Int, $text: String) {
          SaveActivityReply(activityId: $activityId, text: $text) {
            id text createdAt likeCount isLiked
            user { id name avatar { large } }
          }
        }
        """
        let r: Response = try await performQuery(query: q,
            variables: ["activityId": activityId, "text": text], auth: true)
        return r.data.SaveActivityReply
    }
}

