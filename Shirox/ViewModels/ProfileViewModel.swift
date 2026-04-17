import Foundation

@MainActor
final class ProfileViewModel: ObservableObject {
    @Published var user: AniListUser?
    @Published var activity: [AniListActivity] = []
    @Published var notifications: [AniListNotification] = []
    @Published var followers: [AniListUser] = []
    @Published var following: [AniListUser] = []

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

    func loadActivity(userId: Int, feed: ActivityFeed? = nil) async {
        if let feed { activityFeed = feed }
        isLoadingActivity = true
        defer { isLoadingActivity = false }
        do {
            activity = try await AniListSocialService.shared.fetchActivity(
                feed: activityFeed, userId: userId)
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

    func loadSocial(userId: Int) async {
        isLoadingSocial = true
        defer { isLoadingSocial = false }
        do {
            async let f = AniListSocialService.shared.fetchFollowers(userId: userId)
            async let fw = AniListSocialService.shared.fetchFollowing(userId: userId)
            (followers, following) = try await (f, fw)
        } catch {
            self.error = error.localizedDescription
        }
    }

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
