import Foundation

enum AniListActivity: Identifiable {
    case text(TextActivity)
    case list(ListActivity)

    var id: Int {
        switch self {
        case .text(let a): return a.id
        case .list(let a): return a.id
        }
    }
    var createdAt: Int {
        switch self {
        case .text(let a): return a.createdAt
        case .list(let a): return a.createdAt
        }
    }
    var user: ActivityUser? {
        switch self {
        case .text(let a): return a.user
        case .list(let a): return a.user
        }
    }
    var likeCount: Int {
        switch self {
        case .text(let a): return a.likeCount
        case .list(let a): return a.likeCount
        }
    }
    var replyCount: Int {
        switch self {
        case .text(let a): return a.replyCount
        case .list(let a): return a.replyCount
        }
    }
    var isLiked: Bool {
        switch self {
        case .text(let a): return a.isLiked
        case .list(let a): return a.isLiked
        }
    }

    func withLike(count: Int, liked: Bool) -> AniListActivity {
        switch self {
        case .text(let a):
            return .text(TextActivity(id: a.id, text: a.text, createdAt: a.createdAt,
                user: a.user, likeCount: count, replyCount: a.replyCount, isLiked: liked))
        case .list(let a):
            return .list(ListActivity(id: a.id, status: a.status, progress: a.progress,
                createdAt: a.createdAt, user: a.user, media: a.media,
                likeCount: count, replyCount: a.replyCount, isLiked: liked))
        }
    }

    func withIncrementedReplyCount() -> AniListActivity {
        switch self {
        case .text(let a):
            return .text(TextActivity(id: a.id, text: a.text, createdAt: a.createdAt,
                user: a.user, likeCount: a.likeCount, replyCount: a.replyCount + 1, isLiked: a.isLiked))
        case .list(let a):
            return .list(ListActivity(id: a.id, status: a.status, progress: a.progress,
                createdAt: a.createdAt, user: a.user, media: a.media,
                likeCount: a.likeCount, replyCount: a.replyCount + 1, isLiked: a.isLiked))
        }
    }
}

struct TextActivity: Identifiable, Codable {
    let id: Int
    let text: String?
    let createdAt: Int
    let user: ActivityUser?
    let likeCount: Int
    let replyCount: Int
    let isLiked: Bool
}

struct ListActivity: Identifiable, Codable {
    let id: Int
    let status: String?
    let progress: String?
    let createdAt: Int
    let user: ActivityUser?
    let media: ActivityMedia?
    let likeCount: Int
    let replyCount: Int
    let isLiked: Bool
}

struct ActivityUser: Codable, Identifiable {
    let id: Int
    let name: String
    let avatar: AniListUserAvatar?
}

struct ActivityMedia: Codable {
    let id: Int
    let title: AniListTitle?
    let coverImage: AniListCoverImage?
}

extension ActivityMedia {
    var displayTitle: String {
        title?.english ?? title?.romaji ?? title?.native ?? "Unknown"
    }
}

struct ActivityReply: Identifiable, Codable {
    let id: Int
    let text: String?
    let createdAt: Int
    let user: ActivityUser?
    let likeCount: Int
    let isLiked: Bool
}
