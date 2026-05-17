import Foundation

enum NotificationKind {
    case airing(episode: Int, mediaTitle: String?, mediaId: Int, coverImageURL: String?)
    case following(userId: Int, userName: String?, avatarURL: String?)
    case activityMessage(activityId: Int?, context: String?, avatarURL: String?)
    case activityReply(activityId: Int?, context: String?, avatarURL: String?)
    case activityMention(activityId: Int?, context: String?, avatarURL: String?)
    case activityLike(activityId: Int?, context: String?, avatarURL: String?)
    case mediaChange(context: String?)
    case unknown(context: String?)
}

extension NotificationKind {
    enum IconImage {
        case avatar(String)
        case cover(String)
    }

    var iconImage: IconImage? {
        switch self {
        case .airing(_, _, _, let url): return url.map { .cover($0) }
        case .following(_, _, let url): return url.map { .avatar($0) }
        case .activityMessage(_, _, let url): return url.map { .avatar($0) }
        case .activityReply(_, _, let url): return url.map { .avatar($0) }
        case .activityMention(_, _, let url): return url.map { .avatar($0) }
        case .activityLike(_, _, let url): return url.map { .avatar($0) }
        default: return nil
        }
    }
}

struct ProviderNotification: Identifiable {
    let id: Int
    let kind: NotificationKind
    let createdAt: Int
}
