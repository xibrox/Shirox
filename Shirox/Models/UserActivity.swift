import Foundation

// Shared provider-agnostic activity model.
// Reuses ActivityUser and ActivityMedia already defined in AniListActivity.swift.

enum ActivityKind {
    case text(String)
    case list(status: String, progress: String?, media: ActivityMedia?)
}

struct UserActivity: Identifiable, Codable {
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

extension ActivityKind: Codable {
    private enum CodingKeys: String, CodingKey { case type, text, status, progress, media }
    private enum Kind: String, Codable { case text, list }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .text:
            self = .text(try c.decode(String.self, forKey: .text))
        case .list:
            self = .list(
                status: try c.decode(String.self, forKey: .status),
                progress: try c.decodeIfPresent(String.self, forKey: .progress),
                media: try c.decodeIfPresent(ActivityMedia.self, forKey: .media))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let t):
            try c.encode(Kind.text, forKey: .type)
            try c.encode(t, forKey: .text)
        case .list(let status, let progress, let media):
            try c.encode(Kind.list, forKey: .type)
            try c.encode(status, forKey: .status)
            try c.encodeIfPresent(progress, forKey: .progress)
            try c.encodeIfPresent(media, forKey: .media)
        }
    }
}
