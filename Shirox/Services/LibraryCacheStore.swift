import Foundation

/// Disk persistence for each remote provider's fetched library list, keyed by (provider,
/// media-type). Lets the Library load instantly, work offline, and show the *selected*
/// provider's last-saved list when that provider is rate-limited — never the other provider's.
///
/// Only remote providers (.anilist / .mal) are stored here; the local source is persisted by
/// `LocalLibraryManager`. Mirrors that class's pattern (Codable store, atomic JSON write in
/// Application Support).
@MainActor
final class LibraryCacheStore {
    static let shared = LibraryCacheStore()

    struct Snapshot: Codable {
        var entries: [LibraryEntry]
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

    func snapshot(provider: ProviderType, mediaType: MediaKind) -> Snapshot? {
        snapshots[Self.key(provider, mediaType)]
    }

    func save(entries: [LibraryEntry], provider: ProviderType, mediaType: MediaKind) {
        snapshots[Self.key(provider, mediaType)] = Snapshot(entries: entries, syncedAt: Date())
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

    // MARK: - Keys

    private static func key(_ provider: ProviderType, _ mediaType: MediaKind) -> String {
        "\(provider.rawValue)-\(mediaType == .manga ? "manga" : "anime")"
    }

    // MARK: - Persistence

    private var fileURL: URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("library-cache.json")
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(Store(snapshots: snapshots))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            assertionFailure("LibraryCacheStore: encode/write failed — \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let store = try? JSONDecoder().decode(Store.self, from: data) else { return }
        snapshots = store.snapshots
    }
}
