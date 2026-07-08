import Foundation

/// Disk persistence for each viewed profile, keyed by (provider, userId). Lets a profile
/// paint instantly from the last-known-good copy and survive a rate-limited refresh (429/403)
/// instead of showing a blank header. Mirrors `LibraryCacheStore` (Codable store, atomic JSON
/// write in Application Support).
///
/// Only the FIRST page of activity/followers/following is persisted — enough to avoid a blank
/// tab; "load more" always re-fetches fresh.
@MainActor
final class ProfileCacheStore {
    static let shared = ProfileCacheStore()

    struct Snapshot: Codable {
        var profile: UserProfile?
        var activity: [UserActivity]
        var followers: [UserProfile]
        var following: [UserProfile]
        var syncedAt: Date

        static let empty = Snapshot(profile: nil, activity: [], followers: [], following: [], syncedAt: .distantPast)
    }

    private struct Store: Codable {
        var snapshots: [String: Snapshot]
    }

    /// Keep only the most-recently-synced profiles so the file stays small.
    private let maxKeys = 20

    private let directory: URL
    private var snapshots: [String: Snapshot] = [:]

    /// `directory` is injectable so tests use a throwaway temp dir. App code always uses `.shared`.
    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) {
        self.directory = directory
        load()
    }

    // MARK: - API

    func snapshot(provider: ProviderType, userId: Int) -> Snapshot? {
        snapshots[Self.key(provider, userId)]
    }

    func saveProfile(_ profile: UserProfile, provider: ProviderType, userId: Int) {
        mutate(provider, userId) { $0.profile = profile }
    }

    func saveActivity(_ activity: [UserActivity], provider: ProviderType, userId: Int) {
        mutate(provider, userId) { $0.activity = activity }
    }

    func saveFollowers(_ followers: [UserProfile], provider: ProviderType, userId: Int) {
        mutate(provider, userId) { $0.followers = followers }
    }

    func saveFollowing(_ following: [UserProfile], provider: ProviderType, userId: Int) {
        mutate(provider, userId) { $0.following = following }
    }

    func clearAll() {
        snapshots = [:]
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// On-disk size in bytes (0 if the file is absent) — for CacheManager's storage view.
    func diskByteSize() -> Int {
        (try? Data(contentsOf: fileURL).count) ?? 0
    }

    // MARK: - Mutation

    private func mutate(_ provider: ProviderType, _ userId: Int, _ change: (inout Snapshot) -> Void) {
        let k = Self.key(provider, userId)
        var snap = snapshots[k] ?? .empty
        change(&snap)
        snap.syncedAt = Date()
        snapshots[k] = snap
        evictIfNeeded()
        persist()
    }

    private func evictIfNeeded() {
        guard snapshots.count > maxKeys else { return }
        let staleFirst = snapshots.sorted { $0.value.syncedAt < $1.value.syncedAt }
        for (key, _) in staleFirst.prefix(snapshots.count - maxKeys) {
            snapshots.removeValue(forKey: key)
        }
    }

    // MARK: - Keys

    private static func key(_ provider: ProviderType, _ userId: Int) -> String {
        "\(provider.rawValue)-\(userId)"
    }

    // MARK: - Persistence

    private var fileURL: URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("profile-cache.json")
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(Store(snapshots: snapshots))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            assertionFailure("ProfileCacheStore: encode/write failed — \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let store = try? JSONDecoder().decode(Store.self, from: data) else { return }
        snapshots = store.snapshots
    }
}
