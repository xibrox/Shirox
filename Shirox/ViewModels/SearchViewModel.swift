import Foundation
import Combine

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var moduleResults: [SearchItem] = []
    @Published var aniListResults: [Media] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var query = ""
    @Published var hasSearched = false

    private(set) var isUsingModule = false
    private var searchTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init() {
        ProviderManager.shared.$orderedProviders
            .map { $0.first?.providerType }
            .removeDuplicates { $0 == $1 }
            .dropFirst()
            .sink { [weak self] _ in self?.clearResults() }
            .store(in: &cancellables)
    }

    func search(usingModule: Bool) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { clearResults(); return }
        searchTask?.cancel()
        isUsingModule = usingModule
        hasSearched = true
        isLoading = true
        errorMessage = nil
        moduleResults = []
        aniListResults = []
        searchTask = Task {
            do {
                if usingModule {
                    let res = try await JSEngine.shared.search(keyword: q)
                    if !Task.isCancelled {
                        var seen = Set<String>()
                        moduleResults = res.filter { seen.insert($0.href).inserted }
                        aniListResults = []
                    }
                } else {
                    let res = try await ProviderManager.shared.call { try await $0.search(q) }
                    if !Task.isCancelled {
                        var seen = Set<String>()
                        aniListResults = res.filter { seen.insert($0.uniqueId).inserted }
                        moduleResults = []
                    }
                }
            } catch {
                if !Task.isCancelled {
                    errorMessage = error.localizedDescription
                }
            }
            if !Task.isCancelled {
                isLoading = false
            }
        }
    }

    func clearResults() {
        searchTask?.cancel()
        searchTask = nil
        moduleResults = []
        aniListResults = []
        isLoading = false
        errorMessage = nil
        hasSearched = false
    }

    var hasResults: Bool { !moduleResults.isEmpty || !aniListResults.isEmpty }
    var resultCount: Int { moduleResults.count + aniListResults.count }
}
