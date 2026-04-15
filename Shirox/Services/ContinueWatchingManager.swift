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

    private init() {
        load()
        Task { await runLegacyDataMigration() }
    }

    // MARK: - Public API

    /// Upserts an item during active playback.
    /// At ≥ 90%: marks episode watched and queues the next one as a placeholder.
    /// Enforces the one-item-per-show invariant via removeAllShowItems.
    func save(_ item: ContinueWatchingItem) {
        var newItems = items
        removeAllShowItems(for: item, in: &newItems)

        let watchedThreshold: Double = {
            guard UserDefaults.standard.object(forKey: "watchedPercentage") != nil else { return 0.9 }
            return UserDefaults.standard.double(forKey: "watchedPercentage") / 100.0
        }()
        if item.totalSeconds > 0 && item.watchedSeconds / item.totalSeconds >= watchedThreshold {
            markWatched(item)
            if let placeholder = makePlaceholder(
                episodeNumber: item.episodeNumber + 1, from: item,
                aniListID: item.aniListID, moduleId: item.moduleId,
                mediaTitle: item.mediaTitle, imageUrl: nil,
                totalEpisodes: item.totalEpisodes,
                availableEpisodes: item.availableEpisodes,
                isAiring: item.isAiring,
                detailHref: item.detailHref
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

    /// Removes the watched key and any CW item for a single episode.
    func resetEpisodeProgress(aniListID: Int?, moduleId: String?, mediaTitle: String, episodeNumber: Int) {
        if let key = Self.watchedKey(aniListID: aniListID, moduleId: moduleId,
                                     mediaTitle: mediaTitle, episodeNumber: episodeNumber) {
            watchedKeys.remove(key)
        }
        items.removeAll {
            matchesShow($0, aniListID: aniListID, moduleId: moduleId, mediaTitle: mediaTitle)
            && $0.episodeNumber == episodeNumber
        }
        persist()
    }

    /// Removes all watched keys and CW items for a single show.
    func resetProgress(aniListID: Int?, moduleId: String?, mediaTitle: String) {
        if let aid = aniListID {
            watchedKeys = watchedKeys.filter { !$0.hasPrefix("a:\(aid):") }
        } else if let mid = moduleId, !mid.isEmpty {
            let prefix = "m:\(mid):\(mediaTitle):"
            watchedKeys = watchedKeys.filter { !$0.hasPrefix(prefix) }
        }
        var arr = items
        removeAllShowItems(aniListID: aniListID, moduleId: moduleId, mediaTitle: mediaTitle, in: &arr)
        items = arr
        persist()
    }

    /// Returns true if the show has any CW item or watched episode.
    func hasProgress(aniListID: Int?, moduleId: String?, mediaTitle: String) -> Bool {
        if items.contains(where: { matchesShow($0, aniListID: aniListID, moduleId: moduleId, mediaTitle: mediaTitle) }) {
            return true
        }
        if let aid = aniListID {
            return watchedKeys.contains(where: { $0.hasPrefix("a:\(aid):") })
        }
        if let mid = moduleId, !mid.isEmpty {
            return watchedKeys.contains(where: { $0.hasPrefix("m:\(mid):\(mediaTitle):") })
        }
        return false
    }

    /// Clears all watched history and Continue Watching cards.
    func resetAllData() {
        items = []
        watchedKeys = []
        UserDefaults.standard.removeObject(forKey: Keys.storage)
        UserDefaults.standard.removeObject(forKey: Keys.watched)
        UserDefaults.standard.set(Self.currentDataVersion, forKey: Keys.dataVersion)
    }

    /// Syncs local Continue Watching with AniList's "Watching" list.
    func syncWithAniList() async {
        guard let userId = await AniListAuthManager.shared.userId else { return }
        
        do {
            let library = try await AniListLibraryService.shared.fetchAllLists(userId: userId)
            let watching = library.filter { $0.status == .current }
            
            var newItems = items
            
            for entry in watching {
                let media = entry.media
                let nextEp = entry.progress + 1
                
                // Only add if we don't already have progress for this show
                let existing = newItems.first { matchesShow($0, aniListID: media.id, moduleId: nil, mediaTitle: "") }
                
                if existing == nil {
                    // Create a placeholder pointing to the next episode based on AniList progress
                    if let placeholder = makePlaceholder(
                        episodeNumber: nextEp,
                        from: nil,
                        aniListID: media.id,
                        moduleId: nil,
                        mediaTitle: media.title.displayTitle,
                        imageUrl: media.coverImage.best,
                        totalEpisodes: media.episodes,
                        detailHref: nil
                    ) {
                        newItems.append(placeholder)
                    }
                }
            }
            
            // Sort by date and keep unique
            items = Array(newItems.sorted { $0.lastWatchedAt > $1.lastWatchedAt }.prefix(maxItems))
            persist()
            
        } catch {
            print("[CW] Sync failed: \(error.localizedDescription)")
        }
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
                     imageUrl: String? = nil, totalEpisodes: Int? = nil, availableEpisodes: Int? = nil, detailHref: String? = nil) {
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
            imageUrl: imageUrl, totalEpisodes: totalEpisodes,
            availableEpisodes: availableEpisodes ?? current?.availableEpisodes,
            detailHref: detailHref
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
                       imageUrl: String? = nil, totalEpisodes: Int? = nil, availableEpisodes: Int? = nil, detailHref: String? = nil) {
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
            imageUrl: imageUrl, totalEpisodes: totalEpisodes,
            availableEpisodes: availableEpisodes ?? current.availableEpisodes,
            detailHref: detailHref
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
                     imageUrl: String? = nil, totalEpisodes: Int? = nil, availableEpisodes: Int? = nil, detailHref: String? = nil) {
        guard episodeNumber > 0 else { return }
        
        // 1. Mark episodes 1...episodeNumber as watched
        for ep in 1...episodeNumber {
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

        // 2. Queue up the NEXT episode (N + 1) as a placeholder, if it exists
        let nextEp = episodeNumber + 1
        if let placeholder = makePlaceholder(
            episodeNumber: nextEp, from: ref,
            aniListID: aniListID, moduleId: moduleId, mediaTitle: mediaTitle,
            imageUrl: imageUrl, totalEpisodes: totalEpisodes,
            availableEpisodes: availableEpisodes ?? ref?.availableEpisodes,
            detailHref: detailHref
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
    /// Returns nil when imageUrl is unavailable or episodeNumber exceeds availableEpisodes (or totalEpisodes).
    private func makePlaceholder(episodeNumber: Int,
                                  from source: ContinueWatchingItem?,
                                  aniListID: Int?, moduleId: String?, mediaTitle: String,
                                  imageUrl: String?, totalEpisodes: Int?,
                                  availableEpisodes: Int? = nil,
                                  isAiring: Bool? = nil,
                                  detailHref: String?) -> ContinueWatchingItem? {
        let srcImageUrl   = [source?.imageUrl, imageUrl].compactMap { $0 }.first(where: { !$0.isEmpty }) ?? ""
        let srcAniListID  = source?.aniListID     ?? aniListID
        let srcModuleId   = source?.moduleId      ?? moduleId
        let srcMediaTitle = source?.mediaTitle    ?? mediaTitle
        let srcDetailHref = source?.detailHref    ?? detailHref

        // Use the most restrictive total episodes count available
        var srcTotalEps = source?.totalEpisodes
        if let total = totalEpisodes {
            if srcTotalEps == nil || total < srcTotalEps! {
                srcTotalEps = total
            }
        }

        // availableEpisodes — how many are currently aired; may be < total for ongoing shows
        let srcAvailable = availableEpisodes ?? source?.availableEpisodes
        let srcIsAiring = isAiring ?? source?.isAiring

        guard !srcImageUrl.isEmpty else { return nil }

        // If we've passed the currently available (aired) episode count, do not create a placeholder.
        // This makes the CW card disappear when the user is caught up on an ongoing show.
        // ADJUSTMENT: We always allow the current episodeNumber if it's explicitly being requested,
        // to handle cases where the user is watching an episode that AniList metadata hasn't caught up with yet.
        var cap = srcAvailable ?? srcTotalEps
        if let currentCap = cap {
            cap = max(currentCap, episodeNumber)
        }
        
        if let cap, cap > 0, episodeNumber > cap {
            print("[CW] Caught up (ep \(episodeNumber) > available \(cap)), no placeholder created.")
            return nil
        }

        return ContinueWatchingItem(
            id: UUID(), mediaTitle: srcMediaTitle, episodeNumber: episodeNumber,
            episodeTitle: nil, imageUrl: srcImageUrl, streamUrl: "",
            headers: nil, subtitle: nil, streamTitle: nil, aniListID: srcAniListID,
            moduleId: srcModuleId, detailHref: srcDetailHref,
            watchedSeconds: 0, totalSeconds: 0, totalEpisodes: srcTotalEps,
            availableEpisodes: srcAvailable,
            isAiring: srcIsAiring,
            lastWatchedAt: .now
        )
    }

    // MARK: - New Episode Notification

    /// Call this from a detail view after loading episode data to handle ongoing shows.
    /// - If CW has a placeholder for this show whose target ep IS within `availableEpisodes`,
    ///   it refreshes the stored `availableEpisodes` count so the card displays correctly.
    /// - If no CW entry exists but the user has watched episodes and a new one is available
    ///   beyond their last-watched ep, it re-creates the "Up Next" placeholder.
    /// - If the user is on the last available episode, ensures no stale placeholder lingers.
    func notifyNewEpisodesAvailable(aniListID: Int?, moduleId: String?, mediaTitle: String,
                                     availableEpisodes: Int, imageUrl: String? = nil,
                                     totalEpisodes: Int? = nil, isAiring: Bool? = nil, detailHref: String? = nil) {
        guard availableEpisodes > 0 else { return }

        var arr = items
        let existing = arr.first(where: {
            matchesShow($0, aniListID: aniListID, moduleId: moduleId, mediaTitle: mediaTitle)
        })

        if let existing {
            // Case 1 & 2: Self-heal existing placeholders and real items so they always reflect the latest accurate availability
            arr.removeAll { matchesShow($0, aniListID: aniListID, moduleId: moduleId, mediaTitle: mediaTitle) }
            
            if existing.streamUrl.isEmpty {
                // If the updated cap reveals that the user is actually caught up, makePlaceholder will return nil
                // and the stale "Up Next" placeholder will be automatically deleted.
                if let updated = makePlaceholder(
                    episodeNumber: existing.episodeNumber, from: existing,
                    aniListID: aniListID, moduleId: moduleId, mediaTitle: mediaTitle,
                    imageUrl: imageUrl, totalEpisodes: totalEpisodes ?? existing.totalEpisodes,
                    availableEpisodes: availableEpisodes, isAiring: isAiring ?? existing.isAiring, detailHref: detailHref ?? existing.detailHref
                ) {
                    arr.insert(updated, at: 0)
                }
            } else {
                // Real in-progress item: forcefully override with the latest accurate counts
                var updated = existing
                updated.availableEpisodes = availableEpisodes
                updated.isAiring = isAiring ?? updated.isAiring
                if let newTotal = totalEpisodes { updated.totalEpisodes = newTotal }
                arr.insert(updated, at: 0)
            }
            items = arr
            persist()
            return
        }

        // Case 3: no CW entry — check if user has watched episodes and there's a new one waiting
        // Find the highest episode the user has watched for this show
        let highestWatched: Int = {
            if let aid = aniListID {
                let prefix = "a:\(aid):"
                return watchedKeys
                    .filter { $0.hasPrefix(prefix) }
                    .compactMap { Int($0.dropFirst(prefix.count)) }
                    .max() ?? 0
            } else if let mid = moduleId, !mid.isEmpty {
                let prefix = "m:\(mid):\(mediaTitle):"
                return watchedKeys
                    .filter { $0.hasPrefix(prefix) }
                    .compactMap { Int($0.dropFirst(prefix.count)) }
                    .max() ?? 0
            }
            return 0
        }()

        guard highestWatched > 0 else { return }  // user hasn't watched anything yet
        let nextEp = highestWatched + 1
        guard nextEp <= availableEpisodes else { return }  // still caught up

        // New episode is available beyond what the user has watched — recreate "Up Next" card
        print("[CW] New episode available: Up Next ep \(nextEp) (available: \(availableEpisodes))")
        if let placeholder = makePlaceholder(
            episodeNumber: nextEp, from: nil,
            aniListID: aniListID, moduleId: moduleId, mediaTitle: mediaTitle,
            imageUrl: imageUrl, totalEpisodes: totalEpisodes,
            availableEpisodes: availableEpisodes, isAiring: isAiring, detailHref: detailHref
        ) {
            arr.insert(placeholder, at: 0)
            if arr.count > maxItems { arr = Array(arr.prefix(maxItems)) }
            items = arr
            persist()
        }
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

    // MARK: - Migrations

    private func runLegacyDataMigration() async {
        let legacyItems = items.filter { $0.isAiring == nil }
        guard !legacyItems.isEmpty else { return }

        for item in legacyItems {
            guard let mediaId = item.aniListID, let media = try? await AniListService.shared.detail(id: mediaId) else { continue }
            
            let avail = media.nextAiringEpisode != nil ? (media.nextAiringEpisode!.episode - 1) : 0
            if avail > 0 {
                await MainActor.run {
                    self.notifyNewEpisodesAvailable(
                        aniListID: mediaId, moduleId: item.moduleId, mediaTitle: item.mediaTitle,
                        availableEpisodes: avail, imageUrl: item.imageUrl, totalEpisodes: media.episodes,
                        isAiring: media.status == "RELEASING", detailHref: item.detailHref
                    )
                }
            } else {
                await MainActor.run {
                    var arr = self.items
                    if let idx = arr.firstIndex(where: { $0.id == item.id }) {
                        arr[idx].isAiring = false
                        arr[idx].totalEpisodes = media.episodes ?? arr[idx].totalEpisodes
                        self.items = arr
                        self.persist()
                    }
                }
            }
        }
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
