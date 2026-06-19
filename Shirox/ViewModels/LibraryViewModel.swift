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
            try await dataSource.updateEntry(media: entry.media, status: status,
                                              progress: progress, score: score)
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
            try await dataSource.deleteEntry(entry)
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
            let result = try await dataSource.fetchLibrary()
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
