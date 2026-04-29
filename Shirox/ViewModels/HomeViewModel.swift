import Foundation

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var trending: [Media] = []
    @Published var seasonal: [Media] = []
    @Published var popular: [Media] = []
    @Published var topRated: [Media] = []
    @Published var isLoading = false
    @Published var error: String?

    private var loaded = false

    func load() async {
        guard !loaded else { return }
        isLoading = true
        error = nil

        do {
            async let t = ProviderManager.shared.call { try await $0.trending() }
            async let s = ProviderManager.shared.call { try await $0.seasonal() }
            async let p = ProviderManager.shared.call { try await $0.popular() }
            async let r = ProviderManager.shared.call { try await $0.topRated() }

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
