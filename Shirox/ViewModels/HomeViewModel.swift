import Foundation

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var trending: [AniListMedia] = []
    @Published var seasonal: [AniListMedia] = []
    @Published var popular: [AniListMedia] = []
    @Published var topRated: [AniListMedia] = []
    @Published var isLoading = false
    @Published var error: String?

    private var loaded = false

    func load() async {
        guard !loaded else { return }
        isLoading = true
        error = nil

        do {
            async let t = AniListService.shared.trending()
            async let s = AniListService.shared.seasonal()
            async let p = AniListService.shared.popular()
            async let r = AniListService.shared.topRated()

            let (tResult, sResult, pResult, rResult) = try await (t, s, p, r)
            trending = tResult
            seasonal = sResult
            popular = pResult
            topRated = rResult
            loaded = true
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    func reload() async {
        loaded = false
        await load()
    }
}
