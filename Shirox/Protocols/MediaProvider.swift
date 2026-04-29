import Foundation

// MARK: - Errors

enum ProviderError: Error, LocalizedError {
    case unauthenticated
    case notFound
    case serverError(Int)
    case networkError(Error)
    case unsupported
    case decodingError(Error)

    var isFallbackEligible: Bool {
        switch self {
        case .networkError, .serverError: return true
        default: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .unauthenticated: return "Not logged in."
        case .notFound: return "Content not found."
        case .serverError(let code): return "Server error (\(code))."
        case .networkError(let e): return e.localizedDescription
        case .unsupported: return "This feature is not supported by the current provider."
        case .decodingError(let e): return "Data error: \(e.localizedDescription)"
        }
    }
}

// MARK: - Supporting enums

enum LikeableType: String {
    case activity = "ACTIVITY"
    case activityReply = "ACTIVITY_REPLY"
}

enum ActivityFeed: String, CaseIterable, Identifiable {
    case mine, following, global
    var id: String { rawValue }
    var label: String {
        switch self {
        case .mine: return "My Feed"
        case .following: return "Following"
        case .global: return "Global"
        }
    }
    var icon: String {
        switch self {
        case .mine: return "person.circle"
        case .following: return "person.2.circle"
        case .global: return "globe"
        }
    }
}

// MARK: - Protocol

@MainActor
protocol MediaProvider: AnyObject {
    var providerType: ProviderType { get }
    var displayName: String { get }
    var isAuthenticated: Bool { get }

    // Auth
    func login(presentationAnchor: AnyObject) async throws
    func logout()

    // Discovery
    func trending() async throws -> [Media]
    func seasonal() async throws -> [Media]
    func popular() async throws -> [Media]
    func topRated() async throws -> [Media]
    func search(_ query: String) async throws -> [Media]
    func detail(id: Int) async throws -> Media

    // Library
    func fetchLibrary() async throws -> [LibraryEntry]
    func fetchEntry(mediaId: Int) async throws -> LibraryEntry?
    func updateEntry(mediaId: Int, status: MediaListStatus, progress: Int, score: Double) async throws

    // Profile
    func fetchCurrentUser() async throws -> UserProfile
    func fetchProfile(userId: Int) async throws -> UserProfile

    // Social
    func fetchActivity(filter: ActivityFeed, userId: Int, page: Int) async throws -> [UserActivity]
    func fetchNotifications() async throws -> [ProviderNotification]
    func postStatus(_ text: String) async throws
    func toggleLike(id: Int, type: LikeableType) async throws -> Bool
    func toggleFollow(userId: Int) async throws -> Bool
    func postReply(activityId: Int, text: String) async throws
    func deleteActivity(id: Int) async throws
    func fetchFollowers(userId: Int, page: Int) async throws -> [UserProfile]
    func fetchFollowing(userId: Int, page: Int) async throws -> [UserProfile]
}
