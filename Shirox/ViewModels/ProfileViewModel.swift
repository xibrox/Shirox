import Foundation

@MainActor
final class ProfileViewModel: ObservableObject {
    @Published var user: UserProfile?
    @Published var activity: [UserActivity] = []
    @Published var hasNextActivityPage = false
    private var currentActivityPage = 1

    @Published var notifications: [ProviderNotification] = []
    @Published var followers: [UserProfile] = []
    @Published var hasNextFollowersPage = false
    private var currentFollowersPage = 1

    @Published var following: [UserProfile] = []
    @Published var hasNextFollowingPage = false
    private var currentFollowingPage = 1

    @Published var isTogglingFollow = false

    @Published var activityFeed: ActivityFeed = .mine
    @Published var notificationFilter: AniListNotificationFilter = .all

    @Published var isLoadingProfile = false
    @Published var isLoadingActivity = false
    @Published var isLoadingNotifications = false
    @Published var isLoadingSocial = false
    @Published var error: String?

    func loadProfile(userId: Int) async {
        isLoadingProfile = true
        defer { isLoadingProfile = false }
        do {
            user = try await ProviderManager.shared.call { try await $0.fetchProfile(userId: userId) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadActivity(userId: Int, feed: ActivityFeed? = nil, loadMore: Bool = false) async {
        if let feed {
            if activityFeed != feed { activity = []; currentActivityPage = 1 }
            activityFeed = feed
        }
        if loadMore { currentActivityPage += 1 } else { currentActivityPage = 1 }
        isLoadingActivity = true
        defer { isLoadingActivity = false }
        do {
            let result = try await ProviderManager.shared.call {
                try await $0.fetchActivity(filter: self.activityFeed, userId: userId, page: self.currentActivityPage)
            }
            if loadMore { activity.append(contentsOf: result) } else { activity = result }
            hasNextActivityPage = !result.isEmpty
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadNotifications(filter: AniListNotificationFilter? = nil) async {
        if let filter { notificationFilter = filter }
        isLoadingNotifications = true
        defer { isLoadingNotifications = false }
        do {
            notifications = try await ProviderManager.shared.call { try await $0.fetchNotifications() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadSocial(userId: Int, type: SocialType, loadMore: Bool = false) async {
        isLoadingSocial = true
        defer { isLoadingSocial = false }
        let page = loadMore ? (type == .followers ? currentFollowersPage + 1 : currentFollowingPage + 1) : 1
        do {
            if type == .followers {
                let result = try await ProviderManager.shared.call {
                    try await $0.fetchFollowers(userId: userId, page: page)
                }
                if loadMore { followers.append(contentsOf: result) } else { followers = result }
                currentFollowersPage = page
                hasNextFollowersPage = !result.isEmpty
            } else {
                let result = try await ProviderManager.shared.call {
                    try await $0.fetchFollowing(userId: userId, page: page)
                }
                if loadMore { following.append(contentsOf: result) } else { following = result }
                currentFollowingPage = page
                hasNextFollowingPage = !result.isEmpty
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func toggleFollow(userId: Int) async {
        isTogglingFollow = true
        defer { isTogglingFollow = false }
        do {
            let result = try await ProviderManager.shared.call { try await $0.toggleFollow(userId: userId) }
            user?.isFollowing = result
        } catch {
            self.error = error.localizedDescription
        }
    }

    func toggleLike(activityId: Int, type: LikeableType) async {
        do {
            let isLiked = try await ProviderManager.shared.call {
                try await $0.toggleLike(id: activityId, type: type)
            }
            if let index = activity.firstIndex(where: { $0.id == activityId }) {
                activity[index].isLiked = isLiked
                activity[index].likeCount += isLiked ? 1 : -1
            }
        } catch ProviderError.unsupported {
            // MAL doesn't support likes — silently ignore
        } catch {
            self.error = error.localizedDescription
        }
    }

    enum SocialType { case followers, following }

    func postStatus(text: String) async {
        do {
            try await ProviderManager.shared.call { try await $0.postStatus(text) }
            if let uid = AniListAuthManager.shared.userId {
                await loadActivity(userId: uid)
            }
        } catch ProviderError.unsupported {
            self.error = "Posting status is not supported by the current provider."
        } catch {
            self.error = error.localizedDescription
        }
    }
}
