import Foundation

enum NotificationKind {
    case airing(episode: Int, mediaTitle: String?, mediaId: Int)
    case following(userId: Int, userName: String?)
    case activityMessage(activityId: Int?, context: String?)
    case activityReply(activityId: Int?, context: String?)
    case activityMention(activityId: Int?, context: String?)
    case activityLike(activityId: Int?, context: String?)
    case mediaChange(context: String?)
    case unknown(context: String?)
}

struct ProviderNotification: Identifiable {
    let id: Int
    let kind: NotificationKind
    let createdAt: Int
}
