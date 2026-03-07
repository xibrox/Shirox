import Foundation

@MainActor final class ContinueWatchingManager: ObservableObject {
    static let shared = ContinueWatchingManager()

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let storage = "continueWatchingItems"
    }

    // MARK: - Published Properties

    @Published private(set) var items: [ContinueWatchingItem] = []

    // MARK: - Private Properties

    private let maxItems = 20

    // MARK: - Init

    private init() { load() }

    // MARK: - Public API

    /// Upserts an item by (streamUrl + episodeNumber).
    /// Auto-removes (does not save) if watchedSeconds / totalSeconds >= 0.9.
    func save(_ item: ContinueWatchingItem) {
        // Step 1: Remove any existing item with the same streamUrl + episodeNumber
        items.removeAll {
            $0.streamUrl == item.streamUrl && $0.episodeNumber == item.episodeNumber
        }

        // Step 2: Skip saving if the episode is effectively done (>= 90% watched)
        if item.totalSeconds > 0 && item.watchedSeconds / item.totalSeconds >= 0.9 {
            persist()
            return
        }

        // Step 3: Prepend the new item (most recent first)
        items.insert(item, at: 0)

        // Step 4: Trim to maxItems, removing oldest (tail) entries
        if items.count > maxItems {
            items = Array(items.prefix(maxItems))
        }

        // Step 5: Persist
        persist()
    }

    /// Removes an item by its id.
    func remove(_ item: ContinueWatchingItem) {
        items.removeAll { $0.id == item.id }
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        do {
            let data = try JSONEncoder().encode(items)
            UserDefaults.standard.set(data, forKey: Keys.storage)
        } catch {
            assertionFailure("ContinueWatchingManager: encode failed — \(error)")
        }
    }

    private func load() {
        guard
            let data = UserDefaults.standard.data(forKey: Keys.storage),
            let decoded = try? JSONDecoder().decode([ContinueWatchingItem].self, from: data)
        else {
            items = []
            return
        }
        items = decoded.sorted { $0.lastWatchedAt > $1.lastWatchedAt }
    }
}
