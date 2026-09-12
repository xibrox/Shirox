import Foundation

/// Disk persistence for the last successfully-fetched `HomeFeed`, keyed by provider.
///
/// Home had no cache at all: every cold start was a blank spinner until the network answered,
/// and a provider switch showed the *previous* provider's rows until the new ones arrived — or
/// indefinitely, if that request then failed. The Library has had a cache-then-refresh story
/// for a while (`LibraryCacheStore`); this is the same idea for Home, and mirrors that class's
/// pattern: Codable store, atomic JSON write in Application Support.
@MainActor
final class HomeCacheStore {
    static let shared = HomeCacheStore()

    struct Snapshot: Codable {
        var feed: HomeFeed
        var syncedAt: Date
    }

    private struct Store: Codable {
        var snapshots: [String: Snapshot]
    }

    private let directory: URL
    private var snapshots: [String: Snapshot] = [:]

    /// `directory` is injectable so tests use a throwaway temp dir instead of the shared
    /// Application Support store. App code always uses `.shared`.
    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) {
        self.directory = directory
        load()
    }

    // MARK: - API

    func snapshot(provider: ProviderType) -> Snapshot? {
        snapshots[provider.rawValue]
    }

    func save(feed: HomeFeed, provider: ProviderType) {
        snapshots[provider.rawValue] = Snapshot(feed: feed, syncedAt: Date())
        persist()
    }

    func clearAll() {
        snapshots = [:]
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// On-disk size in bytes (0 if the file is absent) — for CacheManager's storage view.
    func diskByteSize() -> Int {
        (try? Data(contentsOf: fileURL).count) ?? 0
    }

    // MARK: - Persistence

    private var fileURL: URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("home-cache.json")
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(Store(snapshots: snapshots))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            assertionFailure("HomeCacheStore: encode/write failed — \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let store = try? JSONDecoder().decode(Store.self, from: data) else { return }
        snapshots = store.snapshots
    }
}
