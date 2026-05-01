import Foundation
import Combine

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var trending: [Media] = []
    @Published var seasonal: [Media] = []
    @Published var popular: [Media] = []
    @Published var topRated: [Media] = []
    @Published var isLoading = false
    @Published var error: String?

    private var loaded = false
    private var cancellables = Set<AnyCancellable>()
    private var currentPrimaryType: ProviderType?

    init() {
        ProviderManager.shared.$orderedProviders
            .map { $0.first?.providerType }
            .removeDuplicates { $0 == $1 }
            .dropFirst() // skip initial value — load() is called by the view's .task
            .sink { [weak self] _ in
                guard let self else { return }
                Task { await self.reload() }
            }
            .store(in: &cancellables)
    }

    func load() async {
        guard !loaded else { return }
        isLoading = true
        error = nil

        do {
            // Jikan (MAL) enforces ~3 req/s; load sequentially to avoid 429s.
            // AniList supports concurrent requests, so detect provider type first.
            let isMAL = ProviderManager.shared.primary?.providerType == .mal
            if isMAL {
                trending = try await ProviderManager.shared.call { try await $0.trending() }
                try await Task.sleep(nanoseconds: 400_000_000)
                seasonal = try await ProviderManager.shared.call { try await $0.seasonal() }
                try await Task.sleep(nanoseconds: 400_000_000)
                popular = try await ProviderManager.shared.call { try await $0.popular() }
                try await Task.sleep(nanoseconds: 400_000_000)
                topRated = try await ProviderManager.shared.call { try await $0.topRated() }
            } else {
                async let t = ProviderManager.shared.call { try await $0.trending() }
                async let s = ProviderManager.shared.call { try await $0.seasonal() }
                async let p = ProviderManager.shared.call { try await $0.popular() }
                async let r = ProviderManager.shared.call { try await $0.topRated() }
                let (tResult, sResult, pResult, rResult) = try await (t, s, p, r)
                trending = tResult
                seasonal = sResult
                popular = pResult
                topRated = rResult
            }
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
