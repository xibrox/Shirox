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
