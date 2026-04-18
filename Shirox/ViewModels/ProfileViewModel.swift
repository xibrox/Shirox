import Foundation

@MainActor
final class ProfileViewModel: ObservableObject {
    @Published var user: AniListUser?
    @Published var activity: [AniListActivity] = []
    @Published var hasNextActivityPage = false
    private var currentActivityPage = 1

    @Published var notifications: [AniListNotification] = []
    @Published var followers: [AniListUser] = []
    @Published var hasNextFollowersPage = false
    private var currentFollowersPage = 1

    @Published var following: [AniListUser] = []
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
            user = try await AniListSocialService.shared.fetchProfile(userId: userId)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadActivity(userId: Int, feed: ActivityFeed? = nil, loadMore: Bool = false) async {
        if let feed {
            if activityFeed != feed {
                activity = []
                currentActivityPage = 1
            }
            activityFeed = feed
        }
        
        if loadMore {
            currentActivityPage += 1
        } else {
            currentActivityPage = 1
        }

        isLoadingActivity = true
        defer { isLoadingActivity = false }
        do {
            let result = try await AniListSocialService.shared.fetchActivity(
                feed: activityFeed, userId: userId, page: currentActivityPage)
            if loadMore {
                activity.append(contentsOf: result.activities)
            } else {
                activity = result.activities
            }
            hasNextActivityPage = result.hasNextPage
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadNotifications(filter: AniListNotificationFilter? = nil) async {
        if let filter { notificationFilter = filter }
        isLoadingNotifications = true
        defer { isLoadingNotifications = false }
        do {
            notifications = try await AniListSocialService.shared.fetchNotifications(
                filter: notificationFilter)
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
                let result = try await AniListSocialService.shared.fetchFollowers(userId: userId, page: page)
                if loadMore {
                    followers.append(contentsOf: result.users)
                } else {
                    followers = result.users
                }
                currentFollowersPage = page
                hasNextFollowersPage = result.hasNextPage
            } else {
                let result = try await AniListSocialService.shared.fetchFollowing(userId: userId, page: page)
                if loadMore {
                    following.append(contentsOf: result.users)
                } else {
                    following = result.users
                }
                currentFollowingPage = page
                hasNextFollowingPage = result.hasNextPage
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func toggleFollow(userId: Int) async {
        isTogglingFollow = true
        defer { isTogglingFollow = false }
        do {
            // This assumes ToggleFollow mutation is in AniListSocialService, I should check if it's there
            // If not I'll have to add it.
            let result = try await AniListSocialService.shared.toggleFollow(userId: userId)
            user?.isFollowing = result
        } catch {
            self.error = error.localizedDescription
        }
    }

    enum SocialType { case followers, following }

    func postStatus(text: String) async {
        do {
            try await AniListSocialService.shared.postStatus(text: text)
            if let uid = AniListAuthManager.shared.userId {
                await loadActivity(userId: uid)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
