import Foundation

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published var entries: [LibraryEntry] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var selectedStatus: MediaListStatus = .current

    private var cache: [MediaListStatus: [LibraryEntry]] = [:]

    func load() async {
        guard let userId = AniListAuthManager.shared.userId else {
            await AniListAuthManager.shared.fetchViewer()
            guard let uid = AniListAuthManager.shared.userId else { return }
            await fetch(status: selectedStatus, userId: uid)
            return
        }
        await fetch(status: selectedStatus, userId: userId)
    }

    func selectStatus(_ status: MediaListStatus) async {
        selectedStatus = status
        if let cached = cache[status] {
            entries = cached
            return
        }
        await load()
    }

    func refresh() async {
        cache[selectedStatus] = nil
        await load()
    }

    func update(entry: LibraryEntry, status: MediaListStatus, progress: Int, score: Double) async {
        do {
            try await AniListLibraryService.shared.updateEntry(
                mediaId: entry.media.id,
                status: status,
                progress: progress,
                score: score
            )
            cache[entry.status] = nil
            cache[status] = nil
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func fetch(status: MediaListStatus, userId: Int) async {
        isLoading = true
        error = nil
        do {
            let result = try await AniListLibraryService.shared.fetchList(status: status, userId: userId)
            cache[status] = result
            entries = result
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}
