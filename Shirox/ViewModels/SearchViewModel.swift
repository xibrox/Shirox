import Foundation

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var moduleResults: [SearchItem] = []
    @Published var aniListResults: [AniListMedia] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var query = ""
    @Published var hasSearched = false

    private(set) var isUsingModule = false
    private var searchTask: Task<Void, Never>?

    func search(usingModule: Bool) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { clearResults(); return }
        searchTask?.cancel()
        isUsingModule = usingModule
        hasSearched = true
        isLoading = true
        errorMessage = nil
        searchTask = Task {
            do {
                if usingModule {
                    let res = try await JSEngine.shared.search(keyword: q)
                    if !Task.isCancelled {
                        moduleResults = res
                        aniListResults = []
                    }
                } else {
                    let res = try await AniListService.shared.search(keyword: q)
                    if !Task.isCancelled {
                        aniListResults = res
                        moduleResults = []
                    }
                }
            } catch {
                if !Task.isCancelled {
                    errorMessage = error.localizedDescription
                }
            }
            isLoading = false
        }
    }

    func clearResults() {
        moduleResults = []
        aniListResults = []
        errorMessage = nil
        hasSearched = false
    }

    var hasResults: Bool { !moduleResults.isEmpty || !aniListResults.isEmpty }
    var resultCount: Int { moduleResults.count + aniListResults.count }
}
