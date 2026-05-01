import Foundation
import Combine

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published var entries: [LibraryEntry] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var selectedStatus: MediaListStatus = .current
    @Published var selectedCustomList: String? = nil

    /// Sorted unique custom list names from the full library
    @Published var customListNames: [String] = []

    private var allEntries: [LibraryEntry] = []
    private var cacheValid = false
    private var cancellables = Set<AnyCancellable>()

    init() {
        ProviderManager.shared.$orderedProviders
            .map { $0.first?.providerType }
            .removeDuplicates { $0 == $1 }
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                Task { await self.refresh() }
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

    func refresh() async {
        cacheValid = false
        await load()
    }

    func update(entry: LibraryEntry, status: MediaListStatus, progress: Int, score: Double) async {
        if let index = allEntries.firstIndex(where: { $0.media.uniqueId == entry.media.uniqueId }) {
            allEntries[index].status = status
            allEntries[index].progress = progress
            allEntries[index].score = score
            applyFilter()
        }
        do {
            try await ProviderManager.shared.call {
                try await $0.updateEntry(mediaId: entry.media.id, status: status,
                                         progress: progress, score: score)
            }
            cacheValid = false
        } catch {
            self.error = error.localizedDescription
            cacheValid = false
            await load()
        }
    }

    // MARK: - Private

    private func fetch() async {
        if cacheValid { applyFilter(); return }
        if allEntries.isEmpty { isLoading = true }
        error = nil
        do {
            let result = try await ProviderManager.shared.call { try await $0.fetchLibrary() }
            allEntries = result
            cacheValid = true
            var seen = Set<String>()
            customListNames = result.compactMap { $0.customListName }.filter { seen.insert($0).inserted }.sorted()
            UserDefaults.standard.set(customListNames, forKey: "libraryCustomListNames")
            applyFilter()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func applyFilter() {
        if let customList = selectedCustomList {
            entries = allEntries.filter { $0.customListName == customList }
        } else {
            entries = allEntries.filter { $0.status == selectedStatus && $0.customListName == nil }
        }
    }
}
