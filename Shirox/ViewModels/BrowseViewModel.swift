import Foundation

@MainActor
final class BrowseViewModel: ObservableObject {
    let category: BrowseCategory

    @Published var items: [Media] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var hasMore = true

    private var currentPage = 0

    init(category: BrowseCategory) {
        self.category = category
    }

    func loadMore() async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        error = nil
        let nextPage = currentPage + 1
        do {
            let aniListItems = try await AniListService.shared.browse(category: category, page: nextPage)
            let newItems = aniListItems.map { AniListProvider.shared.mapMedia($0) }
            items.append(contentsOf: newItems)
            currentPage = nextPage
            if newItems.count < 20 { hasMore = false }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func retry() async {
        error = nil
        hasMore = true
        await loadMore()
    }
}
