import Foundation

@MainActor final class ContinueWatchingManager: ObservableObject {
    static let shared = ContinueWatchingManager()

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let storage = "continueWatchingItems"
        static let watched = "watchedEpisodeKeys"
        static let dataVersion = "cwDataVersion"
    }

    // MARK: - Published Properties

    @Published private(set) var items: [ContinueWatchingItem] = []
    @Published private(set) var watchedKeys: Set<String> = []

    // MARK: - Private Properties

    private let maxItems = 20
    private static let currentDataVersion = 2

    // MARK: - Init

    private init() { load() }

    // MARK: - Public API

    /// Upserts an item during active playback.
    /// At ≥ 90%: marks episode watched and queues the next one as a placeholder.
    /// Enforces the one-item-per-show invariant via removeAllShowItems.
    func save(_ item: ContinueWatchingItem) {
        var newItems = items
        removeAllShowItems(for: item, in: &newItems)

        if item.totalSeconds > 0 && item.watchedSeconds / item.totalSeconds >= 0.9 {
            markWatched(item)
            if let placeholder = makePlaceholder(
                episodeNumber: item.episodeNumber + 1, from: item,
                aniListID: item.aniListID, moduleId: item.moduleId,
                mediaTitle: item.mediaTitle, imageUrl: nil,
                totalEpisodes: item.totalEpisodes, detailHref: item.detailHref
            ) {
                newItems.insert(placeholder, at: 0)
                if newItems.count > maxItems { newItems = Array(newItems.prefix(maxItems)) }
            }
            items = newItems
            persist()
            return
        }

        newItems.insert(item, at: 0)
        if newItems.count > maxItems { newItems = Array(newItems.prefix(maxItems)) }
        items = newItems
        persist()
    }

    /// Removes an item by its id.
    func remove(_ item: ContinueWatchingItem) {
        items.removeAll { $0.id == item.id }
        persist()
    }

    /// Clears all watched history and Continue Watching cards.
    func resetAllData() {
        items = []
        watchedKeys = []
        UserDefaults.standard.removeObject(forKey: Keys.storage)
        UserDefaults.standard.removeObject(forKey: Keys.watched)
        UserDefaults.standard.set(Self.currentDataVersion, forKey: Keys.dataVersion)
    }

    /// Returns true if the episode has been watched to completion.
    func isWatched(aniListID: Int?, moduleId: String?, mediaTitle: String, episodeNumber: Int) -> Bool {
        guard let key = Self.watchedKey(aniListID: aniListID, moduleId: moduleId,
                                        mediaTitle: mediaTitle, episodeNumber: episodeNumber)
        else { return false }
        return watchedKeys.contains(key)
    }

    /// Marks a single episode as watched.
    /// Advances CW to "Up Next N+1" unless CW is already past ep N.
    func markWatched(aniListID: Int?, moduleId: String?, mediaTitle: String, episodeNumber: Int,
                     imageUrl: String? = nil, totalEpisodes: Int? = nil, detailHref: String? = nil) {
        guard let key = Self.watchedKey(aniListID: aniListID, moduleId: moduleId,
                                        mediaTitle: mediaTitle, episodeNumber: episodeNumber)
        else { return }
        watchedKeys.insert(key)

        var arr = items
        let current = arr.first(where: {
            matchesShow($0, aniListID: aniListID, moduleId: moduleId, mediaTitle: mediaTitle)
        })

        // Leave CW alone if it's a real in-progress item, or a placeholder already past this episode
        if let current, !current.streamUrl.isEmpty || current.episodeNumber > episodeNumber {
            persist(); return
        }

        removeAllShowItems(aniListID: aniListID, moduleId: moduleId, mediaTitle: mediaTitle, in: &arr)

        if let placeholder = makePlaceholder(
            episodeNumber: episodeNumber + 1, from: current,
            aniListID: aniListID, moduleId: moduleId, mediaTitle: mediaTitle,
            imageUrl: imageUrl, totalEpisodes: totalEpisodes, detailHref: detailHref
        ) {
            arr.insert(placeholder, at: 0)
            if arr.count > maxItems { arr = Array(arr.prefix(maxItems)) }
        }
        items = arr
        persist()
    }

    /// Marks a single episode as unwatched.
    /// If CW has a real in-progress item (any ep), leaves it alone.
    /// Otherwise replaces CW with "Up Next N" so the card points to this episode.
    func markUnwatched(aniListID: Int?, moduleId: String?, mediaTitle: String, episodeNumber: Int,
                       imageUrl: String? = nil, totalEpisodes: Int? = nil, detailHref: String? = nil) {
        guard let key = Self.watchedKey(aniListID: aniListID, moduleId: moduleId,
                                        mediaTitle: mediaTitle, episodeNumber: episodeNumber)
        else { return }
        watchedKeys.remove(key)

        var arr = items
        let current = arr.first(where: {
            matchesShow($0, aniListID: aniListID, moduleId: moduleId, mediaTitle: mediaTitle)
        })

        // Only update CW when it points to exactly ep N+1 (the placeholder created by marking ep N).
        // Leave CW alone for real in-progress items, higher-ep placeholders, lower-ep placeholders,
        // and absent items — unmarking shouldn't create unexpected CW entries.
        guard let current, current.streamUrl.isEmpty, current.episodeNumber == episodeNumber + 1 else {
            persist(); return
        }

        removeAllShowItems(aniListID: aniListID, moduleId: moduleId, mediaTitle: mediaTitle, in: &arr)

        if let placeholder = makePlaceholder(
            episodeNumber: episodeNumber, from: current,
            aniListID: aniListID, moduleId: moduleId, mediaTitle: mediaTitle,
            imageUrl: imageUrl, totalEpisodes: totalEpisodes, detailHref: detailHref
        ) {
            arr.insert(placeholder, at: 0)
            if arr.count > maxItems { arr = Array(arr.prefix(maxItems)) }
        }
        items = arr
        persist()
    }

    /// Marks eps 1..<episodeNumber as watched and creates "Up Next N" in CW.
    /// If ep N has real in-progress data it is preserved; otherwise a placeholder is created.
    func markWatched(upThrough episodeNumber: Int,
                     aniListID: Int?, moduleId: String?, mediaTitle: String,
                     imageUrl: String? = nil, totalEpisodes: Int? = nil, detailHref: String? = nil) {
        guard episodeNumber > 1 else { return }
        for ep in 1..<episodeNumber {
            if let key = Self.watchedKey(aniListID: aniListID, moduleId: moduleId,
                                         mediaTitle: mediaTitle, episodeNumber: ep) {
                watchedKeys.insert(key)
            }
        }
        var arr = items
        let ref = arr.first(where: {
            matchesShow($0, aniListID: aniListID, moduleId: moduleId, mediaTitle: mediaTitle)
        })
        removeAllShowItems(aniListID: aniListID, moduleId: moduleId, mediaTitle: mediaTitle, in: &arr)

        // Preserve a real in-progress item at exactly ep N
        if let ref, !ref.streamUrl.isEmpty, ref.episodeNumber == episodeNumber {
            arr.insert(ref, at: 0)
            if arr.count > maxItems { arr = Array(arr.prefix(maxItems)) }
        } else if let placeholder = makePlaceholder(
            episodeNumber: episodeNumber, from: ref,
            aniListID: aniListID, moduleId: moduleId, mediaTitle: mediaTitle,
            imageUrl: imageUrl, totalEpisodes: totalEpisodes, detailHref: detailHref
        ) {
            arr.insert(placeholder, at: 0)
            if arr.count > maxItems { arr = Array(arr.prefix(maxItems)) }
        }
        items = arr
        persist()
    }

    /// Marks eps 1..<episodeNumber as unwatched and removes all show CW items.
    /// CW card disappears — the detail button shows "Start Watching".
    func markUnwatched(upThrough episodeNumber: Int,
                       aniListID: Int?, moduleId: String?, mediaTitle: String) {
        guard episodeNumber > 1 else { return }
        for ep in 1..<episodeNumber {
            if let key = Self.watchedKey(aniListID: aniListID, moduleId: moduleId,
                                         mediaTitle: mediaTitle, episodeNumber: ep) {
                watchedKeys.remove(key)
            }
        }
        var arr = items
        removeAllShowItems(aniListID: aniListID, moduleId: moduleId, mediaTitle: mediaTitle, in: &arr)
        items = arr
        persist()
    }

    // MARK: - Private Helpers

    private func matchesShow(_ item: ContinueWatchingItem,
                              aniListID: Int?, moduleId: String?, mediaTitle: String) -> Bool {
        if let aid = aniListID { return item.aniListID == aid }
        if let mid = moduleId { return item.moduleId == mid && item.mediaTitle == mediaTitle }
        return false
    }

    /// Removes every item for the given show from `arr`.
    private func removeAllShowItems(aniListID: Int?, moduleId: String?, mediaTitle: String,
                                     in arr: inout [ContinueWatchingItem]) {
        arr.removeAll { matchesShow($0, aniListID: aniListID, moduleId: moduleId, mediaTitle: mediaTitle) }
    }

    /// Convenience overload — derives show identifiers from an existing item.
    private func removeAllShowItems(for item: ContinueWatchingItem,
                                     in arr: inout [ContinueWatchingItem]) {
        removeAllShowItems(aniListID: item.aniListID, moduleId: item.moduleId,
                           mediaTitle: item.mediaTitle, in: &arr)
    }

    /// Builds a placeholder (streamUrl: "") for `episodeNumber`.
    /// Fields from `source` take priority over the individual fallback params.
    /// Returns nil when imageUrl is unavailable or episodeNumber exceeds totalEpisodes.
    private func makePlaceholder(episodeNumber: Int,
                                  from source: ContinueWatchingItem?,
                                  aniListID: Int?, moduleId: String?, mediaTitle: String,
                                  imageUrl: String?, totalEpisodes: Int?,
                                  detailHref: String?) -> ContinueWatchingItem? {
        let srcImageUrl   = [source?.imageUrl, imageUrl].compactMap { $0 }.first(where: { !$0.isEmpty }) ?? ""
        let srcAniListID  = source?.aniListID     ?? aniListID
        let srcModuleId   = source?.moduleId      ?? moduleId
        let srcMediaTitle = source?.mediaTitle    ?? mediaTitle
        let srcDetailHref = source?.detailHref    ?? detailHref
        let srcTotalEps   = source?.totalEpisodes ?? totalEpisodes
        guard !srcImageUrl.isEmpty else { return nil }
        if let total = srcTotalEps, episodeNumber > total { return nil }
        return ContinueWatchingItem(
            id: UUID(), mediaTitle: srcMediaTitle, episodeNumber: episodeNumber,
            episodeTitle: nil, imageUrl: srcImageUrl, streamUrl: "",
            headers: nil, subtitle: nil, aniListID: srcAniListID,
            moduleId: srcModuleId, detailHref: srcDetailHref,
            watchedSeconds: 0, totalSeconds: 0, totalEpisodes: srcTotalEps,
            lastWatchedAt: .now
        )
    }

    /// Private overload used by save() — marks an item's episode as watched in watchedKeys.
    private func markWatched(_ item: ContinueWatchingItem) {
        if let key = Self.watchedKey(aniListID: item.aniListID, moduleId: item.moduleId,
                                     mediaTitle: item.mediaTitle, episodeNumber: item.episodeNumber) {
            watchedKeys.insert(key)
        }
    }

    private static func watchedKey(aniListID: Int?, moduleId: String?,
                                    mediaTitle: String, episodeNumber: Int) -> String? {
        if let aid = aniListID { return "a:\(aid):\(episodeNumber)" }
        if let mid = moduleId, !mid.isEmpty { return "m:\(mid):\(mediaTitle):\(episodeNumber)" }
        return nil
    }

    // MARK: - Persistence

    private func persist() {
        do {
            let data = try JSONEncoder().encode(items)
            UserDefaults.standard.set(data, forKey: Keys.storage)
            let watchedData = try JSONEncoder().encode(watchedKeys)
            UserDefaults.standard.set(watchedData, forKey: Keys.watched)
        } catch {
            assertionFailure("ContinueWatchingManager: encode failed — \(error)")
        }
    }

    private func load() {
        let storedVersion = UserDefaults.standard.integer(forKey: Keys.dataVersion)
        if storedVersion != Self.currentDataVersion {
            UserDefaults.standard.removeObject(forKey: Keys.storage)
            UserDefaults.standard.removeObject(forKey: Keys.watched)
            UserDefaults.standard.set(Self.currentDataVersion, forKey: Keys.dataVersion)
            return
        }
        if let data = UserDefaults.standard.data(forKey: Keys.storage),
           let decoded = try? JSONDecoder().decode([ContinueWatchingItem].self, from: data) {
            items = decoded.sorted { $0.lastWatchedAt > $1.lastWatchedAt }
        }
        if let wdata = UserDefaults.standard.data(forKey: Keys.watched),
           let wdecoded = try? JSONDecoder().decode(Set<String>.self, from: wdata) {
            watchedKeys = wdecoded
        }
    }
}
