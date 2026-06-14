import Foundation
import Combine

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
        Logger.shared.log("[CW] save called: ep=\(item.episodeNumber) streamUrl=\(item.streamUrl.isEmpty ? "placeholder" : "inprog") watched=\(item.watchedSeconds)/\(item.totalSeconds) title=\(item.mediaTitle)", type: "Debug")
        var newItems = items
        removeAllShowItems(for: item, in: &newItems)

        let watchedThreshold: Double = {
            guard UserDefaults.standard.object(forKey: "watchedPercentage") != nil else { return 0.9 }
            return UserDefaults.standard.double(forKey: "watchedPercentage") / 100.0
        }()
        if item.totalSeconds > 0 && item.watchedSeconds / item.totalSeconds >= watchedThreshold {
            markWatched(item)
            let nextEp = item.episodeNumber + 1
            Logger.shared.log("[CW] save threshold crossed: ep=\(item.episodeNumber) isAiring=\(String(describing: item.isAiring)) totalEps=\(String(describing: item.totalEpisodes)) availableEps=\(String(describing: item.availableEpisodes)) title=\(item.mediaTitle)", type: "Debug")
            // Block "Up Next" if we've confirmed there's no next episode to load.
            // Priority: AniList confirmed total → module available count → assume more exist.
            // availableEpisodes covers ongoing shows at their current last episode and
            // completed shows that lack AniList isAiring/totalEpisodes metadata.
            let isLastEpisode: Bool
            if item.isAiring == false, let cap = item.totalEpisodes {
                isLastEpisode = item.episodeNumber >= cap
            } else if let avail = item.availableEpisodes {
                isLastEpisode = item.episodeNumber >= avail
            } else {
                isLastEpisode = false
            }
            Logger.shared.log("[CW] isLastEpisode=\(isLastEpisode)", type: "Debug")
            let placeholder = makePlaceholder(
                episodeNumber: nextEp, from: item,
                aniListID: item.aniListID, moduleId: item.moduleId,
                mediaTitle: item.mediaTitle, imageUrl: nil,
                totalEpisodes: item.totalEpisodes,
                availableEpisodes: item.availableEpisodes,
                isAiring: item.isAiring,
                detailHref: item.detailHref
            )
            Logger.shared.log("[CW] placeholder for ep\(nextEp): \(placeholder == nil ? "nil (not created)" : "created")", type: "Debug")
            if !isLastEpisode, let placeholder {
                newItems.insert(placeholder, at: 0)
                if newItems.count > maxItems { newItems = Array(newItems.prefix(maxItems)) }
            }
            items = newItems
            persist()
            Logger.shared.log("[CW] save done: items=\(items.map { "\($0.episodeNumber)\($0.streamUrl.isEmpty ? "P" : "I")" }.joined(separator: ",")) title=\(item.mediaTitle)", type: "Debug")
            return
        }

        Logger.shared.log("[CW] save inprog: ep=\(item.episodeNumber) watched=\(item.watchedSeconds)/\(item.totalSeconds) title=\(item.mediaTitle)", type: "Debug")
        newItems.insert(item, at: 0)
        if newItems.count > maxItems { newItems = Array(newItems.prefix(maxItems)) }
        items = newItems
        persist()
        Logger.shared.log("[CW] save done: items=\(items.map { "\($0.episodeNumber)\($0.streamUrl.isEmpty ? "P" : "I")" }.joined(separator: ",")) title=\(item.mediaTitle)", type: "Debug")
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
        guard let userId = AniListAuthManager.shared.userId else { return }
        
        do {
            let library = try await AniListLibraryService.shared.fetchAllLists(userId: userId)
            let watching = library.filter { $0.status == .current || $0.status == .repeating }
            
            var newItems = items
            
            for entry in watching {
                let media = entry.media
                let nextEp = entry.progress + 1

                // availableEpisodes = how many have aired (nextAiringEpisode.episode - 1 for airing shows)
                let availableEpisodes: Int? = media.nextAiringEpisode != nil
                    ? (media.nextAiringEpisode!.episode - 1)
                    : media.episodes
                let isAiring = media.status == "RELEASING"

                // Reconcile watched keys: mark all eps 1...progress as watched locally (highest wins).
                if entry.progress > 0 {
                    for ep in 1...entry.progress {
                        if let key = Self.watchedKey(aniListID: media.id, moduleId: nil,
                                                     mediaTitle: media.title.displayTitle, episodeNumber: ep) {
                            watchedKeys.insert(key)
                        }
                    }
                }

                // Don't create a placeholder if the user is already caught up on all aired episodes
                if let avail = availableEpisodes, nextEp > avail { continue }

                let existing = newItems.first { matchesShow($0, aniListID: media.id, moduleId: nil, mediaTitle: "") }

                // Update existing entry if AniList shows the user has watched further (e.g. on another device)
                if let existing, existing.streamUrl.isEmpty, nextEp > existing.episodeNumber {
                    newItems.removeAll { matchesShow($0, aniListID: media.id, moduleId: nil, mediaTitle: "") }
                    if let placeholder = makePlaceholder(
                        episodeNumber: nextEp,
                        from: existing,
                        aniListID: media.id,
                        moduleId: existing.moduleId,
                        mediaTitle: media.title.displayTitle,
                        imageUrl: media.coverImage.best ?? existing.imageUrl,
                        totalEpisodes: media.episodes ?? existing.totalEpisodes,
                        availableEpisodes: availableEpisodes,
                        isAiring: isAiring,
                        detailHref: existing.detailHref,
                        aniListUpdatedAt: entry.updatedAt
                    ) {
                        newItems.insert(placeholder, at: 0)
                    }
                } else if let existing, let updatedAt = entry.updatedAt {
                    // Refresh aniListUpdatedAt on existing items so sort order stays current
                    if let idx = newItems.firstIndex(where: { $0.id == existing.id }) {
                        newItems[idx].aniListUpdatedAt = updatedAt
                    }
                } else if existing == nil {
                    // No local entry — create a placeholder from AniList progress
                    if let placeholder = makePlaceholder(
                        episodeNumber: nextEp,
                        from: nil,
                        aniListID: media.id,
                        moduleId: nil,
                        mediaTitle: media.title.displayTitle,
                        imageUrl: media.coverImage.best,
                        totalEpisodes: media.episodes,
                        availableEpisodes: availableEpisodes,
                        isAiring: isAiring,
                        detailHref: nil,
                        lastWatchedAt: .distantPast,
                        aniListUpdatedAt: entry.updatedAt
                    ) {
                        newItems.append(placeholder)
                    }
                }
            }
            
            // Sort by date and keep unique
            items = Array(newItems.sorted { cwSortOrder($0, $1) }.prefix(maxItems))
            persist()
            
        } catch {
            // No internet → expected silent failure; anything else is worth logging.
            if !ProviderManager.isOfflineError(error) {
                Logger.shared.log("[CW] Sync failed: \(error.localizedDescription)", type: "Error")
            }
        }
    }

    /// Syncs local watched keys from MAL's watching/rewatching list.
    /// Highest wins: only inserts keys, never removes. Uses cached aniListID mapping
    /// to build keys compatible with `watchedKey` (which is keyed by aniListID, not malID).
    func syncWithMAL() async {
        guard MALAuthManager.shared.isLoggedIn else { return }
        do {
            let library = try await MALLibraryService.shared.fetchLibrary()
            let active = library.filter {
                $0.list_status.status == "watching" || $0.list_status.status == "rewatching"
            }
            for entry in active {
                let progress = entry.list_status.num_episodes_watched ?? 0
                guard progress > 0 else { continue }
                let aniListID = IDMappingService.shared.cachedAnilistId(forMALId: entry.node.id)
                for ep in 1...progress {
                    if let key = Self.watchedKey(aniListID: aniListID, moduleId: nil,
                                                 mediaTitle: entry.node.title, episodeNumber: ep) {
                        watchedKeys.insert(key)
                    }
                }
            }
            persist()
        } catch {
            if !ProviderManager.isOfflineError(error) {
                Logger.shared.log("[CW] MAL sync failed: \(error.localizedDescription)", type: "Error")
            }
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

        // Leave CW alone if the placeholder is already past this episode, or if there's an
        // in-progress item for a DIFFERENT episode (don't disturb active progress on another ep).
        // When the in-progress item IS this episode, proceed and replace it with the next placeholder.
        if let current {
            if current.episodeNumber > episodeNumber { persist(); return }
            if !current.streamUrl.isEmpty && current.episodeNumber != episodeNumber { persist(); return }
        }

        removeAllShowItems(aniListID: aniListID, moduleId: moduleId, mediaTitle: mediaTitle, in: &arr)

        let effectiveCap = availableEpisodes ?? current?.availableEpisodes ?? totalEpisodes ?? current?.totalEpisodes
        let isLastEpisode = effectiveCap.map { episodeNumber >= $0 } ?? false
        if !isLastEpisode, let placeholder = makePlaceholder(
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
        // Don't move CW backward — if placeholder already points past episodeNumber, leave it.
        if let ref, ref.episodeNumber > episodeNumber { persist(); return }
        removeAllShowItems(aniListID: aniListID, moduleId: moduleId, mediaTitle: mediaTitle, in: &arr)

        // 2. Queue up the NEXT episode (N + 1) as a placeholder, if it exists
        let nextEp = episodeNumber + 1
        let effectiveCap = availableEpisodes ?? ref?.availableEpisodes ?? totalEpisodes ?? ref?.totalEpisodes
        let isLastEpisode = effectiveCap.map { episodeNumber >= $0 } ?? false
        if !isLastEpisode, let placeholder = makePlaceholder(
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

    /// Unified entry point for all UI mark/unmark calls.
    ///
    /// Mark watched: applies local (1...ep) + pushes to AniList/MAL. Returns `.applied`.
    /// Mark unwatched: clears local ep + any orphaned keys above ep. If remote progress would
    /// decrease, returns `.needsConfirmation` — local is already applied; caller shows a dialog.
    func markEpisode(_ ep: Int, asWatched: Bool, context: MarkContext) async -> MarkResult {
        if asWatched {
            markWatched(
                upThrough: ep,
                aniListID: context.aniListID, moduleId: context.moduleId,
                mediaTitle: context.mediaTitle, imageUrl: context.imageUrl,
                totalEpisodes: context.totalEpisodes, availableEpisodes: context.availableEpisodes,
                detailHref: context.detailHref
            )
            await pushRemoteProgress(ep: ep, context: context)
            return .applied
        }

        // Check downgrade BEFORE touching local state — if confirmation is needed,
        // defer the unmark into the closures so Cancel leaves the episode intact.
        let proposedProgress = ep - 1
        let aniListLoggedIn = AniListAuthManager.shared.isLoggedIn
        let malLoggedIn = MALAuthManager.shared.isLoggedIn
        let aniFrom = context.currentAniListProgress
        let malFrom = context.currentMALProgress
        let aniNeedsDowngrade = aniListLoggedIn && (aniFrom.map { $0 > proposedProgress } ?? false)
        let malNeedsDowngrade = malLoggedIn && (malFrom.map { $0 > proposedProgress } ?? false)

        if aniNeedsDowngrade || malNeedsDowngrade {
            let capturedContext = context
            let capturedProposed = proposedProgress
            let capturedAniListLoggedIn = aniListLoggedIn
            let capturedMalLoggedIn = malLoggedIn

            return .needsConfirmation(RemoteDowngrade(
                newProgress: capturedProposed,
                anilistFrom: aniNeedsDowngrade ? aniFrom : nil,
                malFrom: malNeedsDowngrade ? malFrom : nil,
                confirm: {
                    self.applyLocalUnmark(ep: ep, context: capturedContext)
                    let remoteStatus: MediaListStatus = capturedProposed == 0 ? .planning : .current
                    if let aid = capturedContext.aniListID, capturedAniListLoggedIn {
                        try? await AniListLibraryService.shared.updateEntry(
                            mediaId: aid, status: remoteStatus, progress: capturedProposed, score: 0)
                    }
                    let malID = capturedContext.malID
                        ?? capturedContext.aniListID.flatMap { IDMappingService.shared.cachedMalId(forAnilistId: $0) }
                    if let mid = malID, capturedMalLoggedIn {
                        do {
                            try await MALProvider.shared.updateEntry(
                                mediaId: mid, status: remoteStatus, progress: capturedProposed, score: 0)
                        } catch {
                            Logger.shared.log("[Tracking] MAL unmark update failed: \(error)", type: "Error")
                        }
                    }
                },
                localOnly: {
                    self.applyLocalUnmark(ep: ep, context: capturedContext)
                }
            ))
        }

        // No remote downgrade — apply local unmark immediately.
        applyLocalUnmark(ep: ep, context: context)
        return .applied
    }

    private func applyLocalUnmark(ep: Int, context: MarkContext) {
        markUnwatched(
            aniListID: context.aniListID, moduleId: context.moduleId,
            mediaTitle: context.mediaTitle, episodeNumber: ep,
            imageUrl: context.imageUrl, totalEpisodes: context.totalEpisodes,
            availableEpisodes: context.availableEpisodes, detailHref: context.detailHref
        )
        let keysAbove = watchedKeys.filter { key in
            if let aid = context.aniListID, key.hasPrefix("a:\(aid):") {
                let suffix = key.dropFirst("a:\(aid):".count)
                return Int(suffix).map { $0 > ep } ?? false
            }
            if let mid = context.moduleId, !mid.isEmpty {
                let canonical = context.mediaTitle.trimmingCharacters(in: .whitespaces).lowercased()
                let prefix = "m:\(mid):\(canonical):"
                if key.hasPrefix(prefix) {
                    let suffix = key.dropFirst(prefix.count)
                    return Int(suffix).map { $0 > ep } ?? false
                }
            }
            return false
        }
        if !keysAbove.isEmpty {
            watchedKeys.subtract(keysAbove)
            persist()
        }
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
                                  detailHref: String?,
                                  lastWatchedAt: Date = .now,
                                  aniListUpdatedAt: Int? = nil) -> ContinueWatchingItem? {
        let srcImageUrl   = [source?.imageUrl, imageUrl].compactMap { $0 }.first(where: { !$0.isEmpty }) ?? ""
        let srcAniListID  = source?.aniListID     ?? aniListID
        let srcModuleId   = source?.moduleId      ?? moduleId
        let srcMediaTitle = source?.mediaTitle    ?? mediaTitle
        let srcDetailHref = source?.detailHref    ?? detailHref

        // Use the largest known totalEpisodes — stale module counts are often 1 and would
        // incorrectly cap a multi-episode show if we took the minimum or first-non-nil.
        let srcTotalEps = [totalEpisodes, source?.totalEpisodes].compactMap { $0 }.max()

        // availableEpisodes — how many are currently aired; may be < total for ongoing shows
        let srcAvailable = availableEpisodes ?? source?.availableEpisodes
        let srcIsAiring = isAiring ?? source?.isAiring

        // Allow empty imageUrl — card display falls back to TVDB thumbnail or gray placeholder

        // Only block "Up Next" for explicitly-finished shows with a confirmed episode count.
        // For airing or unknown shows, always allow the placeholder — stale ones are cleaned
        // up by notifyNewEpisodesAvailable when the detail view reloads.
        if srcIsAiring == false {
            // For completed shows, totalEpisodes is the definitive cap.
            // availableEpisodes is often the module's lazy-loaded count (can be as low as 1)
            // and is meaningless for completed shows where all episodes have aired.
            let cap = srcTotalEps
            if let cap, cap > 0, episodeNumber > cap {
                Logger.shared.log("[CW] No more episodes (ep \(episodeNumber) > cap \(cap)), no placeholder created.", type: "General")
                return nil
            }
        }

        return ContinueWatchingItem(
            id: UUID(), mediaTitle: srcMediaTitle, episodeNumber: episodeNumber,
            episodeTitle: nil, imageUrl: srcImageUrl, streamUrl: "",
            headers: nil, subtitle: nil, streamTitle: nil, aniListID: srcAniListID,
            moduleId: srcModuleId, detailHref: srcDetailHref,
            watchedSeconds: 0, totalSeconds: 0, totalEpisodes: srcTotalEps,
            availableEpisodes: srcAvailable,
            isAiring: srcIsAiring,
            lastWatchedAt: lastWatchedAt,
            thumbnailUrl: nil,
            aniListUpdatedAt: aniListUpdatedAt ?? source?.aniListUpdatedAt
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
                Logger.shared.log("[CW] notifyNew: re-evaluating placeholder ep=\(existing.episodeNumber) avail=\(availableEpisodes) totalEps=\(String(describing: totalEpisodes ?? existing.totalEpisodes)) isAiring=\(String(describing: isAiring ?? existing.isAiring)) title=\(mediaTitle)", type: "Debug")
                if let updated = makePlaceholder(
                    episodeNumber: existing.episodeNumber, from: existing,
                    aniListID: aniListID, moduleId: moduleId, mediaTitle: mediaTitle,
                    imageUrl: imageUrl, totalEpisodes: totalEpisodes ?? existing.totalEpisodes,
                    availableEpisodes: availableEpisodes, isAiring: isAiring ?? existing.isAiring, detailHref: detailHref ?? existing.detailHref
                ) {
                    arr.insert(updated, at: 0)
                } else {
                    Logger.shared.log("[CW] notifyNew: placeholder ep=\(existing.episodeNumber) was DELETED (makePlaceholder returned nil)", type: "Debug")
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
        Logger.shared.log("[CW] New episode available: Up Next ep \(nextEp) (available: \(availableEpisodes))", type: "General")
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
        if let mid = moduleId, !mid.isEmpty {
            let canonical = mediaTitle.trimmingCharacters(in: .whitespaces).lowercased()
            return "m:\(mid):\(canonical):\(episodeNumber)"
        }
        return nil
    }

    // MARK: - Remote Tracking

    private static func trackingPref(_ key: String, default def: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? def : UserDefaults.standard.bool(forKey: key)
    }

    /// Pushes episode progress to AniList and MAL, replicating the player's full tracking logic.
    /// Handles .completed (rewatch), .repeating, and .current status correctly for both services.
    func pushRemoteProgress(ep: Int, context: MarkContext) async {
        let aniListEnabled = Self.trackingPref("aniListTrackingEnabled", default: true)
        let malEnabled     = Self.trackingPref("malTrackingEnabled", default: true)
        let skipRewatch    = Self.trackingPref("skipReWatchTracking", default: true)

        let isCompleted = context.totalEpisodes != nil && context.totalEpisodes == ep
        let targetStatus: MediaListStatus = isCompleted ? .completed : .current

        // --- AniList ---
        if aniListEnabled, AniListAuthManager.shared.isLoggedIn {
            let resolvedAniListID: Int?
            if let aid = context.aniListID {
                resolvedAniListID = aid
            } else if let malID = context.malID {
                resolvedAniListID = await IDMappingService.shared.anilistId(forMALId: malID)
            } else {
                resolvedAniListID = nil
            }
            if let aid = resolvedAniListID {
                if let current = try? await AniListProvider.shared.fetchEntry(mediaId: aid) {
                    if current.status == .completed && skipRewatch {
                        // "Never reduce progress" is on: leave the completed entry untouched
                        // instead of resetting it to a lower ep via rewatch tracking.
                        Logger.shared.log("[Tracking] AniList skip rewatch (never reduce progress): ep \(ep) on completed entry", type: "Info")
                    } else if current.status == .completed {
                        if context.totalEpisodes == 1 {
                            let newRepeat = (current.timesRewatched ?? 0) + 1
                            Logger.shared.log("[Tracking] AniList rewatch (single-ep): repeat → \(newRepeat)", type: "Info")
                            try? await AniListLibraryService.shared.updateEntry(
                                mediaId: aid, status: .completed, progress: ep, repeat: newRepeat)
                        } else {
                            Logger.shared.log("[Tracking] AniList rewatch: setting REPEATING at ep \(ep)", type: "Info")
                            try? await AniListLibraryService.shared.updateEntry(
                                mediaId: aid, status: .repeating, progress: ep)
                        }
                    } else if skipRewatch && ep <= current.progress {
                        Logger.shared.log("[Tracking] AniList skip: ep \(ep) <= tracked \(current.progress)", type: "Info")
                    } else {
                        try? await AniListProvider.shared.updateEntry(
                            mediaId: aid, status: targetStatus, progress: ep, score: 0)
                    }
                } else {
                    try? await AniListProvider.shared.updateEntry(
                        mediaId: aid, status: targetStatus, progress: ep, score: 0)
                }
            }
        }

        // --- MAL ---
        if malEnabled, MALAuthManager.shared.isLoggedIn {
            let resolvedMALID: Int?
            if let malID = context.malID {
                resolvedMALID = malID
            } else if let aid = context.aniListID {
                resolvedMALID = await IDMappingService.shared.malId(forAnilistId: aid)
            } else {
                resolvedMALID = nil
            }
            if let mid = resolvedMALID {
                if let current = try? await MALProvider.shared.fetchEntry(mediaId: mid) {
                    if current.status == .completed && skipRewatch {
                        // "Never reduce progress" is on: leave the completed entry untouched
                        // instead of resetting num_watched_episodes to a lower ep via rewatch tracking.
                        Logger.shared.log("[Tracking] MAL skip rewatch (never reduce progress): ep \(ep) on completed entry", type: "Info")
                    } else if current.status == .completed {
                        if context.totalEpisodes == 1 {
                            let newRepeat = (current.timesRewatched ?? 0) + 1
                            Logger.shared.log("[Tracking] MAL rewatch (single-ep): num_times_rewatched → \(newRepeat)", type: "Info")
                            do {
                                try await MALLibraryService.shared.updateEntry(
                                    malId: mid, status: .completed, progress: ep, score: 0,
                                    numTimesRewatched: newRepeat)
                            } catch {
                                Logger.shared.log("[Tracking] MAL single-ep rewatch update failed: \(error)", type: "Error")
                            }
                        } else {
                            Logger.shared.log("[Tracking] MAL rewatch: setting rewatching at ep \(ep)", type: "Info")
                            do {
                                try await MALLibraryService.shared.updateEntry(
                                    malId: mid, status: .repeating, progress: ep, score: 0)
                            } catch {
                                Logger.shared.log("[Tracking] MAL rewatch update failed: \(error)", type: "Error")
                            }
                        }
                    } else if skipRewatch && ep <= current.progress {
                        Logger.shared.log("[Tracking] MAL skip: ep \(ep) <= tracked \(current.progress)", type: "Info")
                    } else {
                        do {
                            try await MALProvider.shared.updateEntry(
                                mediaId: mid, status: targetStatus, progress: ep, score: 0)
                            Logger.shared.log("[Tracking] MAL progress updated: ep \(ep), malId \(mid)", type: "Info")
                        } catch {
                            Logger.shared.log("[Tracking] MAL update failed: \(error)", type: "Error")
                        }
                    }
                } else {
                    do {
                        try await MALProvider.shared.updateEntry(
                            mediaId: mid, status: targetStatus, progress: ep, score: 0)
                        Logger.shared.log("[Tracking] MAL progress updated (new entry): ep \(ep), malId \(mid)", type: "Info")
                    } catch {
                        Logger.shared.log("[Tracking] MAL new-entry update failed: \(error)", type: "Error")
                    }
                }
            }
        }

        let aniListWillWrite = aniListEnabled && AniListAuthManager.shared.isLoggedIn
        let malWillWrite     = malEnabled     && MALAuthManager.shared.isLoggedIn
        if aniListWillWrite || malWillWrite {
            NotificationCenter.default.post(name: .remoteLibraryProgressDidPush, object: nil)
        }
    }

    // MARK: - Migrations

    private func runLegacyDataMigration() async {
        // Re-key module entries stored with non-canonical (mixed-case/padded) mediaTitle.
        let nonCanonicalModuleKeys = watchedKeys.filter { key in
            guard key.hasPrefix("m:") else { return false }
            let parts = key.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4 else { return false }
            let storedTitle = String(parts[2])
            let canonical = storedTitle.trimmingCharacters(in: .whitespaces).lowercased()
            return storedTitle != canonical
        }
        if !nonCanonicalModuleKeys.isEmpty {
            var updated = watchedKeys
            for key in nonCanonicalModuleKeys {
                let parts = key.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
                guard parts.count == 4 else { continue }
                let mid = String(parts[1])
                let title = String(parts[2])
                let ep = String(parts[3])
                let canonical = title.trimmingCharacters(in: .whitespaces).lowercased()
                updated.remove(key)
                updated.insert("m:\(mid):\(canonical):\(ep)")
            }
            await MainActor.run {
                watchedKeys = updated
                persist()
            }
        }

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

    // MARK: - Sort

    /// Sort order: (1) items with progress bar, by lastWatchedAt desc;
    /// (2) AniList placeholders (no progress), by aniListUpdatedAt desc.
    private func cwSortOrder(_ a: ContinueWatchingItem, _ b: ContinueWatchingItem) -> Bool {
        let aHasProgress = a.watchedSeconds > 0
        let bHasProgress = b.watchedSeconds > 0
        if aHasProgress != bHasProgress { return aHasProgress }
        if aHasProgress {
            return a.lastWatchedAt > b.lastWatchedAt
        }
        // Both are AniList placeholders — sort by AniList updatedAt (unix timestamp)
        let aUpdated = a.aniListUpdatedAt ?? 0
        let bUpdated = b.aniListUpdatedAt ?? 0
        return aUpdated > bUpdated
    }

    // MARK: - Persistence

    private func persist() {
        items = items.sorted { cwSortOrder($0, $1) }
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
            items = decoded.sorted { cwSortOrder($0, $1) }
        }
        if let wdata = UserDefaults.standard.data(forKey: Keys.watched),
           let wdecoded = try? JSONDecoder().decode(Set<String>.self, from: wdata) {
            watchedKeys = wdecoded
        }
    }
}
