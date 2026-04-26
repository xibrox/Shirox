import Foundation

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

    func load() async {
        guard let userId = AniListAuthManager.shared.userId else {
            await AniListAuthManager.shared.fetchViewer()
            guard let uid = AniListAuthManager.shared.userId else { return }
            await fetch(userId: uid)
            return
        }
        await fetch(userId: userId)
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
        // 1. Optimistic update: apply changes immediately to local state
        if let index = allEntries.firstIndex(where: { $0.media.id == entry.media.id }) {
            allEntries[index].status = status
            allEntries[index].progress = progress
            allEntries[index].score = score
            applyFilter()
        }

        do {
            try await AniListLibraryService.shared.updateEntry(
                mediaId: entry.media.id,
                status: status,
                progress: progress,
                score: score
            )
            
            // Mark cache as invalid so next manual refresh or navigation gets fresh data,
            // but don't immediately call load() to avoid stale data flicker from AniList lag.
            cacheValid = false
            
            // Optional: Background refresh after a short delay to get final server state (ids, timestamps)
            // For now, we trust our local state until the next manual refresh or view appearance.
        } catch {
            self.error = error.localizedDescription
            // On error, we should probably revert the optimistic update or force a reload
            cacheValid = false
            await load()
        }
    }

    // MARK: - Private

    private func fetch(userId: Int) async {
        if cacheValid {
            applyFilter()
            return
        }
        
        // Only show full-screen loader if we have no entries at all
        if allEntries.isEmpty {
            isLoading = true
        }
        
        error = nil
        do {
            let result = try await AniListLibraryService.shared.fetchAllLists(userId: userId)
            allEntries = result
            cacheValid = true
            // Collect sorted custom list names
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
