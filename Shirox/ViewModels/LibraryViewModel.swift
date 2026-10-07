import Foundation
import Combine

extension Notification.Name {
    static let remoteLibraryProgressDidPush = Notification.Name("remoteLibraryProgressDidPush")
}

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published var entries: [LibraryEntry] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var selectedStatus: MediaListStatus = .current
    @Published var selectedCustomList: String? = nil
    @Published var mediaType: MediaKind = .anime

    @Published var source: LibrarySource = .provider(.anilist)

    private var dataSource: LibraryDataSource {
        switch source {
        case .local:    return LocalLibraryDataSource()
        case .provider: return RemoteLibraryDataSource()
        case .simkl:    return SimklLibraryDataSource(kind: mediaType)
        }
    }

    var isLocal: Bool { if case .local = source { return true }; return false }

    /// Sorted unique custom list names from the full library
    @Published var customListNames: [String] = []

    private var allEntries: [LibraryEntry] = []

    /// One cached snapshot per (source, media-type) so switching back is instant instead of
    /// re-hitting the network every toggle. A background silent refresh keeps hits fresh.
    private struct CacheKey: Hashable {
        let source: LibrarySource
        let mediaType: MediaKind
    }
    private var cache: [CacheKey: [LibraryEntry]] = [:]
    private var cacheTimestamps: [CacheKey: Date] = [:]
    private let cacheStaleInterval: TimeInterval = 30
    private var currentKey: CacheKey { CacheKey(source: source, mediaType: mediaType) }

    private func isCacheStale(_ key: CacheKey) -> Bool {
        guard let ts = cacheTimestamps[key] else { return true }
        return Date().timeIntervalSince(ts) >= cacheStaleInterval
    }

    /// Monotonic token: only the most recently started `fetch` is allowed to publish its
    /// result. A slow load whose selection has since changed is discarded, so the visible
    /// list can never disagree with the selected source / media-type pill.
    private var loadGeneration = 0

    private var lastFetchedAt: Date?
    private let minAutoRefreshInterval: TimeInterval = 30
    private var cancellables = Set<AnyCancellable>()

    private static func isSignedIn(_ provider: ProviderType) -> Bool {
        switch provider {
        case .anilist: return AniListAuthManager.shared.isLoggedIn
        case .mal: return MALAuthManager.shared.isLoggedIn
        default: return false
        }
    }

    init() {
        // Logged-out users have no provider library, so start on the on-device source.
        // Setting this up front (rather than deferring to an .onAppear) keeps the Library's
        // searchable content present from the first render, so the search bar stays attached
        // to the navigation bar across push/pop.
        if !AniListAuthManager.shared.isLoggedIn && !MALAuthManager.shared.isLoggedIn {
            source = .local
        } else if let primary = ProviderManager.shared.primary?.providerType {
            // `source` must carry the *actual* active provider: anime routes through
            // `ProviderManager.primary`, manga fetches switch on `source`'s embedded type, and
            // the cache keys on it. A stale default (.anilist while MAL is primary) would fetch
            // one provider for anime and another for manga, and collide their cache snapshots.
            // But only one the user is signed into: signed into MyAnimeList alone, with AniList
            // still first in the order, the Library opened on AniList and said "Not logged in."
            // while Settings showed the MyAnimeList account.
            if Self.isSignedIn(primary) {
                source = .provider(primary)
            } else if let signedIn = ProviderManager.shared.orderedProviders
                .map(\.providerType).first(where: Self.isSignedIn) {
                source = .provider(signedIn)
            }
        }
        restoreList()

        // Cold start: show the last-saved list for the initial key instantly, before the first
        // network refresh. `autoRefreshIfNeeded` then refreshes silently (no spinner) and keeps
        // this data if the provider is rate-limited.
        if let hit = cachedSnapshot(for: currentKey) {
            allEntries = hit.entries
            cacheTimestamps[currentKey] = hit.syncedAt
            rebuildCustomListNames(from: hit.entries)
            applyFilter()
        }

        ProviderManager.shared.$orderedProviders
            .map { $0.first?.providerType }
            .removeDuplicates { $0 == $1 }
            .dropFirst()
            .sink { [weak self] providerType in
                // Keep `source` in lock-step with the active provider so switching providers
                // actually re-keys the cache and reloads the list (rather than early-returning
                // in `selectSource` because the nominal source didn't change).
                guard let self, let providerType, case .provider = self.source,
                      Self.isSignedIn(providerType) else { return }
                guard self.source != .provider(providerType) else { return }
                self.source = .provider(providerType)
                self.restoreList()
                self.switchKey()
            }
            .store(in: &cancellables)

        LocalLibraryManager.shared.$entries
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, self.isLocal else { return }
                Task { await self.load() }
            }
            .store(in: &cancellables)

        LocalLibraryManager.shared.$collections
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, self.isLocal else { return }
                self.customListNames = LocalLibraryManager.shared.collections.map(\.name).sorted()
                self.dropMissingCustomList()
                self.applyFilter()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AniListEntryExtrasChange.notification)
            .compactMap { $0.object as? AniListEntryExtrasChange }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in self?.apply(change) }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .remoteLibraryProgressDidPush)
            .sink { [weak self] _ in
                Task { @MainActor in
                    // Force the next auto-refresh to re-hit the network; switching keys still
                    // background-refreshes on its own, so stale snapshots self-heal.
                    self?.lastFetchedAt = nil
                }
            }
            .store(in: &cancellables)
    }

    func load() async {
        await fetch()
    }

    /// An AniList manga list entry, with a manga-tagged Media so `isManga` is reliable and the
    /// chapter total (episodes field) comes from `chapters`.
    nonisolated static func aniListMangaEntry(_ r: AniListRawEntry) -> LibraryEntry {
        let m = r.media
        let media = Media(
            id: m.id, idMal: m.idMal, provider: .anilist,
            title: MediaTitle(romaji: m.title.romaji, english: m.title.english, native: m.title.native),
            coverImage: MediaCoverImage(large: m.coverImage.large, extraLarge: m.coverImage.extraLarge),
            bannerImage: m.bannerImage, description: m.description, episodes: m.chapters,
            status: m.status, averageScore: m.averageScore, genres: m.genres,
            season: nil, seasonYear: nil, nextAiringEpisode: nil, relations: nil,
            type: "MANGA", format: m.format)
        return LibraryEntry(
            id: r.id, media: media,
            status: r.status, progress: r.progress, score: r.score,
            updatedAt: r.updatedAt, customListName: r.customListName,
            timesRewatched: r.repeat, isPrivate: r.isPrivate, notes: r.notes)
    }

    /// Privacy and notes are saved apart from `update`, so the lists held here hear of them now.
    private func apply(_ change: AniListEntryExtrasChange) {
        for i in allEntries.indices { change.apply(to: &allEntries[i]) }
        for (key, entries) in cache where key.source == .provider(.anilist) {
            cache[key] = entries.map { change.apply(to: $0) ?? $0 }
        }
        LibraryCacheStore.shared.apply(change)
        applyFilter()
    }

    func selectStatus(_ status: MediaListStatus) {
        selectedStatus = status
        selectedCustomList = nil
        rememberList()
        applyFilter()
    }

    func selectCustomList(_ name: String?) {
        selectedCustomList = name
        rememberList()
        applyFilter()
    }

    /// Lands on the list last used for this source and type, or the type's default.
    private func restoreList() {
        let place = LibraryListMemory.restorable(LibraryListMemory.load(for: source, mediaType),
                                                 source: source, kind: mediaType)
        selectedStatus = place?.status ?? LibrarySource.defaultStatus(for: mediaType)
        selectedCustomList = place?.customList
    }

    private func rememberList() {
        LibraryListMemory.save(LibraryListMemory.Place(status: selectedStatus, customList: selectedCustomList),
                               for: source, mediaType)
    }

    /// A remembered custom list that no longer exists falls back to its status list.
    private func dropMissingCustomList() {
        guard let list = selectedCustomList, !customListNames.contains(list) else { return }
        selectedCustomList = nil
        rememberList()
    }

    func selectSource(_ source: LibrarySource) {
        // Selecting a provider makes it the active (primary) provider so `source`, the anime
        // fetch (which reads `ProviderManager.primary`) and the manga fetch (which switches on
        // `source`'s type) all agree. When this actually changes primary, the `$orderedProviders`
        // sink updates `source` and reloads; when it doesn't, we fall through and reload here.
        // My Library and Simkl select nothing — Simkl must never become the primary provider.
        if let type = source.providerToSelect {
            ProviderManager.shared.selectProvider(type)
        }
        guard self.source != source else { return }
        self.source = source
        // Simkl has no manga, and AniList and MyAnimeList no TV or movies: arriving on a kind the
        // new source lacks would ask it for a list it doesn't have.
        if !source.mediaKinds.contains(mediaType) { mediaType = .anime }
        restoreList()
        switchKey()
    }

    func selectMediaType(_ kind: MediaKind) {
        guard mediaType != kind else { return }
        mediaType = kind
        restoreList()
        switchKey()
    }

    /// Move the visible list to the newly selected (source, media-type). A cached snapshot is
    /// shown instantly and refreshed quietly in the background; otherwise the list clears and
    /// loads fresh. `fetch` guards against a stale request landing after another switch, so the
    /// pill and the list always agree.
    private func switchKey() {
        error = nil
        if let hit = cachedSnapshot(for: currentKey) {
            allEntries = hit.entries
            cache[currentKey] = hit.entries
            cacheTimestamps[currentKey] = hit.syncedAt
            isLoading = false   // we have content to show now; don't let an in-flight load's spinner linger
            rebuildCustomListNames(from: hit.entries)
            applyFilter()
            // Only re-hit the network if the snapshot is stale — avoids hammering the provider
            // (and its rate limit) when toggling back and forth between recently loaded keys.
            if isCacheStale(currentKey) {
                Task { await fetch(silent: true) }
            }
        } else {
            allEntries = []
            entries = []
            isLoading = true   // set synchronously so no empty-state flash before fetch runs
            Task { await fetch() }
        }
    }

    /// Best available snapshot for a key: the hot in-memory cache first, then the persisted
    /// on-disk snapshot (remote providers only). Nil when neither has data yet.
    private func cachedSnapshot(for key: CacheKey) -> (entries: [LibraryEntry], syncedAt: Date)? {
        if let entries = cache[key] {
            return (entries, cacheTimestamps[key] ?? .distantPast)
        }
        if case .provider(let type) = key.source,
           let snap = LibraryCacheStore.shared.snapshot(provider: type, mediaType: key.mediaType) {
            return (snap.entries, snap.syncedAt)
        }
        // `SimklLibraryService` keeps the Simkl list's snapshots under the same store, per kind.
        if key.source == .simkl,
           let snap = LibraryCacheStore.shared.snapshot(provider: .simkl, mediaType: key.mediaType) {
            return (snap.entries, snap.syncedAt)
        }
        return nil
    }

    func refresh() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.fetch(userRequested: true) }
            group.addTask {
                // Sequential: both sync funcs mutate the same CW store across await points.
                await ContinueWatchingManager.shared.syncWithAniList()
                await ContinueWatchingManager.shared.syncWithMAL()
                await MainActor.run { LocalLibraryManager.shared.syncFromContinueWatching() }
            }
        }
    }

    func update(entry: LibraryEntry, status: MediaListStatus, progress: Int, score: Double) async {
        if let index = allEntries.firstIndex(where: { $0.media.uniqueId == entry.media.uniqueId }) {
            allEntries[index].status = status
            allEntries[index].progress = progress
            allEntries[index].score = score
            cache[currentKey] = allEntries   // keep the optimistic edit across key switches
            applyFilter()
        }
        do {
            if mediaType == .manga, case .provider(let type) = source {
                switch type {
                case .anilist:
                    try await AniListLibraryService.shared.updateEntry(
                        mediaId: entry.media.id, status: status, progress: progress, score: score, type: .manga)
                case .mal:
                    try await MALMangaLibraryService.shared.updateEntry(
                        malId: entry.media.id, status: status, progress: progress, score: score)
                default: break
                }
            } else {
                try await dataSource.updateEntry(media: entry.media, status: status,
                                                  progress: progress, score: score)
            }
        } catch {
            self.error = error.localizedDescription
            cache[currentKey] = nil   // drop the optimistic snapshot, resync from source
            await load()
        }
    }

    func delete(entry: LibraryEntry) async {
        allEntries.removeAll { $0.media.uniqueId == entry.media.uniqueId }
        cache[currentKey] = allEntries   // keep the optimistic removal across key switches
        applyFilter()
        do {
            if mediaType == .manga, case .provider(let type) = source {
                switch type {
                case .anilist: try await AniListLibraryService.shared.deleteEntry(entryId: entry.id)
                case .mal:     try await MALMangaLibraryService.shared.deleteEntry(malId: entry.media.id)
                default: break
                }
            } else {
                try await dataSource.deleteEntry(entry)
            }
        } catch {
            self.error = error.localizedDescription
            cache[currentKey] = nil   // drop the optimistic snapshot, resync from source
            await load()
        }
    }

    func autoRefreshIfNeeded() async {
        if let last = lastFetchedAt, Date().timeIntervalSince(last) < minAutoRefreshInterval {
            return
        }
        let silent = !allEntries.isEmpty
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.fetch(silent: silent) }
            group.addTask {
                // Sequential: both sync funcs mutate the same CW store across await points.
                await ContinueWatchingManager.shared.syncWithAniList()
                await ContinueWatchingManager.shared.syncWithMAL()
                await MainActor.run { LocalLibraryManager.shared.syncFromContinueWatching() }
            }
        }
    }

    // MARK: - Private

    private func fetch(silent: Bool = false, userRequested: Bool = false) async {
        // Claim this generation. `mediaType`, `source` and `currentKey` are read synchronously
        // here — before the first await — so they match the selection this fetch is loading.
        loadGeneration &+= 1
        let generation = loadGeneration
        let key = currentKey

        if allEntries.isEmpty && !silent { isLoading = true }
        if !silent { error = nil }
        do {
            let result: [LibraryEntry]
            if key.mediaType == .manga {
                result = try await fetchMangaLibrary()   // already provider-direct
            } else if case .provider(let type) = key.source {
                // Provider-direct: fetch the *selected* provider only, bypassing ProviderManager's
                // cross-provider fallback, so the AniList list is never served from MAL.
                result = try await fetchRemoteAnimeLibraryDirect(provider: type)
            } else if key.source == .simkl, userRequested {
                // Pull to refresh and Retry are the only times the Simkl list asks Simkl whether
                // anything changed; every other load shows its cached copy.
                result = try await SimklLibraryDataSource(kind: key.mediaType).checkForChanges()
            } else {
                result = try await dataSource.fetchLibrary()   // local, or Simkl's cached list
            }
            // A newer selection superseded this request while the network was in flight —
            // drop the stale result so the list never disagrees with the selected pill.
            guard generation == loadGeneration else { return }
            cache[key] = result
            cacheTimestamps[key] = Date()
            if case .provider(let type) = key.source {
                LibraryCacheStore.shared.save(entries: result, provider: type, mediaType: key.mediaType)
            }
            allEntries = result
            lastFetchedAt = Date()
            rebuildCustomListNames(from: result)
            applyFilter()
            Task { await PendingWriteQueue.shared.flush() }
        } catch {
            guard generation == loadGeneration else { return }
            if !silent { report(error, keepingList: key.source == .simkl && !allEntries.isEmpty) }
        }
        if generation == loadGeneration && !silent { isLoading = false }
    }

    /// Fetches the given provider's library directly, without ProviderManager's cross-provider
    /// fallback — a rate-limited AniList throws here (so the caller keeps the disk snapshot)
    /// instead of silently returning MAL's list.
    private func fetchRemoteAnimeLibraryDirect(provider: ProviderType) async throws -> [LibraryEntry] {
        guard let p = ProviderManager.shared.orderedProviders.first(where: { $0.providerType == provider }) else {
            throw ProviderError.unauthenticated
        }
        return try await p.fetchLibrary()
    }

    /// Shows a failed load. The Simkl list keeps its cached copy on screen — still right as of the
    /// last check — with the error over it: often the daily limit, which no retry clears before
    /// midnight US Eastern. Everything else shows the error in place of the list.
    private func report(_ error: Error, keepingList: Bool) {
        #if !os(tvOS)
        if keepingList {
            ToastManager.shared.show(message: error.localizedDescription, type: .error)
            return
        }
        #endif
        self.error = error.localizedDescription
    }

    /// Refreshes the custom-list-name menu from the freshly fetched entries (or the local
    /// collection store when on the local source), persisting remote names for cold starts.
    private func rebuildCustomListNames(from result: [LibraryEntry]) {
        if isLocal {
            customListNames = LocalLibraryManager.shared.collections.map(\.name).sorted()
        } else {
            var seen = Set<String>()
            customListNames = result.compactMap { $0.customListName }.filter { seen.insert($0).inserted }.sorted()
            UserDefaults.standard.set(customListNames, forKey: "libraryCustomListNames")
        }
        dropMissingCustomList()
    }

    /// Fetches the manga library for the current source. Local reads the on-device
    /// store (filtered to manga); AniList/MAL fetch their MANGA lists directly
    /// (read-only display path — no provider fallback machinery needed for v1).
    private func fetchMangaLibrary() async throws -> [LibraryEntry] {
        switch source {
        case .local:
            return LocalLibraryManager.shared.entries.filter { $0.media.isManga }
        case .simkl:
            return []   // anime only; the Manga pill is hidden on this source
        case .provider(let type):
            switch type {
            case .anilist:
                guard let userId = await AniListAuthManager.shared.authenticatedUserId else { return [] }
                let raw = try await AniListLibraryService.shared.fetchAllLists(userId: userId, type: .manga)
                return raw.map(Self.aniListMangaEntry)
            case .mal:
                let entries = try await MALMangaLibraryService.shared.fetchLibrary()
                return entries.map { e in
                    let node = e.node
                    let media = Media(
                        id: node.id, idMal: node.id, provider: .mal,
                        title: MediaTitle(romaji: node.title, english: nil, native: nil),
                        coverImage: MediaCoverImage(large: node.main_picture?.medium, extraLarge: node.main_picture?.large),
                        bannerImage: nil, description: node.synopsis, episodes: node.num_chapters,
                        status: node.status, averageScore: node.mean.map { Int($0 * 10) },
                        genres: node.genres?.map { $0.name }, season: nil, seasonYear: nil,
                        nextAiringEpisode: nil, relations: nil, type: "MANGA", format: node.media_type)
                    return LibraryEntry(
                        id: node.id, media: media,
                        status: MALMangaLibraryService.shared.mapStatusFromMAL(e.list_status.status),
                        progress: e.list_status.num_chapters_read ?? 0,
                        score: Double(e.list_status.score ?? 0), updatedAt: nil,
                        customListName: nil, timesRewatched: e.list_status.num_times_reread)
                }
            default:
                return []
            }
        }
    }

    private func applyFilter() {
        if let listName = selectedCustomList {
            if isLocal {
                let uids = Set(LocalLibraryManager.shared.collections.first { $0.name == listName }?.mediaUniqueIds ?? [])
                entries = allEntries.filter { uids.contains($0.media.uniqueId) }
            } else {
                entries = allEntries.filter { $0.customListName == listName }
            }
        } else {
            entries = allEntries.filter { $0.status == selectedStatus && $0.customListName == nil }
        }
    }
}
