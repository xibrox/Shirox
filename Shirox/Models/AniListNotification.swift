import Foundation

enum AniListNotification: Identifiable {
    case airing(AiringNotification)
    case following(FollowingNotification)
    case activityMessage(ActivityGenericNotification)
    case activityReply(ActivityGenericNotification)
    case activityReplySubscribed(ActivityGenericNotification)
    case activityMention(ActivityGenericNotification)
    case activityLike(ActivityGenericNotification)
    case activityReplyLike(ActivityGenericNotification)
    case threadCommentMention(ThreadGenericNotification)
    case threadCommentReply(ThreadGenericNotification)
    case threadCommentSubscribed(ThreadGenericNotification)
    case threadCommentLike(ThreadGenericNotification)
    case threadLike(ThreadGenericNotification)
    case mediaAddition(MediaGenericNotification)
    case mediaDataChange(MediaGenericNotification)
    case mediaMerge(MediaGenericNotification)
    case mediaDeletion(MediaDeletionNotification)
    case unknown(Int)

    var id: Int {
        switch self {
        case .airing(let n): return n.id
        case .following(let n): return n.id
        case .activityMessage(let n), .activityReply(let n), .activityReplySubscribed(let n),
             .activityMention(let n), .activityLike(let n), .activityReplyLike(let n):
            return n.id
        case .threadCommentMention(let n), .threadCommentReply(let n),
             .threadCommentSubscribed(let n), .threadCommentLike(let n), .threadLike(let n):
            return n.id
        case .mediaAddition(let n), .mediaDataChange(let n), .mediaMerge(let n):
            return n.id
        case .mediaDeletion(let n): return n.id
        case .unknown(let i): return i
        }
    }

    var createdAt: Int {
        switch self {
        case .airing(let n): return n.createdAt
        case .following(let n): return n.createdAt
        case .activityMessage(let n), .activityReply(let n), .activityReplySubscribed(let n),
             .activityMention(let n), .activityLike(let n), .activityReplyLike(let n):
            return n.createdAt
        case .threadCommentMention(let n), .threadCommentReply(let n),
             .threadCommentSubscribed(let n), .threadCommentLike(let n), .threadLike(let n):
            return n.createdAt
        case .mediaAddition(let n), .mediaDataChange(let n), .mediaMerge(let n):
            return n.createdAt
        case .mediaDeletion(let n): return n.createdAt
        case .unknown: return 0
        }
    }
}

struct AiringNotification: Codable {
    let id: Int
    let episode: Int
    let contexts: [String]?
    let media: ActivityMedia?
    let createdAt: Int
}

struct FollowingNotification: Codable {
    let id: Int
    let context: String?
    let user: ActivityUser?
    let createdAt: Int
}

struct ActivityGenericNotification: Codable {
    let id: Int
    let context: String?
    let activityId: Int?
    let user: ActivityUser?
    let createdAt: Int
}

struct ThreadGenericNotification: Codable {
    let id: Int
    let context: String?
    let user: ActivityUser?
    let createdAt: Int
}

struct MediaGenericNotification: Codable {
    let id: Int
    let context: String?
    let reason: String?
    let media: ActivityMedia?
    let createdAt: Int
}

struct MediaDeletionNotification: Codable {
    let id: Int
    let deletedMediaTitle: String?
    let context: String?
    let reason: String?
    let createdAt: Int
}

enum AniListNotificationFilter: String, CaseIterable, Identifiable {
    case all, airing, activity, follows, media
    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .airing: return "Airing"
        case .activity: return "Activity"
        case .follows: return "Follows"
        case .media: return "Media"
        }
    }

    var icon: String {
        switch self {
        case .all: return "bell"
        case .airing: return "tv"
        case .activity: return "bubble.left.and.bubble.right"
        case .follows: return "person.2"
        case .media: return "sparkles.tv"
        }
    }

    var typeList: [String]? {
        switch self {
        case .all: return nil
        case .airing: return ["AIRING"]
        case .activity:
            return ["ACTIVITY_MESSAGE", "ACTIVITY_REPLY", "ACTIVITY_REPLY_SUBSCRIBED",
                    "ACTIVITY_MENTION", "ACTIVITY_LIKE", "ACTIVITY_REPLY_LIKE"]
        case .follows: return ["FOLLOWING"]
        case .media:
            return ["RELATED_MEDIA_ADDITION", "MEDIA_DATA_CHANGE", "MEDIA_MERGE", "MEDIA_DELETION"]
        }
    }
}
