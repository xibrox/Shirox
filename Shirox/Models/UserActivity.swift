import Foundation

// Shared provider-agnostic activity model.
// Reuses ActivityUser and ActivityMedia already defined in AniListActivity.swift.

enum ActivityKind {
    case text(String)
    case list(status: String, progress: String?, media: ActivityMedia?)
}

struct UserActivity: Identifiable {
    let id: Int
    let kind: ActivityKind
    let createdAt: Int
    let user: ActivityUser?
    var likeCount: Int
    let replyCount: Int
    var isLiked: Bool
}

extension UserActivity {
    var asAniListActivity: AniListActivity {
        switch kind {
        case .text(let t):
            return .text(TextActivity(id: id, text: t, createdAt: createdAt,
                user: user, likeCount: likeCount, replyCount: replyCount, isLiked: isLiked))
        case .list(let status, let progress, let media):
            return .list(ListActivity(id: id, status: status, progress: progress,
                createdAt: createdAt, user: user, media: media,
                likeCount: likeCount, replyCount: replyCount, isLiked: isLiked))
        }
    }
}
