import Foundation
import Combine

@MainActor
final class ProfileViewModel: ObservableObject {
    @Published var user: UserProfile?
    @Published var activity: [UserActivity] = []
    @Published var hasNextActivityPage = false
    private var currentActivityPage = 1

    @Published var notifications: [ProviderNotification] = []
    private var allNotifications: [ProviderNotification] = []
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

    /// Showing a saved (stale) copy because a refresh was rate-limited.
    @Published var usingCachedData = false
    /// No cache exists and every retry failed — drives the tap-to-retry state.
    @Published var profileLoadFailed = false

    static let maxProfileRetries = 2

    /// Retry any failure except a genuine offline / cancelled one — the profile query surfaces
    /// rate-limits as a decode failure (the social service ignores the HTTP status), so we can't
    /// classify on error type alone.
    static func shouldRetryFetch(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        return !ProviderManager.isOfflineError(error)
    }

    /// Exponential backoff capped at 8s: 2s, 4s, 8s…
    static func retryDelay(forAttempt attempt: Int) -> TimeInterval {
        min(pow(2, Double(attempt + 1)), 8)
    }

    /// The provider whose cache this profile belongs to — mirrors ProfileView.activeProviderType.
    private var activeProvider: ProviderType {
        let pm = ProviderManager.shared
        return pm.fallbackActive
            ? (pm.fallback?.providerType ?? .anilist)
            : (pm.primary?.providerType ?? .anilist)
    }

    func loadProfile(userId: Int) async {
        let key = activeProvider

        // Cache-first: paint the last-known-good copy instantly so we never start blank.
        if user == nil, let snap = ProfileCacheStore.shared.snapshot(provider: key, userId: userId) {
            user = snap.profile
            if activity.isEmpty { activity = snap.activity }
            if followers.isEmpty { followers = snap.followers }
            if following.isEmpty { following = snap.following }
        }

        isLoadingProfile = true
        profileLoadFailed = false
        defer { isLoadingProfile = false }

        var attempt = 0
        while true {
            do {
                let fetched = try await ProviderManager.shared.call { try await $0.fetchProfile(userId: userId) }
                user = fetched
                usingCachedData = false
                profileLoadFailed = false
                ProfileCacheStore.shared.saveProfile(fetched, provider: key, userId: userId)
                return
            } catch {
                self.error = error.localizedDescription
                if user != nil {
                    // We have something to show — keep it, flag it stale, stop hammering the API.
                    usingCachedData = true
                    return
                }
                if attempt < Self.maxProfileRetries, Self.shouldRetryFetch(error) {
                    try? await Task.sleep(nanoseconds: UInt64(Self.retryDelay(forAttempt: attempt) * 1_000_000_000))
                    attempt += 1
                    continue
                }
                profileLoadFailed = true
                return
            }
        }
    }

    func loadActivity(userId: Int, feed: ActivityFeed? = nil, loadMore: Bool = false) async {
        if let feed {
            if activityFeed != feed { activity = []; currentActivityPage = 1 }
            activityFeed = feed
        }
        // Cache-first hydrate on the initial page when nothing is loaded yet.
        if !loadMore, activity.isEmpty,
           let snap = ProfileCacheStore.shared.snapshot(provider: activeProvider, userId: userId),
           !snap.activity.isEmpty {
            activity = snap.activity
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
            if !loadMore {
                ProfileCacheStore.shared.saveActivity(activity, provider: activeProvider, userId: userId)
            }
        } catch {
            self.error = error.localizedDescription
            if !activity.isEmpty { usingCachedData = true }
        }
    }

    func loadNotifications(filter: AniListNotificationFilter? = nil) async {
        let filterOnly = filter != nil && !allNotifications.isEmpty
        if let filter { notificationFilter = filter }
        if filterOnly {
            notifications = applyNotificationFilter(allNotifications)
            return
        }
        isLoadingNotifications = true
        defer { isLoadingNotifications = false }
        do {
            allNotifications = try await ProviderManager.shared.call { try await $0.fetchNotifications() }
            notifications = applyNotificationFilter(allNotifications)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func applyNotificationFilter(_ all: [ProviderNotification]) -> [ProviderNotification] {
        switch notificationFilter {
        case .all: return all
        case .airing: return all.filter { if case .airing = $0.kind { return true }; return false }
        case .follows: return all.filter { if case .following = $0.kind { return true }; return false }
        case .activity: return all.filter {
            switch $0.kind {
            case .activityMessage, .activityReply, .activityMention, .activityLike: return true
            default: return false
            }
        }
        case .media: return all.filter { if case .mediaChange = $0.kind { return true }; return false }
        }
    }

    func loadSocial(userId: Int, type: SocialType, loadMore: Bool = false) async {
        isLoadingSocial = true
        defer { isLoadingSocial = false }
        // Cache-first hydrate on the initial page when the list is empty.
        if !loadMore {
            if type == .followers, followers.isEmpty,
               let snap = ProfileCacheStore.shared.snapshot(provider: activeProvider, userId: userId),
               !snap.followers.isEmpty {
                followers = snap.followers
            } else if type == .following, following.isEmpty,
               let snap = ProfileCacheStore.shared.snapshot(provider: activeProvider, userId: userId),
               !snap.following.isEmpty {
                following = snap.following
            }
        }
        let page = loadMore ? (type == .followers ? currentFollowersPage + 1 : currentFollowingPage + 1) : 1
        do {
            if type == .followers {
                let result = try await ProviderManager.shared.call {
                    try await $0.fetchFollowers(userId: userId, page: page)
                }
                if loadMore { followers.append(contentsOf: result) } else { followers = result }
                currentFollowersPage = page
                hasNextFollowersPage = !result.isEmpty
                if !loadMore {
                    ProfileCacheStore.shared.saveFollowers(followers, provider: activeProvider, userId: userId)
                }
            } else {
                let result = try await ProviderManager.shared.call {
                    try await $0.fetchFollowing(userId: userId, page: page)
                }
                if loadMore { following.append(contentsOf: result) } else { following = result }
                currentFollowingPage = page
                hasNextFollowingPage = !result.isEmpty
                if !loadMore {
                    ProfileCacheStore.shared.saveFollowing(following, provider: activeProvider, userId: userId)
                }
            }
        } catch {
            self.error = error.localizedDescription
            if !(type == .followers ? followers : following).isEmpty { usingCachedData = true }
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
            let uid = AniListAuthManager.shared.userId ?? MALAuthManager.shared.userId
            if let uid {
                await loadActivity(userId: uid)
            }
        } catch ProviderError.unsupported {
            self.error = "Posting status is not supported by the current provider."
        } catch {
            self.error = error.localizedDescription
        }
    }
}
