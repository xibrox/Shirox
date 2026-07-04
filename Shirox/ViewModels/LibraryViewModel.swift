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
        }
    }

    var isLocal: Bool { if case .local = source { return true }; return false }

    /// Sorted unique custom list names from the full library
    @Published var customListNames: [String] = []

    private var allEntries: [LibraryEntry] = []
    private var cacheValid = false
    private var lastFetchedAt: Date?
    private let minAutoRefreshInterval: TimeInterval = 30
    private var cancellables = Set<AnyCancellable>()

    init() {
        // Logged-out users have no provider library, so start on the on-device source.
        // Setting this up front (rather than deferring to an .onAppear) keeps the Library's
        // searchable content present from the first render, so the search bar stays attached
        // to the navigation bar across push/pop.
        if !AniListAuthManager.shared.isLoggedIn && !MALAuthManager.shared.isLoggedIn {
            source = .local
        }

        ProviderManager.shared.$orderedProviders
            .map { $0.first?.providerType }
            .removeDuplicates { $0 == $1 }
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, case .provider = self.source else { return }
                Task { await self.refresh() }
            }
            .store(in: &cancellables)

        LocalLibraryManager.shared.$entries
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, self.isLocal else { return }
                self.cacheValid = false
                Task { await self.load() }
            }
            .store(in: &cancellables)

        LocalLibraryManager.shared.$collections
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, self.isLocal else { return }
                self.customListNames = LocalLibraryManager.shared.collections.map(\.name).sorted()
                self.applyFilter()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .remoteLibraryProgressDidPush)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.lastFetchedAt = nil
                    self?.cacheValid = false
                }
            }
            .store(in: &cancellables)
    }

    func load() async {
        await fetch()
    }

    func selectStatus(_ status: MediaListStatus) {
        selectedStatus = status
        selectedCustomList = nil
        applyFilter()
    }

    func selectCustomList(_ name: String?) {
        selectedCustomList = name
        applyFilter()
    }

    func selectSource(_ source: LibrarySource) {
        guard self.source != source else { return }
        self.source = source
        selectedCustomList = nil
        selectedStatus = .current
        cacheValid = false
        Task { await load() }
    }

    func selectMediaType(_ kind: MediaKind) {
        guard mediaType != kind else { return }
        mediaType = kind
        selectedCustomList = nil
        selectedStatus = .current
        cacheValid = false
        Task { await load() }
    }

    func refresh() async {
        cacheValid = false
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.load() }
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
            cacheValid = false
        } catch {
            self.error = error.localizedDescription
            cacheValid = false
            await load()
        }
    }

    func delete(entry: LibraryEntry) async {
        allEntries.removeAll { $0.media.uniqueId == entry.media.uniqueId }
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
            cacheValid = false
        } catch {
            self.error = error.localizedDescription
            cacheValid = false
            await load()
        }
    }

    func autoRefreshIfNeeded() async {
        if let last = lastFetchedAt, Date().timeIntervalSince(last) < minAutoRefreshInterval {
            return
        }
        let silent = !allEntries.isEmpty
        cacheValid = false
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

    private func fetch(silent: Bool = false) async {
        if cacheValid { applyFilter(); return }
        if allEntries.isEmpty && !silent { isLoading = true }
        if !silent { error = nil }
        do {
            let result: [LibraryEntry]
            if mediaType == .manga {
                result = try await fetchMangaLibrary()
            } else {
                result = try await dataSource.fetchLibrary()
            }
            allEntries = result
            cacheValid = true
            lastFetchedAt = Date()
            if isLocal {
                customListNames = LocalLibraryManager.shared.collections.map(\.name).sorted()
            } else {
                var seen = Set<String>()
                customListNames = result.compactMap { $0.customListName }.filter { seen.insert($0).inserted }.sorted()
                UserDefaults.standard.set(customListNames, forKey: "libraryCustomListNames")
            }
            applyFilter()
        } catch {
            if !silent { self.error = error.localizedDescription }
        }
        if !silent { isLoading = false }
    }

    /// Fetches the manga library for the current source. Local reads the on-device
    /// store (filtered to manga); AniList/MAL fetch their MANGA lists directly
    /// (read-only display path — no provider fallback machinery needed for v1).
    private func fetchMangaLibrary() async throws -> [LibraryEntry] {
        switch source {
        case .local:
            return LocalLibraryManager.shared.entries.filter { $0.media.isManga }
        case .provider(let type):
            switch type {
            case .anilist:
                guard let userId = await AniListAuthManager.shared.userId else { return [] }
                let raw = try await AniListLibraryService.shared.fetchAllLists(userId: userId, type: .manga)
                return raw.map { r in
                    let m = r.media   // AniListMedia
                    // Build a manga-tagged Media directly so `isManga` is reliable and the
                    // chapter total (episodes field) is populated from `chapters`.
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
                        timesRewatched: r.repeat)
                }
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
